-- ============================================================
-- 庫存承諾量收斂：_sku_commitment（唯一算法來源）＋ _sku_free_qty（自由量）
-- 併修 _grow_internal_pool 的抵減單負數 bug
--
-- 動機（見 docs/PLAN-現貨直配與承諾收斂.md §3）：
--   「某店某 SKU 被承諾掉多少、還剩多少自由量」這條算式目前 inline 抄在
--   至少四支函式裡（_grow_internal_pool / _trim_internal_pool /
--   _advance_arrived_confirmed_orders / _settle_arrived_backorders），
--   口徑各有細微差異。過去一個月至少四起事故同根因（忠順池子掛 ×10、
--   會員未結金額多算 482 萬、松山 backorder 卡 6 天、盤壞帳 395→79→26
--   組兩次誤判）。接下來的現貨直配（rpc_create_spot_sale）需要同一條算式
--   當可配量閘門 —— 與其抄第五份，先收斂。
--
-- 逐字比對四支現行版本後的結論（差異是刻意的，不能硬統一成單一數字）：
--   promised     ：_grow / _trim / _advance 三支同一套。
--   promised_active：_settle 多一個 backorder_at IS NULL —— 待補貨列
--                  本來就是「還沒配到貨」，算進已承諾等於自己擋自己，
--                  整支會永遠解不開任何一列（20260811000050 檔頭）。
--   waiting      ：只有 _grow 用（confirmed 一般單還在等貨的需求）。
--   pool_claimed ：_grow 用 —— 含在途 RR-（單頭 pending/confirmed）。
--                  避免對同一批還沒到的貨重複掛帳。
--   pool_arrived ：_trim 用 —— 只吃 ready/partially_completed。
--                  RR- 在補貨到店前就存在，把在途的算進來等於拿還在路上的
--                  貨沖銷已交付量（20260811000040）。
--   → 所以本函式回**分項**，不回單一數字；組合方式留給呼叫端。
--
-- ★ 順帶修掉一個 latent bug（_grow_internal_pool）：
--   它的 pool 條件是 co.status NOT IN ('cancelled','expired','transferred_out',
--   'completed')，**沒有排除 order_kind='offset'、也沒有 qty > 0**。而抵減單
--   （-OFF 單）掛在 store_internal 假會員名下、單頭是 confirmed、品項 qty 是
--   負數 —— 正好全部落在那個範圍。結果 pool 被灌成負的 → 自由量虛增 →
--   收貨多給時把不存在的貨掛進 OV- 池子（幽靈庫存）。
--   線上實測 2026-08-16：35 組 (店,SKU) 受影響、合計虛增 112 件
--   （最大一筆：中和店 sku 4729 灌水 30 件）。
--   本次 _sku_commitment 一律 qty > 0 ＋ pool 排除 offset，_grow 換用後
--   行為改變 = 少掛那 112 件（這是修正，不是 regression）。
--   _trim 本來就有 qty > 0，_advance / _settle 的 promised 已排除 offset ＋
--   store_internal，故那三支的口徑不受此修正影響（見下方等價性驗證）。
--
-- 等價性驗證（部署後立刻跑，見檔尾 §4 的 SQL）：
--   對全站每個 (店, SKU) 比對「本函式的分項」與「各呼叫端原本 inline 的算法」，
--   promised / promised_active / waiting / pool_arrived 必須逐筆相等；
--   pool_claimed 只允許在上述 35 組出現差異，且差額 = 負數 offset 量。
--
-- 基底版本：
--   _grow_internal_pool = 20260814010000（唯一版本，本次改寫）
--   _trim_internal_pool = 20260811000040（本次不動，下一支 migration 再換）
--   _advance_arrived_confirmed_orders = 20260813020000（本次不動）
--   _settle_arrived_backorders = 20260811000050（本次不動）
--   * 後三支是**零行為變更**的純去重，與本次的 bug 修正無關；分開上線才能
--     讓「行為有變」與「行為沒變」兩件事各自可回溯、可 rollback。
--
-- rollback:
--   重跑 20260814010000 的 _grow_internal_pool（會退回含 bug 的版本）；
--   DROP FUNCTION IF EXISTS public._sku_free_qty(BIGINT, BIGINT);
--   DROP FUNCTION IF EXISTS public._sku_commitment(BIGINT, BIGINT[]);
-- ============================================================

-- ------------------------------------------------------------
-- 1. _sku_commitment — 某店（可限定 SKU 集合）的承諾量分項
--    set-returning 且**單趟 GROUP BY**：_advance_arrived_confirmed_orders
--    在 20260813(3) 特地把 per-SKU LATERAL 改成一次 GROUP BY（文山 1,704 張
--    單 × ~5ms ≈ 8.5s，PostgREST 8s 直接 timeout）。這裡沿用單趟形狀，
--    之後那支換過來才不會把效能 regression 種回去。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sku_commitment(
  p_store_id BIGINT,
  p_sku_ids  BIGINT[] DEFAULT NULL
) RETURNS TABLE (
  sku_id          BIGINT,
  promised        NUMERIC,   -- 對客人的承諾（未取）
  promised_active NUMERIC,   -- 同上但排除待補貨列（_settle 用）
  waiting         NUMERIC,   -- confirmed 一般單還在等貨的需求
  pool_claimed    NUMERIC,   -- 內部店容器單未取量（含在途 RR-）
  pool_arrived    NUMERIC    -- 內部店容器單未取量（只算已到貨）
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH s AS (
    SELECT st.tenant_id, st.id AS store_id
      FROM stores st WHERE st.id = p_store_id
  ),
  base AS (
    -- 一次撈完該店所有未取品項，後面用 FILTER 切分項（單趟掃描）
    SELECT coi.sku_id                          AS s_sku,
           co.status                           AS ord_status,
           COALESCE(co.order_kind, 'normal')   AS kind,
           COALESCE(m.member_type, '')         AS mtype,
           coi.qty                             AS qty,
           coi.backorder_at                    AS backorder_at
      FROM s
      JOIN customer_orders co
        ON co.tenant_id       = s.tenant_id
       AND co.pickup_store_id = s.store_id
      JOIN customer_order_items coi
        ON coi.order_id = co.id
      LEFT JOIN members m ON m.id = co.member_id
     WHERE coi.status IN ('pending', 'reserved', 'ready')
       -- qty > 0：全站唯一的非正數品項是抵減單（offset ＋ store_internal，
       -- 2026-08-16 實測 49 列）。對 promised / waiting 是 no-op（那兩者本來
       -- 就排除 offset），對 pool_claimed 則是修掉負數灌水（見檔頭）。
       AND coi.qty > 0
       AND (p_sku_ids IS NULL OR coi.sku_id = ANY (p_sku_ids))
  )
  SELECT
    b.s_sku,
    COALESCE(SUM(b.qty) FILTER (
      WHERE b.ord_status IN ('ready', 'partially_completed', 'shipping')
        AND b.kind  <> 'offset'
        AND b.mtype <> 'store_internal'), 0),
    COALESCE(SUM(b.qty) FILTER (
      WHERE b.ord_status IN ('ready', 'partially_completed', 'shipping')
        AND b.kind  <> 'offset'
        AND b.mtype <> 'store_internal'
        AND b.backorder_at IS NULL), 0),
    COALESCE(SUM(b.qty) FILTER (
      WHERE b.ord_status = 'confirmed'
        AND b.kind  =  'normal'
        AND b.mtype <> 'store_internal'), 0),
    COALESCE(SUM(b.qty) FILTER (
      WHERE b.ord_status NOT IN ('cancelled', 'expired', 'transferred_out', 'completed')
        AND b.mtype =  'store_internal'
        AND b.kind  <> 'offset'), 0),
    COALESCE(SUM(b.qty) FILTER (
      WHERE b.ord_status IN ('ready', 'partially_completed')
        AND b.mtype =  'store_internal'
        AND b.kind  <> 'offset'), 0)
    FROM base b
   GROUP BY b.s_sku;
$$;

COMMENT ON FUNCTION public._sku_commitment(BIGINT, BIGINT[]) IS
  '某店（可限定 SKU）的庫存承諾量分項 —— 全站唯一算法來源。'
  'promised=對客人承諾未取；promised_active=同上但排除待補貨列（_settle 用）；'
  'waiting=confirmed 一般單等貨需求；pool_claimed=內部店容器含在途（_grow 用）；'
  'pool_arrived=內部店容器只算已到貨（_trim 用）。'
  '分項刻意不合併成單一數字：各呼叫端的組合本來就不同，硬統一會製造新 bug。'
  '新增任何「把貨配出去」的路徑一律呼叫本函式，不要再 inline 抄一份。';

REVOKE ALL ON FUNCTION public._sku_commitment(BIGINT, BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._sku_commitment(BIGINT, BIGINT[]) TO authenticated, service_role;

-- ------------------------------------------------------------
-- 2. _sku_free_qty — 自由量（沒有任何訂單掛著的貨）
--    ＝ on_hand − promised − waiting − pool_claimed，下限 0。
--    這就是 _grow_internal_pool 的目標水位，也是現貨直配
--    （rpc_create_spot_sale）的可配量上限：兩者問的是同一個問題
--    「這批貨還有幾件沒有主人」。
--    ⚠ 不要改用 stock_balances.reserved —— 那一欄全站實際上沒在維護承諾量。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sku_free_qty(
  p_store_id BIGINT,
  p_sku_id   BIGINT
) RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- _sku_commitment 只呼叫一次（LEFT JOIN LATERAL：該 SKU 完全沒有任何
  -- 承諾時它不回列，這時三個分項都當 0）
  SELECT GREATEST(
           COALESCE(oh.on_hand, 0)
           - COALESCE(c.promised, 0)
           - COALESCE(c.waiting, 0)
           - COALESCE(c.pool_claimed, 0),
           0)
    FROM (
      SELECT sb.on_hand
        FROM stores st
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = st.tenant_id
              AND sb.location_id = st.location_id
              AND sb.sku_id      = p_sku_id
       WHERE st.id = p_store_id
    ) oh
    LEFT JOIN LATERAL public._sku_commitment(p_store_id, ARRAY[p_sku_id]) c ON TRUE;
$$;

COMMENT ON FUNCTION public._sku_free_qty(BIGINT, BIGINT) IS
  '某店某 SKU 的自由量＝on_hand − promised − waiting − pool_claimed（下限 0）：'
  '帳上有、但沒有任何訂單掛著的貨。_grow_internal_pool 的目標水位、'
  '現貨直配 rpc_create_spot_sale 的可配量上限。';

REVOKE ALL ON FUNCTION public._sku_free_qty(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._sku_free_qty(BIGINT, BIGINT) TO authenticated, service_role;

-- ------------------------------------------------------------
-- 3. _grow_internal_pool 換用 _sku_commitment
--    （基底 20260814010000 逐字保留，只把開頭三段 inline SELECT
--      換成一次 _sku_commitment 呼叫；掛帳段完全不動）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._grow_internal_pool(
  p_store_id BIGINT,
  p_sku_id   BIGINT,
  p_max_grow NUMERIC,
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW(),
  p_tag      TEXT DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID;
  v_loc        BIGINT;
  v_grow       NUMERIC;
  v_order_id   BIGINT;
  v_campaign   BIGINT;
  v_ci         BIGINT;
  v_price      NUMERIC;
BEGIN
  IF p_max_grow IS NULL OR p_max_grow <= 0 THEN
    RETURN 0;
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;
  END IF;

  -- 自由量 = on_hand − 已承諾未取 − confirmed 未配需求 − 池子未取（含在途）。
  -- 比 trim 的目標水位多扣「confirmed 未配需求」：還沒配到貨的客人單
  -- 下一批就要吃這批貨，先掛進池子會被轉走 ——「8 位團友撲空」的鏡像版。
  -- LEAST(p_max_grow, ...)：只掛本批造成的自由量，不順手做全域收斂。
  v_grow := LEAST(p_max_grow, public._sku_free_qty(p_store_id, p_sku_id));

  IF v_grow <= 0 THEN
    RETURN 0;
  END IF;

  v_order_id := public._get_or_create_surplus_pool_order(p_store_id, p_operator, p_at);
  SELECT campaign_id INTO v_campaign FROM customer_orders WHERE id = v_order_id;

  -- 品項單價：分店價（branch）優先、退 retail、再退 0 —— 池子單價本來就只是
  -- 掛帳顯示，轉單給真會員時 rpc_transfer_order_partial 會改鎖當下現售價。
  SELECT price INTO v_price
    FROM prices
   WHERE tenant_id = v_tenant AND sku_id = p_sku_id AND scope = 'branch'
     AND effective_from <= p_at AND (effective_to IS NULL OR effective_to > p_at)
   ORDER BY effective_from DESC
   LIMIT 1;
  IF v_price IS NULL THEN
    SELECT price INTO v_price
      FROM prices
     WHERE tenant_id = v_tenant AND sku_id = p_sku_id AND scope = 'retail'
       AND effective_from <= p_at AND (effective_to IS NULL OR effective_to > p_at)
     ORDER BY effective_from DESC
     LIMIT 1;
  END IF;
  v_price := COALESCE(v_price, 0);

  v_ci := public._restock_sentinel_campaign_item(v_tenant, v_campaign, p_sku_id, v_price);

  -- 一批一列（notes 帶來源 tag），退回收貨才對得到帳；不跟既有列合併。
  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant, v_order_id, v_ci, p_sku_id, v_grow, v_price,
    'pending', 'store_internal', p_tag, p_operator, p_operator, p_at, p_at
  );

  UPDATE customer_orders
     SET updated_by = p_operator, updated_at = p_at
   WHERE id = v_order_id;

  RETURN v_grow;
END;
$$;

COMMENT ON FUNCTION public._grow_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT) IS
  '收貨多給掛進【內部】xx 店現貨池（_trim_internal_pool 的鏡像）：'
  'grow = LEAST(p_max_grow, _sku_free_qty(店, SKU))。'
  '掛到 OV- 容器單（_get_or_create_surplus_pool_order），品項 notes 帶 p_tag。'
  '20260816000000：承諾量改走 _sku_commitment（唯一算法來源），'
  '併修 pool 未排除 offset 負數導致自由量虛增的 bug（線上 35 組 / 112 件）。'
  '回傳實際掛進去的數量。';

GRANT EXECUTE ON FUNCTION public._grow_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ, TEXT)
  TO authenticated, service_role;

-- ============================================================
-- 4. 等價性驗證（部署後手動跑，不放進 migration 交易）
--
-- (a) promised / promised_active / waiting / pool_arrived 必須與各呼叫端
--     原本 inline 的算法逐筆相等 —— 預期回 0 列：
--
-- WITH c AS (
--   SELECT st.id AS store_id, k.*
--     FROM stores st, LATERAL public._sku_commitment(st.id) k
--    WHERE st.is_active
-- ), legacy AS (
--   SELECT co.pickup_store_id AS store_id, coi.sku_id,
--     SUM(coi.qty) FILTER (WHERE co.status IN ('ready','partially_completed','shipping')
--        AND COALESCE(co.order_kind,'normal') <> 'offset'
--        AND COALESCE(m.member_type,'') <> 'store_internal')                    AS promised,
--     SUM(coi.qty) FILTER (WHERE co.status IN ('ready','partially_completed','shipping')
--        AND COALESCE(co.order_kind,'normal') <> 'offset'
--        AND COALESCE(m.member_type,'') <> 'store_internal'
--        AND coi.backorder_at IS NULL)                                          AS promised_active,
--     SUM(coi.qty) FILTER (WHERE co.status = 'confirmed'
--        AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
--        AND COALESCE(m.member_type,'') <> 'store_internal')                    AS waiting,
--     SUM(coi.qty) FILTER (WHERE co.status IN ('ready','partially_completed')
--        AND m.member_type = 'store_internal' AND coi.qty > 0)                  AS pool_arrived
--   FROM customer_orders co
--   JOIN customer_order_items coi ON coi.order_id = co.id
--   LEFT JOIN members m ON m.id = co.member_id
--  WHERE coi.status IN ('pending','reserved','ready')
--  GROUP BY 1,2
-- )
-- SELECT * FROM c FULL JOIN legacy l USING (store_id, sku_id)
--  WHERE COALESCE(c.promised,0)        <> COALESCE(l.promised,0)
--     OR COALESCE(c.promised_active,0) <> COALESCE(l.promised_active,0)
--     OR COALESCE(c.waiting,0)         <> COALESCE(l.waiting,0)
--     OR COALESCE(c.pool_arrived,0)    <> COALESCE(l.pool_arrived,0);
--
-- (b) pool_claimed 的差異必須「只出現在有負數 offset 的那 35 組」，
--     且差額剛好等於被排除的負數量 —— 預期回 0 列：
--
-- WITH c AS (
--   SELECT st.id AS store_id, k.sku_id, k.pool_claimed
--     FROM stores st, LATERAL public._sku_commitment(st.id) k WHERE st.is_active
-- ), legacy AS (
--   SELECT co.pickup_store_id AS store_id, coi.sku_id, SUM(coi.qty) AS pool_claimed
--     FROM customer_orders co
--     JOIN customer_order_items coi ON coi.order_id = co.id
--     JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
--    WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed')
--      AND coi.status IN ('pending','reserved','ready')
--    GROUP BY 1,2
-- ), neg AS (
--   SELECT co.pickup_store_id AS store_id, coi.sku_id, SUM(coi.qty) AS neg
--     FROM customer_orders co
--     JOIN customer_order_items coi ON coi.order_id = co.id
--     JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
--    WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed')
--      AND coi.status IN ('pending','reserved','ready') AND coi.qty < 0
--    GROUP BY 1,2
-- )
-- SELECT * FROM c FULL JOIN legacy l USING (store_id, sku_id)
--                 LEFT JOIN neg     n USING (store_id, sku_id)
--  WHERE COALESCE(c.pool_claimed,0) - COALESCE(l.pool_claimed,0)
--        IS DISTINCT FROM -COALESCE(n.neg,0);
-- ============================================================

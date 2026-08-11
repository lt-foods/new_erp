-- ============================================================
-- 2026-08-11 (4)：自動配單之後，【內部】xx 店的現貨池要跟著扣掉
--
-- 承 20260811000020。那一版讓補貨路線發的團在收貨時自動配單
--（confirmed → ready），但**沒有動 ride-along 的 RR- 內部單** ——
-- 忠順店回報：今天進 10 包鮭魚頭、客人訂單 8 包已經配掉了，
-- 內部店庫存單卻還是掛著 ×10，應該要只剩 2。
--
-- 為什麼一定要修（不只是畫面難看）：
--   RR- 單就是店端的現貨池帳本，轉單給客人時會從它身上扣
--   （rpc_transfer_order_partial：等量 → 整行 cancelled、部分 → qty 遞減）。
--   池子沒扣＝店員看到還有 10 包可以轉，實際上其中 8 包已經是團購客人的貨，
--   全部轉出去就會有 8 位團友撲空，庫存也會被扣成負的。
--
-- 修法：新增 _trim_internal_pool(store, sku, max_trim, operator, at)，
--   把池子收斂到「可自由運用量 = on_hand − 對客人的承諾（未取）」，
--   且一次最多只扣 p_max_trim（＝本次配出去的量）：
--
--     trim = LEAST(p_max_trim, GREATEST(池子未取量 − (on_hand − 已承諾未取), 0))
--
--   兩層上限缺一不可：
--   * 用 GREATEST(..., 0) 夾住 → 貨是走該團自己的波次進來的（on_hand 同時
--     蓋得住池子和團購單）時 trim = 0，不會誤吃店家本來就有的現貨。
--   * 用 LEAST(p_max_trim, ...) 夾住 → 只收拾自己造成的超額。線上還有 395 組
--     (店, SKU) 的池子本來就超額掛帳（合計 2,804 件，多半是舊 RR 單沒收尾），
--     那是另一件事，不在這支的守備範圍，不要順手一起砍。
--
--   扣法比照 _settle_restock_ride_along：整行吃掉 → status='cancelled'；
--   只吃一部分 → 拆行（被配走的另開一列 cancelled 留痕，折扣按數量比例分攤），
--   一律標 '[已配給團購單]'。前端對 cancelled 列本來就會畫刪除線，
--   店家看得到「這 8 包去哪了」而不是憑空消失。
--
--   CLAUDE.md：任何把 customer_order_items 改成 cancelled 的路徑，
--   後面一律接 _close_orders_all_items_settled 收單頭。
--
-- 基底版本：
--   _advance_arrived_confirmed_orders = 20260811000020（逐字保留，只加
--   v_alloc 累計 + 尾巴呼叫 _trim_internal_pool）
--   rpc_receive_transfer 不動（它呼叫的是同一支 helper）。
--
-- 一次性修復：20260811000020 的回填已經把 133 張推成 ready、但沒扣池子，
--   本檔尾端用同一支 helper 針對那批 (店, SKU) 補扣一次。
--
-- Rollback：
--   CREATE OR REPLACE FUNCTION public._advance_arrived_confirmed_orders 回
--     20260811000020 的版本；
--   DROP FUNCTION IF EXISTS public._trim_internal_pool(BIGINT,BIGINT,NUMERIC,UUID,TIMESTAMPTZ);
--   池子扣減還原（拆行的要連原列 qty 一起加回去，建議逐張確認）：
--     SELECT * FROM customer_order_items WHERE notes LIKE '%[已配給團購單%';
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _trim_internal_pool — 把【內部】xx 店現貨池收斂到可自由運用量
--    回傳實際扣掉的數量。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._trim_internal_pool(
  p_store_id BIGINT,
  p_sku_id   BIGINT,
  p_max_trim NUMERIC,
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_pool_qty NUMERIC;
  v_on_hand  NUMERIC := 0;
  v_promised NUMERIC := 0;
  v_trim     NUMERIC;
  v_done     NUMERIC := 0;
  v_new_disc NUMERIC;
  v_pool     RECORD;
  v_touched  BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  IF p_max_trim IS NULL OR p_max_trim <= 0 THEN
    RETURN 0;
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;
  END IF;

  -- 池子目前掛著的未取量
  SELECT COALESCE(SUM(coi.qty), 0) INTO v_pool_qty
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status NOT IN ('cancelled','expired','transferred_out','completed')
     AND coi.sku_id = p_sku_id
     AND coi.status IN ('pending','reserved','ready');

  SELECT COALESCE(sb.on_hand, 0) INTO v_on_hand
    FROM stock_balances sb
   WHERE sb.tenant_id = v_tenant AND sb.location_id = v_loc AND sb.sku_id = p_sku_id;
  v_on_hand := COALESCE(v_on_hand, 0);

  -- 對客人的承諾（未取）；排除 store_internal 容器單與抵減單
  SELECT COALESCE(SUM(coi2.qty), 0) INTO v_promised
    FROM customer_orders co2
    JOIN customer_order_items coi2 ON coi2.order_id = co2.id
    LEFT JOIN members m2 ON m2.id = co2.member_id
   WHERE co2.tenant_id       = v_tenant
     AND co2.pickup_store_id = p_store_id
     AND co2.status IN ('ready','partially_completed','shipping')
     AND COALESCE(co2.order_kind, 'normal') <> 'offset'
     AND COALESCE(m2.member_type, '') <> 'store_internal'
     AND coi2.sku_id = p_sku_id
     AND coi2.status IN ('pending','reserved','ready');

  v_trim := LEAST(p_max_trim, GREATEST(v_pool_qty - (v_on_hand - v_promised), 0));
  IF v_trim <= 0 THEN
    RETURN 0;
  END IF;

  FOR v_pool IN
    SELECT coi.*
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
      JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
     WHERE co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.status NOT IN ('cancelled','expired','transferred_out','completed')
       AND coi.sku_id = p_sku_id
       AND coi.status IN ('pending','reserved','ready')
     ORDER BY co.created_at, coi.id
     FOR UPDATE OF coi
  LOOP
    EXIT WHEN v_trim <= 0;
    v_touched := v_touched || v_pool.order_id;

    IF v_pool.qty <= v_trim THEN
      -- 整行被配走
      UPDATE customer_order_items
         SET status     = 'cancelled',
             notes      = TRIM(BOTH E'\n' FROM COALESCE(notes || E'\n', '') || '[已配給團購單]'),
             updated_by = p_operator,
             updated_at = p_at
       WHERE id = v_pool.id;
      v_trim := v_trim - v_pool.qty;
      v_done := v_done + v_pool.qty;
    ELSE
      -- 只被配走一部分：拆行（折扣按數量比例分攤，同 20260805000100 / 20260810000000）
      v_new_disc := round(COALESCE(v_pool.discount_amount, 0) * v_trim / v_pool.qty);
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, notes, discount_amount, discount_percent,
        created_by, updated_by, created_at, updated_at
      ) VALUES (
        v_pool.tenant_id, v_pool.order_id, v_pool.campaign_item_id, v_pool.sku_id,
        v_trim, v_pool.unit_price,
        'cancelled', v_pool.source,
        TRIM(BOTH E'\n' FROM COALESCE(v_pool.notes || E'\n', '')
             || '[已配給團購單|拆分自#' || v_pool.id || ']'),
        v_new_disc, v_pool.discount_percent,
        p_operator, p_operator, p_at, p_at
      );
      UPDATE customer_order_items
         SET qty             = v_pool.qty - v_trim,
             discount_amount = COALESCE(v_pool.discount_amount, 0) - v_new_disc,
             updated_by      = p_operator,
             updated_at      = p_at
       WHERE id = v_pool.id;
      v_done := v_done + v_trim;
      v_trim := 0;
    END IF;
  END LOOP;

  -- CLAUDE.md：任何把品項改成 cancelled 的路徑，後面接單頭收尾
  --（池子被吃光的 RR- 單才結得掉，不然會卡在 ready / partially_completed）
  IF array_length(v_touched, 1) > 0 THEN
    PERFORM public._close_orders_all_items_settled(v_touched, p_operator, p_at);
  END IF;

  RETURN v_done;
END;
$$;

COMMENT ON FUNCTION public._trim_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ) IS
  '把【內部】xx 店現貨池（member_type=store_internal 的未取品項）收斂到 '
  'on_hand − 對客人的承諾，單次最多扣 p_max_trim 件。整行吃掉 → cancelled，'
  '部分 → 拆行留痕，一律標 [已配給團購單]。回傳實際扣掉的數量。';

GRANT EXECUTE ON FUNCTION public._trim_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 2. _advance_arrived_confirmed_orders — 配完單後收斂現貨池
--    （基底 20260811000020，逐字保留；只加 v_alloc 累計 + 尾巴呼叫）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._advance_arrived_confirmed_orders(
  p_store_id BIGINT,
  p_sku_ids  BIGINT[],
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_budget   JSONB   := '{}'::JSONB;   -- sku_id(text) → 尚可配數量
  v_alloc    JSONB   := '{}'::JSONB;   -- sku_id(text) → 本次實際配出去的量
  v_ord      RECORD;
  v_it       RECORD;
  v_fits     BOOLEAN;
  v_rem      NUMERIC;
  v_advanced INT := 0;
BEGIN
  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;

  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;   -- 沒設倉庫位置的店沒有 on_hand 可算，直接不動
  END IF;

  -- 可配量：本店現有庫存 − 已承諾未取量。
  -- 種子集合＝本店所有 confirmed 單的未取 SKU（不限 p_sku_ids）——
  -- 多品項的單要每一項都有預算才能推，所以預算表不能只放這次到貨的 SKU。
  SELECT COALESCE(jsonb_object_agg(b.sku_id::TEXT, b.avail), '{}'::JSONB)
    INTO v_budget
    FROM (
      SELECT sk.sku_id,
             COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0) AS avail
        FROM (
          SELECT DISTINCT coi.sku_id
            FROM customer_orders co
            JOIN customer_order_items coi ON coi.order_id = co.id
           WHERE co.tenant_id       = v_tenant
             AND co.pickup_store_id = p_store_id
             AND co.status          = 'confirmed'
             AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
             AND coi.status IN ('pending','reserved','ready')
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_loc
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN LATERAL (
          -- 已經被承諾、貨還沒交出去的量。排除 store_internal 會員的單
          --（RR- / 【內部】xx 店是現貨池容器，不是對客人的承諾）。
          SELECT SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = p_store_id
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.sku_id = sk.sku_id
             AND coi2.status IN ('pending','reserved','ready')
        ) pr ON TRUE
    ) b;

  IF v_budget = '{}'::JSONB THEN
    RETURN 0;
  END IF;

  -- 依下單時間由早到晚（同時間用單號決勝，與 20260805000070 同規則）
  FOR v_ord IN
    SELECT co.id
      FROM customer_orders co
     WHERE co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.status          = 'confirmed'
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       -- 便宜的前置篩：至少一項是這次到貨的 SKU、且店裡真的有帳上庫存。
       -- 先擋掉絕大多數候選，才輪到昂貴的 is_order_pickup_ready()。
       AND EXISTS (
         SELECT 1
           FROM customer_order_items coi
           JOIN stock_balances sb
             ON sb.tenant_id   = v_tenant
            AND sb.location_id = v_loc
            AND sb.sku_id      = coi.sku_id
            AND sb.on_hand     > 0
          WHERE coi.order_id = co.id
            AND coi.status IN ('pending','reserved','ready')
            AND (p_sku_ids IS NULL OR coi.sku_id = ANY (p_sku_ids))
       )
       -- 整單閘門：所有未取品項都到貨（Path A~D'、qty_received > 0、backorder_at）
       AND public.is_order_pickup_ready(co.id)
     ORDER BY co.created_at, co.order_no
  LOOP
    -- 裝得下才推：整單每一個 SKU 的需求都要在預算內（不拆行）
    v_fits := TRUE;
    FOR v_it IN
      SELECT coi.sku_id, SUM(coi.qty) AS need
        FROM customer_order_items coi
       WHERE coi.order_id = v_ord.id
         AND coi.status IN ('pending','reserved','ready')
       GROUP BY coi.sku_id
    LOOP
      IF COALESCE((v_budget ->> v_it.sku_id::TEXT)::NUMERIC, 0) < v_it.need THEN
        v_fits := FALSE;
        EXIT;
      END IF;
    END LOOP;

    IF NOT v_fits THEN
      CONTINUE;   -- 裝不下就跳過，繼續試後面的小單（維持 confirmed 等下批貨）
    END IF;

    FOR v_it IN
      SELECT coi.sku_id, SUM(coi.qty) AS need
        FROM customer_order_items coi
       WHERE coi.order_id = v_ord.id
         AND coi.status IN ('pending','reserved','ready')
       GROUP BY coi.sku_id
    LOOP
      v_rem := COALESCE((v_budget ->> v_it.sku_id::TEXT)::NUMERIC, 0) - v_it.need;
      v_budget := jsonb_set(v_budget, ARRAY[v_it.sku_id::TEXT], to_jsonb(v_rem));
      -- 20260811(4)：記下本次配出量，稍後用來收斂現貨池
      v_alloc := jsonb_set(
        v_alloc, ARRAY[v_it.sku_id::TEXT],
        to_jsonb(COALESCE((v_alloc ->> v_it.sku_id::TEXT)::NUMERIC, 0) + v_it.need));
    END LOOP;

    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = p_at,
           updated_by = p_operator,
           updated_at = p_at
     WHERE id = v_ord.id
       AND status = 'confirmed';

    v_advanced := v_advanced + 1;
  END LOOP;

  -- 20260811(4)：配出去的貨已經是客人的了，【內部】xx 店的池子不能再掛著同一批
  FOR v_it IN
    SELECT k.key::BIGINT AS sku_id, k.value::NUMERIC AS allocated
      FROM jsonb_each_text(v_alloc) k
  LOOP
    PERFORM public._trim_internal_pool(
      p_store_id, v_it.sku_id, v_it.allocated, p_operator, p_at);
  END LOOP;

  RETURN v_advanced;
END;
$$;

COMMENT ON FUNCTION public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ) IS
  '到貨後把該店 confirmed 的客人訂單依訂單時間推 ready（補貨路線發的團沒有 campaign 對齊波次，'
  '不會被 rpc_mark_orders_shipping_for_wave 推到 shipping，收貨端也就接不到）。'
  '守衛：整單過 is_order_pickup_ready + 可配量（on_hand − 已承諾未取，排除 store_internal 容器單）'
  '裝得下才推，裝不下維持 confirmed。配完後呼叫 _trim_internal_pool 扣掉現貨池的超額掛帳，'
  '避免同一批貨被重複轉單給別人。p_sku_ids = NULL → 該店所有 SKU。';

-- ----------------------------------------------------------------
-- 3. 一次性修復：20260811000020 的回填推了 133 張單卻沒扣池子，補扣一次。
--    對象＝那批單涉及的 (店, SKU)，扣減上限＝該組合被配掉的量。
-- ----------------------------------------------------------------
DO $$
DECLARE
  r       RECORD;
  v_done  NUMERIC;
  v_total NUMERIC := 0;
  v_combo INT := 0;
BEGIN
  FOR r IN
    SELECT co.pickup_store_id AS store_id, coi.sku_id, SUM(coi.qty) AS allocated
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.updated_by = '00000000-0000-0000-0000-000000000000'::UUID
       AND co.status     = 'ready'
       AND coi.status IN ('pending','reserved','ready')
     GROUP BY 1, 2
     ORDER BY 1, 2
  LOOP
    v_done := public._trim_internal_pool(
                r.store_id, r.sku_id, r.allocated,
                '00000000-0000-0000-0000-000000000000'::UUID, NOW());
    IF v_done > 0 THEN
      RAISE NOTICE '  store % / sku %: 池子扣掉 % 件（本次配出 %）',
        r.store_id, r.sku_id, v_done, r.allocated;
      v_combo := v_combo + 1;
      v_total := v_total + v_done;
    END IF;
  END LOOP;

  RAISE NOTICE '現貨池補扣完成：% 組 (店, SKU)、共 % 件', v_combo, v_total;
END $$;

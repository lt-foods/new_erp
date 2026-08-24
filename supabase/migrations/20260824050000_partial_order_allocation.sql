-- ============================================================
-- 2026-08-24 (5)：配單改品項層級 —— 多品項單可以只給裝得下的那幾項
--
-- 災情（Alex，平鎮 GRP-20260630-019-0045 王美玲）：單上有 (A)+(B) 兩項，
-- (B) 這批缺貨 → 整張單被「整單裝得下才能勾」鎖死，(A) 明明有貨也給不了。
--
-- 修法：
--   A. rpc_get_transfer_allocation_preview：orders.items 改逐品項回傳
--      （item_id / sku_id / qty / backordered），不再依 SKU 加總。
--   B. rpc_receive_transfer_manual 加 p_allocate_item_ids / p_backorder_item_ids：
--      給到的品項逐項清待補貨旗標（閘門開，Path C + 數量守衛放行），
--      沒給的逐項標待補貨（閘門關）。部分給的單「單頭不動」——
--      取貨頁本來就逐品項放行（ready 全項可取、其餘看 item 閘門），
--      會員端 OrderCard 也是逐品項顯示。整張全給的單照舊推單頭
--      （p_order_ids：shipping 快照推 ready / confirmed 走配單 RPC）。
--      沒給品項參數時退回訂單層級（舊前端相容）。
--
-- 基底：兩支皆以 20260824020000（線上現行版）逐字為底。
-- Rollback：重跑 20260824020000 的 B/C 區塊（manual 需先 DROP 9 參數版）。
-- ============================================================

-- ----------------------------------------------------------------
-- A. rpc_get_transfer_allocation_preview：items 逐品項
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_transfer_allocation_preview(
  p_transfer_ids BIGINT[],
  p_lines        JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '60000'
AS $$
DECLARE
  v_ids        BIGINT[];
  v_tenant     UUID;
  v_dest       BIGINT;
  v_store      BIGINT;
  v_store_name TEXT;
  v_cnt        INT;
  v_incoming   JSONB;
  v_budget     JSONB;
  v_orders     JSONB;
  v_cand_ids   BIGINT[];
  v_ship_ids   BIGINT[];
BEGIN
  IF p_transfer_ids IS NULL OR cardinality(p_transfer_ids) = 0 THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;
  v_ids := ARRAY(SELECT DISTINCT UNNEST(p_transfer_ids));

  SELECT COUNT(*) INTO v_cnt FROM transfers WHERE id = ANY (v_ids);
  IF v_cnt <> cardinality(v_ids) THEN
    RAISE EXCEPTION '有調撥單不存在';
  END IF;
  IF EXISTS (SELECT 1 FROM transfers WHERE id = ANY (v_ids) AND status <> 'shipped') THEN
    RAISE EXCEPTION '只有待收貨（已派出）的調撥單可以邊收邊配';
  END IF;
  SELECT COUNT(*) INTO v_cnt
    FROM (SELECT DISTINCT tenant_id, dest_location
            FROM transfers WHERE id = ANY (v_ids)) x;
  IF v_cnt > 1 THEN
    RAISE EXCEPTION '跨分店的調撥單請分開處理';
  END IF;
  -- 20260824020000：p_lines 以 transfer_item_id 定位（全域唯一），跨多張調撥單
  -- 也不會歧義 —— 只驗每一列都屬於這批單。
  IF p_lines IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lines) l
      LEFT JOIN transfer_items ti
        ON ti.id = (l->>'transfer_item_id')::BIGINT
       AND ti.transfer_id = ANY (v_ids)
     WHERE ti.id IS NULL) THEN
    RAISE EXCEPTION 'p_lines 含不屬於這批調撥單的品項';
  END IF;

  SELECT tenant_id, dest_location INTO v_tenant, v_dest
    FROM transfers WHERE id = v_ids[1];

  -- 跨租戶守衛（讀頂層 tenant_id claim；沒有 claim 的 service 情境放行）
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'transfer not in current tenant';
  END IF;

  SELECT id, name INTO v_store, v_store_name
    FROM stores WHERE tenant_id = v_tenant AND location_id = v_dest
    LIMIT 1;
  IF v_store IS NULL THEN
    -- 目的地不是分店（例如退回總倉）→ 沒有顧客訂單可配
    RETURN jsonb_build_object(
      'store_id', NULL, 'store_name', NULL,
      'incoming', '[]'::jsonb, 'budget', '[]'::jsonb, 'orders', '[]'::jsonb);
  END IF;

  -- 本次到貨量：p_lines 有值的品項以實收為準，其餘 = 派出量（同 rpc_receive_transfer）
  WITH li AS (
    SELECT (l->>'transfer_item_id')::BIGINT AS tid,
           (l->>'qty_received')::NUMERIC    AS q
      FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) l
  ),
  inc AS (
    SELECT ti.sku_id, SUM(GREATEST(COALESCE(li.q, ti.qty_shipped), 0)) AS qty
      FROM transfer_items ti
      LEFT JOIN li ON li.tid = ti.id
     WHERE ti.transfer_id = ANY (v_ids)
     GROUP BY ti.sku_id
    HAVING SUM(GREATEST(COALESCE(li.q, ti.qty_shipped), 0)) > 0
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',   inc.sku_id,
           'sku_code', s.sku_code,
           'name',     TRIM(COALESCE(s.product_name, '')
                         || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                 THEN ' / ' || s.variant_name ELSE '' END),
           'qty',      inc.qty
         ) ORDER BY inc.sku_id), '[]'::jsonb)
    INTO v_incoming
    FROM inc JOIN skus s ON s.id = inc.sku_id;

  -- 對到的訂單：該店還在等貨的一般單（排除內部容器單），至少一個未取品項的
  -- SKU 在本次到貨清單裡。
  -- 20260814：confirmed（等貨中，可配）＋ shipping（波次出貨時已配給他，
  -- 可保留或拉回）都列。先收 id 陣列 —— 之後的訂單 JSON、閘門呼叫、
  -- promised 排除都以同一個集合為準。
  SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[]),
         COALESCE(ARRAY_AGG(co.id) FILTER (WHERE co.status = 'shipping'), '{}'::BIGINT[])
    INTO v_cand_ids, v_ship_ids
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = v_store
     AND co.status          IN ('confirmed', 'shipping')
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal'
     AND EXISTS (
       SELECT 1
         FROM customer_order_items coi
         JOIN transfer_items ti
           ON ti.transfer_id = ANY (v_ids)
          AND ti.sku_id      = coi.sku_id
        WHERE coi.order_id = co.id
          AND coi.status IN ('pending','reserved','ready')
     );

  -- 訂單 JSON：多回 status（單頭）與 arrived（取貨閘門）。閘門只對候選
  -- 陣列跑（20260813020000 的教訓：別讓 planner 有機會把閘門提前對全店跑）。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id',      co.id,
           'order_no',      co.order_no,
           'member_id',     co.member_id,
           'customer',      COALESCE(m.name, co.nickname_snapshot),
           'campaign_name', CASE WHEN LEFT(COALESCE(gbc.campaign_no, ''), 2) = '__'
                                 THEN NULL ELSE gbc.name END,
           'created_at',    co.created_at,
           'status',        co.status,
           'arrived',       public.is_order_pickup_ready(co.id),
           -- 20260824050000：逐品項（不再依 SKU 加總）—— 配單改品項層級，
           -- 前端要能只給整張單裡裝得下的那幾項，其餘轉待到貨。
           'items', (
             SELECT jsonb_agg(jsonb_build_object(
                      'item_id',    coi.id,
                      'sku_id',     coi.sku_id,
                      'qty',        coi.qty,
                      'backordered', coi.backorder_at IS NOT NULL)
                    ORDER BY coi.sku_id, coi.id)
               FROM customer_order_items coi
              WHERE coi.order_id = co.id
                AND coi.status IN ('pending','reserved','ready')
           )
         ) ORDER BY co.created_at, co.order_no), '[]'::jsonb)
    INTO v_orders
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN group_buy_campaigns gbc ON gbc.id = co.campaign_id
   WHERE co.id = ANY (v_cand_ids);

  -- 既有可配量（收貨前）：on_hand − 已承諾未取；promised 一次 GROUP BY 後 JOIN。
  -- 種子 = 到貨 SKU ∪ 候選單的全部未取 SKU（多品項單要每一項都有數字）。
  -- 20260814：promised 排除畫面上列出的 shipping 單（v_ship_ids）——
  -- 它們的需求改成「勾了才佔額度」，前端把勾選需求逐 SKU 從上限扣；
  -- 沒勾（會被拉回 confirmed）就不佔。畫面外的 shipping 單照舊預扣。
  -- 20260814(2)：每列多回 'pool'（池子既有未取掛帳）—— 前端預估
  -- 「多給的會掛幾件進內部店」要扣掉它，跟 _grow_internal_pool 同一套帳。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',    b.sku_id,
           'sku_code',  s.sku_code,
           'name',      TRIM(COALESCE(s.product_name, '')
                          || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                  THEN ' / ' || s.variant_name ELSE '' END),
           'available', b.avail,
           'pool',      b.pool_qty
         ) ORDER BY b.sku_id), '[]'::jsonb)
    INTO v_budget
    FROM (
      SELECT sk.sku_id,
             COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0) AS avail,
             COALESCE(pl.pool_qty, 0) AS pool_qty
        FROM (
          SELECT DISTINCT ti.sku_id
            FROM transfer_items ti
           WHERE ti.transfer_id = ANY (v_ids)
          UNION
          SELECT DISTINCT coi.sku_id
            FROM customer_order_items coi
           WHERE coi.order_id = ANY (v_cand_ids)
             AND coi.status IN ('pending','reserved','ready')
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_dest
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN (
          SELECT coi2.sku_id, SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = v_store
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.status IN ('pending','reserved','ready')
             AND NOT (co2.id = ANY (v_ship_ids))
           GROUP BY coi2.sku_id
        ) pr ON pr.sku_id = sk.sku_id
        LEFT JOIN (
          SELECT coi3.sku_id, SUM(coi3.qty) AS pool_qty
            FROM customer_orders co3
            JOIN customer_order_items coi3 ON coi3.order_id = co3.id
            JOIN members m3 ON m3.id = co3.member_id AND m3.member_type = 'store_internal'
           WHERE co3.tenant_id       = v_tenant
             AND co3.pickup_store_id = v_store
             AND co3.status NOT IN ('cancelled','expired','transferred_out','completed')
             AND coi3.status IN ('pending','reserved','ready')
           GROUP BY coi3.sku_id
        ) pl ON pl.sku_id = sk.sku_id
    ) b
    JOIN skus s ON s.id = b.sku_id;

  RETURN jsonb_build_object(
    'store_id',   v_store,
    'store_name', v_store_name,
    'incoming',   v_incoming,
    'budget',     v_budget,
    'orders',     v_orders
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB) IS
  '收貨前的手動配單預覽：這批（同店）調撥單的到貨品項，對到該店 confirmed（等貨中）'
  '與 shipping（波次已配給他）的一般單，各附單頭 status 與 arrived（取貨閘門）。'
  '可配上限 = 既有可配（on_hand − 已承諾未取，排除畫面上的 shipping 單）＋ 本次到貨量；'
  'budget 每列另回 pool（池子既有未取掛帳，前端預估多給量用）。'
  '確認收貨走 rpc_receive_transfer_manual：沒勾的 shipping 單拉回 confirmed、'
  '多給的量掛進【內部】店現貨池。';

GRANT EXECUTE ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- B. rpc_receive_transfer_manual：品項層級配貨參數
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[]);
DROP FUNCTION IF EXISTS public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[], BIGINT[]);

CREATE OR REPLACE FUNCTION public.rpc_receive_transfer_manual(
  p_transfer_ids        BIGINT[],
  p_operator            UUID,
  p_order_ids           BIGINT[] DEFAULT NULL,
  p_notes               TEXT     DEFAULT NULL,
  p_lines               JSONB    DEFAULT NULL,
  p_pullback_order_ids  BIGINT[] DEFAULT NULL,
  p_backorder_order_ids BIGINT[] DEFAULT NULL,
  -- 20260824050000：品項層級配貨（多品項單可以只給裝得下的那幾項）。
  -- 有給品項參數時以品項層級為準；沒給則沿用訂單層級（舊前端相容）。
  p_allocate_item_ids   BIGINT[] DEFAULT NULL,
  p_backorder_item_ids  BIGINT[] DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '180000'
AS $$
DECLARE
  v_ids          BIGINT[];
  v_tenant       UUID;
  v_dest         BIGINT;
  v_store        BIGINT;
  v_cnt          INT;
  v_id           BIGINT;
  v_recv         JSONB;
  v_results      JSONB := '[]'::jsonb;
  v_alloc        JSONB := NULL;
  v_now          TIMESTAMPTZ := NOW();
  v_pulled       BIGINT[] := '{}'::BIGINT[];
  v_pull_skipped JSONB := '[]'::jsonb;
  v_chk_ship     BIGINT[] := '{}'::BIGINT[];
  v_ship_adv     INT := 0;
  v_conf         BIGINT[];
  v_tag          TEXT;
  v_sk           RECORD;
  v_grown        NUMERIC;
  v_surplus      JSONB := '[]'::jsonb;
  v_batch_skus   BIGINT[];
  v_bo_orders    INT := 0;
BEGIN
  IF p_transfer_ids IS NULL OR cardinality(p_transfer_ids) = 0 THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;
  v_ids := ARRAY(SELECT DISTINCT UNNEST(p_transfer_ids));

  SELECT COUNT(*) INTO v_cnt FROM transfers WHERE id = ANY (v_ids);
  IF v_cnt <> cardinality(v_ids) THEN
    RAISE EXCEPTION '有調撥單不存在';
  END IF;
  SELECT COUNT(*) INTO v_cnt
    FROM (SELECT DISTINCT tenant_id, dest_location
            FROM transfers WHERE id = ANY (v_ids)) x;
  IF v_cnt > 1 THEN
    RAISE EXCEPTION '跨分店的調撥單請分開處理';
  END IF;
  -- 20260824020000：p_lines 以 transfer_item_id 定位（全域唯一），支援跨多張
  -- 調撥單 —— 只驗每一列都屬於這批單，收貨迴圈再逐張切分。
  IF p_lines IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lines) l
      LEFT JOIN transfer_items ti
        ON ti.id = (l->>'transfer_item_id')::BIGINT
       AND ti.transfer_id = ANY (v_ids)
     WHERE ti.id IS NULL) THEN
    RAISE EXCEPTION 'p_lines 含不屬於這批調撥單的品項';
  END IF;
  -- 同一張單不能又配又拉 —— 一定是前端組參數組錯了，直接擋
  IF p_order_ids IS NOT NULL AND p_pullback_order_ids IS NOT NULL
     AND EXISTS (SELECT 1 FROM UNNEST(p_order_ids) o
                  WHERE o = ANY (p_pullback_order_ids)) THEN
    RAISE EXCEPTION '同一張訂單不能同時勾選配單又拉回';
  END IF;
  -- 同一張單不能又勾又標待補貨（20260824）
  IF p_order_ids IS NOT NULL AND p_backorder_order_ids IS NOT NULL
     AND EXISTS (SELECT 1 FROM UNNEST(p_order_ids) o
                  WHERE o = ANY (p_backorder_order_ids)) THEN
    RAISE EXCEPTION '同一張訂單不能同時勾選配單又標待補貨';
  END IF;
  -- 同一個品項不能又給又標待補貨（20260824050000）
  IF p_allocate_item_ids IS NOT NULL AND p_backorder_item_ids IS NOT NULL
     AND EXISTS (SELECT 1 FROM UNNEST(p_allocate_item_ids) i
                  WHERE i = ANY (p_backorder_item_ids)) THEN
    RAISE EXCEPTION '同一個品項不能同時配貨又標待補貨';
  END IF;

  SELECT tenant_id, dest_location INTO v_tenant, v_dest
    FROM transfers WHERE id = v_ids[1];
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'transfer not in current tenant';
  END IF;

  SELECT id INTO v_store
    FROM stores WHERE tenant_id = v_tenant AND location_id = v_dest
    LIMIT 1;
  IF v_store IS NULL
     AND ((p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0)
       OR (p_pullback_order_ids IS NOT NULL AND cardinality(p_pullback_order_ids) > 0)
       OR (p_backorder_order_ids IS NOT NULL AND cardinality(p_backorder_order_ids) > 0)) THEN
    RAISE EXCEPTION '目的地不是分店，無法配單';
  END IF;

  -- 本批涵蓋的 SKU（派出清單）：清標/重標的範圍都以它為準 ——
  -- 配單視窗的候選本來就是「有品項對到本批 SKU」的單。
  v_batch_skus := ARRAY(
    SELECT DISTINCT ti.sku_id FROM transfer_items ti WHERE ti.transfer_id = ANY (v_ids));

  -- 拉回：沒勾的派貨中訂單退回 confirmed（這批貨不配給他，下批可再配）。
  -- **必須在收貨之前** —— 收貨邏輯 C 會把 shipping 單推 ready，先退回才攔得住。
  -- 拉不回的（狀態已變：已被收貨推進、已取貨…）記 pullback_skipped，不擋收貨。
  IF p_pullback_order_ids IS NOT NULL AND cardinality(p_pullback_order_ids) > 0 THEN
    WITH pulled AS (
      UPDATE customer_orders co
         SET status     = 'confirmed',
             updated_by = p_operator,
             updated_at = v_now
       WHERE co.id = ANY (p_pullback_order_ids)
         AND co.tenant_id       = v_tenant
         AND co.pickup_store_id = v_store
         AND co.status          = 'shipping'
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND NOT EXISTS (SELECT 1 FROM members m
                          WHERE m.id = co.member_id
                            AND m.member_type = 'store_internal')
      RETURNING co.id
    )
    SELECT COALESCE(ARRAY_AGG(id), '{}'::BIGINT[]) INTO v_pulled FROM pulled;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'order_id', u.oid,
             'order_no', co.order_no,
             'status',   COALESCE(co.status, 'not_found'))), '[]'::jsonb)
      INTO v_pull_skipped
      FROM (SELECT DISTINCT UNNEST(p_pullback_order_ids) AS oid) u
      LEFT JOIN customer_orders co ON co.id = u.oid
     WHERE NOT (u.oid = ANY (v_pulled));
  END IF;

  -- 勾選中的派貨中訂單快照（收貨前）：收完貨要推「可取貨」的集合
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[])
      INTO v_chk_ship
      FROM customer_orders co
      LEFT JOIN members m ON m.id = co.member_id
     WHERE co.id = ANY (p_order_ids)
       AND co.tenant_id       = v_tenant
       AND co.pickup_store_id = v_store
       AND co.status          = 'shipping'
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND COALESCE(m.member_type, '') <> 'store_internal';
  END IF;

  -- 逐張收貨（不自動配單）。**沒有 savepoint** —— 任何一張失敗整包回滾，
  -- 對應「按確認才完成收貨」：失敗＝什麼都沒發生，跟批次收貨的部分成功語意不同。
  FOREACH v_id IN ARRAY v_ids LOOP
    v_recv := public.rpc_receive_transfer(
      v_id,
      CASE WHEN p_lines IS NULL THEN NULL ELSE (
        SELECT jsonb_agg(l)
          FROM jsonb_array_elements(p_lines) l
          JOIN transfer_items ti ON ti.id = (l->>'transfer_item_id')::BIGINT
         WHERE ti.transfer_id = v_id) END,
      p_operator, p_notes, FALSE);
    v_results := v_results || jsonb_build_array(v_recv);
  END LOOP;

  -- 20260824：勾選的訂單先清掉本批 SKU 的待補貨旗標 —— 上一批配單被標過
  -- 的人這批被勾了，就是「這批給他」；不清的話下面的閘門重驗
  -- （rpc_manual_allocate_confirmed_orders / is_order_pickup_ready 都含
  -- backorder_at IS NULL）會把他跳過 not_arrived，勾了等於沒勾。
  IF p_allocate_item_ids IS NOT NULL AND cardinality(p_allocate_item_ids) > 0 THEN
    -- 品項層級（20260824050000）：勾到的品項就是「這批給他」，逐項清旗標
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = v_now
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND coi.id = ANY (p_allocate_item_ids)
       AND co.tenant_id       = v_tenant
       AND co.pickup_store_id = v_store
       AND coi.status IN ('pending','reserved','ready')
       AND coi.backorder_at IS NOT NULL;
  ELSIF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = v_now
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND coi.order_id = ANY (p_order_ids)
       AND co.tenant_id       = v_tenant
       AND co.pickup_store_id = v_store
       AND coi.sku_id = ANY (v_batch_skus)
       AND coi.status IN ('pending','reserved','ready')
       AND coi.backorder_at IS NOT NULL;
  END IF;

  -- 勾選的派貨中訂單 → 可取貨。同波次到貨的多數已被收貨邏輯 C 推掉
  -- （閘門放行），這裡收尾跨批次到貨、閘門還沒開的 —— 店家勾了就是
  -- 「這批貨給他」，與邏輯 C 同樣 qty-blind、不做 _trim_internal_pool
  -- （波次貨不動現貨池；池子收斂只屬於 confirmed 配單路徑）。
  IF cardinality(v_chk_ship) > 0 THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = v_now,
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = ANY (v_chk_ship)
       AND status = 'shipping';

    SELECT COUNT(*) INTO v_ship_adv
      FROM customer_orders
     WHERE id = ANY (v_chk_ship) AND status = 'ready';
  END IF;

  -- 配單（confirmed 勾選單）：守衛全在 rpc_manual_allocate_confirmed_orders 裡
  -- （可配量、整單裝得下、閘門重驗、池子收斂；裝不下回報 skipped 不硬推）。
  -- 派貨中快照已在上面處理，剩下的照舊交給配單 RPC —— 狀態不符的它會
  -- 回報 not_eligible，跳過原因不遺失。
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    v_conf := ARRAY(SELECT DISTINCT UNNEST(p_order_ids)
                    EXCEPT SELECT UNNEST(v_chk_ship));
    IF cardinality(v_conf) > 0 THEN
      v_alloc := public.rpc_manual_allocate_confirmed_orders(v_store, v_conf, p_operator);
    END IF;
  END IF;

  -- 20260824：沒勾的候選訂單 → 本批 SKU 的 active 品項標「待補貨」。
  -- 取貨閘門含 backorder_at IS NULL → 一定關；會員端顯示「待到貨」。
  -- **必須在收貨迴圈之後** —— 收貨邏輯 A0 會解除舊旗標，先標會被它洗掉。
  -- 下一批貨到時 A0 自動重算解除（可配量夠才放）；那批又沒勾就再標回。
  IF p_backorder_item_ids IS NOT NULL AND cardinality(p_backorder_item_ids) > 0 THEN
    -- 品項層級（20260824050000）：只標「這批沒給」的那幾項 —— 部分給的單
    -- 給到的品項閘門照開、沒給的關，單頭不動（取貨頁本來就逐品項放行）。
    WITH marked AS (
      UPDATE customer_order_items coi
         SET backorder_at = v_now, backorder_by = p_operator,
             updated_by = p_operator, updated_at = v_now
        FROM customer_orders co
       WHERE co.id = coi.order_id
         AND coi.id = ANY (p_backorder_item_ids)
         AND co.tenant_id       = v_tenant
         AND co.pickup_store_id = v_store
         AND co.status          IN ('confirmed', 'shipping')
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND NOT EXISTS (SELECT 1 FROM members m
                          WHERE m.id = co.member_id
                            AND m.member_type = 'store_internal')
         AND coi.sku_id = ANY (v_batch_skus)
         AND coi.status IN ('pending','reserved','ready')
         AND coi.backorder_at IS NULL
      RETURNING coi.order_id
    )
    SELECT COUNT(DISTINCT order_id) INTO v_bo_orders FROM marked;
  ELSIF p_backorder_order_ids IS NOT NULL AND cardinality(p_backorder_order_ids) > 0 THEN
    WITH marked AS (
      UPDATE customer_order_items coi
         SET backorder_at = v_now, backorder_by = p_operator,
             updated_by = p_operator, updated_at = v_now
        FROM customer_orders co
       WHERE co.id = coi.order_id
         AND coi.order_id = ANY (p_backorder_order_ids)
         AND co.tenant_id       = v_tenant
         AND co.pickup_store_id = v_store
         AND co.status          IN ('confirmed', 'shipping')
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND NOT EXISTS (SELECT 1 FROM members m
                          WHERE m.id = co.member_id
                            AND m.member_type = 'store_internal')
         AND coi.sku_id = ANY (v_batch_skus)
         AND coi.status IN ('pending','reserved','ready')
         AND coi.backorder_at IS NULL
      RETURNING coi.order_id
    )
    SELECT COUNT(DISTINCT order_id) INTO v_bo_orders FROM marked;
  END IF;

  -- 20260814(2)：多給的要跳出內部店 —— 收貨＋配單之後，本批沒有訂單主人的
  -- 剩餘量掛進【內部】xx 店現貨池。逐 SKU：
  --   本批剩餘 = 本批實收 − 本次配掉（保留勾選的派貨中單 ＋ 本次推 ready 的
  --   confirmed 單，只算各自在該 SKU 上的未取需求）。
  -- 實際掛帳交給 _grow_internal_pool 夾兩層上限（本批剩餘 × 帳上自由量 ——
  -- 自由量已扣掉沒勾/拉回而還在等貨的 confirmed 單，不吃他們下一批要領的貨）。
  IF v_store IS NOT NULL THEN
    v_tag := '[收貨多給|TF#' || array_to_string(v_ids, ',') || ']';
    FOR v_sk IN
      WITH got AS (
        SELECT ti.sku_id, SUM(ti.qty_received) AS received
          FROM transfer_items ti
         WHERE ti.transfer_id = ANY (v_ids)
           AND ti.qty_received > 0
         GROUP BY ti.sku_id
      ),
      alloc AS (
        SELECT coi.sku_id, SUM(coi.qty) AS used
          FROM customer_order_items coi
         WHERE coi.status IN ('pending','reserved','ready')
           AND (coi.order_id = ANY (v_chk_ship)
                OR coi.id = ANY (COALESCE(p_allocate_item_ids, '{}'::BIGINT[]))
                OR (v_conf IS NOT NULL AND coi.order_id IN (
                      SELECT co.id FROM customer_orders co
                       WHERE co.id = ANY (v_conf)
                         AND co.status = 'ready'
                         AND co.ready_at = v_now)))
         GROUP BY coi.sku_id
      )
      SELECT g.sku_id, GREATEST(g.received - COALESCE(a.used, 0), 0) AS leftover
        FROM got g
        LEFT JOIN alloc a ON a.sku_id = g.sku_id
       WHERE GREATEST(g.received - COALESCE(a.used, 0), 0) > 0
    LOOP
      v_grown := public._grow_internal_pool(
        v_store, v_sk.sku_id, v_sk.leftover, p_operator, v_now, v_tag);
      IF v_grown > 0 THEN
        v_surplus := v_surplus
          || jsonb_build_object('sku_id', v_sk.sku_id, 'qty', v_grown);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'transfers_received', cardinality(v_ids),
    'received',           v_results,
    'pulled_back',        COALESCE(cardinality(v_pulled), 0),
    'pullback_skipped',   v_pull_skipped,
    'shipping_advanced',  v_ship_adv,
    'allocation',         v_alloc,
    'surplus',            v_surplus,
    'backordered',        v_bo_orders
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[], BIGINT[], BIGINT[], BIGINT[]) IS
  '手動配貨的一段式確認：單一交易內 拉回沒勾的派貨中訂單（shipping → confirmed，'
  '收貨前做，攔住邏輯 C）→ 逐張 rpc_receive_transfer(p_auto_allocate=FALSE) → '
  '清掉勾選單本批 SKU 的待補貨旗標 → 勾選的派貨中訂單推可取貨 → confirmed 勾選單走 '
  'rpc_manual_allocate_confirmed_orders → 品項層級（20260824050000）：p_allocate_item_ids '
  '逐項清旗標、p_backorder_item_ids 逐項標待補貨（多品項單可只給裝得下的幾項，'
  '單頭不動）；沒給品項參數時退回訂單層級 — 沒勾的候選（p_backorder_order_ids）本批 SKU '
  '品項標待補貨（取貨閘門關、會員端顯示待到貨；下一批收貨 A0 自動重算解除）→ '
  '本批多給的剩餘量掛進【內部】店現貨池（_grow_internal_pool）。'
  '無 savepoint —— 任何一步失敗整包回滾（確認才完成收貨；取消/失敗＝什麼都沒發生）。';

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[], BIGINT[], BIGINT[], BIGINT[])
  TO authenticated, service_role;

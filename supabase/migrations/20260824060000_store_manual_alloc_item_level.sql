-- ============================================================
-- 2026-08-24 (6)：常駐「手動配單」（store 模式）也改品項層級
--
-- 兩個要修的：
--   1. 王美玲同型：多品項單有一項還在等貨，整張被「整單閘門」鎖死，
--      到了的那項也配不了。
--   2. 20260824010000 引入的洞：「只收貨不配單」會把全部候選品項標待補貨
--      （閘門關）→ 手動配單的候選條件是「整單閘門已過」→ 清單整個變空，
--      店家承諾的「之後可從手動配單再配」做不到，要等下一批貨 A0 自動解。
--
-- 修法：
--   A. rpc_get_manual_allocation_candidates：候選＝任一 active 品項
--      「閘門已過」或「掛待補貨」的 confirmed 單；items 逐品項回傳
--      arrived / backordered（兩者皆否＝等貨中，前端顯示但不可勾）。
--   B. rpc_manual_allocate_confirmed_orders 加 p_allocate_item_ids /
--      p_backorder_item_ids：清旗標在整單推進之前（閘門重驗才過得了）；
--      部分給的單單頭不動；notify 補上部分給且閘門已過的單。
--      加參數換簽名 → DROP 3 參數版重建（舊前端不帶新參數照常可呼叫）。
--
-- 基底：candidates ← 20260813020000；allocate ← 20260813000000
--   （兩支都 grep 過為最新版）。
-- Rollback：DROP 5 參數 allocate、重跑上列基底檔對應區塊。
-- ============================================================

-- ----------------------------------------------------------------
-- A. rpc_get_manual_allocation_candidates：品項層級候選
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_manual_allocation_candidates(
  p_store_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '60000'
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_pre_ids  BIGINT[];
  v_cand_ids BIGINT[];
  v_total    INT := 0;
  v_budget   JSONB;
  v_orders   JSONB;
BEGIN
  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;
  -- 跨租戶守衛。直接讀頂層 tenant_id claim（hook 有拉，見 CLAUDE.md）；
  -- 不用 _current_tenant_id() —— 它在沒有 claim 時會 RAISE，service_role 會炸。
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'store % not in current tenant', p_store_id;
  END IF;
  IF v_loc IS NULL THEN
    -- 沒設倉庫位置的店算不出可配量（同 helper 直接不動）
    RETURN jsonb_build_object(
      'store_id', p_store_id, 'budget', '[]'::jsonb,
      'orders', '[]'::jsonb, 'waiting_count', 0);
  END IF;

  -- 20260813(3)：預篩先收進陣列、閘門只對倖存者跑。原本寫在同一個 WHERE，
  -- planner 把 is_order_pickup_ready() 提前對全部 confirmed 單跑
  -- （文山 1,704 張 ≈ 8.9s → PostgREST 8s timeout）。拆開後 ~0.2s。
  SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[])
    INTO v_pre_ids
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status          = 'confirmed'
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal'
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
     );

  -- 20260824060000：候選改品項層級 —— 有任何一個 active 品項「閘門已過」
  -- 或「掛著待補貨」（含配單時沒勾而被標的；只收貨不配單後全店都是這種，
  -- 舊的整單閘門條件會讓清單整個變空、店家配不回來）就列。
  SELECT COALESCE(ARRAY_AGG(DISTINCT coi.order_id), '{}'::BIGINT[])
    INTO v_cand_ids
    FROM customer_order_items coi
   WHERE coi.order_id = ANY (v_pre_ids)
     AND coi.status IN ('pending','reserved','ready')
     AND (coi.backorder_at IS NOT NULL
          OR public.is_order_item_pickup_ready(coi.id));

  -- 分母：本店全部 confirmed 一般單（排除內部容器）——
  -- 差額 = 貨還沒到齊 / 店裡沒庫存、目前配不了的張數，前端當註腳顯示。
  SELECT COUNT(*)
    INTO v_total
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status          = 'confirmed'
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal';

  -- 各 SKU 可配量：算法與 _advance_arrived_confirmed_orders 同一套。
  -- 20260813(3)：種子縮成**候選單**的未取 SKU（彈窗只拿 budget 算候選單
  -- 裝不裝得下與顯示，非候選 SKU 的列從沒被用到；每 SKU 數值不變）；
  -- promised 改一次 GROUP BY 後 JOIN。available 回原始值（可為負）。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',    b.sku_id,
           'sku_code',  s.sku_code,
           'name',      TRIM(COALESCE(s.product_name, '')
                          || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                  THEN ' / ' || s.variant_name ELSE '' END),
           'available', b.avail
         ) ORDER BY b.sku_id), '[]'::jsonb)
    INTO v_budget
    FROM (
      SELECT sk.sku_id,
             COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0) AS avail
        FROM (
          SELECT DISTINCT coi.sku_id
            FROM customer_order_items coi
           WHERE coi.order_id = ANY (v_cand_ids)
             AND coi.status IN ('pending','reserved','ready')
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_loc
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN (
          SELECT coi2.sku_id, SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = p_store_id
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.status IN ('pending','reserved','ready')
           GROUP BY coi2.sku_id
        ) pr ON pr.sku_id = sk.sku_id
    ) b
    JOIN skus s ON s.id = b.sku_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id',      co.id,
           'order_no',      co.order_no,
           'member_id',     co.member_id,
           'customer',      COALESCE(m.name, co.nickname_snapshot),
           'campaign_name', CASE WHEN LEFT(COALESCE(gbc.campaign_no, ''), 2) = '__'
                                 THEN NULL ELSE gbc.name END,
           'created_at',    co.created_at,
           -- 20260824060000：逐品項。arrived=閘門已過（現在就可取）、
           -- backordered=掛待補貨（配這批＝清旗標）。兩者皆否＝還在等貨，
           -- 前端顯示但不可勾。
           'items', (
             SELECT jsonb_agg(jsonb_build_object(
                      'item_id',     coi.id,
                      'sku_id',      coi.sku_id,
                      'qty',         coi.qty,
                      'arrived',     public.is_order_item_pickup_ready(coi.id),
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

  RETURN jsonb_build_object(
    'store_id',      p_store_id,
    'budget',        v_budget,
    'orders',        v_orders,
    'waiting_count', GREATEST(v_total - COALESCE(cardinality(v_cand_ids), 0), 0)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_get_manual_allocation_candidates(BIGINT) IS
  '手動配單彈窗的候選清單（20260824060000 起品項層級）：本店 confirmed 一般單'
  '（排除 store_internal 容器單）中，任一 active 品項閘門已過或掛待補貨者。'
  'items 逐品項回傳 arrived/backordered；budget = on_hand − 已承諾未取。'
  'waiting_count = 其餘配不了的張數。預篩先收陣列、閘門只對倖存者跑。';

GRANT EXECUTE ON FUNCTION public.rpc_get_manual_allocation_candidates(BIGINT)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 3. rpc_get_transfer_allocation_preview — promised 單趟化 + 保險 timeout
--    （沒有閘門呼叫，本來就不會踩 planner 反排序；純吃效能小改）

-- ----------------------------------------------------------------
-- B. rpc_manual_allocate_confirmed_orders：品項層級參數
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_manual_allocate_confirmed_orders(BIGINT, BIGINT[], UUID);

CREATE OR REPLACE FUNCTION public.rpc_manual_allocate_confirmed_orders(
  p_store_id           BIGINT,
  p_order_ids          BIGINT[],
  p_operator           UUID,
  -- 20260824060000：品項層級。allocate=這批給他（清待補貨旗標）、
  -- backorder=這批不給（標旗標，閘門關）。部分給的單「單頭不動」。
  p_allocate_item_ids  BIGINT[] DEFAULT NULL,
  p_backorder_item_ids BIGINT[] DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_now      TIMESTAMPTZ := NOW();
  v_eligible BIGINT[] := '{}'::BIGINT[];
  v_advanced INT := 0;
  v_orders   JSONB;
  v_skipped  JSONB;
  v_notify   JSONB;
BEGIN
  IF (p_order_ids IS NULL OR cardinality(p_order_ids) = 0)
     AND (p_allocate_item_ids IS NULL OR cardinality(p_allocate_item_ids) = 0)
     AND (p_backorder_item_ids IS NULL OR cardinality(p_backorder_item_ids) = 0) THEN
    RAISE EXCEPTION '未選擇任何訂單';
  END IF;
  IF p_allocate_item_ids IS NOT NULL AND p_backorder_item_ids IS NOT NULL
     AND EXISTS (SELECT 1 FROM UNNEST(p_allocate_item_ids) i
                  WHERE i = ANY (p_backorder_item_ids)) THEN
    RAISE EXCEPTION '同一個品項不能同時配貨又標待補貨';
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;
  -- 跨租戶守衛（同 rpc_get_manual_allocation_candidates，讀頂層 claim）
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'store % not in current tenant', p_store_id;
  END IF;

  -- 兩個店員同時配單時序列化，避免同一批可配量被算兩次
  PERFORM pg_advisory_xact_lock(hashtext('manual_alloc:' || p_store_id::TEXT));

  -- 20260824060000：品項層級先做 —— 清旗標要在整單推進（閘門重驗）之前，
  -- 否則上一輪被標待補貨的單永遠推不動。範圍限本店 confirmed/shipping 一般單。
  IF p_allocate_item_ids IS NOT NULL AND cardinality(p_allocate_item_ids) > 0 THEN
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = v_now
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND coi.id = ANY (p_allocate_item_ids)
       AND co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.status          IN ('confirmed', 'shipping')
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND coi.status IN ('pending','reserved','ready')
       AND coi.backorder_at IS NOT NULL;
  END IF;

  IF p_backorder_item_ids IS NOT NULL AND cardinality(p_backorder_item_ids) > 0 THEN
    UPDATE customer_order_items coi
       SET backorder_at = v_now, backorder_by = p_operator,
           updated_by = p_operator, updated_at = v_now
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND coi.id = ANY (p_backorder_item_ids)
       AND co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.status          IN ('confirmed', 'shipping')
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND NOT EXISTS (SELECT 1 FROM members m
                        WHERE m.id = co.member_id
                          AND m.member_type = 'store_internal')
       AND coi.status IN ('pending','reserved','ready')
       AND coi.backorder_at IS NULL;
  END IF;

  -- 只吃本店的 confirmed 一般單（排除內部容器單）；其餘進 skipped
  SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[])
    INTO v_eligible
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.id = ANY (COALESCE(p_order_ids, '{}'::BIGINT[]))
     AND co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status          = 'confirmed'
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal';

  IF cardinality(v_eligible) > 0 THEN
    v_advanced := public._advance_arrived_confirmed_orders(
      p_store_id, NULL, p_operator, v_now, v_eligible);
  END IF;

  -- 這一次真的被推 ready 的單（ready_at = v_now 是本次呼叫的印記）
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id', co.id,
           'order_no', co.order_no,
           'customer', COALESCE(m.name, co.nickname_snapshot)
         ) ORDER BY co.order_no), '[]'::jsonb)
    INTO v_orders
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.id = ANY (v_eligible)
     AND co.status = 'ready'
     AND co.ready_at = v_now;

  -- 沒推成的單附原因：not_eligible（不是本店可配的 confirmed 一般單）/
  -- not_arrived（貨未到齊，閘門沒過）/ insufficient_stock（可配量裝不下整單）
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id', u.oid,
           'order_no', co.order_no,
           'reason',   CASE
                         WHEN co.id IS NULL                       THEN 'not_found'
                         WHEN NOT (u.oid = ANY (v_eligible))      THEN 'not_eligible'
                         WHEN NOT public.is_order_pickup_ready(co.id)
                                                                  THEN 'not_arrived'
                         ELSE 'insufficient_stock'
                       END)), '[]'::jsonb)
    INTO v_skipped
    FROM (SELECT DISTINCT UNNEST(COALESCE(p_order_ids, '{}'::BIGINT[])) AS oid) u
    LEFT JOIN customer_orders co ON co.id = u.oid
   WHERE co.id IS NULL
      OR NOT (co.status = 'ready' AND co.ready_at = v_now AND u.oid = ANY (v_eligible));

  -- 到貨推播名單（同 rpc_get_members_to_notify_for_transfer 的黑名單規則；
  -- 推不推由前端依「收貨後通知會員」開關決定）
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'member_id',             co.member_id,
           'order_id',              co.id,
           'order_no',              co.order_no,
           'last_notify_pickup_at', co.last_notify_pickup_at
         )), '[]'::jsonb)
    INTO v_notify
    FROM customer_orders co
    JOIN members m ON m.id = co.member_id
   WHERE COALESCE(m.no_notify_pickup, FALSE) = FALSE
     AND ((co.id = ANY (v_eligible) AND co.status = 'ready' AND co.ready_at = v_now)
          -- 20260824060000：部分給的單（單頭沒動）—— 這次清了旗標且該品項
          -- 閘門現在已過的，也通知客人「有東西可以來拿了」
          OR EXISTS (
               SELECT 1 FROM customer_order_items coi
                WHERE coi.order_id = co.id
                  AND coi.id = ANY (COALESCE(p_allocate_item_ids, '{}'::BIGINT[]))
                  AND coi.updated_at = v_now
                  AND coi.backorder_at IS NULL
                  AND public.is_order_item_pickup_ready(coi.id)));

  RETURN jsonb_build_object(
    'advanced', v_advanced,
    'orders',   v_orders,
    'skipped',  v_skipped,
    'notify',   v_notify
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_manual_allocate_confirmed_orders(BIGINT, BIGINT[], UUID, BIGINT[], BIGINT[]) IS
  '手動配單（20260824060000 起品項層級）：p_allocate_item_ids 逐項清待補貨旗標、'
  'p_backorder_item_ids 逐項標（閘門關）；p_order_ids = 整張全給的單走'
  '_advance_arrived_confirmed_orders 推 ready（清旗標在前，閘門重驗才過得了）。'
  '部分給的單單頭不動（取貨頁逐品項放行）。notify 含整張推 ready 與部分給且'
  '閘門已過的單，皆已過黑名單。';

GRANT EXECUTE ON FUNCTION public.rpc_manual_allocate_confirmed_orders(BIGINT, BIGINT[], UUID, BIGINT[], BIGINT[])
  TO authenticated, service_role;

-- ============================================================
-- 2026-08-24：配單沒勾到的訂單 → 標「待補貨」，取貨頁一律擋住
--
-- 災情（Alex 2026-08-24，平鎮 WV260818001815 皮蛋先生）：
--   收貨走「✋ 配單」、刻意沒勾某位客人 → 他的單退回/維持 confirmed，
--   但取貨頁照樣放行。原因：配單只動單頭 status，取貨閘門
--   is_order_item_pickup_ready 是另一套 —— Path C 只問「本店該 SKU
--   該團有沒有實收」（qty-blind），兩道數量守衛又是照 (created_at,
--   order_no) 讓排前面的人先拿。沒勾的人只要下單時間排得進到貨量，
--   閘門照開 —— 配單的「這批不給他」閘門完全不知道。
--
-- 修法（老闆定案「沒勾的就變成待到貨」）：
--   rpc_receive_transfer_manual 加參數 p_backorder_order_ids（前端把
--   配單視窗裡「沒勾的候選訂單」全部傳進來，含拉回的派貨中單），
--   收貨與配單都完成之後，把這些單上「本批 SKU」的 active 品項標
--   backorder_at —— 閘門含 backorder_at IS NULL（20260805000060），
--   標了取貨頁一定關；會員端因 gate=false 顯示「待到貨」。
--
--   解除路徑（全部既有，不新增人工關卡）：
--   - 下一批貨到：收貨邏輯 A0 _settle_arrived_backorders（20260811000050）
--     自動重算解除（可配量夠才放），手動配模式也照跑（20260813 定案）。
--     A0 跑在收貨迴圈裡、本函式的重標跑在交易尾端 → 這批又沒勾的人
--     會被重新標回，最終狀態正確。
--   - 這批就勾他：本函式在推單頭之前先清掉勾選單的 backorder_at
--     （不清的話 rpc_manual_allocate_confirmed_orders 的閘門重驗會把
--     他跳過 not_arrived，勾了等於沒勾）。
--   - 人工：⚖️ 配貨（rpc_allocate_shortage）／取消待補貨，照舊。
--
--   刻意不動的：
--   - rpc_unreceive_transfer 不加反向解標 —— 退回收貨後供給歸零，
--     閘門本來就關；殘留旗標由下一批 A0 重算收掉。
--   - store 模式手動配單（rpc_manual_allocate_confirmed_orders 直呼）
--     不標 —— 那個模式的候選本來就是閘門已開的單，語意是「先配誰」
--     不是「這批給誰」。
--
-- 基底：rpc_receive_transfer_manual 以 20260814010000 版逐字為底
--   （grep 過 20260813010000 / 20260814000000 / 20260814010000，
--   最新是 20260814010000）。加參數要換簽名 → DROP 舊 6 參數版重建。
-- Rollback：DROP 本版 7 參數函式，重跑 20260814010000 的
--   rpc_receive_transfer_manual 區塊（恢復 6 參數版）。
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[]);

CREATE OR REPLACE FUNCTION public.rpc_receive_transfer_manual(
  p_transfer_ids        BIGINT[],
  p_operator            UUID,
  p_order_ids           BIGINT[] DEFAULT NULL,
  p_notes               TEXT     DEFAULT NULL,
  p_lines               JSONB    DEFAULT NULL,
  p_pullback_order_ids  BIGINT[] DEFAULT NULL,
  p_backorder_order_ids BIGINT[] DEFAULT NULL
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
  IF p_lines IS NOT NULL AND cardinality(v_ids) > 1 THEN
    RAISE EXCEPTION 'p_lines 只支援單張調撥單';
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
      CASE WHEN cardinality(v_ids) = 1 THEN p_lines ELSE NULL END,
      p_operator, p_notes, FALSE);
    v_results := v_results || jsonb_build_array(v_recv);
  END LOOP;

  -- 20260824：勾選的訂單先清掉本批 SKU 的待補貨旗標 —— 上一批配單被標過
  -- 的人這批被勾了，就是「這批給他」；不清的話下面的閘門重驗
  -- （rpc_manual_allocate_confirmed_orders / is_order_pickup_ready 都含
  -- backorder_at IS NULL）會把他跳過 not_arrived，勾了等於沒勾。
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
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
  IF p_backorder_order_ids IS NOT NULL AND cardinality(p_backorder_order_ids) > 0 THEN
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

COMMENT ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[], BIGINT[]) IS
  '手動配貨的一段式確認：單一交易內 拉回沒勾的派貨中訂單（shipping → confirmed，'
  '收貨前做，攔住邏輯 C）→ 逐張 rpc_receive_transfer(p_auto_allocate=FALSE) → '
  '清掉勾選單本批 SKU 的待補貨旗標 → 勾選的派貨中訂單推可取貨 → confirmed 勾選單走 '
  'rpc_manual_allocate_confirmed_orders → 沒勾的候選（p_backorder_order_ids）本批 SKU '
  '品項標待補貨（取貨閘門關、會員端顯示待到貨；下一批收貨 A0 自動重算解除）→ '
  '本批多給的剩餘量掛進【內部】店現貨池（_grow_internal_pool）。'
  '無 savepoint —— 任何一步失敗整包回滾（確認才完成收貨；取消/失敗＝什麼都沒發生）。';

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[], BIGINT[])
  TO authenticated, service_role;

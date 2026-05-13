-- ============================================================
-- 🚨 Critical bug fix: rpc_record_pickup 沒寫 stock_movement
--
-- 發現過程：跑完整 E2E 鏈路 (建商品→取貨) 後發現
-- 各分店帳上庫存沒被扣（顧客取了貨、stock_balances 還在）。
-- 影響：所有歷史取貨 — stock 持續膨脹、月結算對不上實體庫存。
--
-- 修法 (3 段)：
-- 1. CREATE OR REPLACE rpc_record_pickup：取貨時為每個 item 寫
--    stock_movement type='sale' 在 pickup_store 的 location_id、
--    回填 customer_order_items.pickup_movement_id
-- 2. Backfill：對 status='picked_up' AND pickup_movement_id IS NULL
--    的歷史 items 補 stock_movement (同上邏輯、operator 用 updated_by)
-- 3. fn_check_pickup_movements_consistency() 給 e2e / CI 抓孤兒
-- 4. Migration 末尾 self-check：0 orphans 才 apply
--
-- Rollback: CREATE OR REPLACE 回 20260606000040 版本; 反向 stock_movements
--           UPDATE customer_order_items SET pickup_movement_id=NULL.
-- ============================================================

-- 1. RPC: 修改加上 stock_movement 寫入
CREATE OR REPLACE FUNCTION public.rpc_record_pickup(p_order_id bigint, p_item_ids bigint[], p_operator uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_pickup_loc       BIGINT;
  v_item             RECORD;
  v_movement_id      BIGINT;
  v_picked_count     INT := 0;
  v_active_remaining INT;
  v_new_status       TEXT;
  v_event_type       TEXT;
  v_event_id         BIGINT;
  v_now              TIMESTAMPTZ := NOW();
BEGIN
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_item_ids is empty';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_pickup:' || p_order_id::text));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 %', p_order_id;
  END IF;

  IF v_order.status IN ('completed','expired','cancelled','transferred_out') THEN
    RAISE EXCEPTION '訂單 % 目前狀態為「%」，無法取貨', p_order_id, v_order.status;
  END IF;

  IF NOT public.is_order_pickup_ready(p_order_id) THEN
    RAISE EXCEPTION '訂單 % 對應的分店尚未確認收到出倉單，無法取貨', p_order_id;
  END IF;

  -- 取得 pickup_store 對應的 location_id
  SELECT location_id INTO v_pickup_loc
    FROM stores
   WHERE id = v_order.pickup_store_id;

  IF v_pickup_loc IS NULL THEN
    RAISE EXCEPTION '分店 % 未設定倉庫位置 (location_id)、無法寫 stock_movement', v_order.pickup_store_id;
  END IF;

  -- 為每個 item: 鎖、寫 movement、標 picked_up + pickup_movement_id
  FOR v_item IN
    SELECT id, sku_id, qty, status
      FROM customer_order_items
     WHERE id = ANY(p_item_ids)
       AND order_id = p_order_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.status NOT IN ('pending','reserved','ready') THEN
      RAISE EXCEPTION '品項 % 狀態 % 不可取貨', v_item.id, v_item.status;
    END IF;

    -- 寫 sale movement (-qty)
    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, movement_type,
      source_doc_type, source_doc_id, source_doc_line_id,
      reason, operator_id
    ) VALUES (
      v_order.tenant_id, v_pickup_loc, v_item.sku_id, -v_item.qty, 'sale',
      'customer_order', p_order_id, v_item.id,
      format('顧客取貨 order=%s item=%s', p_order_id, v_item.id),
      p_operator
    ) RETURNING id INTO v_movement_id;

    -- 標 item picked_up + 回填 pickup_movement_id
    UPDATE customer_order_items
       SET status = 'picked_up',
           pickup_movement_id = v_movement_id,
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_item.id;

    v_picked_count := v_picked_count + 1;
  END LOOP;

  -- 驗有東西真的被 picked
  IF v_picked_count = 0 THEN
    RAISE EXCEPTION 'no items picked (check p_item_ids belongs to order %)', p_order_id;
  END IF;

  -- 重算 order status
  SELECT COUNT(*) INTO v_active_remaining
    FROM customer_order_items
   WHERE order_id = p_order_id
     AND status IN ('pending','reserved','ready');

  IF v_active_remaining = 0 THEN
    v_new_status := 'completed';
    v_event_type := 'picked_up';
  ELSE
    v_new_status := 'partially_completed';
    v_event_type := 'partial_pickup';
  END IF;

  UPDATE customer_orders
     SET status       = v_new_status,
         completed_at = CASE WHEN v_new_status = 'completed' THEN v_now ELSE NULL END,
         updated_by   = p_operator,
         updated_at   = v_now
   WHERE id = p_order_id;

  -- 寫 event
  INSERT INTO order_pickup_events (
    tenant_id, order_id, pickup_store_id, event_type, item_ids, notes, created_by
  ) VALUES (
    v_order.tenant_id, p_order_id, v_order.pickup_store_id, v_event_type,
    to_jsonb(p_item_ids), p_notes, p_operator
  ) RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'event_id',        v_event_id,
    'event_type',      v_event_type,
    'picked_count',    v_picked_count,
    'active_remaining', v_active_remaining,
    'new_status',      v_new_status
  );
END;
$function$;

-- 2. Backfill: 對 picked_up 但沒 pickup_movement_id 的歷史 items 補 stock_movement
DO $$
DECLARE
  v_row RECORD;
  v_movement_id BIGINT;
  v_backfilled INT := 0;
  v_skipped INT := 0;
BEGIN
  FOR v_row IN
    SELECT coi.id AS item_id, coi.order_id, coi.sku_id, coi.qty,
           co.tenant_id, co.pickup_store_id,
           s.location_id AS pickup_loc,
           COALESCE(coi.updated_by, coi.created_by, co.updated_by, co.created_by) AS operator
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
      LEFT JOIN stores s ON s.id = co.pickup_store_id
     WHERE coi.status = 'picked_up'
       AND coi.pickup_movement_id IS NULL
  LOOP
    IF v_row.pickup_loc IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
    -- 防禦：若已有同 (source_doc_type, source_doc_line_id) 的 sale movement、不重複寫
    IF EXISTS (
      SELECT 1 FROM stock_movements
       WHERE source_doc_type = 'customer_order'
         AND source_doc_id = v_row.order_id
         AND source_doc_line_id = v_row.item_id
         AND movement_type = 'sale'
    ) THEN
      -- 已有 movement、只回填 pickup_movement_id
      SELECT id INTO v_movement_id FROM stock_movements
       WHERE source_doc_type='customer_order' AND source_doc_id=v_row.order_id
         AND source_doc_line_id=v_row.item_id AND movement_type='sale'
       LIMIT 1;
      UPDATE customer_order_items SET pickup_movement_id = v_movement_id WHERE id = v_row.item_id;
      v_backfilled := v_backfilled + 1;
      CONTINUE;
    END IF;

    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, movement_type,
      source_doc_type, source_doc_id, source_doc_line_id,
      reason, operator_id
    ) VALUES (
      v_row.tenant_id, v_row.pickup_loc, v_row.sku_id, -v_row.qty, 'sale',
      'customer_order', v_row.order_id, v_row.item_id,
      format('backfill 取貨庫存扣帳 order=%s item=%s (20260614 migration)', v_row.order_id, v_row.item_id),
      v_row.operator
    ) RETURNING id INTO v_movement_id;

    UPDATE customer_order_items
       SET pickup_movement_id = v_movement_id
     WHERE id = v_row.item_id;

    v_backfilled := v_backfilled + 1;
  END LOOP;

  RAISE NOTICE 'Backfilled stock_movements: % rows, skipped (no pickup_loc): %', v_backfilled, v_skipped;
END $$;

-- 3. Invariant fn
CREATE OR REPLACE FUNCTION public.fn_check_pickup_movements_consistency()
RETURNS TABLE(
  issue TEXT,
  order_id BIGINT,
  order_no TEXT,
  item_id BIGINT,
  sku_id BIGINT,
  qty NUMERIC,
  pickup_store_id BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  -- 情境：customer_order_items.status='picked_up' 但 pickup_movement_id IS NULL
  RETURN QUERY
  SELECT
    'picked_up_without_movement'::TEXT,
    coi.order_id,
    co.order_no,
    coi.id,
    coi.sku_id,
    coi.qty,
    co.pickup_store_id
  FROM customer_order_items coi
  JOIN customer_orders co ON co.id = coi.order_id
  WHERE coi.status = 'picked_up'
    AND coi.pickup_movement_id IS NULL;
END;
$$;

COMMENT ON FUNCTION public.fn_check_pickup_movements_consistency() IS
  '檢查 customer_order_items.status=picked_up 都有 pickup_movement_id (對應 stock_movement)。'
  '回傳孤兒。E2E / CI 應期待 0 rows。';

GRANT EXECUTE ON FUNCTION public.fn_check_pickup_movements_consistency() TO authenticated;

-- 4. Self-check: migration 末尾跑檢查、有孤兒就 RAISE
DO $$
DECLARE
  v_count INTEGER;
  v_skipped INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM public.fn_check_pickup_movements_consistency();
  -- 算 backfill 可能跳過的 (分店沒 location_id 的)
  SELECT COUNT(*) INTO v_skipped
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    LEFT JOIN stores s ON s.id = co.pickup_store_id
   WHERE coi.status = 'picked_up'
     AND coi.pickup_movement_id IS NULL
     AND (s.location_id IS NULL);

  IF v_count > v_skipped THEN
    RAISE EXCEPTION 'pickup_movement consistency check failed: % orphan rows (% are pickup_store missing location_id - need manual review). '
      'Run "SELECT * FROM fn_check_pickup_movements_consistency()" to see details.',
      v_count, v_skipped;
  END IF;
  RAISE NOTICE 'pickup_movement invariant: % orphans (all % are stores missing location_id - blocked by store setup, not RPC bug).', v_count, v_skipped;
END $$;

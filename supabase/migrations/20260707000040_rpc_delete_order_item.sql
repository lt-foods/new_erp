-- ============================================================
-- rpc_delete_order_item — 店家/HQ 刪除 pending 訂單裡的單一品項
--
-- 背景：
--   店家可改顧客訂單品項數量（rpc_update_order_item_qty），但無法「刪掉
--   某個品項」。schema CHECK qty > 0 讓「改成 0」也做不到，只能整單取消。
--   實際需求是顧客改單想拿掉其中一項，本 RPC 補上單品項刪除。
--
-- 設計（刻意對齊既有慣例，不另開新 status 值）：
--   - 軟刪：品項 status -> 'cancelled'（與「斷貨連動」同一機制，所有既有
--     view / RPC 的 `status NOT IN ('cancelled','expired')` 過濾自動正確），
--     stockout_at 維持 NULL 代表「人工刪除」而非斷貨，UI 顯示「已取消」。
--   - 狀態閘：僅 pending。與 rpc_update_order_item_qty 同閘
--     （confirmed 之後訂單被 PR 鎖定，數量/品項都不該再動）。
--   - 權限：沿用 _check_order_edit_qty_perm
--     （HQ tier 全部 / 店長限 app_metadata.stores 含訂單 pickup_store；含 FOR UPDATE）。
--   - 稽核：寫 customer_order_audit_log field='status'
--     （該值由 20260625000000 擴充 CHECK 後合法）。
--   - 刪到最後一個 active 品項 → 自動取消整單，條件對齊斷貨連動
--     （未付款 + 未用儲值金才自動取消；有金流的留人工退款處理）。
--
-- 基底依賴：
--   - _check_order_edit_qty_perm：20260629000010_rpc_order_qty_store_manager.sql
--   - customer_order_items.stockout_at：20260702020000_stockout_propagation.sql
--   - audit_log field CHECK 含 'status'：20260625000000_pr_create_lock_campaign_and_orders.sql
--
-- Rollback：DROP FUNCTION public.rpc_delete_order_item(BIGINT, BIGINT, UUID, TEXT);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_delete_order_item(
  p_order_id BIGINT,
  p_item_id  BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order           customer_orders%ROWTYPE;
  v_old_status      TEXT;
  v_remaining       INTEGER;
  v_order_cancelled BOOLEAN := FALSE;
BEGIN
  -- 1. 權限 + 鎖訂單（HQ 全部 / 店長限自家 pickup_store）
  v_order := _check_order_edit_qty_perm(p_order_id);

  -- 2. 狀態閘：僅 pending（confirmed 後被 PR 鎖定，與改數量同閘）
  IF v_order.status <> 'pending' THEN
    RAISE EXCEPTION '訂單狀態為 %,僅 待確認 訂單可刪除品項', v_order.status;
  END IF;

  -- 3. 取品項並上鎖
  SELECT status INTO v_old_status
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  -- 4. 已取消/已過期視為已刪，no-op 短路
  IF v_old_status IN ('cancelled', 'expired') THEN
    RETURN jsonb_build_object(
      'item_id', p_item_id, 'already_removed', TRUE, 'order_cancelled', FALSE
    );
  END IF;

  -- 5. 軟刪：標記 cancelled（stockout_at 保持 NULL = 人工刪除）
  UPDATE customer_order_items
     SET status     = 'cancelled',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id;

  -- 6. 稽核
  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'status',
     to_jsonb(v_old_status), to_jsonb('cancelled'::TEXT), p_reason, p_operator);

  -- 7. 刪到最後一個 active 品項 → 自動取消整單
  --    條件對齊斷貨連動：未付款 + 未用儲值金才自動取消
  SELECT COUNT(*) INTO v_remaining
    FROM customer_order_items
   WHERE order_id = p_order_id
     AND status NOT IN ('cancelled', 'expired');

  IF v_remaining = 0
     AND COALESCE(v_order.payment_status, 'unpaid') <> 'paid'
     AND COALESCE(v_order.wallet_paid_amount, 0) = 0
  THEN
    UPDATE customer_orders
       SET status       = 'cancelled',
           cancelled_at = NOW(),
           updated_by   = p_operator,
           updated_at   = NOW()
     WHERE id = p_order_id
       AND status = 'pending';
    v_order_cancelled := TRUE;

    INSERT INTO customer_order_audit_log
      (tenant_id, order_id, entity_type, entity_id, field,
       before_value, after_value, edit_reason, operator_id)
    VALUES
      (v_order.tenant_id, p_order_id, 'order', p_order_id, 'status',
       to_jsonb('pending'::TEXT), to_jsonb('cancelled'::TEXT),
       COALESCE(NULLIF(BTRIM(p_reason), '') || ' / ', '') || '刪除最後一個品項自動取消整單',
       p_operator);
  END IF;

  RETURN jsonb_build_object(
    'item_id',         p_item_id,
    'already_removed', FALSE,
    'order_cancelled', v_order_cancelled,
    'remaining_items', v_remaining
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_delete_order_item(BIGINT, BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_order_item IS
  '刪除 pending 訂單的單一品項（軟刪：status->cancelled，stockout_at 留 NULL 代表人工刪除）。'
  'HQ tier 全部 / 店長限 app_metadata.stores 含訂單 pickup_store；訂單須為 pending；'
  '寫 customer_order_audit_log；刪到最後一個 active 品項且未付款/未用儲值金時自動取消整單。';

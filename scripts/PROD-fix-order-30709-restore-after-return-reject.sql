-- ============================================================
-- PROD FIX: 復原 GRP-20260612-010-0067 (customer_orders.id = 30709)
--
-- 事故經過（2026-07-07 查證）：
--   1. 訂單 30709 三個品項全數已取貨（customer_order_items 皆 picked_up），
--      正確終態應為 status='completed'（ready_at 2026-07-01、取貨 2026-07-03）。
--   2. 分店 2026-07-03 對它發起「取貨後退回總倉」→ rpc_create_order_return
--      建 return_to_hq transfer TR2607030151 (id=3935, customer_order_id=30709)。
--   3. 總倉 2026-07-06 拒收該退貨 → 呼叫 rpc_reject_transfer。
--
-- 根因（rpc_reject_transfer 的語意錯配）：
--   rpc_reject_transfer 是為「互助單」設計的：它假設 transfer.customer_order_id
--   指向一張「專屬互助/收件端訂單」，拒收即應整張取消。
--   但 return_to_hq 的 customer_order_id 指向的是「原始訂單」本身（30709），
--   於是拒收把原訂單 30709 誤設成 cancelled + cancelled_at=2026-07-06T07:40:53Z。
--   → 原訂單「消失」、商品脫離原單。這就是回報的現象。
--
-- 庫存不需修（僅還原訂單狀態，不動 stock_movements）：
--   店10 對每個 SKU 的淨額 = 取貨 outbound(-10) + 退貨 outbound(-10) + 拒收 inbound(+10)
--   = -10（＝只有取貨那筆），已正確反映「貨在顧客手上、退貨未成立」。
--
-- 修法（冪等，只有現況 cancelled 才動）：
--   1. customer_orders 30709: cancelled → completed，cancelled_at → NULL
--   2. customer_order_audit_log 補一列 entity='order' field='status'
--      before='cancelled' after='completed'（後台「編輯歷史」看得到）
--
-- 注意：需以 postgres/owner 身分執行（Supabase Studio SQL Editor 或 Management API），
--       才能繞過 customer_order_audit_log 的 RLS（該表只允 SECURITY DEFINER / owner 寫）。
--
-- Rollback：
--   UPDATE customer_orders
--      SET status='cancelled', cancelled_at='2026-07-06T07:40:53.022785+00:00'
--    WHERE id=30709;
--   -- 稽核列為 append-only（trg_no_mut_coa 擋 DELETE），如需移除以 owner：
--   ALTER TABLE customer_order_audit_log DISABLE TRIGGER trg_no_mut_coa;
--   DELETE FROM customer_order_audit_log
--    WHERE order_id=30709 AND field='status' AND edit_reason LIKE 'TR2607030151%';
--   ALTER TABLE customer_order_audit_log ENABLE TRIGGER trg_no_mut_coa;
-- ============================================================
DO $$
DECLARE
  v_order  customer_orders%ROWTYPE;
  v_op     UUID;
BEGIN
  SELECT * INTO v_order FROM customer_orders WHERE id = 30709 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order 30709 not found';
  END IF;

  IF v_order.status <> 'cancelled' THEN
    RAISE NOTICE 'order 30709 status=% (非 cancelled) — 已處理過或狀況不符，略過', v_order.status;
    RETURN;
  END IF;

  -- 操作人：優先取拒收該退貨單的人，否則退回最早的 auth 使用者（owner）
  SELECT updated_by INTO v_op FROM transfers WHERE transfer_no = 'TR2607030151';
  IF v_op IS NULL THEN
    SELECT id INTO v_op FROM auth.users ORDER BY created_at LIMIT 1;
  END IF;

  UPDATE customer_orders
     SET status       = 'completed',
         cancelled_at = NULL,
         updated_by   = v_op,
         updated_at   = NOW()
   WHERE id = 30709;

  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_order.tenant_id, 30709, 'order', NULL, 'status',
    to_jsonb('cancelled'::text), to_jsonb('completed'::text),
    'TR2607030151(取貨後退回)被總倉拒絕，rpc_reject_transfer 誤取消原訂單；手動復原至 completed，商品回到原訂單',
    v_op
  );

  RAISE NOTICE 'order 30709 復原 cancelled → completed，已補稽核列 (operator=%)', v_op;
END $$;

-- 驗證（同一 batch 最後一句會顯示）：
SELECT id, order_no, status, cancelled_at, updated_at
  FROM customer_orders WHERE id = 30709;

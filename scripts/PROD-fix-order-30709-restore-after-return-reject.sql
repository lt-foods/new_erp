-- ============================================================
-- PROD FIX: GRP-20260612-010-0067 (customer_orders.id = 30709) → 改回「未取貨」
--
-- 事故經過（2026-07-07 查證）：
--   1. 訂單 30709 三品 2026-07-03 被記「取貨」(order_pickup_events #2888「一次全取」)，
--      items picked_up、各記一筆 sale 出庫 (movements 19355/19356/19357，-10)。
--   2. 同日發起「取貨後退回總倉」→ return_to_hq transfer TR2607030151 (id 3935)：
--      店端 customer_return +10 (顧客把貨帶回店) 再 customer_return -10 (出貨去總倉)。
--   3. 2026-07-06 總倉拒收 → rpc_reject_transfer：transfer_reject +10 (退回店) +
--      **誤把原訂單 30709 設成 cancelled**（rpc_reject_transfer 為互助單設計、
--      對 return_to_hq 的 customer_order_id=原訂單 錯配）。
--   4. 已先用前一版腳本把 30709 從 cancelled 還原（現況 status=completed）。
--
-- 使用者要的終態：**未取貨**（會員其實沒領走，退貨原因註記即「未取」）。
--
-- 關鍵：庫存**不可再動**。
--   店10 每個 SKU 的 order 相關 movement 淨額
--     = sale(-10) + customer_return(+10) + customer_return(-10) + transfer_reject(+10) = 0
--   ＝貨已在店（等同「到貨、未取」）。取貨的 sale(-10) 早被退貨的 customer_return(+10)
--   抵銷，若再跑 rpc_undo_pickup 會多沖一筆 +10／SKU＝30 個幽靈庫存。故本腳本
--   **只改訂單/品項狀態、不寫任何 stock_movements、不呼叫 rpc_undo_pickup**。
--
-- 修法（冪等，只有現況非 ready 才動）：
--   1. customer_order_items 36208/36209/36210: picked_up → ready、清 pickup_movement_id
--   2. customer_orders 30709: → ready、清 completed_at / cancelled_at
--   3. customer_order_audit_log 逐品項 + 訂單各補一列 field='status'（後台「編輯歷史」看得到）
--
-- 需以 postgres/owner 身分執行（Studio SQL Editor 或 Management API）以繞過 audit_log RLS。
--
-- Rollback（把它改回 completed / 已取貨；庫存本來就沒動、無須還原）：
--   UPDATE customer_order_items SET status='picked_up',
--          pickup_movement_id = CASE id WHEN 36208 THEN 19355 WHEN 36209 THEN 19356
--                                       WHEN 36210 THEN 19357 END
--    WHERE id IN (36208,36209,36210);
--   UPDATE customer_orders SET status='completed' WHERE id=30709;
--   -- audit 為 append-only，如需移除以 owner 關 trg_no_mut_coa 後 DELETE 本次列。
-- ============================================================
DO $$
DECLARE
  v_order  customer_orders%ROWTYPE;
  v_op     UUID;
  v_item   RECORD;
  v_before TEXT;
  v_cnt    INT := 0;
BEGIN
  SELECT * INTO v_order FROM customer_orders WHERE id = 30709 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'order 30709 not found'; END IF;

  IF v_order.status = 'ready' THEN
    RAISE NOTICE 'order 30709 已是 ready(未取貨) — 略過'; RETURN;
  END IF;

  -- operator：優先取拒收該退貨單者，否則退回最早的 auth 使用者（owner）
  SELECT updated_by INTO v_op FROM transfers WHERE transfer_no = 'TR2607030151';
  IF v_op IS NULL THEN SELECT id INTO v_op FROM auth.users ORDER BY created_at LIMIT 1; END IF;

  v_before := v_order.status;

  -- 1. 品項 picked_up → ready，清 pickup_movement_id（不動庫存）
  FOR v_item IN
    SELECT id FROM customer_order_items WHERE order_id = 30709 AND status = 'picked_up'
  LOOP
    UPDATE customer_order_items
       SET status = 'ready', pickup_movement_id = NULL,
           updated_by = v_op, updated_at = NOW()
     WHERE id = v_item.id;

    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_order.tenant_id, 30709, 'item', v_item.id, 'status',
      to_jsonb('picked_up'::text), to_jsonb('ready'::text),
      'TR2607030151(取貨後退回)被總倉拒收、會員實際未取貨；品項改回未取貨。庫存不動（sale 已被退貨 customer_return 抵銷）',
      v_op
    );
    v_cnt := v_cnt + 1;
  END LOOP;

  -- 2. 訂單 → ready(未取貨)，清 completed_at / cancelled_at
  UPDATE customer_orders
     SET status       = 'ready',
         completed_at = NULL,
         cancelled_at = NULL,
         ready_at     = COALESCE(ready_at, NOW()),
         updated_by   = v_op,
         updated_at   = NOW()
   WHERE id = 30709;

  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_order.tenant_id, 30709, 'order', NULL, 'status',
    to_jsonb(v_before), to_jsonb('ready'::text),
    'TR2607030151(取貨後退回)被總倉拒收、會員實際未取貨；訂單改回未取貨(ready)。庫存不動（貨已在店、order 相關 movement 淨額=0）',
    v_op
  );

  RAISE NOTICE 'order 30709 % → ready(未取貨)，還原 % 個品項，已補稽核 (operator=%)', v_before, v_cnt, v_op;
END $$;

-- 驗證
SELECT co.id, co.order_no, co.status, co.completed_at, co.cancelled_at,
       jsonb_agg(jsonb_build_object('item', coi.id, 'status', coi.status,
                                    'pickup_movement_id', coi.pickup_movement_id)
                 ORDER BY coi.id) AS items
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
 WHERE co.id = 30709
 GROUP BY co.id, co.order_no, co.status, co.completed_at, co.cancelled_at;

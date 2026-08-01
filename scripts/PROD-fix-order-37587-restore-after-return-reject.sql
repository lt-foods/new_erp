-- ============================================================
-- PROD FIX: GRP-20260623-022-INT0038 (customer_orders.id = 37587) → 還原「已到店(ready)」
--
-- 事故經過（2026-08-01 查證）：
--   1. 訂單 37587（湖口店長內部叫貨、1 件 G00704-01 / sku 2226）7/31 06:33
--      隨 transfer 8178 到店 → 訂單 ready（ready_at=2026-07-31 06:33:53）。
--      品項 44221 維持 pending（store_internal 品項不隨收貨改狀態，事故前即如此）。
--   2. 8/1 04:44 店端以「退貨」建 return_to_hq 退貨單 TR2608010350（transfer 8372）：
--      customer_return -1（店端出庫、帳面出貨去總倉）。訂單狀態不動（設計如此）。
--   3. 8/1 06:30 總倉拒收（原因「非退貨 是少收」）→ rpc_reject_transfer：
--      transfer_reject +1（貨帳退回店端，正確）＋
--      **誤把原訂單 37587 設成 cancelled**（rpc_reject_transfer 的訂單取消
--      為互助單設計、對 return_to_hq 的 customer_order_id=原訂單 錯配；
--      與 30709 / TR2607030151 同型事故，RPC 本體已由
--      20260801000000_reject_return_to_hq_keep_original_order.sql 修正）。
--
-- 終態：訂單回「已到店(ready)」＝拒收前的狀態，店家可正常處理（取貨或另走少收）。
--
-- 關鍵：**庫存不可再動**。
--   店18 sku2226 本事件相關 movement 淨額
--     = customer_return(-1, mov 48919) + transfer_reject(+1, mov 49446) = 0
--   ＝貨帳已在店。品項 44221 從頭到尾是 pending、未被動過，不需還原。
--   故本腳本**只改訂單狀態、不寫任何 stock_movements、不動品項**。
--
-- 修法（冪等，只有現況 cancelled 才動）：
--   1. customer_orders 37587: cancelled → ready、清 cancelled_at（ready_at 保留原值）
--   2. customer_order_audit_log 補一列 field='status'（後台「編輯歷史」看得到）
--
-- 需以 postgres/owner 身分執行（Studio SQL Editor 或 Management API）以繞過 audit_log RLS。
--
-- Rollback（改回 cancelled；庫存本來就沒動、無須還原）：
--   UPDATE customer_orders SET status='cancelled',
--          cancelled_at='2026-08-01 06:30:20.460583+00' WHERE id=37587;
--   -- audit 為 append-only，如需移除以 owner 關 trg_no_mut_coa 後 DELETE 本次列。
-- ============================================================
DO $$
DECLARE
  v_order  customer_orders%ROWTYPE;
  v_op     UUID;
  v_before TEXT;
BEGIN
  SELECT * INTO v_order FROM customer_orders WHERE id = 37587 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'order 37587 not found'; END IF;

  IF v_order.status <> 'cancelled' THEN
    RAISE NOTICE 'order 37587 目前是 %（非 cancelled）— 略過', v_order.status; RETURN;
  END IF;

  -- operator：優先取拒收該退貨單者，否則退回最早的 auth 使用者（owner）
  SELECT updated_by INTO v_op FROM transfers WHERE transfer_no = 'TR2608010350';
  IF v_op IS NULL THEN SELECT id INTO v_op FROM auth.users ORDER BY created_at LIMIT 1; END IF;

  v_before := v_order.status;

  UPDATE customer_orders
     SET status       = 'ready',
         cancelled_at = NULL,
         ready_at     = COALESCE(ready_at, NOW()),
         updated_by   = v_op,
         updated_at   = NOW()
   WHERE id = 37587;

  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_order.tenant_id, 37587, 'order', NULL, 'status',
    to_jsonb(v_before), to_jsonb('ready'::text),
    'TR2608010350(退訂單回總倉)被總倉拒收(非退貨 是少收)，rpc_reject_transfer 誤取消原訂單；還原為已到店(ready)。庫存不動（customer_return -1 已被 transfer_reject +1 抵銷、貨帳在店）',
    v_op
  );

  RAISE NOTICE 'order 37587 % → ready(已到店)，已補稽核 (operator=%)', v_before, v_op;
END $$;

-- 驗證
SELECT co.id, co.order_no, co.status, co.ready_at, co.cancelled_at, co.completed_at,
       jsonb_agg(jsonb_build_object('item', coi.id, 'status', coi.status,
                                    'pickup_movement_id', coi.pickup_movement_id)
                 ORDER BY coi.id) AS items
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
 WHERE co.id = 37587
 GROUP BY co.id, co.order_no, co.status, co.ready_at, co.cancelled_at, co.completed_at;

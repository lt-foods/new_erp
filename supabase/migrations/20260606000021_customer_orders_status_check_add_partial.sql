-- ============================================================
-- 修補：CHECK 漏掉 partially_completed
--   rpc_record_pickup 部分取貨時會 SET customer_orders.status='partially_completed'
--   先前 20260606000020 砍掉它導致 partial pickup 會被 CHECK 擋
--   （生產 0 筆是因為偶然沒人做過 partial，不代表這個 status 沒在用）
-- ============================================================

ALTER TABLE customer_orders DROP CONSTRAINT IF EXISTS customer_orders_status_check;

ALTER TABLE customer_orders
  ADD CONSTRAINT customer_orders_status_check
  CHECK (status IN (
    'pending','confirmed','ready','shipping','partially_completed',
    'completed','cancelled','transferred_out','expired'
  ));

COMMENT ON CONSTRAINT customer_orders_status_check ON customer_orders IS
  '對齊 apps/admin/src/lib/orderStatus.ts ORDER_STATUSES (9 個)；新增 status 須同步改此 + lib';

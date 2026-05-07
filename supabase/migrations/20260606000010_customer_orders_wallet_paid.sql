-- ============================================================
-- customer_orders.wallet_paid_amount
--   訂單以儲值金支付的累計金額
--   對應 wallet_ledger spend/refund/reversal entries (source_type='customer_order')
--   應付剩餘 = payable_amount - wallet_paid_amount (新 view 提供 balance_due)
-- ============================================================

ALTER TABLE customer_orders
  ADD COLUMN wallet_paid_amount NUMERIC(18,2) NOT NULL DEFAULT 0
    CHECK (wallet_paid_amount >= 0);

COMMENT ON COLUMN customer_orders.wallet_paid_amount IS
  '此訂單以儲值金支付的累計金額；source of truth 仍是 wallet_ledger，本欄位為快取/索引用途';

-- partial index：只索引有用儲值金的訂單（多數訂單為 0、不入索引）
CREATE INDEX idx_corders_wallet_paid ON customer_orders (member_id)
  WHERE wallet_paid_amount > 0;

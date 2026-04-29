-- ============================================================
-- customer_orders: 加 LIFF 顧客端「我的結單」頁所需的付款 / 出貨 / 金額欄位
--
-- 不另開 shipping_status：出貨狀態用既有 customer_orders.status 派生
--   shipping / completed → 已寄出
--   其他                 → 未寄出
--
-- payment_status 是新維度，與 status 平行（一筆訂單同時有 status 與 payment_status）
-- ============================================================

ALTER TABLE customer_orders
  ADD COLUMN payment_method   TEXT,
  ADD COLUMN payment_status   TEXT NOT NULL DEFAULT 'unpaid'
    CHECK (payment_status IN ('unpaid', 'paid')),
  ADD COLUMN paid_at          TIMESTAMPTZ,
  ADD COLUMN remit_amount     NUMERIC(18,2) NOT NULL DEFAULT 0,
  ADD COLUMN remit_at         TIMESTAMPTZ,
  ADD COLUMN remit_note       TEXT,
  ADD COLUMN shipping_method  TEXT,
  ADD COLUMN shipping_address TEXT,
  ADD COLUMN shipping_phone   TEXT,
  ADD COLUMN shipping_note    TEXT,
  ADD COLUMN shipping_fee     NUMERIC(18,2) NOT NULL DEFAULT 0,
  ADD COLUMN discount_amount  NUMERIC(18,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN customer_orders.payment_method   IS '付款方式（顧客可見）：貨到付款 / 匯款 / 信用卡 等';
COMMENT ON COLUMN customer_orders.payment_status   IS '付款狀態：unpaid / paid（與 status 平行）';
COMMENT ON COLUMN customer_orders.paid_at          IS '付款完成時點';
COMMENT ON COLUMN customer_orders.remit_amount     IS '匯款金額（顧客匯款備案）';
COMMENT ON COLUMN customer_orders.remit_at         IS '匯款時間';
COMMENT ON COLUMN customer_orders.remit_note       IS '匯款備註（後 5 碼等）';
COMMENT ON COLUMN customer_orders.shipping_method  IS '出貨方式：面交 / 宅配 / 自取';
COMMENT ON COLUMN customer_orders.shipping_address IS '收件地址（宅配用）';
COMMENT ON COLUMN customer_orders.shipping_phone   IS '收件人電話';
COMMENT ON COLUMN customer_orders.shipping_note    IS '出貨備註';
COMMENT ON COLUMN customer_orders.shipping_fee     IS '運費（含於應付）';
COMMENT ON COLUMN customer_orders.discount_amount  IS '折扣金額（從應付扣除）';

CREATE INDEX idx_corders_payment_status ON customer_orders (member_id, payment_status, status);

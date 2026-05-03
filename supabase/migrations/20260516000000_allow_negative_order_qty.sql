-- ============================================================
-- 負數訂單（庫存抵減單）schema 支援
--
-- 業務情境：店裡已有庫存不想多訂，又不想取消顧客的訂單，
-- 但要讓採購聚合扣掉這部分。做法是門市建一張 order_kind='offset'
-- 的訂單、qty 為負，由 store_internal member 持有，僅在 demand
-- 聚合時參與抵減，不會出現在顧客視角。
--
-- 變更：
--   1. customer_order_items.qty CHECK qty > 0 → CHECK qty <> 0
--   2. customer_orders 新增 order_kind 欄位 (normal | offset)
--   3. 加 idx_customer_orders_kind 加速依 kind 過濾
-- ============================================================

ALTER TABLE customer_order_items DROP CONSTRAINT customer_order_items_qty_check;
ALTER TABLE customer_order_items ADD CONSTRAINT customer_order_items_qty_check CHECK (qty <> 0);

ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS order_kind TEXT NOT NULL DEFAULT 'normal'
    CHECK (order_kind IN ('normal', 'offset'));

COMMENT ON COLUMN customer_orders.order_kind IS
  'normal=一般訂單; offset=門市庫存抵減單（qty<0，由 store_internal member 建立，僅影響採購聚合）';

CREATE INDEX IF NOT EXISTS idx_customer_orders_kind
  ON customer_orders(tenant_id, campaign_id, order_kind);

-- 既有 partial UNIQUE INDEX customer_orders_trio_active_uniq（20260509000006 建立）
-- 不含 order_kind，會讓同 store_internal member 不能同時有 normal (店長叫貨) 與
-- offset (抵減單)。改成包含 order_kind 才允許共存。
DROP INDEX IF EXISTS customer_orders_trio_active_uniq;

CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq
  ON customer_orders (tenant_id, campaign_id, channel_id, member_id, order_kind)
  WHERE status NOT IN ('transferred_out', 'expired', 'cancelled');

COMMENT ON INDEX customer_orders_trio_kind_active_uniq IS
  '同 (tenant, campaign, channel, member, order_kind) 只允許一筆 active 訂單；'
  'closed (transferred_out/expired/cancelled) 不佔 slot。'
  '加 order_kind 是為了讓 store_internal member 可同時有 normal 與 offset 兩張單。';

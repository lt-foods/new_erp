-- ============================================================
-- customer_orders: 提前加 5 個狀態時間戳（idempotent）
--
-- 原 migration 20260510000003 加這 5 欄，但 20260429160002 view 已經 reference
-- 它們，導致 fresh bootstrap 失敗（local supabase start / supabase db reset）。
--
-- 本 migration idempotent — 對既有 prod（已 apply 20260510000003）是 no-op；
-- 對 fresh bootstrap 提供必要欄位。
-- ============================================================

ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS shipping_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ready_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

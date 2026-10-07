-- 20261006000000_rls_backup_coi_price_tables.sql
--
-- Supabase 安全掃描（2026-10-03）：rls_disabled_in_public
--   public._backup_coi_price_20260519（6 列）
--   public._backup_coi_price_20260520（0 列）
--
-- 這兩張是 2026-05-19/20 手動修 customer_order_items.unit_price（SKU 761 從 0 改 339）
-- 時直接在線上建的備份表，從來沒有對應 migration，也沒有任何 view / 函式 / 前端引用
-- （repo 全域 grep 為 0）。public schema 預設 GRANT 讓 anon / authenticated 都有 SELECT，
-- 而且沒開 RLS → PostgREST 對任何人都讀得到。
--
-- 做法：保留資料備查，但開 RLS（不建 policy ＝ 全擋）並收回 anon / authenticated / PUBLIC 的
-- 所有權限。CREATE TABLE IF NOT EXISTS 是為了讓「從零重跑」的環境不會因表不存在而失敗
-- （結構照線上 \d 抄）。
--
-- rollback：
--   ALTER TABLE public._backup_coi_price_20260519 DISABLE ROW LEVEL SECURITY;
--   ALTER TABLE public._backup_coi_price_20260520 DISABLE ROW LEVEL SECURITY;
--   GRANT SELECT ON public._backup_coi_price_20260519, public._backup_coi_price_20260520
--     TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public._backup_coi_price_20260519 (
  backed_up_at   timestamptz,
  item_id        bigint,
  order_id       bigint,
  sku_id         bigint,
  old_unit_price numeric,
  new_unit_price numeric
);

CREATE TABLE IF NOT EXISTS public._backup_coi_price_20260520 (
  backed_up_at   timestamptz,
  item_id        bigint,
  order_id       bigint,
  sku_id         bigint,
  old_unit_price numeric,
  new_unit_price numeric
);

ALTER TABLE public._backup_coi_price_20260519 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public._backup_coi_price_20260520 ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public._backup_coi_price_20260519 FROM anon, authenticated, PUBLIC;
REVOKE ALL ON public._backup_coi_price_20260520 FROM anon, authenticated, PUBLIC;

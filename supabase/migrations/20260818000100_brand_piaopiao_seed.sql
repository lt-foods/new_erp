-- ============================================================
-- 2026-08-18: 建立「漂漂館」子品牌（B-1）
--
-- 背景：
--   漂漂館要跟找貨群團購分線，但 brands 裡從來沒有「漂漂館」這一筆
--   （現況只有 3 個品牌、is_sub_brand 子品牌 0 個）。
--   欄位 brands.is_sub_brand / parent_brand_id 早在
--   20260423120003_purchase_v02_review_arrival.sql:41-43 就 ALTER 加好了，
--   PRD（docs/PRD-採購模組-v0.2-addendum.md §漂漂館）也設計過，但從沒被建起來。
--
-- 這支是「資料」不是 schema，所以特別注意三件事：
--   1. brands 有 UNIQUE (tenant_id, code) → code 一定要給值。
--      用 'PIAOPIAO'：前端一律以 code 反查 id（apps/admin/src/lib/piaopiao.ts），
--      ⛔ 不寫死任何 brand id。
--   2. ⛔ 不寫死 tenant_id：對每一個「還活著的租戶」各建一筆。
--      取兩個來源的聯集，避免有租戶只出現在其中一邊：
--        - tenants（status <> 'deleted'）
--        - brands 裡已經出現過的 tenant_id（比 tenants 表更早存在的租戶）
--   3. idempotent：ON CONFLICT (tenant_id, code) DO NOTHING
--      → 重複套用不會變成兩筆，也不會覆寫老闆事後改過的 name/is_active。
--
-- parent_brand_id 刻意留 NULL：
--   漂漂館目前沒有母品牌可指（既有三個品牌是「其他 / 自有品牌 / 進口品牌」，
--   都不是漂漂館的母品牌）。is_sub_brand = TRUE 本身就是老闆要的「子品牌」語意，
--   idx_brands_sub 這個 partial index 也只吃 is_sub_brand = TRUE。
--
-- created_by / updated_by 留 NULL：
--   migration 由 service_role / postgres 執行，沒有 auth.uid() 可寫，
--   與 20260707000000_tenants_table.sql 的 backfill 同慣例。
--
-- Rollback：
--   -- 只刪「還沒有任何商品掛上去」的那些，已經在用的不要動
--   DELETE FROM brands b
--    WHERE b.code = 'PIAOPIAO'
--      AND NOT EXISTS (SELECT 1 FROM products p WHERE p.brand_id = b.id)
--      AND NOT EXISTS (SELECT 1 FROM skus    s WHERE s.brand_id = b.id);
--
-- Scope：只寫一筆資料。不動 schema、不動任何函式、不碰既有 2098 個商品
--        （老闆已拍板「舊商品不回頭標記」）。
-- ============================================================

INSERT INTO brands (tenant_id, code, name, is_active, is_sub_brand)
SELECT t.id, 'PIAOPIAO', '漂漂館', TRUE, TRUE
  FROM (
    SELECT id FROM public.tenants WHERE status <> 'deleted'
    UNION
    SELECT DISTINCT tenant_id FROM public.brands
  ) AS t(id)
ON CONFLICT (tenant_id, code) DO NOTHING;

-- 自檢：套完之後每個租戶都應該剛好有一筆漂漂館（0 筆代表 tenants 是空的，要人工確認）
DO $$
DECLARE
  v_brands  BIGINT;
  v_tenants BIGINT;
BEGIN
  SELECT COUNT(*) INTO v_brands FROM brands WHERE code = 'PIAOPIAO';
  SELECT COUNT(*) INTO v_tenants FROM (
    SELECT id FROM public.tenants WHERE status <> 'deleted'
    UNION
    SELECT DISTINCT tenant_id FROM public.brands
  ) AS t(id);

  RAISE NOTICE '漂漂館品牌：% 筆 / 目標租戶 % 個', v_brands, v_tenants;

  IF v_brands = 0 THEN
    RAISE WARNING '沒有建立任何漂漂館品牌 —— tenants 與 brands 都查不到租戶，請人工確認';
  END IF;
END $$;

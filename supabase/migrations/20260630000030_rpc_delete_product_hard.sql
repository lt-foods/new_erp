-- ============================================================
-- rpc_delete_product：軟刪除 → 硬刪除（實體刪除），守門加「不可有關聯開團」
--
-- 變更動機（使用者要求）：
--   商品要能「硬刪除」（實體移除 product + 其 skus 及設定資料），
--   但「裡面有開團」不可刪。
--   守門改為：
--     1. 上架中(status='active') 不可刪 → 請先下架。
--     2. 有關聯開團不可刪（排除 __INTERNAL_RESTOCK__ 補貨 sentinel）。
--     3. 有任何顧客訂單不可刪（FK 安全 + 邏輯上必經開團）。
--
-- 為何先前是軟刪除：
--   skus / products 有 forbid_sku_delete 的 BEFORE DELETE trigger
--   （trg_no_delete_sku / trg_no_delete_product）一律 raise。
--   硬刪除需在交易內暫停這兩個 trigger，刪完（含例外路徑）一律補回。
--
-- FK 安全（products / skus 多為「無 ON DELETE CASCADE」被參照）：
--   無開團、無訂單的商品，realistically 只殘留「設定時期」子表：
--     prices / barcodes / sku_suppliers / promotion_skus / sku_packs(CASCADE)
--     pending_barcodes.resolved_sku_id(可空) / campaign_items(僅 sentinel 防禦)
--   並需解除 community_product_candidates.adopted_product_id / similar_product_id
--   （選品候選 → 建商品時會回填 adopted_product_id，無 CASCADE；刪商品時把該
--    候選還原成未排程，回到選品池）。
--   其餘下游表（庫存/採購/撿貨/調撥/結算…）僅在商品被使用後才有列，已被守門
--   2/3 擋住；萬一仍有殘參照，DELETE 觸發 foreign_key_violation → 捕捉後改丟
--   可讀訊息，避免噴原始 FK 錯誤。
--
-- 以哪個版本為基底：
--   20260618000010_rpc_delete_product.sql（時間最新、唯一現役定義；軟刪除版）。
-- Rollback：
--   重新套用 20260618000010_rpc_delete_product.sql 即恢復軟刪除行為。
--
-- Scope：只改 rpc_delete_product，不動表、不動 trigger 定義、不動其他 RPC。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_delete_product(
  p_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_status TEXT;
  v_before JSONB;
BEGIN
  SELECT status INTO v_status
    FROM products
   WHERE id = p_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'product % not found', p_id;
  END IF;

  -- 守門 1：上架中不可刪
  IF v_status = 'active' THEN
    RAISE EXCEPTION 'product % is active, cannot delete', p_id;
  END IF;

  -- 守門 2：有關聯開團不可刪（排除 __INTERNAL_RESTOCK__ 補貨 sentinel）
  --   兩條關聯路徑：group_buy_campaigns.product_id、或 campaign_items→skus
  IF EXISTS (
    SELECT 1
      FROM group_buy_campaigns c
     WHERE c.tenant_id = v_tenant
       AND c.campaign_no <> '__INTERNAL_RESTOCK__'
       AND (
         c.product_id = p_id
         OR EXISTS (
           SELECT 1
             FROM campaign_items ci
             JOIN skus s ON s.id = ci.sku_id
            WHERE ci.campaign_id = c.id
              AND s.product_id   = p_id
              AND s.tenant_id    = v_tenant
         )
       )
  ) THEN
    RAISE EXCEPTION 'product % has campaigns, cannot delete', p_id;
  END IF;

  -- 守門 3：有任何顧客訂單不可刪
  IF EXISTS (
    SELECT 1
      FROM customer_order_items coi
      JOIN skus s ON s.id = coi.sku_id
     WHERE s.product_id = p_id
       AND s.tenant_id  = v_tenant
  ) THEN
    RAISE EXCEPTION 'product % has orders, cannot delete', p_id;
  END IF;

  SELECT to_jsonb(p) INTO v_before FROM products p WHERE p.id = p_id;

  -- 解除選品候選的回填參照（無 CASCADE）：把採用此商品的候選還原回選品池
  UPDATE community_product_candidates
     SET adopted_product_id   = NULL,
         owner_action         = CASE WHEN owner_action IN ('scheduled','adopted')
                                     THEN 'none' ELSE owner_action END,
         scheduled_open_at    = NULL,
         scheduled_sort_order = NULL,
         scheduled_by         = NULL,
         scheduled_at         = NULL,
         updated_at           = NOW(),
         updated_by           = v_user
   WHERE adopted_product_id = p_id AND tenant_id = v_tenant;
  UPDATE community_product_candidates
     SET similar_product_id = NULL
   WHERE similar_product_id = p_id AND tenant_id = v_tenant;

  -- 暫停 skus / products 的物理刪除保護
  ALTER TABLE skus     DISABLE TRIGGER trg_no_delete_sku;
  ALTER TABLE products DISABLE TRIGGER trg_no_delete_product;
  BEGIN
    -- 先清掉「設定時期」會參照 sku 的無 CASCADE 子表
    DELETE FROM prices
     WHERE sku_id IN (SELECT id FROM skus WHERE product_id = p_id AND tenant_id = v_tenant);
    DELETE FROM barcodes
     WHERE sku_id IN (SELECT id FROM skus WHERE product_id = p_id AND tenant_id = v_tenant);
    DELETE FROM sku_suppliers
     WHERE sku_id IN (SELECT id FROM skus WHERE product_id = p_id AND tenant_id = v_tenant);
    DELETE FROM promotion_skus
     WHERE sku_id IN (SELECT id FROM skus WHERE product_id = p_id AND tenant_id = v_tenant);
    -- 防禦：殘留的 campaign_items（理論上僅 sentinel；真實開團已被守門 2 擋）
    DELETE FROM campaign_items
     WHERE sku_id IN (SELECT id FROM skus WHERE product_id = p_id AND tenant_id = v_tenant);
    -- pending_barcodes.resolved_sku_id 可為 NULL，解除參照
    UPDATE pending_barcodes
       SET resolved_sku_id = NULL, resolved = FALSE,
           resolved_by = NULL, resolved_at = NULL
     WHERE resolved_sku_id IN (SELECT id FROM skus WHERE product_id = p_id AND tenant_id = v_tenant);
    -- 刪 sku（sku_packs 由 FK ON DELETE CASCADE 連帶刪）
    DELETE FROM skus     WHERE product_id = p_id AND tenant_id = v_tenant;
    -- 刪 product 本體
    DELETE FROM products WHERE id = p_id AND tenant_id = v_tenant;
  EXCEPTION
    WHEN foreign_key_violation THEN
      ALTER TABLE skus     ENABLE TRIGGER trg_no_delete_sku;
      ALTER TABLE products ENABLE TRIGGER trg_no_delete_product;
      RAISE EXCEPTION 'product % still referenced by other records, cannot delete', p_id;
    WHEN OTHERS THEN
      ALTER TABLE skus     ENABLE TRIGGER trg_no_delete_sku;
      ALTER TABLE products ENABLE TRIGGER trg_no_delete_product;
      RAISE;
  END;
  ALTER TABLE skus     ENABLE TRIGGER trg_no_delete_sku;
  ALTER TABLE products ENABLE TRIGGER trg_no_delete_product;

  -- 稽核（product_audit_log.entity_id 無 FK，記已刪商品 id；after=NULL）
  PERFORM public._log_product_audit(
    v_tenant, 'product', p_id, 'delete',
    v_before, NULL, '商品硬刪除（實體刪除：product + skus + 價格/條碼/供應商等設定）'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_product(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_product(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_product(BIGINT) IS
  '商品硬刪除：限非上架中、無關聯開團、無顧客訂單；實體刪除 product + skus 及 prices/barcodes/sku_suppliers/promotion_skus 等設定（sku_packs CASCADE），暫停 forbid_sku_delete trigger；還原採用此商品的選品候選；同 tenant；寫 product_audit_log action=delete。';

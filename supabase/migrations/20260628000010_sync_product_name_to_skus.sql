-- ============================================================
-- 同步 products.name → skus.product_name (denorm 欄位)
--
-- 背景：
--   skus.product_name 是 products.name 的反正規化快照，rpc_upsert_sku 建立／更新
--   SKU 時會帶過去；但 rpc_upsert_product 改名只動 products.name，沒 cascade，
--   導致訂單明細 / 揀貨單等讀 skus.product_name 的畫面顯示舊名（例如 LINE 匯入
--   殘留的 "(emoji)..." 即使在 products 改乾淨了還是出現在訂單裡）。
--
--   `_sync_product_name_to_campaigns` 已處理 group_buy_campaigns.name，這裡補做
--   skus.product_name 對等的同步。
--
-- Scope: 加 trigger function + trigger + backfill；不動既有表 / RPC
-- Rollback:
--   DROP TRIGGER IF EXISTS trg_products_sync_sku_name ON products;
--   DROP FUNCTION IF EXISTS public._sync_product_name_to_skus();
-- ============================================================

CREATE OR REPLACE FUNCTION public._sync_product_name_to_skus()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.name IS NOT DISTINCT FROM OLD.name THEN
    RETURN NEW;
  END IF;

  UPDATE skus
     SET product_name = NEW.name,
         updated_at   = NOW()
   WHERE tenant_id   = NEW.tenant_id
     AND product_id  = NEW.id
     AND product_name IS DISTINCT FROM NEW.name;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_sync_sku_name ON products;
CREATE TRIGGER trg_products_sync_sku_name
  AFTER UPDATE OF name ON products
  FOR EACH ROW
  EXECUTE FUNCTION public._sync_product_name_to_skus();

COMMENT ON FUNCTION public._sync_product_name_to_skus() IS
  'Auto-sync product.name → skus.product_name (denorm snapshot) when product name changes.';

-- ----------------------------------------------------------------
-- 一次性 backfill：把目前 stale 的 skus.product_name 補成 products.name
-- ----------------------------------------------------------------
DO $$
DECLARE
  cnt INT;
BEGIN
  WITH updated AS (
    UPDATE skus s
       SET product_name = p.name,
           updated_at   = NOW()
      FROM products p
     WHERE s.product_id = p.id
       AND s.tenant_id  = p.tenant_id
       AND s.product_name IS DISTINCT FROM p.name
    RETURNING 1
  )
  SELECT COUNT(*) INTO cnt FROM updated;
  RAISE NOTICE 'Backfill: synced % skus.product_name to current products.name', cnt;
END $$;

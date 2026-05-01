-- ============================================================
-- 同步 product / SKU 變更到關聯的 draft/open campaign
--
-- 兩個情境：
--   1. 商品零售價更新 → campaign_items.unit_price 自動跟（draft/open campaign）
--   2. 商品名稱更新   → group_buy_campaigns.name 自動跟（限 1-product 的 campaign）
--
-- 設計：
--   - 只動 status IN ('draft','open') 的 campaign（已收單後不再變動）
--   - 多商品 campaign（campaign_items 跨多個 product_id）不自動改 name，避免覆蓋使用者命名
--   - 1-product campaign（候選池排日期 / 從單一商品開團）name 跟著 product 走
--
-- Scope: 加 trigger function + trigger + backfill；不動既有表 / RPC
-- Rollback:
--   DROP TRIGGER IF EXISTS trg_prices_sync_campaigns ON prices;
--   DROP TRIGGER IF EXISTS trg_products_sync_campaign_name ON products;
--   DROP FUNCTION IF EXISTS public._sync_retail_price_to_campaigns();
--   DROP FUNCTION IF EXISTS public._sync_product_name_to_campaigns();
-- ============================================================

-- ----------------------------------------------------------------
-- Trigger 1: prices INSERT (scope='retail') → 同步 campaign_items.unit_price
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sync_retail_price_to_campaigns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 只處理 retail（cost / branch / promo 不影響 campaign 售價）
  IF NEW.scope IS DISTINCT FROM 'retail' THEN
    RETURN NEW;
  END IF;
  -- 只處理「現行價」（effective_to IS NULL = 最新版）
  IF NEW.effective_to IS NOT NULL THEN
    RETURN NEW;
  END IF;

  UPDATE campaign_items ci
     SET unit_price = NEW.price,
         updated_at = NOW()
    FROM group_buy_campaigns gbc
   WHERE ci.tenant_id  = NEW.tenant_id
     AND ci.sku_id     = NEW.sku_id
     AND ci.campaign_id = gbc.id
     AND gbc.tenant_id = NEW.tenant_id
     AND gbc.status IN ('draft','open');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prices_sync_campaigns ON prices;
CREATE TRIGGER trg_prices_sync_campaigns
  AFTER INSERT ON prices
  FOR EACH ROW
  EXECUTE FUNCTION public._sync_retail_price_to_campaigns();

-- ----------------------------------------------------------------
-- Trigger 2: products UPDATE OF name → 同步 1-product campaign.name
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sync_product_name_to_campaigns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.name IS NOT DISTINCT FROM OLD.name THEN
    RETURN NEW;
  END IF;

  -- 只更新「campaign_items 內所有 SKU 都屬於這個 product」的 campaign
  -- (子查詢用 GROUP BY + HAVING 篩出 1-product campaign)
  UPDATE group_buy_campaigns gbc
     SET name = NEW.name,
         updated_at = NOW()
   WHERE gbc.tenant_id = NEW.tenant_id
     AND gbc.status IN ('draft','open')
     AND gbc.id IN (
       SELECT ci.campaign_id
         FROM campaign_items ci
         JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
        WHERE ci.tenant_id = NEW.tenant_id
        GROUP BY ci.campaign_id
       HAVING COUNT(DISTINCT s.product_id) = 1
          AND MAX(s.product_id) = NEW.id
     );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_sync_campaign_name ON products;
CREATE TRIGGER trg_products_sync_campaign_name
  AFTER UPDATE OF name ON products
  FOR EACH ROW
  EXECUTE FUNCTION public._sync_product_name_to_campaigns();

COMMENT ON FUNCTION public._sync_retail_price_to_campaigns() IS
  'Auto-sync retail price changes to campaign_items.unit_price for draft/open campaigns.';
COMMENT ON FUNCTION public._sync_product_name_to_campaigns() IS
  'Auto-sync product.name to group_buy_campaigns.name for single-product draft/open campaigns.';

-- ----------------------------------------------------------------
-- 一次性 backfill：把 draft/open campaign 的價格 / 名稱補齊到目前 product/price 狀態
-- ----------------------------------------------------------------
DO $$
DECLARE
  cnt_price INT;
  cnt_name  INT;
BEGIN
  -- 價格 backfill：每個 campaign_items 的 unit_price 更新成 SKU 目前的 retail 最新值
  WITH updated AS (
    UPDATE campaign_items ci
       SET unit_price = sub.retail_price,
           updated_at = NOW()
      FROM (
        SELECT s.id AS sku_id, s.tenant_id,
               COALESCE((
                 SELECT pr.price
                   FROM prices pr
                  WHERE pr.tenant_id = s.tenant_id
                    AND pr.sku_id    = s.id
                    AND pr.scope     = 'retail'
                    AND pr.effective_to IS NULL
                  ORDER BY pr.effective_from DESC
                  LIMIT 1
               ), 0) AS retail_price
          FROM skus s
      ) sub,
           group_buy_campaigns gbc
     WHERE ci.sku_id      = sub.sku_id
       AND ci.tenant_id   = sub.tenant_id
       AND ci.campaign_id = gbc.id
       AND gbc.tenant_id  = sub.tenant_id
       AND gbc.status IN ('draft','open')
       AND ci.unit_price IS DISTINCT FROM sub.retail_price
    RETURNING 1
  )
  SELECT COUNT(*) INTO cnt_price FROM updated;
  RAISE NOTICE 'Backfill: synced % campaign_items.unit_price', cnt_price;

  -- 名稱 backfill：1-product campaign 名稱跟 product.name 對齊
  WITH single_product_campaigns AS (
    SELECT ci.campaign_id,
           MAX(s.product_id)        AS product_id,
           MAX(p.name)              AS p_name,
           (MAX(gbc.tenant_id::TEXT))::UUID AS tenant_id
      FROM campaign_items ci
      JOIN skus s ON s.id = ci.sku_id
      JOIN products p ON p.id = s.product_id
      JOIN group_buy_campaigns gbc ON gbc.id = ci.campaign_id
     WHERE gbc.status IN ('draft','open')
     GROUP BY ci.campaign_id
    HAVING COUNT(DISTINCT s.product_id) = 1
  ),
  updated AS (
    UPDATE group_buy_campaigns gbc
       SET name = spc.p_name,
           updated_at = NOW()
      FROM single_product_campaigns spc
     WHERE gbc.id = spc.campaign_id
       AND gbc.tenant_id = spc.tenant_id
       AND gbc.name IS DISTINCT FROM spc.p_name
    RETURNING 1
  )
  SELECT COUNT(*) INTO cnt_name FROM updated;
  RAISE NOTICE 'Backfill: synced % campaign names', cnt_name;
END $$;

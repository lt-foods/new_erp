-- ============================================================
-- 1 campaign : 1 product invariant
--
-- 變更：
--   1. group_buy_campaigns 加 product_id BIGINT REFERENCES products(id)
--   2. Backfill：從既有 campaign_items 反查 product（多商品 campaign 取第一個 product_id）
--   3. 加 trigger：campaign_items INSERT/UPDATE 時，新 SKU 的 product_id 必須等於 campaign.product_id
--   4. 簡化 _sync_product_name_to_campaigns trigger：直接看 campaign.product_id（拿掉 1-product 子查詢）
--   5. rpc_schedule_candidate / rpc_create_campaign_from_products 之後在後續 migration / RPC 重寫負責設 product_id
--
-- 既有 6 個多商品 campaign：backfill 取第一個 product_id；constraint 只擋未來 INSERT、不破壞歷史
--
-- Scope: 加欄位 + 簡化 trigger + 加 trigger
-- Rollback:
--   ALTER TABLE group_buy_campaigns DROP COLUMN product_id;
--   DROP TRIGGER IF EXISTS trg_campaign_items_check_product ON campaign_items;
--   DROP FUNCTION IF EXISTS public._enforce_campaign_product_invariant();
-- ============================================================

-- ----------------------------------------------------------------
-- 1. 加 product_id 欄位
-- ----------------------------------------------------------------
ALTER TABLE group_buy_campaigns
  ADD COLUMN IF NOT EXISTS product_id BIGINT REFERENCES products(id);

CREATE INDEX IF NOT EXISTS idx_gbc_product
  ON group_buy_campaigns (tenant_id, product_id);

COMMENT ON COLUMN group_buy_campaigns.product_id IS
  '1 campaign : 1 product invariant；所有 campaign_items.skus.product_id 必須等於此欄位';

-- ----------------------------------------------------------------
-- 2. Backfill：每個 campaign 找 SKU 對應的 product_id（多商品取最小 sku_id 的 product）
-- ----------------------------------------------------------------
DO $$
DECLARE
  cnt INT;
BEGIN
  WITH first_product_per_campaign AS (
    SELECT DISTINCT ON (ci.campaign_id)
           ci.campaign_id,
           s.product_id,
           ci.tenant_id
      FROM campaign_items ci
      JOIN skus s ON s.id = ci.sku_id
     ORDER BY ci.campaign_id, ci.sku_id
  ),
  updated AS (
    UPDATE group_buy_campaigns gbc
       SET product_id = fp.product_id
      FROM first_product_per_campaign fp
     WHERE gbc.id = fp.campaign_id
       AND gbc.tenant_id = fp.tenant_id
       AND gbc.product_id IS NULL
    RETURNING 1
  )
  SELECT COUNT(*) INTO cnt FROM updated;
  RAISE NOTICE 'Backfill: set product_id on % group_buy_campaigns', cnt;
END $$;

-- ----------------------------------------------------------------
-- 3. campaign_items 防呆 trigger：新加的 SKU 必須跟 campaign.product_id 同 product
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._enforce_campaign_product_invariant()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign_product BIGINT;
  v_sku_product      BIGINT;
BEGIN
  SELECT product_id INTO v_campaign_product
    FROM group_buy_campaigns
   WHERE id = NEW.campaign_id
     AND tenant_id = NEW.tenant_id;

  -- campaign 還沒設 product_id（理論上 backfill 後不會發生）→ 略過
  IF v_campaign_product IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT product_id INTO v_sku_product
    FROM skus
   WHERE id = NEW.sku_id
     AND tenant_id = NEW.tenant_id;

  IF v_sku_product IS DISTINCT FROM v_campaign_product THEN
    RAISE EXCEPTION '1-campaign-1-product invariant violated: campaign % is for product %, but sku % belongs to product %',
      NEW.campaign_id, v_campaign_product, NEW.sku_id, v_sku_product;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_campaign_items_check_product ON campaign_items;
CREATE TRIGGER trg_campaign_items_check_product
  BEFORE INSERT OR UPDATE OF sku_id ON campaign_items
  FOR EACH ROW
  EXECUTE FUNCTION public._enforce_campaign_product_invariant();

-- ----------------------------------------------------------------
-- 4. 簡化 _sync_product_name_to_campaigns：直接 join campaign.product_id
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

  UPDATE group_buy_campaigns
     SET name = NEW.name,
         updated_at = NOW()
   WHERE tenant_id = NEW.tenant_id
     AND product_id = NEW.id
     AND status IN ('draft','open');

  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------
-- 5. _sync_sku_to_open_campaigns 也改成用 campaign.product_id（更直接）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sync_sku_to_open_campaigns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unit_price NUMERIC;
  c            RECORD;
BEGIN
  IF NEW.status IS DISTINCT FROM 'active' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'active' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(p.price, 0) INTO v_unit_price
    FROM prices p
   WHERE p.tenant_id = NEW.tenant_id
     AND p.sku_id    = NEW.id
     AND p.scope     = 'retail'
     AND p.effective_to IS NULL
   ORDER BY p.effective_from DESC
   LIMIT 1;
  v_unit_price := COALESCE(v_unit_price, 0);

  -- 改用 campaign.product_id 直接找：所有此 product 的 draft/open campaign
  FOR c IN
    SELECT id AS campaign_id
      FROM group_buy_campaigns
     WHERE tenant_id  = NEW.tenant_id
       AND product_id = NEW.product_id
       AND status IN ('draft','open')
  LOOP
    INSERT INTO campaign_items (
      tenant_id, campaign_id, sku_id, unit_price, sort_order,
      created_by, updated_by
    ) VALUES (
      NEW.tenant_id, c.campaign_id, NEW.id, v_unit_price, 999,
      auth.uid(), auth.uid()
    )
    ON CONFLICT (campaign_id, sku_id) DO NOTHING;
  END LOOP;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._sync_product_name_to_campaigns() IS
  'Auto-sync product.name → group_buy_campaigns.name for draft/open campaigns linked via product_id (1:1 invariant).';
COMMENT ON FUNCTION public._sync_sku_to_open_campaigns() IS
  'Auto-add new active SKU to draft/open campaigns linked to the same product via campaign.product_id.';

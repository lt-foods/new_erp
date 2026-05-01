-- ============================================================
-- 開團 status 從 draft → open 時、把活動單價 snapshot 鎖定
--
-- 變更：
--   1. campaign_items 加 locked_at TIMESTAMPTZ 欄位（鎖定時間）
--   2. 修 _sync_retail_price_to_campaigns trigger：只動 status='draft' 的 campaign
--      （open 後 retail 改不影響活動單價）
--   3. 加 trigger _lock_campaign_prices_on_open：
--      campaign.status: draft → open 那一刻、把所有 campaign_items.locked_at 設成 NOW()
--   4. Backfill：既有 status >= open 的 campaign，locked_at 補成 campaign.updated_at
--
-- 之後使用者要手動調整 open 後的活動單價，仍可直接 UPDATE campaign_items.unit_price
-- （trigger 不會干擾）
--
-- Scope: 加欄位 + 加 trigger + 改 trigger，不動 RPC / customer_order_items
-- Rollback:
--   ALTER TABLE campaign_items DROP COLUMN locked_at;
--   DROP TRIGGER IF EXISTS trg_campaigns_lock_on_open ON group_buy_campaigns;
--   DROP FUNCTION IF EXISTS public._lock_campaign_prices_on_open();
--   重新 apply 20260514000007 的 _sync_retail_price_to_campaigns
-- ============================================================

-- ----------------------------------------------------------------
-- 1. 加 locked_at 欄位
-- ----------------------------------------------------------------
ALTER TABLE campaign_items
  ADD COLUMN IF NOT EXISTS locked_at TIMESTAMPTZ;

COMMENT ON COLUMN campaign_items.locked_at IS
  'Snapshot lock time. NULL = draft（unit_price 跟 retail 走）；NOT NULL = 已鎖定（status >= open，retail 改不再影響）';

-- ----------------------------------------------------------------
-- 2. 改 _sync_retail_price_to_campaigns：只動 draft 的 campaign
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sync_retail_price_to_campaigns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.scope IS DISTINCT FROM 'retail' THEN
    RETURN NEW;
  END IF;
  IF NEW.effective_to IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- 只動 draft 階段（open 後鎖定）
  UPDATE campaign_items ci
     SET unit_price = NEW.price,
         updated_at = NOW()
    FROM group_buy_campaigns gbc
   WHERE ci.tenant_id  = NEW.tenant_id
     AND ci.sku_id     = NEW.sku_id
     AND ci.campaign_id = gbc.id
     AND gbc.tenant_id = NEW.tenant_id
     AND gbc.status    = 'draft';

  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------
-- 3. 新 trigger：campaign.status: draft → open 鎖定價格
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._lock_campaign_prices_on_open()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.status = 'draft' AND NEW.status = 'open' THEN
    UPDATE campaign_items
       SET locked_at  = NOW(),
           updated_at = NOW()
     WHERE campaign_id = NEW.id
       AND tenant_id   = NEW.tenant_id
       AND locked_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_campaigns_lock_on_open ON group_buy_campaigns;
CREATE TRIGGER trg_campaigns_lock_on_open
  AFTER UPDATE OF status ON group_buy_campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public._lock_campaign_prices_on_open();

COMMENT ON FUNCTION public._lock_campaign_prices_on_open() IS
  'On campaign status draft→open: snapshot locked_at = NOW() for all campaign_items.';

-- ----------------------------------------------------------------
-- 4. Backfill：既有 status >= open 的 campaign_items.locked_at = campaign.updated_at
-- ----------------------------------------------------------------
DO $$
DECLARE
  cnt INT;
BEGIN
  WITH updated AS (
    UPDATE campaign_items ci
       SET locked_at = gbc.updated_at
      FROM group_buy_campaigns gbc
     WHERE ci.campaign_id = gbc.id
       AND ci.tenant_id   = gbc.tenant_id
       AND gbc.status IN ('open','closed','ordered','receiving','ready','completed','cancelled')
       AND ci.locked_at IS NULL
    RETURNING 1
  )
  SELECT COUNT(*) INTO cnt FROM updated;
  RAISE NOTICE 'Backfill: locked_at set on % campaign_items rows', cnt;
END $$;

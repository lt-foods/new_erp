-- ============================================================
-- 新 SKU 自動加到該商品所有 draft / open 的 campaign 商品明細
--
-- 背景：
--   - rpc_schedule_candidate 建出的 campaign 一開始只有 1 個自動 default SKU。
--   - 之後使用者去商品編輯頁加第 2 個規格、campaign 那邊不會跟著同步。
--   - rpc_create_campaign_from_products 已經會抓所有 active SKU（不需修），
--     這個 trigger 補的是「campaign 建立後新增 SKU」的同步。
--
-- 行為：
--   AFTER INSERT ON skus（status='active'）→
--     找該 product_id 在 group_buy_campaigns status IN ('draft','open') 的 campaign
--     對每個 campaign 補一筆 campaign_items（unit_price 用 retail 最新值或 0）
--     ON CONFLICT (campaign_id, sku_id) DO NOTHING — 防 race
--
-- AFTER UPDATE ON skus（status: 非 active → active）也同步
-- AFTER UPDATE ON skus（status: active → 非 active）不主動移除，保留歷史 / 訂單參照
--
-- 不動 closed/ordered/receiving/ready/completed/cancelled 的 campaign（已凍結）
--
-- Scope: 加 trigger function + trigger，不動既有 RPC
-- Rollback:
--   DROP TRIGGER IF EXISTS trg_skus_sync_campaigns_ins ON skus;
--   DROP TRIGGER IF EXISTS trg_skus_sync_campaigns_upd ON skus;
--   DROP FUNCTION IF EXISTS public._sync_sku_to_open_campaigns();
-- ============================================================

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
  -- 只處理 active SKU
  IF NEW.status IS DISTINCT FROM 'active' THEN
    RETURN NEW;
  END IF;

  -- UPDATE 路徑：若 status 沒從非 active 變成 active 就不同步
  IF TG_OP = 'UPDATE' AND OLD.status = 'active' THEN
    RETURN NEW;
  END IF;

  -- 抓最新 retail price 當 unit_price（找不到回 0）
  SELECT COALESCE(p.price, 0)
    INTO v_unit_price
    FROM prices p
   WHERE p.tenant_id = NEW.tenant_id
     AND p.sku_id    = NEW.id
     AND p.scope     = 'retail'
     AND p.effective_to IS NULL
   ORDER BY p.effective_from DESC
   LIMIT 1;
  v_unit_price := COALESCE(v_unit_price, 0);

  -- 對所有同 product 的 draft / open campaign 補一筆 campaign_items
  FOR c IN
    SELECT DISTINCT gbc.id AS campaign_id
      FROM group_buy_campaigns gbc
      JOIN campaign_items ci ON ci.campaign_id = gbc.id AND ci.tenant_id = NEW.tenant_id
      JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = NEW.tenant_id
     WHERE gbc.tenant_id = NEW.tenant_id
       AND gbc.status IN ('draft','open')
       AND s.product_id = NEW.product_id
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

DROP TRIGGER IF EXISTS trg_skus_sync_campaigns_ins ON skus;
CREATE TRIGGER trg_skus_sync_campaigns_ins
  AFTER INSERT ON skus
  FOR EACH ROW
  EXECUTE FUNCTION public._sync_sku_to_open_campaigns();

DROP TRIGGER IF EXISTS trg_skus_sync_campaigns_upd ON skus;
CREATE TRIGGER trg_skus_sync_campaigns_upd
  AFTER UPDATE OF status ON skus
  FOR EACH ROW
  EXECUTE FUNCTION public._sync_sku_to_open_campaigns();

COMMENT ON FUNCTION public._sync_sku_to_open_campaigns() IS
  'Auto-add new active SKU to draft/open campaigns of the same product. Trigger on skus INSERT/UPDATE.';

-- ============================================================
-- 一次性 backfill：把目前 draft / open campaign 缺漏的同商品 active SKU 補齊
-- ============================================================
DO $$
DECLARE
  cnt INT;
BEGIN
  WITH inserted AS (
    INSERT INTO campaign_items (
      tenant_id, campaign_id, sku_id, unit_price, sort_order,
      created_by, updated_by
    )
    SELECT DISTINCT
           s_new.tenant_id,
           gbc.id,
           s_new.id,
           COALESCE((
             SELECT p.price
               FROM prices p
              WHERE p.tenant_id = s_new.tenant_id
                AND p.sku_id = s_new.id
                AND p.scope = 'retail'
                AND p.effective_to IS NULL
              ORDER BY p.effective_from DESC
              LIMIT 1
           ), 0),
           999,
           NULL::UUID,
           NULL::UUID
      FROM group_buy_campaigns gbc
      JOIN campaign_items ci_existing ON ci_existing.campaign_id = gbc.id
                                      AND ci_existing.tenant_id = gbc.tenant_id
      JOIN skus s_existing ON s_existing.id = ci_existing.sku_id
                           AND s_existing.tenant_id = gbc.tenant_id
      JOIN skus s_new ON s_new.product_id = s_existing.product_id
                      AND s_new.tenant_id = gbc.tenant_id
                      AND s_new.status = 'active'
                      AND s_new.id <> s_existing.id
     WHERE gbc.status IN ('draft','open')
       AND NOT EXISTS (
         SELECT 1 FROM campaign_items ci_check
          WHERE ci_check.campaign_id = gbc.id
            AND ci_check.sku_id      = s_new.id
       )
    ON CONFLICT (campaign_id, sku_id) DO NOTHING
    RETURNING 1
  )
  SELECT COUNT(*) INTO cnt FROM inserted;
  RAISE NOTICE 'Backfill: added % campaign_items rows', cnt;
END $$;

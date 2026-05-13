-- ============================================================
-- 防護 trigger + 驗證 fn — 確保 purchase_request_items.source_campaign_id
-- 永遠跟 purchase_request_campaigns join 表同步
--
-- 為什麼：撿貨工作站 v_picking_demand_by_po 用 join 表抓 PR↔campaign linkage。
-- 但歷史上 rpc_create_pr_from_close_date / rpc_append_campaign_to_pr 都漏寫
-- join 表 (只寫 pri.source_campaign_id)，導致 PO 被建出來但撿貨看不到。
-- 已在 20260614000010 修這兩支 RPC + view fallback、本檔是「永久防護」：
--
-- 1. AFTER INSERT/UPDATE OF source_campaign_id ON purchase_request_items
--    → 自動 upsert purchase_request_campaigns row
--    (任何寫入 pri 的 RPC / SQL 都會自動同步, 不再依賴呼叫端)
-- 2. fn_check_pr_campaigns_consistency() → 回傳孤兒清單 (供 e2e / CI 驗)
-- 3. Migration 末尾跑自我檢查 → 0 rows 才算 OK、否則 RAISE
--
-- Rollback: DROP TRIGGER + DROP FUNCTION
-- ============================================================

-- 1. Sync trigger function
CREATE OR REPLACE FUNCTION public.trg_sync_pri_to_prc()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant UUID;
BEGIN
  -- 只在 source_campaign_id 非 NULL 時 sync
  IF NEW.source_campaign_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- 取對應 PR 的 tenant_id (purchase_request_campaigns 帶 tenant_id 用於 RLS)
  SELECT tenant_id INTO v_tenant
    FROM purchase_requests
   WHERE id = NEW.pr_id;

  IF v_tenant IS NULL THEN
    -- 防禦性：PR 不存在 (應該不可能、FK 已保護),但保險起見不 raise
    RETURN NEW;
  END IF;

  -- Upsert join 表
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (NEW.pr_id, NEW.source_campaign_id, v_tenant)
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.trg_sync_pri_to_prc() IS
  '自動 sync purchase_request_items.source_campaign_id → purchase_request_campaigns; '
  '由 trg_pri_sync_campaigns trigger 觸發,任何寫入 pri 都會自動補 join 表。';

-- 2. Trigger
DROP TRIGGER IF EXISTS trg_pri_sync_campaigns ON public.purchase_request_items;
CREATE TRIGGER trg_pri_sync_campaigns
AFTER INSERT OR UPDATE OF source_campaign_id, pr_id
ON public.purchase_request_items
FOR EACH ROW
EXECUTE FUNCTION public.trg_sync_pri_to_prc();

-- 3. Consistency check function (給 e2e / CI 用)
CREATE OR REPLACE FUNCTION public.fn_check_pr_campaigns_consistency()
RETURNS TABLE(
  issue TEXT,
  pr_id BIGINT,
  pr_no TEXT,
  pr_status TEXT,
  sku_id BIGINT,
  campaign_id BIGINT,
  campaign_no TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  -- 情境 1: pri.source_campaign_id 存在但 join 表沒對應 row
  RETURN QUERY
  SELECT
    'orphan_pri_campaign'::TEXT,
    pri.pr_id,
    pr.pr_no,
    pr.status,
    pri.sku_id,
    pri.source_campaign_id,
    gbc.campaign_no
  FROM purchase_request_items pri
  JOIN purchase_requests pr ON pr.id = pri.pr_id
  LEFT JOIN group_buy_campaigns gbc ON gbc.id = pri.source_campaign_id
  WHERE pri.source_campaign_id IS NOT NULL
    AND pr.status NOT IN ('cancelled')
    AND NOT EXISTS (
      SELECT 1 FROM purchase_request_campaigns prc
      WHERE prc.pr_id = pri.pr_id
        AND prc.campaign_id = pri.source_campaign_id
    );
END;
$$;

COMMENT ON FUNCTION public.fn_check_pr_campaigns_consistency() IS
  '檢查 purchase_request_items.source_campaign_id ↔ purchase_request_campaigns 一致性; '
  '回傳所有孤兒。E2E / CI 應期待 0 rows。';

GRANT EXECUTE ON FUNCTION public.fn_check_pr_campaigns_consistency() TO authenticated;

-- 4. Self-check: migration 末尾跑檢查、有孤兒就 RAISE
DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM public.fn_check_pr_campaigns_consistency();
  IF v_count > 0 THEN
    RAISE EXCEPTION 'PR campaigns consistency check failed: % orphan rows. '
      'Run "SELECT * FROM fn_check_pr_campaigns_consistency()" to see details.',
      v_count;
  END IF;
  RAISE NOTICE 'PR campaigns invariant OK (0 orphans).';
END;
$$;

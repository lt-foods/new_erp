-- ============================================================
-- 2026-05-14: 兩件事
--   A. SKU 從 active → 非 active (inactive/discontinued) 時，
--      自動清掉所有 status='draft' 的 campaign_items（已下架的 SKU
--      不該出現在草稿開團中）。open / closed 以後不動，避免破壞已產生
--      的訂單/採購。
--   B. rpc_bulk_set_campaign_status：列表頁批次切換開團狀態
--      （draft → open / open → closed），維持既有 trigger
--      (`_lock_campaign_prices_on_open`) 行為。
-- ============================================================

-- ----------------------------------------------------------------
-- A. _cleanup_sku_from_draft_campaigns trigger
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._cleanup_sku_from_draft_campaigns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 只在 active → 非 active 那一刻動作
  IF OLD.status = 'active' AND NEW.status IS DISTINCT FROM 'active' THEN
    DELETE FROM campaign_items ci
     USING group_buy_campaigns gbc
     WHERE ci.campaign_id = gbc.id
       AND ci.sku_id      = NEW.id
       AND gbc.tenant_id  = NEW.tenant_id
       AND gbc.status     = 'draft';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_skus_cleanup_draft_campaigns ON skus;
CREATE TRIGGER trg_skus_cleanup_draft_campaigns
  AFTER UPDATE OF status ON skus
  FOR EACH ROW
  EXECUTE FUNCTION public._cleanup_sku_from_draft_campaigns();

COMMENT ON FUNCTION public._cleanup_sku_from_draft_campaigns() IS
  'SKU active→非 active 時，從同 tenant 的 draft 開團移除對應 campaign_items。';

-- ----------------------------------------------------------------
-- A.1 Backfill：現存「draft 開團 + 已下架 SKU」也清乾淨
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_deleted INTEGER;
BEGIN
  WITH del AS (
    DELETE FROM campaign_items ci
     USING group_buy_campaigns gbc, skus s
     WHERE ci.campaign_id = gbc.id
       AND ci.sku_id      = s.id
       AND gbc.status     = 'draft'
       AND s.status       <> 'active'
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_deleted FROM del;
  RAISE NOTICE 'Backfill: removed % campaign_items where draft campaign × non-active sku', v_deleted;
END $$;

-- ----------------------------------------------------------------
-- B. rpc_bulk_set_campaign_status — 列表頁批次操作用
--    走 UPDATE 觸發 `_lock_campaign_prices_on_open`；同 tenant 限制；
--    驗證合法狀態轉換：draft↔open / open→closed。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_bulk_set_campaign_status(
  p_ids    BIGINT[],
  p_status TEXT
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
  v_cur    TEXT;
  v_count  INTEGER := 0;
BEGIN
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;
  IF p_status NOT IN ('draft','open','closed','cancelled') THEN
    RAISE EXCEPTION 'invalid bulk target status: %', p_status;
  END IF;

  FOREACH v_id IN ARRAY p_ids LOOP
    SELECT status INTO v_cur FROM group_buy_campaigns
      WHERE id = v_id AND tenant_id = v_tenant;
    IF v_cur IS NULL THEN
      CONTINUE; -- 跨 tenant / 不存在
    END IF;
    IF v_cur = p_status THEN
      CONTINUE; -- 已是目標
    END IF;

    -- 合法轉換：
    --   draft → open / cancelled
    --   open  → closed / cancelled
    --   closed → cancelled
    IF NOT (
         (v_cur = 'draft'  AND p_status IN ('open','cancelled'))
      OR (v_cur = 'open'   AND p_status IN ('closed','cancelled'))
      OR (v_cur = 'closed' AND p_status = 'cancelled')
    ) THEN
      CONTINUE; -- 跳過不合法的轉換
    END IF;

    -- 額外保護：draft→open 前要有 campaign_items
    IF v_cur = 'draft' AND p_status = 'open' THEN
      PERFORM 1 FROM campaign_items WHERE campaign_id = v_id LIMIT 1;
      IF NOT FOUND THEN
        CONTINUE;
      END IF;
    END IF;

    UPDATE group_buy_campaigns
       SET status     = p_status,
           updated_by = auth.uid(),
           updated_at = NOW()
     WHERE id = v_id AND tenant_id = v_tenant;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_bulk_set_campaign_status(BIGINT[], TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bulk_set_campaign_status(BIGINT[], TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_bulk_set_campaign_status(BIGINT[], TEXT) IS
  '批次切換開團狀態（draft/open/closed/cancelled）。同 tenant、合法轉換、有 items 才放行。回傳實際變更筆數。';

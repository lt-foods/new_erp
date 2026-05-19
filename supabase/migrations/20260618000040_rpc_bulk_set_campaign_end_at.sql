-- ============================================================
-- 2026-06-18: rpc_bulk_set_campaign_end_at
--   列表頁多選 → 批次設定開團「收單時間」(group_buy_campaigns.end_at)
--   對齊 rpc_bulk_set_campaign_status 的骨架：
--     - 同 tenant 限制（_current_tenant_id）
--     - 僅「還在收單」階段可改：status IN ('draft','open')
--       一旦 closed/ordered/receiving/ready/completed/cancelled，
--       end_at 已被結單流程（rpc_close_campaign 以 end_at 當收單日
--       決定 PR 連動）快照，不可再被批次改動
--     - 跨 tenant / 不存在 / 狀態不符 一律略過，回傳實際變更筆數
--   self-contained：僅依賴 group_buy_campaigns + _current_tenant_id()
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_bulk_set_campaign_end_at(
  p_ids    BIGINT[],
  p_end_at TIMESTAMPTZ
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
  IF p_end_at IS NULL THEN
    RAISE EXCEPTION 'p_end_at is required';
  END IF;

  FOREACH v_id IN ARRAY p_ids LOOP
    SELECT status INTO v_cur FROM group_buy_campaigns
      WHERE id = v_id AND tenant_id = v_tenant;
    IF v_cur IS NULL THEN
      CONTINUE; -- 跨 tenant / 不存在
    END IF;
    -- 只有「草稿 / 開團中」可改收單時間
    IF v_cur NOT IN ('draft','open') THEN
      CONTINUE;
    END IF;

    UPDATE group_buy_campaigns
       SET end_at     = p_end_at,
           updated_by = auth.uid(),
           updated_at = NOW()
     WHERE id = v_id AND tenant_id = v_tenant;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_bulk_set_campaign_end_at(BIGINT[], TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bulk_set_campaign_end_at(BIGINT[], TIMESTAMPTZ) TO authenticated;

COMMENT ON FUNCTION public.rpc_bulk_set_campaign_end_at(BIGINT[], TIMESTAMPTZ) IS
  '批次設定開團收單時間 end_at。同 tenant、僅 draft/open 可改（closed 之後 end_at 已被結單快照）。回傳實際變更筆數。';

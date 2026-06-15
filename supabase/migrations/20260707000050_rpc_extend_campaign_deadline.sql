-- ============================================================
-- 2026-07-07: rpc_extend_campaign_deadline
--   單筆延長「開團中」活動的收單時間 end_at（campaigns 頁「延長結單」按鈕）。
--   基底 = 20260618000040_rpc_bulk_set_campaign_end_at（最新動到 end_at 的 RPC）骨架，
--   收緊為：單筆 / 限 status='open' / 只能往後延 / 僅 owner|admin。
--   守門：
--     1) 角色：僅 owner / admin。讀 app_metadata.role —— 頂層 auth.jwt()->>'role'
--        在這套一律是 'authenticated'，讀錯路徑會連 owner 都被擋（踩過雷）。
--     2) 同 tenant（_current_tenant_id）且活動存在。
--     3) 僅 status='open' 可延長；closed 之後 end_at 已被結單流程（rpc_close_campaign
--        以 end_at 當收單日決定 PR 連動）快照，不可再改。
--     4) 新時間必須在未來、且嚴格晚於目前 end_at（只能延後、不能提前）。
--   self-contained：僅依賴 group_buy_campaigns + _current_tenant_id() + auth.uid()/auth.jwt()。
--   回傳：更新後的 end_at。
--   rollback：DROP FUNCTION public.rpc_extend_campaign_deadline(BIGINT, TIMESTAMPTZ);
--            （本檔為首次建立，無前一版本）
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_extend_campaign_deadline(
  p_campaign_id BIGINT,
  p_new_end_at  TIMESTAMPTZ
) RETURNS TIMESTAMPTZ
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant  UUID := public._current_tenant_id();
  v_role    TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_status  TEXT;
  v_cur_end TIMESTAMPTZ;
BEGIN
  -- (1) 權限：僅 owner / admin
  IF v_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION '權限不足：僅 owner/admin 可延長結單時間'
      USING ERRCODE = '42501';
  END IF;

  IF p_new_end_at IS NULL THEN
    RAISE EXCEPTION 'p_new_end_at is required';
  END IF;

  -- (2) 同 tenant 取目標活動
  SELECT status, end_at INTO v_status, v_cur_end
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant;

  IF v_status IS NULL THEN
    RAISE EXCEPTION '找不到開團或不在目前 tenant：%', p_campaign_id;
  END IF;

  -- (3) 僅開團中可延長
  IF v_status <> 'open' THEN
    RAISE EXCEPTION '僅「開團中」可延長結單時間（目前狀態：%）', v_status;
  END IF;

  -- (4) 只能往後延：新時間需在未來且嚴格晚於目前 end_at
  IF p_new_end_at <= NOW() THEN
    RAISE EXCEPTION '新收單時間必須在未來';
  END IF;
  IF v_cur_end IS NOT NULL AND p_new_end_at <= v_cur_end THEN
    RAISE EXCEPTION '新收單時間必須晚於目前收單時間（目前：%）', v_cur_end;
  END IF;

  UPDATE group_buy_campaigns
     SET end_at     = p_new_end_at,
         updated_by = auth.uid(),
         updated_at = NOW()
   WHERE id = p_campaign_id AND tenant_id = v_tenant;

  RETURN p_new_end_at;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_extend_campaign_deadline(BIGINT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_extend_campaign_deadline(BIGINT, TIMESTAMPTZ) TO authenticated;

COMMENT ON FUNCTION public.rpc_extend_campaign_deadline(BIGINT, TIMESTAMPTZ) IS
  '單筆延長開團收單時間 end_at。僅 owner/admin、同 tenant、status=open、只能往後延。回傳更新後的 end_at。';

-- ============================================================================
-- 2026-07-07: rpc_member_gdpr_delete_bulk — 會員列表多選批次刪除
-- ----------------------------------------------------------------------------
-- 背景：rpc_member_gdpr_delete（20260618000040）一次只刪一筆。後台會員列表
--       加上「勾選多筆 → 批次刪除」需求，故補一支 array 版包裝。
--
-- 設計（對齊 rpc_bulk_set_campaign_end_at 的批次骨架）：
--   - 同 tenant 限制（_current_tenant_id；含試用到期守門）
--   - 逐筆委派給既有 rpc_member_gdpr_delete，邏輯不重寫（DRY）：
--     PII 清空 / 退卡 / 移除標籤 / 流水訂單保留 / 稽核，全沿用單筆版
--   - 跨 tenant / 不存在 / 已刪除 / 已合併 → 一律略過（CONTINUE），
--     不讓單一壞 id abort 整批；回傳「實際執行刪除」的筆數
--   - operator 取 auth.uid()，與單筆版一致
--
-- 不在此重複單筆版的觸發器/留存規則說明，詳見 20260618000040。
-- 冪等：已 deleted 的 id 會被略過（不重複動作、不灌稽核）。
-- 權限：SECURITY DEFINER（與單筆版、rpc_merge_member 同慣例，UI 端以 isAdmin
--   把關 + 二次確認）。authenticated 可執行。
-- rollback：DROP FUNCTION public.rpc_member_gdpr_delete_bulk(BIGINT[], TEXT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_member_gdpr_delete_bulk(
  p_member_ids BIGINT[],
  p_reason     TEXT DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_operator UUID := COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);
  v_id       BIGINT;
  v_status   TEXT;
  v_count    INTEGER := 0;
BEGIN
  IF p_member_ids IS NULL OR array_length(p_member_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  FOREACH v_id IN ARRAY p_member_ids LOOP
    SELECT status INTO v_status FROM members
      WHERE id = v_id AND tenant_id = v_tenant;
    IF v_status IS NULL THEN
      CONTINUE; -- 跨 tenant / 不存在
    END IF;
    IF v_status IN ('deleted', 'merged') THEN
      CONTINUE; -- 已刪除 / 已合併 略過
    END IF;

    PERFORM rpc_member_gdpr_delete(v_id, p_reason, v_operator);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_member_gdpr_delete_bulk(BIGINT[], TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_member_gdpr_delete_bulk(BIGINT[], TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_member_gdpr_delete_bulk(BIGINT[], TEXT) IS
  '會員批次 GDPR 刪除：逐筆委派 rpc_member_gdpr_delete。同 tenant、跨 tenant/不存在/已刪除/已合併略過，回傳實際刪除筆數。';

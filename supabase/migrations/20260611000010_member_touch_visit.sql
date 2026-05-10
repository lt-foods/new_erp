-- ============================================================
-- Member: last_visit_at touch
-- ============================================================
-- 目的：LIFF / OAuth login 時 bump members.last_visit_at,
-- 但不要連帶把 updated_at 也 bump（會干擾「更新」排序語意）。
--
-- 做法：
--   1. touch_updated_at() 加判斷,當 session GUC app.skip_updated_at='1' 時跳過
--   2. 新增 rpc_member_touch_visit(p_member_id) — 先 set GUC 再 UPDATE
-- ============================================================

CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  IF current_setting('app.skip_updated_at', true) = '1' THEN
    RETURN NEW;
  END IF;
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION rpc_member_touch_visit(p_member_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- transaction-local：只影響當下這次 UPDATE 的 trigger
  PERFORM set_config('app.skip_updated_at', '1', true);
  UPDATE members SET last_visit_at = NOW() WHERE id = p_member_id;
END;
$$;

-- 開放 service_role / authenticated 呼叫
GRANT EXECUTE ON FUNCTION rpc_member_touch_visit(BIGINT) TO service_role, authenticated;

COMMENT ON FUNCTION rpc_member_touch_visit(BIGINT) IS
  'LIFF / OAuth login 時 bump members.last_visit_at；不影響 updated_at（觸發器透過 GUC 跳過）。';

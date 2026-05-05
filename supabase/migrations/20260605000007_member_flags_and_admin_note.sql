-- ============================================================
-- members 加 3 欄：黑名單 (no_notify_pickup / no_new_order) + admin 暱稱備註
--   admin_note 只在 admin 介面顯示，不可外露 LIFF / 列印 / 我的介面
--   (LIFF/print 端 SELECT 都已明列欄位，不會帶到此欄)
-- ============================================================

ALTER TABLE members
  ADD COLUMN IF NOT EXISTS no_notify_pickup BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS no_new_order     BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS admin_note       TEXT;

COMMENT ON COLUMN members.no_notify_pickup IS '黑名單旗標：跳過取貨到貨通知';
COMMENT ON COLUMN members.no_new_order     IS '黑名單旗標：禁止此會員加新訂單 (UI/RPC 端阻擋)';
COMMENT ON COLUMN members.admin_note       IS '管理員專用暱稱/備註（不對外露：不在 LIFF / 列印 / 顧客介面顯示）';

-- 統一 RPC 設旗標 + admin_note (SECURITY DEFINER 繞 RLS / role NULL)
CREATE OR REPLACE FUNCTION rpc_set_member_flags(
  p_member_id        BIGINT,
  p_no_notify_pickup BOOLEAN,
  p_no_new_order     BOOLEAN,
  p_admin_note       TEXT,
  p_operator         UUID DEFAULT NULL
) RETURNS members
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role     TEXT := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                       NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                       ''
                     );
  v_operator UUID := COALESCE(p_operator, auth.uid());
  v_row      members;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant','') THEN
    RAISE EXCEPTION 'permission denied: only HQ tier can edit member flags';
  END IF;

  UPDATE members
     SET no_notify_pickup = p_no_notify_pickup,
         no_new_order     = p_no_new_order,
         admin_note       = NULLIF(TRIM(COALESCE(p_admin_note, '')), ''),
         updated_by       = v_operator,
         updated_at       = NOW()
   WHERE id = p_member_id AND tenant_id = v_tenant
   RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'member % not found in tenant %', p_member_id, v_tenant;
  END IF;
  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_set_member_flags(BIGINT, BOOLEAN, BOOLEAN, TEXT, UUID) TO authenticated;

-- ============================================================
-- Fix: rpc_next_member_no INT overflow when DB has legacy
-- member_no like 'M20260511150125485' (17-digit timestamp form).
-- Constrain regex to M + 1~9 digits so timestamp-form 編號 are
-- ignored as not part of the auto sequence.
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_next_member_no()
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_next   INT;
BEGIN
  SELECT COALESCE(MAX((SUBSTRING(member_no FROM '^M(\d{1,9})$'))::INT), 0) + 1
    INTO v_next
    FROM members
   WHERE tenant_id = v_tenant
     AND member_no ~ '^M\d{1,9}$';
  RETURN 'M' || lpad(v_next::text, 6, '0');
END;
$$;

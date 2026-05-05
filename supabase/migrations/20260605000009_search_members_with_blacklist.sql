-- ============================================================
-- 擴 rpc_search_members / rpc_search_aliases 回傳 黑名單旗標 + admin_note
--   讓 order-entry / 取貨頁可以在使用者選會員時就警告
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_search_members(TEXT, INT);
DROP FUNCTION IF EXISTS public.rpc_search_aliases(BIGINT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.rpc_search_members(
  p_term  TEXT,
  p_limit INT DEFAULT 20
) RETURNS TABLE (
  id                BIGINT,
  member_no         TEXT,
  name              TEXT,
  phone             TEXT,
  avatar_url        TEXT,
  home_store_id     BIGINT,
  home_store_name   TEXT,
  no_new_order      BOOLEAN,
  no_notify_pickup  BOOLEAN,
  admin_note        TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_term   TEXT := COALESCE(NULLIF(TRIM(p_term), ''), NULL);
  v_lim    INT  := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  RETURN QUERY
  SELECT m.id, m.member_no, m.name, m.phone, m.avatar_url,
         m.home_store_id, s.name,
         m.no_new_order, m.no_notify_pickup, m.admin_note
    FROM members m
    LEFT JOIN stores s ON s.id = m.home_store_id
   WHERE m.tenant_id = v_tenant
     AND (
       v_term IS NULL
       OR m.name      ILIKE '%' || v_term || '%'
       OR m.member_no ILIKE '%' || v_term || '%'
       OR m.phone     ILIKE '%' || v_term || '%'
     )
   ORDER BY m.created_at DESC
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_members TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_search_aliases(
  p_channel_id BIGINT,
  p_term       TEXT,
  p_limit      INT DEFAULT 20
) RETURNS TABLE (
  alias_id          BIGINT,
  nickname          TEXT,
  member_id         BIGINT,
  member_no         TEXT,
  member_name       TEXT,
  phone             TEXT,
  avatar_url        TEXT,
  home_store_id     BIGINT,
  home_store_name   TEXT,
  no_new_order      BOOLEAN,
  no_notify_pickup  BOOLEAN,
  admin_note        TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_term   TEXT := COALESCE(NULLIF(TRIM(p_term), ''), NULL);
  v_lim    INT  := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  RETURN QUERY
  SELECT a.id, a.nickname, m.id, m.member_no, m.name, m.phone, m.avatar_url,
         m.home_store_id, s.name,
         m.no_new_order, m.no_notify_pickup, m.admin_note
    FROM customer_line_aliases a
    JOIN members m ON m.id = a.member_id
    LEFT JOIN stores s ON s.id = m.home_store_id
   WHERE a.tenant_id  = v_tenant
     AND a.channel_id = p_channel_id
     AND (v_term IS NULL OR a.nickname ILIKE '%' || v_term || '%')
   ORDER BY a.updated_at DESC
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_aliases TO authenticated;

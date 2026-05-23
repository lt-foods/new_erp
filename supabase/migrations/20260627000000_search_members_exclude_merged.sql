-- ============================================================
-- rpc_search_members / rpc_search_aliases：
--   1. 排除 已合併 / 已刪除 的會員
--   2. Google 式多 token 搜尋：以空白 / + 拆字串，每個 token 都需在
--      name / member_no / phone（aliases 用 nickname）任一欄命中
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
  v_tenant UUID   := public._current_tenant_id();
  v_tokens TEXT[] := ARRAY(
    SELECT t
      FROM regexp_split_to_table(COALESCE(p_term, ''), '[\s+]+') AS t
     WHERE t <> ''
  );
  v_lim    INT    := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  RETURN QUERY
  SELECT m.id, m.member_no, m.name, m.phone, m.avatar_url,
         m.home_store_id, s.name,
         m.no_new_order, m.no_notify_pickup, m.admin_note
    FROM members m
    LEFT JOIN stores s ON s.id = m.home_store_id
   WHERE m.tenant_id = v_tenant
     AND m.status NOT IN ('merged', 'deleted')
     AND (
       COALESCE(array_length(v_tokens, 1), 0) = 0
       OR NOT EXISTS (
         SELECT 1
           FROM unnest(v_tokens) AS tok
          WHERE NOT (
            m.name      ILIKE '%' || tok || '%'
            OR m.member_no ILIKE '%' || tok || '%'
            OR m.phone     ILIKE '%' || tok || '%'
          )
       )
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
  v_tenant UUID   := public._current_tenant_id();
  v_tokens TEXT[] := ARRAY(
    SELECT t
      FROM regexp_split_to_table(COALESCE(p_term, ''), '[\s+]+') AS t
     WHERE t <> ''
  );
  v_lim    INT    := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
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
     AND m.status NOT IN ('merged', 'deleted')
     AND (
       COALESCE(array_length(v_tokens, 1), 0) = 0
       OR NOT EXISTS (
         SELECT 1
           FROM unnest(v_tokens) AS tok
          WHERE NOT (a.nickname ILIKE '%' || tok || '%')
       )
     )
   ORDER BY a.updated_at DESC
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_aliases TO authenticated;

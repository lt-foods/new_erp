-- ============================================================
-- rpc_search_members / rpc_search_aliases：搜尋命中已合併的舊檔時，
-- 翻譯成它被併進去的新會員（沿著 merged_into_member_id 最多 5 跳追到 active）。
-- 舊檔本身不再回傳；如果新會員的查詢結果中已經包含它，會自動去重。
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
  WITH RECURSIVE matches AS (
    SELECT m.id, m.status, m.merged_into_member_id, m.created_at
      FROM members m
     WHERE m.tenant_id = v_tenant
       AND m.status <> 'deleted'
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
  ),
  resolved AS (
    SELECT id AS source_id, id AS target_id, status, merged_into_member_id, 0 AS hop, created_at
      FROM matches
    UNION ALL
    SELECT r.source_id, m.id, m.status, m.merged_into_member_id, r.hop + 1, m.created_at
      FROM resolved r
      JOIN members m ON m.id = r.merged_into_member_id
     WHERE r.status = 'merged'
       AND r.merged_into_member_id IS NOT NULL
       AND r.hop < 5
  ),
  finals AS (
    SELECT DISTINCT ON (source_id) source_id, target_id, status, created_at
      FROM resolved
     ORDER BY source_id, hop DESC
  )
  SELECT m.id, m.member_no, m.name, m.phone, m.avatar_url,
         m.home_store_id, s.name,
         m.no_new_order, m.no_notify_pickup, m.admin_note
    FROM (
      SELECT DISTINCT ON (target_id) target_id, created_at
        FROM finals
       WHERE status NOT IN ('merged', 'deleted')
       ORDER BY target_id, created_at DESC
    ) f
    JOIN members m ON m.id = f.target_id
    LEFT JOIN stores s ON s.id = m.home_store_id
   ORDER BY f.created_at DESC
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
  WITH RECURSIVE matches AS (
    SELECT a.id AS alias_id, a.nickname, a.member_id, a.updated_at,
           m.status, m.merged_into_member_id
      FROM customer_line_aliases a
      JOIN members m ON m.id = a.member_id
     WHERE a.tenant_id  = v_tenant
       AND a.channel_id = p_channel_id
       AND m.status <> 'deleted'
       AND (
         COALESCE(array_length(v_tokens, 1), 0) = 0
         OR NOT EXISTS (
           SELECT 1
             FROM unnest(v_tokens) AS tok
            WHERE NOT (a.nickname ILIKE '%' || tok || '%')
         )
       )
  ),
  resolved AS (
    SELECT alias_id, nickname, member_id AS target_id, status, merged_into_member_id, 0 AS hop, updated_at
      FROM matches
    UNION ALL
    SELECT r.alias_id, r.nickname, m.id, m.status, m.merged_into_member_id, r.hop + 1, r.updated_at
      FROM resolved r
      JOIN members m ON m.id = r.merged_into_member_id
     WHERE r.status = 'merged'
       AND r.merged_into_member_id IS NOT NULL
       AND r.hop < 5
  ),
  finals AS (
    SELECT DISTINCT ON (alias_id) alias_id, nickname, target_id, status, updated_at
      FROM resolved
     ORDER BY alias_id, hop DESC
  )
  SELECT f.alias_id, f.nickname, m.id, m.member_no, m.name, m.phone, m.avatar_url,
         m.home_store_id, s.name,
         m.no_new_order, m.no_notify_pickup, m.admin_note
    FROM finals f
    JOIN members m ON m.id = f.target_id
    LEFT JOIN stores s ON s.id = m.home_store_id
   WHERE f.status NOT IN ('merged', 'deleted')
   ORDER BY f.updated_at DESC
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_aliases TO authenticated;

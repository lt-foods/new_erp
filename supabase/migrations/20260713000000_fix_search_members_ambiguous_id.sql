-- ============================================================
-- 修 rpc_search_members / rpc_search_aliases 執行期報 42702「column reference
-- "id" is ambiguous」，導致加單頁會員搜尋整個炸掉、搜不到任何會員。
--
-- 根因：20260628000000_search_members_resolve_merged.sql 的 CTE 內用了未加限定
--   的欄位名（resolved 錨點 `SELECT id AS source_id ...`；aliases 的
--   `SELECT alias_id, nickname, member_id ...`）。這些名字同時是函式 RETURNS TABLE
--   的 OUT 欄位（id / member_no / name / alias_id / nickname / member_id ...），
--   在 plpgsql 內既是變數又是欄位 → 執行期 ambiguous。CREATE 時不會報、呼叫才炸，
--   所以當初 20260627/20260628 根本沒成功套進正式庫（schema_migrations 直接跳過）。
--
-- 修法：把所有 CTE 內部欄位改用不與 OUT 欄位撞名的別名（m_*/r_*/a_*），
--   最外層才用 m.* / s.name 對應到 OUT 欄位。行為與 20260628 完全一致
--   （命中已合併舊檔 → 沿 merged_into_member_id 解算到 active 目標，舊檔不回傳）。
--
-- 另修 20260628 的第二個潛在 bug（同樣因沒真的套上線才沒爆過）：多 token 過濾
--   用 `NOT EXISTS(... WHERE NOT(name ILIKE OR member_no ILIKE OR phone ILIKE))`，
--   但 phone/name 可為 NULL，「false OR false OR NULL = NULL」，經外層 NOT 反轉後
--   會把「完全不相符」的會員誤放進結果（現象：搜任何字都跳出一堆不相干、phone 為
--   NULL 的最新會員，等同搜尋失效）。每個 ILIKE 包 COALESCE(..., FALSE) 修正。
--
-- 基底：20260628000000_search_members_resolve_merged.sql（僅修 ambiguous、邏輯不變）
-- rollback：重跑 20260605000009_search_members_with_blacklist.sql
--   （回到無合併解算、但可正常搜尋的版本）
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
    SELECT m.id                    AS m_id,
           m.status                AS m_status,
           m.merged_into_member_id AS m_into,
           m.created_at            AS m_created
      FROM members m
     WHERE m.tenant_id = v_tenant
       AND m.status <> 'deleted'
       AND (
         COALESCE(array_length(v_tokens, 1), 0) = 0
         OR NOT EXISTS (
           SELECT 1
             FROM unnest(v_tokens) AS tok
            WHERE NOT (
              -- COALESCE：phone/name 可能為 NULL；沒有 COALESCE 時
              -- 「false OR false OR NULL = NULL」，經外層 NOT 反轉會把
              -- 不相符的會員誤放進來（搜尋等同失效）。
              COALESCE(m.name      ILIKE '%' || tok || '%', FALSE)
              OR COALESCE(m.member_no ILIKE '%' || tok || '%', FALSE)
              OR COALESCE(m.phone     ILIKE '%' || tok || '%', FALSE)
            )
         )
       )
  ),
  resolved AS (
    SELECT matches.m_id     AS source_id,
           matches.m_id     AS target_id,
           matches.m_status AS r_status,
           matches.m_into   AS r_into,
           0                AS hop,
           matches.m_created AS r_created
      FROM matches
    UNION ALL
    SELECT resolved.source_id,
           m.id,
           m.status,
           m.merged_into_member_id,
           resolved.hop + 1,
           m.created_at
      FROM resolved
      JOIN members m ON m.id = resolved.r_into
     WHERE resolved.r_status = 'merged'
       AND resolved.r_into IS NOT NULL
       AND resolved.hop < 5
  ),
  finals AS (
    SELECT DISTINCT ON (resolved.source_id)
           resolved.source_id,
           resolved.target_id,
           resolved.r_status,
           resolved.r_created
      FROM resolved
     ORDER BY resolved.source_id, resolved.hop DESC
  )
  SELECT m.id, m.member_no, m.name, m.phone, m.avatar_url,
         m.home_store_id, s.name,
         m.no_new_order, m.no_notify_pickup, m.admin_note
    FROM (
      SELECT DISTINCT ON (finals.target_id) finals.target_id, finals.r_created
        FROM finals
       WHERE finals.r_status NOT IN ('merged', 'deleted')
       ORDER BY finals.target_id, finals.r_created DESC
    ) f
    JOIN members m ON m.id = f.target_id
    LEFT JOIN stores s ON s.id = m.home_store_id
   ORDER BY f.r_created DESC
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
    SELECT a.id         AS a_alias_id,
           a.nickname   AS a_nickname,
           a.member_id  AS a_member_id,
           a.updated_at AS a_updated,
           m.status                AS m_status,
           m.merged_into_member_id AS m_into
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
            WHERE NOT COALESCE(a.nickname ILIKE '%' || tok || '%', FALSE)
         )
       )
  ),
  resolved AS (
    SELECT matches.a_alias_id  AS r_alias_id,
           matches.a_nickname  AS r_nickname,
           matches.a_member_id AS target_id,
           matches.m_status    AS r_status,
           matches.m_into      AS r_into,
           0                   AS hop,
           matches.a_updated   AS r_updated
      FROM matches
    UNION ALL
    SELECT resolved.r_alias_id,
           resolved.r_nickname,
           m.id,
           m.status,
           m.merged_into_member_id,
           resolved.hop + 1,
           resolved.r_updated
      FROM resolved
      JOIN members m ON m.id = resolved.r_into
     WHERE resolved.r_status = 'merged'
       AND resolved.r_into IS NOT NULL
       AND resolved.hop < 5
  ),
  finals AS (
    SELECT DISTINCT ON (resolved.r_alias_id)
           resolved.r_alias_id,
           resolved.r_nickname,
           resolved.target_id,
           resolved.r_status,
           resolved.r_updated
      FROM resolved
     ORDER BY resolved.r_alias_id, resolved.hop DESC
  )
  SELECT f.r_alias_id, f.r_nickname, m.id, m.member_no, m.name, m.phone, m.avatar_url,
         m.home_store_id, s.name,
         m.no_new_order, m.no_notify_pickup, m.admin_note
    FROM finals f
    JOIN members m ON m.id = f.target_id
    LEFT JOIN stores s ON s.id = m.home_store_id
   WHERE f.r_status NOT IN ('merged', 'deleted')
   ORDER BY f.r_updated DESC
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_aliases TO authenticated;

-- ============================================================================
-- LINE 記事本 RLS：可見貼文改成「一次算好的陣列」，不再每列呼叫 _line_note_post_visible
--
-- 背景（2026-09-24 事故調查）：
--   DB（Small 2GB）一週 OOM 重開 6 次，當天 3 次。pg_stat_statements 排第一的是
--   留言加單頁的 line_note_comments 查詢：每次 ~5 秒。原因是 lncm_perm_read 的
--   `_line_note_post_visible(post_id)` 逐列執行（SECURITY DEFINER + SET search_path
--   無法 inline），3,303 則留言 × ~1.3ms ≈ 4.4s；v_line_note_post_groups
--   （security_invoker）走 lnp_perm_read 同樣的逐列呼叫，~3 秒。
--   總部帳號只要有 line_notes_view perm 也一樣付這筆（permissive policy 是 OR，
--   perm_read 排在前面先算）。
--
-- 改法：
--   * 新 helper `_line_note_visible_post_ids()`：一次把「分店帳號看得到的貼文 id」
--     收成 bigint[]（先算自己的店 id，再一趟 join 過濾）。語意同 _line_note_post_visible：
--     社群沒綁店或綁到自己店，且團是總部團（owner_store_id NULL）或自己店開的團；
--     campaign_id NULL 的貼文照舊只看社群那一層（LEFT JOIN）。
--   * 三條 policy 改成
--       NOT (SELECT _is_branch_scoped_user()) OR (SELECT _line_note_visible_post_ids()) @> ARRAY[id]
--     兩個都是 initplan，一個查詢只算一次；非分店帳號直接短路不算陣列。
--     陣列比對用 @>，不要寫 = ANY ((SELECT …))（見 CLAUDE.md，會 bigint = bigint[]）。
--   * _line_note_post_visible 本身不動（RPC 的單筆存取檢查還在用，單筆呼叫不貴）。
--
-- 基底版本：
--   lnp_perm_read / lncm_perm_read   → 20260918000000_line_notes_view_perm.sql
--   lncm_perm_update                 → 20260918020000_line_notes_view_perm_process_comments.sql
--
-- Rollback：重跑上面兩支 migration 裡對應的 DROP/CREATE POLICY 段落，然後
--   DROP FUNCTION public._line_note_visible_post_ids();
-- ============================================================================

CREATE OR REPLACE FUNCTION public._line_note_visible_post_ids()
RETURNS BIGINT[]
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH my_stores AS (
    SELECT COALESCE(array_agg(s.id), '{}'::BIGINT[]) AS ids
      FROM stores s
     WHERE s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
       AND COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb) ? s.name
  )
  SELECT COALESCE(array_agg(p.id), '{}'::BIGINT[])
    FROM line_note_posts p
    JOIN line_note_communities    c ON c.id = p.community_id
    LEFT JOIN group_buy_campaigns g ON g.id = p.campaign_id
    CROSS JOIN my_stores ms
   WHERE (c.store_id IS NULL OR c.store_id = ANY (ms.ids))
     AND (g.owner_store_id IS NULL OR g.owner_store_id = ANY (ms.ids));
$$;

COMMENT ON FUNCTION public._line_note_visible_post_ids() IS
  '分店帳號（_is_branch_scoped_user）看得到的 line_note_posts.id，語意同 _line_note_post_visible；給 RLS 當 initplan 用，一個查詢只算一次。';

REVOKE ALL ON FUNCTION public._line_note_visible_post_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._line_note_visible_post_ids() TO authenticated;

DROP POLICY IF EXISTS lnp_perm_read ON public.line_note_posts;
CREATE POLICY lnp_perm_read ON public.line_note_posts FOR SELECT
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND (NOT (SELECT public._is_branch_scoped_user())
         OR (SELECT public._line_note_visible_post_ids()) @> ARRAY[id])
  );

DROP POLICY IF EXISTS lncm_perm_read ON public.line_note_comments;
CREATE POLICY lncm_perm_read ON public.line_note_comments FOR SELECT
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND (NOT (SELECT public._is_branch_scoped_user())
         OR (SELECT public._line_note_visible_post_ids()) @> ARRAY[post_id])
  );

DROP POLICY IF EXISTS lncm_perm_update ON public.line_note_comments;
CREATE POLICY lncm_perm_update ON public.line_note_comments FOR UPDATE
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND (NOT (SELECT public._is_branch_scoped_user())
         OR (SELECT public._line_note_visible_post_ids()) @> ARRAY[post_id])
  )
  WITH CHECK (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND (NOT (SELECT public._is_branch_scoped_user())
         OR (SELECT public._line_note_visible_post_ids()) @> ARRAY[post_id])
  );

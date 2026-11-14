-- ============================================================
-- staff_password_reset_log：誰在什麼時候重設了誰的登入密碼（append-only）
--
-- 起因（2026-11-14）：老闆問「feifei8279 的密碼是誰改的」，只能去翻 Supabase 平台紀錄
--   （logs 的 function_edge_logs，log_attributes['request.sb.auth_user']）——
--   平台紀錄保留期有限，而 auth.audit_log_entries 線上是空的。
--   從這支起，staff-reset-password 重設成功後由 service_role 寫一列，後台員工管理頁讀。
--
-- 寫入：只有 Edge Function（service_role 繞過 RLS）。不開 INSERT/UPDATE/DELETE policy，
--       authenticated 也收回寫入權限。函式端寫入是 best-effort：寫不進去不擋重設。
-- 讀取：同公司 owner / admin / ''（沒有顯式 role 的 legacy admin），對齊 lib/role.ts ADMIN_ROLES。
--       role 一律讀 app_metadata（頂層 role 永遠是 'authenticated'）。
-- 刪除：append-only trigger；rpc_purge_tenant 用 session_replication_role=replica 繞過，
--       且本表帶 tenant_id，會被它的主迴圈自動清掉。
-- 回補：#1151 上線（2026-11-13 22:33 台北）後的兩筆，取自平台紀錄，source = 'platform_logs'。
--       IP 不進 repo；email 當場從 auth.users 取。
--
-- rollback：DROP TABLE public.staff_password_reset_log;
--   （函式寫入是 best-effort，表不在只會在函式 log 留一行錯誤，不影響重設密碼。）
-- ============================================================

CREATE TABLE IF NOT EXISTS public.staff_password_reset_log (
  id             BIGSERIAL   PRIMARY KEY,
  tenant_id      UUID        NOT NULL,
  actor_user_id  UUID        NOT NULL,
  actor_email    TEXT,
  target_user_id UUID        NOT NULL,
  target_email   TEXT,
  ip             TEXT,
  user_agent     TEXT,
  source         TEXT        NOT NULL DEFAULT 'staff-reset-password'
                   CHECK (source IN ('staff-reset-password', 'platform_logs')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sprl_tenant_created
  ON public.staff_password_reset_log (tenant_id, created_at DESC);

DROP TRIGGER IF EXISTS trg_no_mut_sprl ON public.staff_password_reset_log;
CREATE TRIGGER trg_no_mut_sprl BEFORE UPDATE OR DELETE ON public.staff_password_reset_log
  FOR EACH ROW EXECUTE FUNCTION public.forbid_append_only_mutation();

ALTER TABLE public.staff_password_reset_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sprl_admin_read ON public.staff_password_reset_log;
CREATE POLICY sprl_admin_read ON public.staff_password_reset_log
  FOR SELECT TO authenticated USING (
    tenant_id = (SELECT public._current_tenant_id())
    AND (SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')) IN ('owner', 'admin', '')
  );

REVOKE ALL ON public.staff_password_reset_log FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.staff_password_reset_log FROM authenticated;
GRANT SELECT ON public.staff_password_reset_log TO authenticated;

-- 回補（冪等：同一位目標、同一個時間點只會有一列）
INSERT INTO public.staff_password_reset_log
  (tenant_id, actor_user_id, actor_email, target_user_id, target_email, user_agent, source, created_at)
SELECT (a.raw_app_meta_data ->> 'tenant_id')::uuid, a.id, a.email, t.id, t.email, v.ua, 'platform_logs', v.at
  FROM (VALUES
    ('b261672d-2144-4a50-8881-e31c6e8e93a3'::uuid, 'ae52b562-61ff-4b96-b566-cddc7b49a9bf'::uuid,
     '2026-11-13 14:35:06.517+00'::timestamptz,
     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36'),
    ('b261672d-2144-4a50-8881-e31c6e8e93a3'::uuid, '1754a931-c4c0-41b3-a992-47bad8e47212'::uuid,
     '2026-11-13 14:37:10.957+00'::timestamptz,
     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36')
  ) AS v(actor_id, target_id, at, ua)
  JOIN auth.users a ON a.id = v.actor_id
  JOIN auth.users t ON t.id = v.target_id
 WHERE NOT EXISTS (
   SELECT 1 FROM public.staff_password_reset_log l
    WHERE l.target_user_id = v.target_id AND l.created_at = v.at
 );

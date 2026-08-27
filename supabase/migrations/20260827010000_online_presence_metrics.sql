-- ============================================================================
-- 2026-08-27: 在線人數 / DAU 指標（admin 儀表板用）
--
-- Alex：想看「多少人同時上線」「QPS / DAU」。QPS 不自己做（Supabase Dashboard
--   → Reports → API 現成就有，前端卡片放連結）；這支只做 presence / DAU：
--   - 兩個 app 登入後每 60 秒打一次心跳（admin 走 rpc_heartbeat、member 走
--     liff-api 的 heartbeat action → rpc_member_heartbeat）。
--   - 「同時在線」＝最近 3 分鐘有心跳的不重複人數（心跳 60s，3 分鐘容錯）。
--   - DAU＝當天（台北時區日界線）有心跳的不重複人數；一列 = (人,天)，
--     列數即 DAU，量級每天數百列，保留 90 天由 cron 清理。
--
-- 設計取捨：
--   - 不用 Realtime Presence（要開 channel、會員端 LIFF 不掛 supabase-js 連線），
--     心跳寫表最笨最穩，量也小（尖峰 ~200 人 × 每分鐘 1 列 upsert）。
--   - app_presence 開 RLS 但不開任何 policy —— 讀寫全走 SECURITY DEFINER RPC
--     與 service_role（liff-api），前端拿不到明細，只拿得到 rpc_online_stats
--     的彙總數字。
--   - auth.* 一律包 (SELECT ...)（見 20260818000020 RLS initplan 的教訓）。
--
-- Rollback：cron.unschedule('presence-prune-daily')；DROP FUNCTION
--   rpc_online_stats / rpc_member_heartbeat / rpc_heartbeat；DROP TABLE
--   app_presence。純新增，無既有物件被改動。
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.app_presence (
  tenant_id     UUID        NOT NULL,
  kind          TEXT        NOT NULL CHECK (kind IN ('staff', 'member')),
  subject_id    TEXT        NOT NULL,  -- staff: auth.uid()；member: members.id
  seen_date     DATE        NOT NULL,  -- 台北時區日界線
  store_id      BIGINT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT app_presence_pkey PRIMARY KEY (tenant_id, kind, subject_id, seen_date)
);

CREATE INDEX IF NOT EXISTS idx_app_presence_tenant_last_seen
  ON public.app_presence (tenant_id, last_seen_at DESC);

ALTER TABLE public.app_presence ENABLE ROW LEVEL SECURITY;
-- 刻意不開任何 policy：讀寫全走 SECURITY DEFINER RPC / service_role。

-- ---------------------------------------------------------------------------
-- 店員心跳（admin 前端每 60 秒呼叫；身分取自 JWT，前端帶不了別人的身分）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_heartbeat(p_store_id BIGINT DEFAULT NULL)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER
SET search_path TO 'public'
AS $$
  INSERT INTO app_presence (tenant_id, kind, subject_id, seen_date, store_id, last_seen_at)
  SELECT ((SELECT auth.jwt()) ->> 'tenant_id')::uuid,
         'staff',
         (SELECT auth.uid())::text,
         (NOW() AT TIME ZONE 'Asia/Taipei')::date,
         p_store_id,
         NOW()
   WHERE (SELECT auth.uid()) IS NOT NULL
     AND COALESCE((SELECT auth.jwt()) ->> 'tenant_id', '') <> ''
  ON CONFLICT (tenant_id, kind, subject_id, seen_date)
  DO UPDATE SET last_seen_at = NOW(),
                store_id     = COALESCE(EXCLUDED.store_id, app_presence.store_id);
$$;

REVOKE ALL ON FUNCTION public.rpc_heartbeat(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_heartbeat(BIGINT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 會員心跳（只給 liff-api（service_role）呼叫；member 身分由 liff-api 驗過
-- session 後帶進來，authenticated / anon 一律不可執行）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_member_heartbeat(
  p_tenant UUID, p_member_id BIGINT, p_store_id BIGINT DEFAULT NULL)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER
SET search_path TO 'public'
AS $$
  INSERT INTO app_presence (tenant_id, kind, subject_id, seen_date, store_id, last_seen_at)
  SELECT p_tenant, 'member', p_member_id::text,
         (NOW() AT TIME ZONE 'Asia/Taipei')::date, p_store_id, NOW()
   WHERE p_tenant IS NOT NULL AND p_member_id IS NOT NULL
  ON CONFLICT (tenant_id, kind, subject_id, seen_date)
  DO UPDATE SET last_seen_at = NOW(),
                store_id     = COALESCE(EXCLUDED.store_id, app_presence.store_id);
$$;

REVOKE ALL ON FUNCTION public.rpc_member_heartbeat(UUID, BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_member_heartbeat(UUID, BIGINT, BIGINT) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.rpc_member_heartbeat(UUID, BIGINT, BIGINT) TO service_role;

-- ---------------------------------------------------------------------------
-- 儀表板彙總（任何登入的後台使用者可讀；只回數字不回明細）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_online_stats()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH me AS (
    SELECT (((SELECT auth.jwt()) ->> 'tenant_id'))::uuid AS tenant
     WHERE COALESCE((SELECT auth.jwt()) ->> 'tenant_id', '') <> ''
  ),
  today AS (SELECT (NOW() AT TIME ZONE 'Asia/Taipei')::date AS d)
  SELECT jsonb_build_object(
    'online_staff', (
      SELECT COUNT(*) FROM app_presence p, me, today
       WHERE p.tenant_id = me.tenant AND p.kind = 'staff'
         AND p.seen_date = today.d
         AND p.last_seen_at > NOW() - INTERVAL '3 minutes'),
    'online_members', (
      SELECT COUNT(*) FROM app_presence p, me, today
       WHERE p.tenant_id = me.tenant AND p.kind = 'member'
         AND p.seen_date = today.d
         AND p.last_seen_at > NOW() - INTERVAL '3 minutes'),
    'dau_staff', (
      SELECT COUNT(*) FROM app_presence p, me, today
       WHERE p.tenant_id = me.tenant AND p.kind = 'staff' AND p.seen_date = today.d),
    'dau_members', (
      SELECT COUNT(*) FROM app_presence p, me, today
       WHERE p.tenant_id = me.tenant AND p.kind = 'member' AND p.seen_date = today.d),
    'daily', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'date', x.d, 'staff', x.staff, 'members', x.members)
               ORDER BY x.d), '[]'::jsonb)
        FROM (
          SELECT p.seen_date AS d,
                 COUNT(*) FILTER (WHERE p.kind = 'staff')  AS staff,
                 COUNT(*) FILTER (WHERE p.kind = 'member') AS members
            FROM app_presence p, me, today
           WHERE p.tenant_id = me.tenant
             AND p.seen_date >= today.d - 13
           GROUP BY p.seen_date
        ) x)
  )
  FROM (SELECT 1) _one
  WHERE EXISTS (SELECT 1 FROM me);
$$;

REVOKE ALL ON FUNCTION public.rpc_online_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_online_stats() TO authenticated;

-- ---------------------------------------------------------------------------
-- 保留 90 天（cron.schedule 同名 job 為 idempotent，重複 run migration 不會炸）
-- 20:30 UTC = 台北 04:30 離峰
-- ---------------------------------------------------------------------------
SELECT cron.schedule(
  'presence-prune-daily',
  '30 20 * * *',
  $$DELETE FROM public.app_presence
     WHERE seen_date < ((NOW() AT TIME ZONE 'Asia/Taipei')::date - 90)$$
);

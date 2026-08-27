-- ============================================================================
-- 2026-08-27 (2): 在線統計加「商城訪客」—— 沒登入逛 /shop 的人也要算
--
-- Alex：「商城頁面也要一起統計」。會員端的 /shop 分享連結點進來的人很多
--   還沒登入（沒有 member session），20260827010000 的心跳只數得到已綁定
--   會員。這支加第三種 kind='guest'：前端在 /shop* 頁、無會員 session 時，
--   用 localStorage 隨機 anon id 打 liff-api 免 token 的 guest_heartbeat。
--
-- 防灌水：免 token 端點任何人打得到，rpc_guest_heartbeat 內建兩道守衛 ——
--   anon id 必須是 UUID 格式；當天新訪客列建立速率超過 600 列/分鐘時
--   只更新既有列、不再新增（正常商城流量遠低於此，灌水最多讓「訪客數」
--   停止上升，不會撐爆表）。
--
-- 基底：app_presence / rpc_online_stats ← 20260827010000（今天剛建，無其他修改）。
-- Rollback：DROP FUNCTION rpc_guest_heartbeat；rpc_online_stats 重跑
--   20260827010000 的版本；CHECK constraint 改回 ('staff','member')
--   （先 DELETE kind='guest' 的列）。
-- ============================================================================

ALTER TABLE public.app_presence DROP CONSTRAINT IF EXISTS app_presence_kind_check;
ALTER TABLE public.app_presence
  ADD CONSTRAINT app_presence_kind_check CHECK (kind IN ('staff', 'member', 'guest'));

-- ---------------------------------------------------------------------------
-- 訪客心跳（只給 liff-api（service_role）呼叫；anon id 由前端 localStorage 產生）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_guest_heartbeat(
  p_tenant UUID, p_anon_id TEXT, p_store_id BIGINT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_today DATE := (NOW() AT TIME ZONE 'Asia/Taipei')::date;
BEGIN
  IF p_tenant IS NULL
     OR p_anon_id IS NULL
     OR p_anon_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN;
  END IF;

  -- 新列速率守衛：這一分鐘內新建的訪客列已超過 600 → 只更新既有列
  IF NOT EXISTS (SELECT 1 FROM app_presence
                  WHERE tenant_id = p_tenant AND kind = 'guest'
                    AND subject_id = p_anon_id AND seen_date = v_today)
     AND (SELECT COUNT(*) FROM app_presence
           WHERE kind = 'guest' AND seen_date = v_today
             AND first_seen_at > NOW() - INTERVAL '1 minute') > 600 THEN
    RETURN;
  END IF;

  INSERT INTO app_presence (tenant_id, kind, subject_id, seen_date, store_id, last_seen_at)
  VALUES (p_tenant, 'guest', p_anon_id, v_today, p_store_id, NOW())
  ON CONFLICT (tenant_id, kind, subject_id, seen_date)
  DO UPDATE SET last_seen_at = NOW(),
                store_id     = COALESCE(EXCLUDED.store_id, app_presence.store_id);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_guest_heartbeat(UUID, TEXT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_guest_heartbeat(UUID, TEXT, BIGINT) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.rpc_guest_heartbeat(UUID, TEXT, BIGINT) TO service_role;

-- ---------------------------------------------------------------------------
-- 彙總加訪客（基底 20260827010000，加 online_guests / dau_guests / daily.guests）
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
    'online_guests', (
      SELECT COUNT(*) FROM app_presence p, me, today
       WHERE p.tenant_id = me.tenant AND p.kind = 'guest'
         AND p.seen_date = today.d
         AND p.last_seen_at > NOW() - INTERVAL '3 minutes'),
    'dau_staff', (
      SELECT COUNT(*) FROM app_presence p, me, today
       WHERE p.tenant_id = me.tenant AND p.kind = 'staff' AND p.seen_date = today.d),
    'dau_members', (
      SELECT COUNT(*) FROM app_presence p, me, today
       WHERE p.tenant_id = me.tenant AND p.kind = 'member' AND p.seen_date = today.d),
    'dau_guests', (
      SELECT COUNT(*) FROM app_presence p, me, today
       WHERE p.tenant_id = me.tenant AND p.kind = 'guest' AND p.seen_date = today.d),
    'daily', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'date', x.d, 'staff', x.staff, 'members', x.members, 'guests', x.guests)
               ORDER BY x.d), '[]'::jsonb)
        FROM (
          SELECT p.seen_date AS d,
                 COUNT(*) FILTER (WHERE p.kind = 'staff')  AS staff,
                 COUNT(*) FILTER (WHERE p.kind = 'member') AS members,
                 COUNT(*) FILTER (WHERE p.kind = 'guest')  AS guests
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

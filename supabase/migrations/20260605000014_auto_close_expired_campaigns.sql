-- ============================================================
-- 開團 end_at 到期自動切 status=closed (已收單)
--   pg_cron 每分鐘掃 status='open' 且 end_at < NOW() 的活動切成 closed
--   end_at IS NULL 視為「無到期日」不自動關
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

-- 給 cron schema 在 postgres role 之外可訪問
GRANT USAGE ON SCHEMA cron TO postgres;

-- RPC：執行一次掃描 + 關團；回傳關掉的數量供觀察
CREATE OR REPLACE FUNCTION public.rpc_auto_close_expired_campaigns()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT;
BEGIN
  WITH closed AS (
    UPDATE group_buy_campaigns
       SET status     = 'closed',
           updated_at = NOW()
     WHERE status     = 'open'
       AND end_at IS NOT NULL
       AND end_at < NOW()
    RETURNING id
  )
  SELECT COUNT(*) INTO v_count FROM closed;
  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.rpc_auto_close_expired_campaigns IS
  '每分鐘 cron 掃 end_at 到期的 open 活動切成 closed';

-- 排程：每分鐘執行
-- 注意：cron.schedule 會 idempotent 處理同名 job，重複 run migration 不會炸
SELECT cron.schedule(
  'auto-close-expired-campaigns',
  '* * * * *',
  $cron$ SELECT public.rpc_auto_close_expired_campaigns(); $cron$
);

-- ============================================================
-- 2026-07-20: 互助交流板側欄 badge + 到期自動清理
--
-- 需求：
--   1. 分店登入時，互助板有進行中貼文就在側欄「互助交流板」掛小數字
--      （同「收貨」badge，見 20260720000020_rpc_inbound_pending_count.sql）。
--   2. 貼文到期（expires_at 過了）沒人認領 → 整筆自動刪除；
--      有被部分認領過的到期貼文保留紀錄、標成 status='expired'。
--
-- 實作：
--   - rpc_aid_board_active_count()：badge 用，分店帳號回全 tenant
--     status='active' 貼文數（互助板是跨店佈告欄，看全部）；其他帳號回 0。
--   - rpc_purge_expired_aid_board()：pg_cron 每 10 分鐘跑。
--     「沒人認領」= qty_remaining = qty_available 且無 mutual_aid_claims
--     （claims FK 無 cascade，有 legacy 認領紀錄的不刪以免 FK 炸）→ DELETE；
--     其餘到期 active → status='expired'。
--   - mutual_aid_replies 是 append-only（trg_no_mut_aid_replies 禁
--     UPDATE/DELETE），board DELETE cascade 到 replies 會被擋 → 換成
--     專用 trigger function forbid_aid_reply_mutation()：purge 交易內
--     （app.aid_board_purge='on'，transaction-local）放行 DELETE，其他照禁。
--
-- 歷史：
--   - trg_no_mut_aid_replies 建於 20260509000000（掛共用
--     forbid_append_only_mutation），20260509000001 只有暫時 DISABLE/ENABLE，
--     無其他改動 → 本檔改掛專用 function，共用的 forbid_append_only_mutation
--     不動（其他稽核表還在用）。
--   - rpc_aid_board_active_count / rpc_purge_expired_aid_board 為新函式，
--     無歷史版本（已 grep supabase/migrations/ 確認）。
--
-- Rollback：
--   SELECT cron.unschedule('purge-expired-aid-board');
--   DROP FUNCTION public.rpc_purge_expired_aid_board();
--   DROP FUNCTION public.rpc_aid_board_active_count();
--   DROP TRIGGER trg_no_mut_aid_replies ON mutual_aid_replies;
--   CREATE TRIGGER trg_no_mut_aid_replies BEFORE UPDATE OR DELETE ON mutual_aid_replies
--     FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();
--   DROP FUNCTION public.forbid_aid_reply_mutation();
-- ============================================================

-- ----------------------------------------------------------------
-- 1. 側欄 badge：rpc_aid_board_active_count
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_aid_board_active_count()
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT ARRAY(
      SELECT jsonb_array_elements_text(
        COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb))
    ) AS store_names
  )
  SELECT CASE
    -- 分店帳號 = stores 非空且不含「總倉」，對齊前端 isBranchUser()
    WHEN (SELECT cardinality(store_names) > 0
             AND NOT ('總倉' = ANY (store_names))
            FROM me) THEN (
      SELECT COUNT(*)::int
        FROM mutual_aid_board b
       WHERE b.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND b.status = 'active'
    )
    ELSE 0
  END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_aid_board_active_count() TO authenticated;

COMMENT ON FUNCTION public.rpc_aid_board_active_count IS
  '側欄「互助交流板」badge 用：分店帳號回全 tenant status=active 貼文數'
  '（跨店佈告欄，含自己店的貼文）；HQ/總倉/未綁店回 0。';

-- ----------------------------------------------------------------
-- 2. replies append-only trigger 換專用 function：purge 時放行 cascade DELETE
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.forbid_aid_reply_mutation()
RETURNS TRIGGER AS $$
BEGIN
  -- 只有互助板到期 purge（rpc_purge_expired_aid_board 交易內）允許
  -- board DELETE cascade 帶掉留言；其他 UPDATE / DELETE 照樣禁止
  IF TG_OP = 'DELETE'
     AND current_setting('app.aid_board_purge', true) = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_no_mut_aid_replies ON mutual_aid_replies;
CREATE TRIGGER trg_no_mut_aid_replies BEFORE UPDATE OR DELETE ON mutual_aid_replies
  FOR EACH ROW EXECUTE FUNCTION public.forbid_aid_reply_mutation();

COMMENT ON FUNCTION public.forbid_aid_reply_mutation IS
  'mutual_aid_replies 專用 append-only 守門：僅 rpc_purge_expired_aid_board '
  '交易內（app.aid_board_purge=on）放行 DELETE cascade，其他一律禁。';

-- ----------------------------------------------------------------
-- 3. 到期清理：rpc_purge_expired_aid_board
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_purge_expired_aid_board()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INT;
  v_expired INT;
BEGIN
  -- transaction-local flag：讓 replies 的 append-only trigger 放行 cascade DELETE
  PERFORM set_config('app.aid_board_purge', 'on', true);

  -- 沒人認領的到期貼文整筆刪除（含留言 cascade）：
  --   qty 沒被扣過（qty_remaining = qty_available，rpc_consume_aid_board /
  --   legacy rpc_claim_aid 都會扣量）且無 claims 紀錄（該 FK 無 cascade）
  WITH doomed AS (
    DELETE FROM mutual_aid_board b
     WHERE b.status = 'active'
       AND b.expires_at < NOW()
       AND b.qty_remaining = b.qty_available
       AND NOT EXISTS (SELECT 1 FROM mutual_aid_claims c WHERE c.board_id = b.id)
    RETURNING b.id
  )
  SELECT COUNT(*) INTO v_deleted FROM doomed;

  PERFORM set_config('app.aid_board_purge', '', true);

  -- 有被認領過（部分成交）的到期貼文保留紀錄，標成 expired 下板
  WITH marked AS (
    UPDATE mutual_aid_board b
       SET status = 'expired'
     WHERE b.status = 'active'
       AND b.expires_at < NOW()
    RETURNING b.id
  )
  SELECT COUNT(*) INTO v_expired FROM marked;

  RETURN jsonb_build_object('deleted', v_deleted, 'marked_expired', v_expired);
END;
$$;

-- 只給 cron / service_role 跑，不開放前端
REVOKE EXECUTE ON FUNCTION public.rpc_purge_expired_aid_board FROM authenticated, anon, public;
GRANT EXECUTE ON FUNCTION public.rpc_purge_expired_aid_board TO service_role;

COMMENT ON FUNCTION public.rpc_purge_expired_aid_board IS
  '互助板到期清理（cron 每 10 分鐘）：沒人認領的到期貼文整筆刪除（含留言），'
  '有部分認領的標 status=expired 保留紀錄。回 {deleted, marked_expired}。';

-- 排程：每 10 分鐘（cron.schedule 同名 job 為 idempotent，重複 run migration 不會炸）
SELECT cron.schedule(
  'purge-expired-aid-board',
  '*/10 * * * *',
  $cron$ SELECT public.rpc_purge_expired_aid_board(); $cron$
);

-- ============================================================
-- 2026-08-24: 互助交流板要有歷史 —— 到期貼文不再整筆刪除
--
-- 現況（20260720000030 rpc_purge_expired_aid_board，唯一版本，已 grep 確認）：
--   到期（expires_at < NOW()）且「沒人認領」（qty_remaining = qty_available
--   且無 mutual_aid_claims 紀錄）的貼文會被整筆 DELETE（cascade 帶掉
--   mutual_aid_replies）。這是絕大多數貼文的結局（沒人接手、自然到期），
--   所以現行行為等於「大部分貼文都不留任何紀錄」——
--   前端 /inventory/mutual-aid 又只查 status='active'，兩邊疊起來，
--   一則貼文一旦不是進行中，店家就再也查不到「我們之前貼過什麼、
--   誰接過」。
--
-- 改法：cron 到期清理**不再刪除**，一律和「有被部分認領」的分支一樣，
--   標成 status='expired' 保留紀錄。deleted 分支整段拿掉。
--   mutual_aid_claims 是死表（20260509000000 起 rpc_claim_aid 就廢了，
--   apps/ 全站沒有寫入路徑），這裡不用再查它。
--
-- 沒有動到的：
--   - rpc_close_aid_board（手動關貼 → cancelled）本來就不會被 purge 動到，
--     一直都留著紀錄，這次沒改。
--   - forbid_aid_reply_mutation / app.aid_board_purge 那組 escape hatch
--     （20260720000030）：purge 不再 DELETE，這組用不到了，但留著無害
--     （trigger 本體照樣擋一般的 UPDATE/DELETE），沒有必要在同一支
--     migration 裡把它退回 forbid_append_only_mutation。
--   - rpc_aid_board_active_count：badge 只算 status='active'，語意不變。
--
-- 前端另開 PR 補「進行中／歷史」分頁（apps/admin 的
-- inventory/mutual-aid/page.tsx、print/page.tsx），純前端零 migration。
--
-- Rollback（回 20260720000030 的版本）：
--   CREATE OR REPLACE FUNCTION public.rpc_purge_expired_aid_board()
--   RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
--   AS $$
--   DECLARE v_deleted INT; v_expired INT;
--   BEGIN
--     PERFORM set_config('app.aid_board_purge', 'on', true);
--     WITH doomed AS (
--       DELETE FROM mutual_aid_board b
--        WHERE b.status = 'active' AND b.expires_at < NOW()
--          AND b.qty_remaining = b.qty_available
--          AND NOT EXISTS (SELECT 1 FROM mutual_aid_claims c WHERE c.board_id = b.id)
--       RETURNING b.id
--     )
--     SELECT COUNT(*) INTO v_deleted FROM doomed;
--     PERFORM set_config('app.aid_board_purge', '', true);
--     WITH marked AS (
--       UPDATE mutual_aid_board b SET status = 'expired'
--        WHERE b.status = 'active' AND b.expires_at < NOW()
--       RETURNING b.id
--     )
--     SELECT COUNT(*) INTO v_expired FROM marked;
--     RETURN jsonb_build_object('deleted', v_deleted, 'marked_expired', v_expired);
--   END;
--   $$;
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_purge_expired_aid_board()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired INT;
BEGIN
  -- 到期一律標 expired 保留紀錄，不再整筆刪除（互助交流板要有歷史）
  WITH marked AS (
    UPDATE mutual_aid_board b
       SET status = 'expired'
     WHERE b.status = 'active'
       AND b.expires_at < NOW()
    RETURNING b.id
  )
  SELECT COUNT(*) INTO v_expired FROM marked;

  RETURN jsonb_build_object('marked_expired', v_expired);
END;
$$;

COMMENT ON FUNCTION public.rpc_purge_expired_aid_board IS
  '互助板到期清理（cron 每 10 分鐘）：到期貼文一律標 status=expired 保留紀錄，'
  '2026-08-24 起不再刪除（互助交流板要有歷史）。回 {marked_expired}。';

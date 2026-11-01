-- ============================================================================
-- 20261101000070_candidates_keep_14_days.sql
--
-- 選品候選池只留兩個禮拜（老闆 2026-11-01 指示；中間說過一個月、一個禮拜，最後定兩個禮拜）。
--
-- 刪：建立超過 14 天、而且老闆沒動過（owner_action = 'none'）或已忽略（'ignored'）的候選。
-- 不刪：收藏（collected）、排程（scheduled）、已採用（adopted）—— 那是老闆的決定紀錄（候選池頁的收藏／已採用分頁全部顯示），
--   排程的還是「週曆」的歷史，採用的連著商品主檔（adopted_product_id）。
-- 每天台北 03:41（UTC 19:41）跑一次；本檔先清一輪。
-- 沒有任何表 FK 指向 community_product_candidates（已查 pg_constraint）。
-- 廠商群組來源（source_external_id 'ln:%'）一樣照這個規則；原文仍留在 line_note_market_posts。
--
-- rollback：SELECT cron.unschedule('candidates-keep-14-days'); DROP FUNCTION public._purge_old_candidates();
--   （已刪的資料救不回來）
-- ============================================================================

CREATE OR REPLACE FUNCTION public._purge_old_candidates()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n INT;
BEGIN
  DELETE FROM community_product_candidates
   WHERE created_at < now() - INTERVAL '14 days'
     AND owner_action IN ('none', 'ignored');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._purge_old_candidates() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule('candidates-keep-14-days')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'candidates-keep-14-days');
SELECT cron.schedule('candidates-keep-14-days', '41 19 * * *', $cron$ SELECT public._purge_old_candidates(); $cron$);

SELECT public._purge_old_candidates() AS purged;

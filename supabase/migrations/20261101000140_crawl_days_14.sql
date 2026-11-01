-- ============================================================================
-- 20261101000140_crawl_days_14.sql
--
-- 廠商群組記事本一律讀近兩個禮拜（老闆 2026-11-01 指示）。原本預設 3 天（每天讀一次夠用），
-- 但剛勾選的群組第一次讀只看得到 3 天內的貼文；改成 14 天，跟候選池只留兩個禮拜
-- （20261101000070）對齊。line-note-worker 本來就把 crawl_days 夾在 1～14。
-- 已經讀過的貼文重讀不會重複（line_note_market_posts 以 (群組, 貼文 id) upsert）。
--
-- rollback：ALTER TABLE line_note_communities ALTER COLUMN crawl_days SET DEFAULT 3;
-- ============================================================================

ALTER TABLE public.line_note_communities ALTER COLUMN crawl_days SET DEFAULT 14;
UPDATE public.line_note_communities SET crawl_days = 14 WHERE crawl_days <> 14;

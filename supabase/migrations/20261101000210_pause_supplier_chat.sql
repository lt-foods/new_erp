-- ============================================================================
-- 廠商群組聊天室讀取先停（20261101000210）
--
-- Alex 2026-11-01：「廠商群組聊天室讀取可以先停了」。
-- 只關 crawl_chat（20261101000150 開給全富 / 中太 / 核果果），記事本照讀、程式不動；
-- 已經讀進來的聊天貼文與候選留著（14 天後照候選池規則自動清）。
-- 要再開：UPDATE line_note_communities SET crawl_chat = TRUE WHERE id IN (...);
-- rollback：同上，把這三個群組的 crawl_chat 改回 TRUE。
-- ============================================================================
UPDATE public.line_note_communities SET crawl_chat = FALSE WHERE crawl_chat;

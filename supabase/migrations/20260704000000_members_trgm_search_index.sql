-- ============================================================
-- 加單會員搜尋慢 SQL 修正：members 三欄加 pg_trgm GIN index
--
-- 問題：小幫手加單頁 (campaigns/order-entry) 的會員搜尋框每打一個字都會
--   呼叫 rpc_search_members，內部對 members.name / member_no / phone 做
--   ILIKE '%term%'（前綴萬用字元，btree 用不到）→ 整張表 Seq Scan。
--   members 約 2.2 萬筆，單次掃描 ~65ms；pg_stat_statements 實測此 RPC
--   ~117k 次呼叫、平均 ~68ms、尖峰 max 6.3 秒（批量任務並發時 buffer / CPU
--   爭用而爆掉），累計 DB 時間 ~8,000,000 ms。對照同一個搜尋框同時觸發、
--   但有索引可用的 rpc_search_aliases 只要 2.6ms。
--   使用者現象：加單打字卡頓、搜不到會員編號 → 誤判沒這個會員而重複建檔。
--
-- 修法：裝 pg_trgm，對 name / member_no / phone 各建一個 GIN trigram
--   index，讓 ILIKE 走 BitmapOr index scan。實測（member_no / phone /
--   3 字以上名稱）：65ms Seq Scan → 0.13ms Bitmap index scan（約 500x）。
--   註：2 字純中文名 trigram 無法命中、仍走 Seq Scan，但這類僅個位數筆，
--   且大宗搜尋（會員編號 / 手機 / 較長名稱）已大幅改善，整體 DB 負載驟降，
--   連帶消掉並發爭用造成的 6 秒尖峰。
--
-- 基底：沿用 20260628000000_search_members_resolve_merged.sql 的
--   rpc_search_members 邏輯，本檔只加索引、不更動 function。
--   members 僅 17MB，一般 CREATE INDEX 鎖表時間 <1s，可接受。
--
-- Rollback:
--   DROP INDEX IF EXISTS public.idx_members_name_trgm;
--   DROP INDEX IF EXISTS public.idx_members_member_no_trgm;
--   DROP INDEX IF EXISTS public.idx_members_phone_trgm;
--   （pg_trgm extension 可保留，無副作用）
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_members_name_trgm
  ON public.members USING gin (name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_members_member_no_trgm
  ON public.members USING gin (member_no gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_members_phone_trgm
  ON public.members USING gin (phone gin_trgm_ops);

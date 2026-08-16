-- ============================================================
-- 2026-08-16: 重新開放「自由轉貨」建單（撤銷 20260814050000）
--
-- 決策（使用者 2026-08-16）：自由轉貨（店↔店、掛虛擬 SKU、只申報估價、
-- 背後沒有任何單據）重新開放。8/14 停用時的兩個前端入口一併接回去：
--   1. /wms/transfers 標頭的「+ 建自由轉貨」（FreeTransferCreateModal）
--   2. /transfers/free 獨立頁（停用說明頁改回 FreeTransferCreateForm）
--
-- 這裡把 RPC 的執行權還回去 —— 只把按鈕接回來、EXECUTE 還被 REVOKE 著的話，
-- 使用者按下去只會拿到 permission denied for function（前端唯一呼叫點是
-- FreeTransferCreateForm，走 authenticated 的 anon key）。
--
-- 函式本體從頭到尾沒有被改過（最新版本仍是 20260515000002 建立的那支），
-- 20260814050000 只動了 grant 與 comment，所以這裡也只要還原這兩樣。
-- 函式內自己還有一層角色守衛（owner/admin/hq_manager/store_manager/''），
-- 收回 EXECUTE 只是外面那道門。
--
-- 基底 / rollback：
--   基底 = 20260515000002_rpc_store_self_service（函式定義 + 原始 GRANT）
--   rollback = 重跑 20260814050000_disable_free_transfer 的 REVOKE
-- ============================================================

GRANT EXECUTE ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT) IS
  'Case 1：自由轉貨（虛擬 SKU + description + estimated_amount）。'
  '2026-08-14 曾停用（20260814050000），2026-08-16 重新開放建單'
  '（20260816000040：authenticated 的 EXECUTE 已還原，前端入口已接回）。';

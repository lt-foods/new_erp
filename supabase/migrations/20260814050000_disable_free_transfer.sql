-- ============================================================
-- 2026-08-14: 停用「自由轉貨」建單
--
-- 決策（使用者 2026-08-14）：自由轉貨（店↔店、掛虛擬 SKU、只申報估價、
-- 背後沒有任何單據）不再開放使用，前端兩個入口一併移除：
--   1. /wms/transfers 標頭的「+ 建自由轉貨」（FreeTransferCreateModal）
--   2. /transfers/free 獨立頁（改成停用說明頁；原本只有收貨短少處理彈窗的
--      「補出貨 → 前往自由轉貨建單」連過來，那個 CTA 同步改指補貨申請）
--
-- 這裡連 RPC 的執行權一起收掉，否則「按鈕拿掉了、API 還通」——
-- 前端唯一呼叫點就是被移除的那張表單（FreeTransferCreateForm），
-- 沒有任何 SECURITY DEFINER 函式在內部呼叫它，收掉不會連帶壞掉別的流程。
--
-- 刻意保留的部分（既有 199 張自由轉貨單還要看得到、收得完）：
--   - rpc_delete_free_transfer（草稿可刪）
--   - rpc_receive_transfer / 收貨頁 / TransferDetailModal / 月結 free_in・free_out
--   - rpc_update_free_transfer_amount（改估價）
--
-- 需要恢復時：
--   GRANT EXECUTE ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT)
--     TO authenticated;
--   並把 /wms/transfers 的按鈕與 /transfers/free 的表單接回去。
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT)
  FROM authenticated, anon, PUBLIC;

COMMENT ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT) IS
  'Case 1：自由轉貨（虛擬 SKU + description + estimated_amount）。'
  '2026-08-14 起停用：前端入口已移除、authenticated 的 EXECUTE 也已收回'
  '（見 20260814050000）。既有單的檢視／收貨／刪除／估價不受影響。';

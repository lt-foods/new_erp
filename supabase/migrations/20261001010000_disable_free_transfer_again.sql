-- ============================================================
-- 2026-10-01: 再次停用「自由轉貨」建單（撤銷 20260816000040 的重新開放）
--
-- 決策（老闆 2026-10-01）：自由轉貨（店↔店、掛虛擬 SKU、只申報估價、
-- 背後沒有任何單據）關閉建單，**所有帳號一起關**（含總倉 / 老闆，沒有例外）。
-- 店家之間互給東西 = 店家自己處理，系統不記帳、月結不算。
--
-- 時間序（函式本體從頭到尾沒改過，開關只動 grant 與 comment）：
--   2026-05-15  20260515000002  上線（GRANT 給 authenticated）
--   2026-08-14  20260814050000  停用（REVOKE + 前端入口移除）
--   2026-08-16  20260816000040  重新開放（GRANT + 前端入口接回）
--   2026-10-01  本檔            再次停用（REVOKE + 前端入口移除）
--
-- 理由：
--   - 建單永遠只寫虛擬 SKU MISC-01（20260515000002 函式內），真的品名只寫在
--     transfer_items.description。來源店那樣商品一件都沒少、收貨店一件都沒多
--     —— 真貨的庫存帳完全不動；取貨閘門拿實體庫存擋，貨在架上客人取不到、
--     或系統以為還有、客人撲空。
--   - 出貨端跳過虛擬 SKU、收貨端沒跳過 → MISC-01 在各店只增不減。
--   - 月結 free_in / free_out 直接吃店家自己填的 estimated_amount。
--   - 跨月的單（月底出貨、隔月初收貨）曾兩個月都被算進去，重複算帳。
--
-- 前端兩個入口同一個 PR 一併移除：
--   1. /wms/transfers 標頭的「+ 建自由轉貨」（FreeTransferCreateModal）
--      與進頁自動彈出的運作說明動畫（FreeTransferExplainerModal）
--   2. /transfers/free 獨立頁（改成停用說明頁）
--
-- 這裡連 RPC 的執行權一起收掉，否則「按鈕拿掉了、API 還通」——
-- 前端唯一呼叫點就是被移除的那張表單（FreeTransferCreateForm），
-- 沒有任何 SECURITY DEFINER 函式在內部呼叫它，收掉不會連帶壞掉別的流程。
-- 上線順序：先上前端、再套本檔；反過來的話，還沒重新整理的舊畫面按下去
-- 會拿到 permission denied for function。
--
-- 刻意保留的部分（既有自由轉貨單還要看得到、收得完）：
--   - rpc_delete_free_transfer（草稿可刪）
--   - rpc_receive_transfer / 收貨頁 / TransferDetailModal / 月結 free_in・free_out
--   - rpc_update_free_transfer_amount（改估價）
--   - 收件匣的「🔄 自由轉貨」篩選、明細、列印出貨單
--
-- 本檔只有 REVOKE 與 COMMENT，可重跑（REVOKE 對已收回的權限是 no-op）。
-- ⛔ 沒有老闆明確指示不要再打開。
--
-- 需要恢復時（rollback）：
--   GRANT EXECUTE ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT)
--     TO authenticated;
--   並把 /wms/transfers 的按鈕與 /transfers/free 的表單接回去（參考 20260816000040）。
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT)
  FROM authenticated, anon, PUBLIC;

COMMENT ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT) IS
  'Case 1：自由轉貨（虛擬 SKU + description + estimated_amount）。'
  '2026-05-15 上線（20260515000002）→ 2026-08-14 停用（20260814050000）'
  '→ 2026-08-16 重新開放（20260816000040）→ 2026-10-01 再次停用'
  '（20261001010000：authenticated / anon / PUBLIC 的 EXECUTE 已收回，前端入口已移除）。'
  '既有單的檢視／出貨／收貨／刪除／改估價／月結不受影響。';

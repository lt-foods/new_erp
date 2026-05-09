-- ============================================================
-- Backfill:SEED 資料的 transfers.shipped_at 是 NULL,影響「收貨待辦」頁排序
--
-- 原因:早期 SEED 資料(transfer_no 前綴 'SEED-')直接寫入 status='received',
-- 沒填 shipped_at。導致 ORDER BY shipped_at DESC 時 NULLs 排在最前面,
-- 把真正待收的 transfer 擠出 limit。
--
-- 修法:把 received 但 shipped_at IS NULL 的舊資料,shipped_at 用 received_at
-- 填回去(若 received_at 也 NULL,用 created_at)。
--
-- 資料筆數:約 6500+ rows(預估)
-- 風險:可逆轉(備份 NULL 後可還原)。但這是時間戳,精確值無重要意義。
-- ============================================================

UPDATE transfers
   SET shipped_at = COALESCE(received_at, created_at)
 WHERE status = 'received'
   AND shipped_at IS NULL;

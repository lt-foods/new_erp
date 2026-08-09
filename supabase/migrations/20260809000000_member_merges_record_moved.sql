-- ============================================================================
-- 2026-08-09: member_merges 記錄「這次合併搬走了哪些列」+ 復原狀態欄位
--
-- 為什麼需要：rpc_merge_member 是用 `UPDATE ... SET member_id = 目標` 搬資料的，
-- 搬完之後那些列跟目標自己原本的列**長得一模一樣**，沒有任何欄位指回來源。
-- member_merges 只存了加總（points_moved / wallet_moved / cards_moved），
-- 存不下「是哪 39 張訂單」。所以合併一旦做錯，就沒有東西能拿來精準還原。
--
-- 這支補上缺的那塊：合併當下把每張表被搬走的 id 陣列寫進 moved。
-- 有了它，rpc_unmerge_member 才能「原封不動搬回去」，而不是靠猜。
--
-- moved 的形狀（v=1）：
--   {
--     "v": 1,
--     "source": "recorded",          -- recorded = 合併當下記的；reconstructed = 事後推回來的
--     "src_status_before": "active", -- 來源會員被標成 merged 之前的 status，復原要還原成它
--     "order_ids": [...], "alias_ids": [...], "tag_ids": [...], "card_ids": [...],
--     "points_ledger_ids": [...], "wallet_ledger_ids": [...]
--   }
--
-- 舊資料（本次上線前的 816 筆）moved 一律是 NULL —— 那是事實，不要填假的進去。
-- rpc_unmerge_member 對 NULL 的處理見該支自己的註解（用 updated_at 時間戳推回，
-- 且只在沒動到錢/卡片時才允許）。
--
-- Rollback：
--   ALTER TABLE member_merges DROP COLUMN moved, DROP COLUMN reverted_at,
--     DROP COLUMN reverted_by, DROP COLUMN reverted_reason;
-- ============================================================================

ALTER TABLE member_merges
  ADD COLUMN IF NOT EXISTS moved           JSONB,
  ADD COLUMN IF NOT EXISTS reverted_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reverted_by     UUID,
  ADD COLUMN IF NOT EXISTS reverted_reason TEXT;

COMMENT ON COLUMN member_merges.moved IS
  '合併當下被搬走的列 id（v=1；order_ids / alias_ids / tag_ids / card_ids / points_ledger_ids / wallet_ledger_ids 與 src_status_before）。NULL = 本欄上線前的舊紀錄，沒有精準還原依據';
COMMENT ON COLUMN member_merges.reverted_at IS
  '這筆合併被復原的時間；非 NULL 表示已復原（紀錄保留供稽核，但不再算在「合併紀錄」清單裡）';
COMMENT ON COLUMN member_merges.reverted_by IS '執行復原的操作者';
COMMENT ON COLUMN member_merges.reverted_reason IS '復原原因（店員填的，例如「合併到錯的人」）';

-- 「還沒被復原的合併」是 UI 清單與各處統計的主要查詢條件
CREATE INDEX IF NOT EXISTS idx_member_merges_active
  ON member_merges (primary_member_id) WHERE reverted_at IS NULL;

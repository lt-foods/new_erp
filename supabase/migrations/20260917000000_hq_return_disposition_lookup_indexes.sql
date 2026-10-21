-- ============================================================
-- 總倉退回貨處理 — 補兩個查詢索引（不改任何資料、不改任何函式）
-- 20260917000000_hq_return_disposition_lookup_indexes.sql
--
-- 動機（2026-09-17 待套用包核對，阿審第 1 輪 P1）：
--   20260907030000_hq_return_disposition_reversals.sql 掛上的觸發器，
--   在「每天都在跑」的路徑上查兩個沒有索引的欄位。
--
--   1. transfer_items.shortage_return_transfer_id
--      _guard_hq_return_transfer_mutation()（20260907030000:573）一進來就
--      無條件查 `ti.shortage_return_transfer_id = OLD.id`（:597-600），
--      掛在 transfers 的 BEFORE UPDATE OF tenant_id, transfer_type,
--      source_location, dest_location, status, received_at（:662-665）與
--      BEFORE DELETE（:667-669），FOR EACH ROW、沒有 WHEN 條件
--      ⇒ 任何一張調撥單（不只退貨單）改狀態／收貨時間／地點，每一列查一次。
--      全 repo 650 支 migration 在 transfer_items 上只有 pkey、
--      idx_transfer_items_unresolved_shortage（20260607000040:31-33）、
--      idx_transfer_items_transfer（20260720000040:117-118）三個索引，
--      都不含這欄 ⇒ 每次都整張表掃一遍。
--      同一張表缺索引在正式庫撞過 authenticated 的 8 秒
--      statement_timeout（20260720000040:4-7、:15-17）。
--      這欄只有「短收同意退回」產生的記帳單才有值（20260901000010:93-98），
--      絕大多數列是 NULL ⇒ 部分索引，寫法比照
--      20260510000002:17-23（transfers.customer_order_id／next_transfer_id）。
--      `= OLD.id` 這種等號條件本身就排除 NULL，所以部分索引用得上。
--
--   2. hq_return_batches.source_transfer_item_id
--      同一支 header 守門用 `b.source_transfer_item_id = ti.id` 做 JOIN（:584-596）；
--      _assert_hq_return_item_sources_current()（:517-555）是
--      CONSTRAINT TRIGGER AFTER INSERT OR UPDATE ON transfer_items
--      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW（:561-564），沒有提早離開
--      ⇒ 每一列調撥明細新增／修改，交易結尾都查一次（:535-538）；
--      _guard_hq_return_item_mutation() 刪除／改歸屬也查（:428-431、:462-465）。
--      20260907010000:44-81 只建了 source_movement_id 唯一鍵、
--      (tenant_id, status, created_at)、(tenant_id, location_id, sku_id) 部分索引，
--      沒有這欄。表剛建好是空的，今天不慢；但批次只增不刪，
--      筆數多了之後，一次寫很多明細的交易結尾要逐列掃這張表。
--      現在表是空的，建索引幾乎不花時間。
--      _hq_hold_return 保證這欄必填（20260907010000:233-236）⇒ 一般索引即可。
--
-- 語意完全不變：索引不改變任何查詢的結果，也不寫入任何資料列。
--
-- 為什麼不用 CONCURRENTLY：
--   CREATE INDEX CONCURRENTLY 不能在交易區塊裡執行，而 Supabase SQL Editor
--   一次 Run 是怎麼送出的（是否包成交易）沒有查證過；CONCURRENTLY 失敗還會
--   留下 invalid 索引，之後 IF NOT EXISTS 看到同名就跳過（本 repo 已記錄：
--   20260820000000:213-214）。⇒ 用一般 CREATE INDEX。
--   代價：建索引期間 transfer_items 只能讀、不能寫（本 repo 已記錄：
--   20260819000000:24-26）⇒ 跟 20260907010000～040 同一個沒人收貨出貨的時段貼。
--
-- 依賴：
--   transfer_items.shortage_return_transfer_id ← 20260901000010:93-94
--   hq_return_batches.source_transfer_item_id  ← 20260907010000:23
--   ⇒ 必須在 20260907010000 之後；建議第 4 支（20260907040000）之後立刻貼。
--
-- rollback：
--   DROP INDEX IF EXISTS public.idx_transfer_items_shortage_return_transfer;
--   DROP INDEX IF EXISTS public.idx_hq_return_batches_source_transfer_item;
--   （拿掉只會變慢、不會壞；DROP INDEX 一樣會短暫鎖表，挑沒人操作的時段）
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_transfer_items_shortage_return_transfer
  ON public.transfer_items (shortage_return_transfer_id)
  WHERE shortage_return_transfer_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_hq_return_batches_source_transfer_item
  ON public.hq_return_batches (source_transfer_item_id);

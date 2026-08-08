-- ============================================================
-- 2026-08-08: customer_order_items.source 新增 'pwa'
--
-- 需求：訂單頁要用折線圖分「App 下單 / 商城下單 / 小幫手」三條線，但目前
--   會員自助下單一律寫 source='liff'（liff-api.placeMemberOrder 寫死），
--   PWA（已安裝的會員 App）與 LINE 內建瀏覽器（LIFF 商城）分不出來。
--
-- 新的語意（與 apps/admin/src/lib/orderSource.ts 對齊）：
--   'pwa'  → 會員在 App（PWA / 外部瀏覽器開的會員站）自助下單  ＝「App」
--   'liff' → 會員在 LINE 內（LIFF 商城）自助下單                ＝「商城」
--   'manual' → 小幫手後台代客 key 單                            ＝「小幫手」
--
-- 判斷在前端做（apps/member/src/lib/clientChannel.ts）：UA 含 " Line/"
--   或 liff.isInClient() 為真 → 'liff'，其餘 → 'pwa'。liff-api 只收白名單值，
--   沒帶／帶了非法值一律退回 'liff'（＝維持這支 migration 之前的行為）。
--
-- ⚠ 既有 249 筆 source='liff' 不回填 —— 當時沒有記錄執行環境，無從得知是
--   PWA 還是 LINE 內開的。歷史資料一律算「商城」，折線圖上這段期間的
--   「App」線會是 0，屬預期。
--
-- 基底版本：20260507000000_order_transfer_and_internal.sql（1.3 節，
--   grep customer_order_items_source_check 僅該檔與 20260423120000 動過，
--   線上 pg_get_constraintdef 與 20260507000000 一致）。
-- Rollback：
--   ALTER TABLE customer_order_items DROP CONSTRAINT customer_order_items_source_check;
--   ALTER TABLE customer_order_items ADD CONSTRAINT customer_order_items_source_check
--     CHECK (source IN ('manual','screenshot_parse','csv','rollover','liff',
--                       'store_internal','aid_transfer'));
--   （回滾前要先確認沒有 source='pwa' 的資料，否則加不回去。）
-- ============================================================

ALTER TABLE customer_order_items DROP CONSTRAINT IF EXISTS customer_order_items_source_check;
ALTER TABLE customer_order_items ADD CONSTRAINT customer_order_items_source_check
  CHECK (source IN ('manual','screenshot_parse','csv','rollover','liff','pwa',
                    'store_internal','aid_transfer'));

COMMENT ON COLUMN customer_order_items.source IS
  '品項來源通路。pwa=會員 App 自助下單、liff=LINE 商城自助下單、manual=小幫手代客；'
  '其餘為系統流程（screenshot_parse/csv/rollover/store_internal/aid_transfer）。'
  '中央定義見 apps/admin/src/lib/orderSource.ts。';

-- ============================================================
-- stores: 加 LIFF 顧客端「總覽」頁所需的 5 個顯示欄位
--
-- 與既有 allowed_payment_methods (JSONB) 並存：
--   - allowed_payment_methods 是程式判斷用的 enum 陣列
--   - payment_methods_text / shipping_methods_text 是顯示給顧客看的文字
--
-- store_short_code：用於顧客端結單號尾碼（例：S-00000123-SK 中的 SK）
--   backfill = upper(left(code, 2))
-- ============================================================

ALTER TABLE stores
  ADD COLUMN banner_url            TEXT,
  ADD COLUMN description           TEXT,
  ADD COLUMN payment_methods_text  TEXT,
  ADD COLUMN shipping_methods_text TEXT,
  ADD COLUMN store_short_code      TEXT;

COMMENT ON COLUMN stores.banner_url            IS 'LIFF 總覽頁 banner 圖 URL';
COMMENT ON COLUMN stores.description           IS 'LIFF 總覽頁「賣場介紹」純文字';
COMMENT ON COLUMN stores.payment_methods_text  IS 'LIFF 總覽頁顯示用付款方式文字';
COMMENT ON COLUMN stores.shipping_methods_text IS 'LIFF 總覽頁顯示用出貨方式文字';
COMMENT ON COLUMN stores.store_short_code      IS '結單號尾碼（2 字大寫），例：SK';

-- backfill：既有 store 用 code 前 2 字大寫
UPDATE stores
   SET store_short_code = upper(left(code, 2))
 WHERE store_short_code IS NULL;

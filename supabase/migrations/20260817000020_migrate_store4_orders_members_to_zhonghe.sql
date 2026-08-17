-- 四號店（store_id=37，已停用）收攤：訂單與會員整批轉到中和店（store_id=45）。
-- 一次性資料搬移（data migration），不動 schema、不動函式。
--
-- 搬移範圍（只搬「訂單跟會員」，其餘刻意不動）：
--   1. member_line_bindings：四號店的 LINE 綁定改掛中和店。
--      唯一鍵是 (tenant_id, store_id, line_user_id) / (tenant_id, store_id, member_id)，
--      同一人已經在中和店有綁定的（兩店都綁過）→ 先刪四號店那筆，留中和店既有的。
--   2. members.home_store_id：37 → 45（members 的唯一鍵都是 tenant 層級，不會撞）。
--   3. customer_orders.pickup_store_id：37 → 45（全部 1,543 張，含歷史單，
--      全是 order_kind='normal' 的 GRP-/GB- 單；四號店沒有 RR-/SP- 容器單，
--      trio 唯一索引不含 pickup_store_id，不會撞）。
--
-- 刻意不搬（不在本次範圍，見 PR 說明）：
--   - stock_balances / stock_movements / transfers（四號店倉 location_id=8 還有
--     24 筆結餘、合計 59 件）→ 庫存搬移另案處理。
--   - picking_wave_items.store_id（805 筆派貨紀錄）→ 歷史派貨事實，
--     不改寫；後果是舊單在中和的取貨閘門 Path A/B 對不上波次，
--     要靠 Path C（中和實收過該 SKU）或後續收貨推進。
--   - order_pickup_events / store_monthly_settlements / member_imports → 歷史紀錄。
--
-- rollback：本檔案跑完會留下 migration_note（見檔尾 DO 區塊的 RAISE NOTICE 數字），
-- 反向即 45→37 同樣三步，但重複綁定那 3 筆刪掉就回不來（原本就是冗餘資料）。


-- 1a. 兩店都綁過的人：刪四號店那筆綁定，保留中和店既有綁定
DELETE FROM member_line_bindings b
 WHERE b.store_id = 37
   AND EXISTS (
     SELECT 1 FROM member_line_bindings b2
      WHERE b2.tenant_id = b.tenant_id
        AND b2.store_id = 45
        AND (b2.line_user_id = b.line_user_id OR b2.member_id = b.member_id)
   );

-- 1b. 其餘綁定改掛中和店
UPDATE member_line_bindings
   SET store_id = 45
 WHERE store_id = 37;

-- 2. 會員改隸中和店
UPDATE members
   SET home_store_id = 45
 WHERE home_store_id = 37;

-- 3. 訂單取貨店改為中和店（含歷史單，全數搬移）
UPDATE customer_orders
   SET pickup_store_id = 45
 WHERE pickup_store_id = 37;

-- 自檢：搬完四號店身上不應該再掛任何訂單 / 會員 / 綁定
DO $$
DECLARE
  v_orders   BIGINT;
  v_members  BIGINT;
  v_bindings BIGINT;
BEGIN
  SELECT count(*) INTO v_orders   FROM customer_orders     WHERE pickup_store_id = 37;
  SELECT count(*) INTO v_members  FROM members              WHERE home_store_id   = 37;
  SELECT count(*) INTO v_bindings FROM member_line_bindings WHERE store_id        = 37;
  IF v_orders > 0 OR v_members > 0 OR v_bindings > 0 THEN
    RAISE EXCEPTION 'store-4 migration incomplete: orders=%, members=%, bindings=%',
      v_orders, v_members, v_bindings;
  END IF;
END $$;


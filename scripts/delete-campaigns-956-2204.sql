-- ============================================================
-- Tier-3 硬刪 campaign 956 (GRP-20260523-002) + 2204 (GRP-20260531-001)
-- 全部相關紀錄（含採購 PR/PO/GRN）+ 重算受影響庫存（負數 clamp 0）。
--
-- 2026-06-03 應使用者要求對 production 執行（2204 為 open 活團，已二次確認）。
-- 備份：backups/PROD-delete-GRP-956-2204-20260603.json（被刪所有 row + 刪前餘額）。
--
-- 刪除清單（已對 prod 列舉 + 閉包驗證）：
--   campaigns 956, 2204 + campaign_items×7
--   customer_orders×13 (956:4738,4739,4740,4741,11546,11547  2204:17596,17599,17600,17601,17632,17762,19395)
--     + items×17 + audit×8 + pickup_events×5
--   picking_waves×5 (956:1,2,9,10  2204:4) + wave_items×28 + wave_audit×26
--   transfers×18：956:4,5,6,7,17,18,19,23,26,27,28,29,30
--                 2204:11,12,13,14,15（含訂單轉手鏈 14→13、return_to_hq 15）
--     + transfer_items×28
--   goods_receipts×2 (1,3) + gr_items×5
--   purchase_orders×2 (1,3) + po_items×5
--   purchase_requests×2 (4,6) + pr_items×5 + pr_campaigns×2
--   stock_movements×57（GRN 1,3 進貨 + 18 transfer 出入/退 + 13 訂單 sale）
--
-- 訂單轉手 FK：17601.transferred_to_order_id→17762、17762.transferred_from_order_id→17601 先清。
-- 庫存：刪 movement 後對「受影響 (location,sku)」重算 on_hand=GREATEST(0,Σ殘存)。
--   PO1/GRN1 共用 SKU(1026,1027,1029,1030) 扣掉已刪的 2205 後僅 956 在消耗，
--   重算後總倉歸 0（含解消上次殘留的 1030 = -1）；無新增負數。in_transit_in 全 0。
-- 設計約束同前：append-only(stock_movements/*_audit/pickup_events) 走 replica 繞過，
--   顯式 child-first，不依賴 CASCADE。
-- Rollback：用備份 JSON 逐表 re-insert + 還原 stock_balances_before。
-- ============================================================

BEGIN;

-- ---- 前置守衛 ----
DO $$
DECLARE n bigint;
BEGIN
  PERFORM 1 FROM group_buy_campaigns WHERE id=956  AND campaign_no='GRP-20260523-002';
  IF NOT FOUND THEN RAISE EXCEPTION '中止：campaign 956 / GRP-20260523-002 不存在'; END IF;
  PERFORM 1 FROM group_buy_campaigns WHERE id=2204 AND campaign_no='GRP-20260531-001';
  IF NOT FOUND THEN RAISE EXCEPTION '中止：campaign 2204 / GRP-20260531-001 不存在'; END IF;

  SELECT count(*) INTO n FROM customer_orders WHERE campaign_id=956;
  IF n<>6 THEN RAISE EXCEPTION '中止：956 訂單應 6，實際 %', n; END IF;
  SELECT count(*) INTO n FROM customer_orders WHERE campaign_id=2204;
  IF n<>7 THEN RAISE EXCEPTION '中止：2204 訂單應 7，實際 %', n; END IF;

  SELECT count(*) INTO n FROM stock_movements
   WHERE (source_doc_type='goods_receipt' AND source_doc_id IN (1,3))
      OR (source_doc_type='transfer' AND source_doc_id IN (4,5,6,7,17,18,19,23,26,27,28,29,30,11,12,13,14,15))
      OR (source_doc_type='customer_order' AND source_doc_id IN (4738,4739,4740,4741,11546,11547,17596,17599,17600,17601,17632,17762,19395));
  IF n<>57 THEN RAISE EXCEPTION '中止：待刪 stock_movements 應 57，實際 %', n; END IF;
END $$;

SET LOCAL session_replication_role = 'replica';

-- ---- 快照受影響 (location,sku)（刪 movement 前）----
CREATE TEMP TABLE _affected ON COMMIT DROP AS
  SELECT DISTINCT location_id, sku_id FROM stock_movements
   WHERE (source_doc_type='goods_receipt' AND source_doc_id IN (1,3))
      OR (source_doc_type='transfer' AND source_doc_id IN (4,5,6,7,17,18,19,23,26,27,28,29,30,11,12,13,14,15))
      OR (source_doc_type='customer_order' AND source_doc_id IN (4738,4739,4740,4741,11546,11547,17596,17599,17600,17601,17632,17762,19395));

-- ---- 履約子表 ----
DELETE FROM customer_order_audit_log WHERE order_id IN (4738,4739,4740,4741,11546,11547,17596,17599,17600,17601,17632,17762,19395);
DELETE FROM order_pickup_events      WHERE order_id IN (4738,4739,4740,4741,11546,11547,17596,17599,17600,17601,17632,17762,19395);
DELETE FROM customer_order_items     WHERE order_id IN (4738,4739,4740,4741,11546,11547,17596,17599,17600,17601,17632,17762,19395);

-- ---- 撿貨子表 ----
DELETE FROM picking_wave_audit_log WHERE wave_id IN (1,2,9,10,4);
DELETE FROM picking_wave_items     WHERE wave_id IN (1,2,9,10,4);

-- ---- transfer 子表 ----
DELETE FROM transfer_items WHERE transfer_id IN (4,5,6,7,17,18,19,23,26,27,28,29,30,11,12,13,14,15);

-- ---- 進貨子表 ----
DELETE FROM goods_receipt_items WHERE gr_id IN (1,3);

-- ---- 採購子表 ----
DELETE FROM purchase_order_items       WHERE po_id IN (1,3);
DELETE FROM purchase_request_items     WHERE pr_id IN (4,6);
DELETE FROM purchase_request_campaigns WHERE pr_id IN (4,6);

-- ---- 開團子表 ----
DELETE FROM campaign_items WHERE campaign_id IN (956,2204);

-- ---- 清訂單轉手自參照 FK（17601 ↔ 17762）----
UPDATE customer_orders SET transferred_to_order_id   = NULL WHERE id = 17601;
UPDATE customer_orders SET transferred_from_order_id = NULL WHERE id = 17762;

-- ---- stock_movements（須在 transfer_items / goods_receipt_items 之後）----
DELETE FROM stock_movements
   WHERE (source_doc_type='goods_receipt' AND source_doc_id IN (1,3))
      OR (source_doc_type='transfer' AND source_doc_id IN (4,5,6,7,17,18,19,23,26,27,28,29,30,11,12,13,14,15))
      OR (source_doc_type='customer_order' AND source_doc_id IN (4738,4739,4740,4741,11546,11547,17596,17599,17600,17601,17632,17762,19395));

-- ---- 父表 / 表頭 ----
DELETE FROM transfers          WHERE id IN (4,5,6,7,17,18,19,23,26,27,28,29,30,11,12,13,14,15);
DELETE FROM goods_receipts     WHERE id IN (1,3);
DELETE FROM picking_waves      WHERE id IN (1,2,9,10,4);
DELETE FROM customer_orders    WHERE id IN (4738,4739,4740,4741,11546,11547,17596,17599,17600,17601,17632,17762,19395);
DELETE FROM purchase_orders    WHERE id IN (1,3);
DELETE FROM purchase_requests  WHERE id IN (4,6);
DELETE FROM group_buy_campaigns WHERE id IN (956,2204);

-- ---- 重算受影響 (location,sku)：on_hand = max(0, Σ殘存 movement) ----
UPDATE stock_balances sb
   SET on_hand = GREATEST(0, COALESCE((
         SELECT SUM(m.quantity) FROM stock_movements m
          WHERE m.location_id = sb.location_id AND m.sku_id = sb.sku_id
       ), 0)),
       updated_at = NOW()
  FROM _affected a
 WHERE sb.location_id = a.location_id AND sb.sku_id = a.sku_id;

-- ---- 後置守衛 ----
DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM customer_orders WHERE campaign_id IN (956,2204);
  IF n<>0 THEN RAISE EXCEPTION '殘留 customer_orders %', n; END IF;
  SELECT count(*) INTO n FROM group_buy_campaigns WHERE id IN (956,2204);
  IF n<>0 THEN RAISE EXCEPTION '殘留 group_buy_campaigns %', n; END IF;
  SELECT count(*) INTO n FROM transfers WHERE id IN (4,5,6,7,17,18,19,23,26,27,28,29,30,11,12,13,14,15);
  IF n<>0 THEN RAISE EXCEPTION '殘留 transfers %', n; END IF;
  SELECT count(*) INTO n FROM transfer_items WHERE transfer_id IN (4,5,6,7,17,18,19,23,26,27,28,29,30,11,12,13,14,15);
  IF n<>0 THEN RAISE EXCEPTION '殘留 transfer_items %', n; END IF;
  SELECT count(*) INTO n FROM picking_waves WHERE id IN (1,2,9,10,4);
  IF n<>0 THEN RAISE EXCEPTION '殘留 picking_waves %', n; END IF;
  SELECT count(*) INTO n FROM purchase_orders WHERE id IN (1,3);
  IF n<>0 THEN RAISE EXCEPTION '殘留 purchase_orders %', n; END IF;
  SELECT count(*) INTO n FROM stock_movements
   WHERE (source_doc_type='goods_receipt' AND source_doc_id IN (1,3))
      OR (source_doc_type='transfer' AND source_doc_id IN (4,5,6,7,17,18,19,23,26,27,28,29,30,11,12,13,14,15))
      OR (source_doc_type='customer_order' AND source_doc_id IN (4738,4739,4740,4741,11546,11547,17596,17599,17600,17601,17632,17762,19395));
  IF n<>0 THEN RAISE EXCEPTION '殘留 stock_movements %', n; END IF;
  RAISE NOTICE 'Tier3 全刪完成：campaign 956 + 2204 已清除，庫存已重算（負數 clamp 0）';
END $$;

COMMIT;

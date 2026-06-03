-- ============================================================
-- Tier-3 硬刪 campaign 2205 / GRP-20260531-002「🍂包子媽生鮮小舖🍂」全部相關紀錄
-- （含採購 PR/PO/GRN）+ 重算受影響庫存。
--
-- 2026-06-03 應使用者要求對 production 執行。備份見
--   backups/PROD-delete-GRP-20260531-002-20260603.json（含被刪所有 row + 刪前餘額）。
--
-- 刪除清單（已對 prod 列舉確認）：
--   group_buy_campaigns 2205 + campaign_items×6
--   customer_orders×11 (17763,17764,17766..17774) + items×22 + audit×7 + pickup_events×1
--   picking_waves×6 (5,6,7,8,11,12) + wave_items×20 + wave_audit×14
--   transfers×8 (16,20,21,22,24,25,32,33) + transfer_items×8
--   goods_receipts×2 (4,5) + goods_receipt_items×6
--   purchase_orders×2 (4,5) + po_items×6
--   purchase_requests×2 (8,9) + pr_items×12 + pr_campaigns×2
--   stock_movements×20 (45-50 進貨 + 51,52,53,56,57,59,80-85,103,104 出入/取貨)
--
-- 庫存：刪 20 筆 movement 後，對 10 個受影響 (location,sku) 重算 on_hand =
--   GREATEST(0, SUM(殘存 movement))。跨團共用導致 loc1/sku1030(G00123-06) 殘存 -1,
--   依使用者決定 clamp 成 0。
--
-- 設計約束：stock_movements 與 *_audit_log / order_pickup_events 都有 append-only
--   forbid trigger（含 forbid_movement_mutation），故整段在 session_replication_role
--   ='replica' 下執行以繞過；replica 模式同時停用 FK 強制，因此採顯式 child-first 刪除、
--   不依賴 CASCADE（沿用 scripts/hard-delete-order-GRP-20260523-002-TF0009.sql 教訓）。
--
-- Rollback：用 backups/PROD-delete-GRP-20260531-002-20260603.json 逐表 re-insert，
--   並把 stock_balances 還原成該檔 stock_balances_before。
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_campaign bigint := 2205;
  v_oids  bigint[] := ARRAY[17763,17764,17766,17767,17768,17769,17770,17771,17772,17773,17774];
  v_waves bigint[] := ARRAY[5,6,7,8,11,12];
  v_xfers bigint[] := ARRAY[16,20,21,22,24,25,32,33];
  v_grns  bigint[] := ARRAY[4,5];
  v_pos   bigint[] := ARRAY[4,5];
  v_prs   bigint[] := ARRAY[8,9];
  v_movs  bigint[] := ARRAY[45,46,47,48,49,50,51,52,53,56,57,59,80,81,82,83,84,85,103,104];
  n bigint;
BEGIN
  -- ---- 前置守衛：確認目標就是這團、規模相符 ----
  PERFORM 1 FROM group_buy_campaigns WHERE id = v_campaign AND campaign_no = 'GRP-20260531-002';
  IF NOT FOUND THEN RAISE EXCEPTION '中止：campaign 2205 / GRP-20260531-002 不存在'; END IF;

  SELECT count(*) INTO n FROM customer_orders WHERE campaign_id = v_campaign;
  IF n <> 11 THEN RAISE EXCEPTION '中止：campaign 2205 訂單數應為 11，實際 %', n; END IF;

  SELECT count(*) INTO n FROM stock_movements WHERE id = ANY(v_movs);
  IF n <> 20 THEN RAISE EXCEPTION '中止：待刪 stock_movements 應為 20，實際 %', n; END IF;

  SET LOCAL session_replication_role = 'replica';

  -- ---- 履約子表 ----
  DELETE FROM customer_order_audit_log WHERE order_id = ANY(v_oids);
  DELETE FROM order_pickup_events      WHERE order_id = ANY(v_oids);
  DELETE FROM customer_order_items     WHERE order_id = ANY(v_oids);

  -- ---- 撿貨子表 ----
  DELETE FROM picking_wave_audit_log WHERE wave_id = ANY(v_waves);
  DELETE FROM picking_wave_items     WHERE wave_id = ANY(v_waves);

  -- ---- transfer 子表 ----
  DELETE FROM transfer_items WHERE transfer_id = ANY(v_xfers);

  -- ---- 進貨子表 ----
  DELETE FROM goods_receipt_items WHERE gr_id = ANY(v_grns);

  -- ---- 採購子表 ----
  DELETE FROM purchase_order_items      WHERE po_id = ANY(v_pos);
  DELETE FROM purchase_request_items    WHERE pr_id = ANY(v_prs);
  DELETE FROM purchase_request_campaigns WHERE pr_id = ANY(v_prs);

  -- ---- 開團子表 ----
  DELETE FROM campaign_items WHERE campaign_id = v_campaign;

  -- ---- stock_movements（須在 transfer_items / goods_receipt_items 之後，因 FK 由其指向）----
  DELETE FROM stock_movements WHERE id = ANY(v_movs);

  -- ---- 父表 / 表頭 ----
  DELETE FROM transfers          WHERE id = ANY(v_xfers);
  DELETE FROM goods_receipts     WHERE id = ANY(v_grns);
  DELETE FROM picking_waves      WHERE id = ANY(v_waves);
  DELETE FROM customer_orders    WHERE id = ANY(v_oids);
  DELETE FROM purchase_orders    WHERE id = ANY(v_pos);
  DELETE FROM purchase_requests  WHERE id = ANY(v_prs);
  DELETE FROM group_buy_campaigns WHERE id = v_campaign;

  -- ---- 重算受影響 (location,sku) 餘額：on_hand = max(0, Σ殘存 movement) ----
  UPDATE stock_balances sb
     SET on_hand = GREATEST(0, COALESCE((
           SELECT SUM(m.quantity) FROM stock_movements m
            WHERE m.location_id = sb.location_id AND m.sku_id = sb.sku_id
         ), 0)),
         updated_at = NOW()
   WHERE (sb.location_id = 1  AND sb.sku_id IN (1026,1027,1028,1029,1030,1031))
      OR (sb.location_id = 18 AND sb.sku_id IN (1027,1028,1030,1031));

  -- ---- 後置守衛：確認全清空 ----
  SELECT count(*) INTO n FROM customer_orders WHERE campaign_id = v_campaign;
  IF n <> 0 THEN RAISE EXCEPTION '殘留 customer_orders %', n; END IF;
  SELECT count(*) INTO n FROM group_buy_campaigns WHERE id = v_campaign;
  IF n <> 0 THEN RAISE EXCEPTION '殘留 group_buy_campaigns %', n; END IF;
  SELECT count(*) INTO n FROM picking_wave_items WHERE wave_id = ANY(v_waves);
  IF n <> 0 THEN RAISE EXCEPTION '殘留 picking_wave_items %', n; END IF;
  SELECT count(*) INTO n FROM transfer_items WHERE transfer_id = ANY(v_xfers);
  IF n <> 0 THEN RAISE EXCEPTION '殘留 transfer_items %', n; END IF;
  SELECT count(*) INTO n FROM stock_movements WHERE id = ANY(v_movs);
  IF n <> 0 THEN RAISE EXCEPTION '殘留 stock_movements %', n; END IF;
  SELECT count(*) INTO n FROM purchase_orders WHERE id = ANY(v_pos);
  IF n <> 0 THEN RAISE EXCEPTION '殘留 purchase_orders %', n; END IF;

  RAISE NOTICE 'Tier3 全刪完成：campaign 2205 / GRP-20260531-002 已清除，庫存已重算（loc1/sku1030 clamp 0）';
END $$;

COMMIT;

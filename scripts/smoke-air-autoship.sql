-- ============================================================
-- Smoke test — 空中轉全自動派貨（migration 20260714000010 + 20260714000020 套用後）
--
-- 安全：整段包在 BEGIN … ROLLBACK，跑完不留任何資料。用 RAISE NOTICE 印結果，
--      任一斷言失敗會 RAISE EXCEPTION（同樣 rollback）。
--
-- 前提：DB 已套 000010（air→confirmed）+ 000020（auto-ship），且至少有一張
--      status='ready'、未轉出、有未取消品項的 customer_orders，且其來源店在庫存夠
--      （rpc_ship_aid_order 會對來源店 location 做 transfer_out）。
--
-- 跑法（本機切片 / 任何有 psql 的環境）：
--   psql "<conn>" -f scripts/smoke-air-autoship.sql
-- ============================================================
BEGIN;

DO $$
DECLARE
  op            UUID := '00000000-0000-0000-0000-0000000000aa';  -- 任意 operator（測試用）
  v_src         BIGINT;
  v_src_loc     BIGINT;
  v_dest_store  BIGINT;
  v_new_id      BIGINT;
  v_new_status  TEXT;
  v_leg_cnt     INT;
  v_leg_status  TEXT;
  v_out_cnt     INT;
BEGIN
  -- 來源：真的 ready、未轉出、有未取消品項
  SELECT co.id, src.location_id
    INTO v_src, v_src_loc
  FROM customer_orders co
  JOIN stores src ON src.id = co.pickup_store_id
  WHERE co.status='ready' AND co.transferred_to_order_id IS NULL
    AND src.location_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM customer_order_items i WHERE i.order_id=co.id AND i.status<>'cancelled')
  ORDER BY co.id DESC
  LIMIT 1;
  IF v_src IS NULL THEN RAISE EXCEPTION 'SMOKE: 找不到可測的 ready 訂單（需先 seed）'; END IF;

  -- 收件店：同租戶、不同 location、active
  SELECT s.id INTO v_dest_store
  FROM stores s
  WHERE s.tenant_id = (SELECT tenant_id FROM customer_orders WHERE id=v_src)
    AND s.location_id IS NOT NULL AND s.location_id <> v_src_loc
    AND s.is_active AND s.deleted_at IS NULL
  ORDER BY s.id LIMIT 1;
  IF v_dest_store IS NULL THEN RAISE EXCEPTION 'SMOKE: 找不到不同 location 的收件店'; END IF;

  -- 執行整單空中轉（000020 後：內部自動派貨）
  v_new_id := rpc_transfer_order_to_store(v_src, v_dest_store, NULL, NULL, op, 'SMOKE', true);

  SELECT status INTO v_new_status FROM customer_orders WHERE id=v_new_id;
  SELECT count(*), max(t.status) INTO v_leg_cnt, v_leg_status
    FROM transfers t WHERE t.customer_order_id=v_new_id AND t.transfer_type='store_to_store';
  SELECT count(*) INTO v_out_cnt
    FROM stock_movements m
    WHERE m.movement_type='transfer_out' AND m.location_id=v_src_loc
      AND m.source_doc_id IN (SELECT id FROM transfers WHERE customer_order_id=v_new_id);

  RAISE NOTICE 'SMOKE 空中轉 auto-ship | src=% dest_store=% new_order=% status=% legs=% leg_status=% out_moves=%',
    v_src, v_dest_store, v_new_id, v_new_status, v_leg_cnt, v_leg_status, v_out_cnt;

  IF v_new_status <> 'shipping' THEN RAISE EXCEPTION 'FAIL: 轉入單 status=% ≠ shipping', v_new_status; END IF;
  IF v_leg_cnt <> 1 THEN RAISE EXCEPTION 'FAIL: 期望 1 段 leg、實際 %', v_leg_cnt; END IF;
  IF v_leg_status <> 'shipped' THEN RAISE EXCEPTION 'FAIL: leg status=% ≠ shipped', v_leg_status; END IF;
  IF v_out_cnt < 1 THEN RAISE EXCEPTION 'FAIL: 來源店沒有 transfer_out 出庫'; END IF;

  -- 空中轉不該有經總倉那段 hq_to_store leg
  IF EXISTS (SELECT 1 FROM transfers WHERE customer_order_id=v_new_id AND transfer_type='hq_to_store') THEN
    RAISE EXCEPTION 'FAIL: 出現 hq_to_store leg（空中轉不該經總倉）';
  END IF;

  RAISE NOTICE 'PASS ✅ 空中轉 auto-ship：轉入單 shipping、1 段 store_to_store shipped、來源店已出庫、無總倉中轉段';
END $$;

ROLLBACK;
-- 原子性（T1.6）另驗：挑一張來源店庫存不足的 ready 單重跑上面的 transfer，
-- 應整筆 RAISE + rollback（轉入單不存在、來源單未 transferred_out）。

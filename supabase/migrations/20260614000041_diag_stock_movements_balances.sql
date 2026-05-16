-- ============================================================
-- 診斷用 migration（一次性、不改任何資料）：
-- 1. 確認 stock_movements 14952/14953 存在嗎？實際 location/sku/quantity？
-- 2. 對 transfer 965 全部 transfer_items 的 in_movement_id 抓 movement
-- 3. 對 location=7 + sku in (729,735,736) 看 stock_balances
-- 4. 對 location=7 看所有 stock_movements 統計
-- 結果走 RAISE NOTICE。
-- ============================================================

DO $$
DECLARE
  r RECORD;
  v_count INTEGER;
BEGIN
  RAISE NOTICE '=== A. stock_movements 14952/14953 ===';
  FOR r IN
    SELECT id, location_id, sku_id, movement_type, quantity, source_doc_type, source_doc_id, created_at
      FROM stock_movements
     WHERE id IN (14952, 14953)
     ORDER BY id
  LOOP
    RAISE NOTICE '  mov %: loc=% sku=% type=% qty=% src=%:% at=%',
      r.id, r.location_id, r.sku_id, r.movement_type, r.quantity,
      r.source_doc_type, r.source_doc_id, r.created_at;
  END LOOP;

  RAISE NOTICE '=== B. transfer 965 transfer_items + in_movement ===';
  FOR r IN
    SELECT ti.id AS item_id, ti.sku_id, ti.qty_shipped, ti.qty_received,
           ti.in_movement_id,
           sm.id AS sm_id, sm.location_id AS sm_loc, sm.quantity AS sm_qty, sm.movement_type AS sm_type
      FROM transfer_items ti
      LEFT JOIN stock_movements sm ON sm.id = ti.in_movement_id
     WHERE ti.transfer_id = 965
     ORDER BY ti.id
  LOOP
    RAISE NOTICE '  item % sku=% ship=% recv=% in_mov_id=% (sm_id=% loc=% qty=% type=%)',
      r.item_id, r.sku_id, r.qty_shipped, r.qty_received, r.in_movement_id,
      r.sm_id, r.sm_loc, r.sm_qty, r.sm_type;
  END LOOP;

  RAISE NOTICE '=== C. stock_balances loc=7 sku in (729,735,736) ===';
  v_count := 0;
  FOR r IN
    SELECT sku_id, on_hand, reserved, in_transit_in, last_movement_at
      FROM stock_balances
     WHERE location_id = 7 AND sku_id IN (729, 735, 736)
     ORDER BY sku_id
  LOOP
    RAISE NOTICE '  sku=% on_hand=% reserved=% in_transit_in=% last_mov=%',
      r.sku_id, r.on_hand, r.reserved, r.in_transit_in, r.last_movement_at;
    v_count := v_count + 1;
  END LOOP;
  IF v_count = 0 THEN
    RAISE NOTICE '  (NONE) — stock_balances 對 location 7 + 這些 sku 0 筆';
  END IF;

  RAISE NOTICE '=== D. stock_movements loc=7 sku in (729,735,736) 共幾筆 ===';
  SELECT COUNT(*) INTO v_count FROM stock_movements
   WHERE location_id = 7 AND sku_id IN (729, 735, 736);
  RAISE NOTICE '  count = %', v_count;

  RAISE NOTICE '=== E. stock_balances loc=7 全部統計 ===';
  SELECT COUNT(*) INTO v_count FROM stock_balances WHERE location_id = 7;
  RAISE NOTICE '  rows = %', v_count;

  RAISE NOTICE '=== F. stock_movements loc=7 全部統計 + type 分佈 ===';
  FOR r IN
    SELECT movement_type, COUNT(*) AS c, SUM(quantity) AS sum_qty
      FROM stock_movements
     WHERE location_id = 7
     GROUP BY movement_type
     ORDER BY movement_type
  LOOP
    RAISE NOTICE '  type=% count=% sum_qty=%', r.movement_type, r.c, r.sum_qty;
  END LOOP;
END $$;

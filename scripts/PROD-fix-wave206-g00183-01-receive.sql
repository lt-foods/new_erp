-- PROD 一次性補正（2026-07-01）
-- 情境：WAVE-206-S1 (transfer id=2969, 平鎮店 loc 2) 收貨時把 G00183-01 (sku 1112)
--       誤填「沒收」→ qty_received=0、in_movement_id 空，但實際 4 條都有收到。
--       導致 order 15247 (GB20260526-C000425-0067) 對 1112 退貨時 rpc_outbound
--       擋「Insufficient stock」(店端 on_hand=0)，整筆退貨 rollback。
-- 修法：只補這一行 —— 等同收貨當下該做的 transfer_in 入庫 + 回填 qty_received/in_movement_id。
--       姊妹行 sku 1137 (G00183-02) qty_received=4 正常，不動。
--       不走「退回整張收貨(rpc_unreceive_transfer)」：1137 on_hand=3<4(已消耗1)，
--       unreceive 物理守衛會擋。
-- 補收數量 = qty_shipped(4)，與姊妹行一致（實際全收）。若現場其實短收，改 v_qty。
-- 影響面：只新增一筆 transfer_in stock_movement + 更新 transfer_items 一行；
--         不動訂單狀態、不動其他 SKU。append-only，無 rollback 需求
--         （若要撤銷：對新 movement 補一筆 reversal 負量、qty_received 歸零）。
BEGIN;

DO $$
DECLARE
  v_tid    BIGINT := 2969;   -- WAVE-206-S1
  v_sku    BIGINT := 1112;   -- G00183-01
  v_qty    NUMERIC;          -- 補收量 = qty_shipped
  v_item   RECORD;
  v_tenant UUID;
  v_dest   BIGINT;
  v_op     UUID;
  v_mov    BIGINT;
BEGIN
  SELECT tenant_id, dest_location, COALESCE(received_by, updated_by, created_by)
    INTO v_tenant, v_dest, v_op
    FROM transfers WHERE id = v_tid FOR UPDATE;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'transfer % not found', v_tid; END IF;

  SELECT ti.id, ti.qty_shipped, ti.qty_received, ti.in_movement_id,
         COALESCE(ABS(sm.unit_cost), 0) AS out_cost
    INTO v_item
    FROM transfer_items ti
    LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
   WHERE ti.transfer_id = v_tid AND ti.sku_id = v_sku
   FOR UPDATE OF ti;
  IF v_item.id IS NULL THEN RAISE EXCEPTION 'sku % not in transfer %', v_sku, v_tid; END IF;

  -- 守衛：已補過就中止（防重複執行造成幽靈庫存）
  IF v_item.qty_received > 0 OR v_item.in_movement_id IS NOT NULL THEN
    RAISE EXCEPTION '已收過 (qty_received=%, in_movement=%)，中止不重複補',
      v_item.qty_received, v_item.in_movement_id;
  END IF;

  v_qty := v_item.qty_shipped;

  v_mov := rpc_inbound(
    p_tenant_id       => v_tenant,
    p_location_id     => v_dest,
    p_sku_id          => v_sku,
    p_quantity        => v_qty,
    p_unit_cost       => v_item.out_cost,
    p_movement_type   => 'transfer_in',
    p_source_doc_type => 'transfer',
    p_source_doc_id   => v_tid,
    p_operator        => v_op
  );

  UPDATE transfer_items
     SET qty_received   = v_qty,
         in_movement_id = v_mov,
         updated_by     = v_op,
         updated_at     = NOW()
   WHERE id = v_item.id;

  RAISE NOTICE '補收 sku=% 到 loc=%：qty=%, unit_cost=%, movement_id=%',
    v_sku, v_dest, v_qty, v_item.out_cost, v_mov;
END $$;

COMMIT;

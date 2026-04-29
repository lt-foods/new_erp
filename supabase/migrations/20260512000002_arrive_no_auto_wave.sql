-- ============================================================================
-- 進貨不再自動建撿貨單
--
-- 之前 rpc_arrive_and_distribute 在收貨時會自動建 picking_wave（status='picking'、
-- picked_qty=0），導致撿貨工作站看到該 SKU 顯示「✓ 已撿過」(因為已有非 cancelled
-- 的 wave 涉及該 sku)，操作者無法再從工作站建立撿貨單。
--
-- 改為：
--   - rpc_arrive_and_distribute 只做 GR 入倉（confirm_gr）。
--   - picking_wave 由撿貨工作站「+ 加入」→「🧾 建立撿貨單」時呼叫
--     rpc_create_picking_wave 來建立。
--   - allocations 參數不再使用（保留向下相容、忽略內容）。
--
-- 收尾資料修正：
--   把先前 rpc_arrive_and_distribute 自動建出來、尚未實際撿過貨的 wave
--   （note LIKE 'auto from PO %' AND status='picking' AND 全部 picked_qty=0）
--   標為 cancelled，讓那些 SKU 重新出現在撿貨工作站。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_arrive_and_distribute(
  p_po_id      BIGINT,
  p_arrivals   JSONB,
  p_operator   UUID,
  p_invoice_no TEXT DEFAULT NULL,
  p_notes      TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_po              RECORD;
  v_close_dates     DATE[];
  v_close_date      DATE;
  v_gr_id           BIGINT;
  v_gr_no           TEXT;
  v_arrival         JSONB;
  v_po_item_id      BIGINT;
  v_sku_id          BIGINT;
  v_qty_received    NUMERIC(18,3);
  v_qty_damaged     NUMERIC(18,3);
  v_unit_cost       NUMERIC(18,4);
  v_default_cost    NUMERIC(18,4);
BEGIN
  -- 1. PO 守衛
  SELECT id, tenant_id, supplier_id, dest_location_id, status
    INTO v_po
    FROM purchase_orders
   WHERE id = p_po_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PO % not found', p_po_id;
  END IF;
  IF v_po.status NOT IN ('sent','partially_received') THEN
    RAISE EXCEPTION 'PO % must be sent/partially_received (current: %)', p_po_id, v_po.status;
  END IF;

  -- 2. 反查 close_date（保留供回傳值）
  SELECT array_agg(DISTINCT pr.source_close_date)
    INTO v_close_dates
    FROM purchase_order_items poi
    JOIN purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN purchase_requests pr ON pr.id = pri.pr_id
   WHERE poi.po_id = p_po_id
     AND pr.source_close_date IS NOT NULL;

  IF v_close_dates IS NOT NULL AND array_length(v_close_dates, 1) > 1 THEN
    RAISE EXCEPTION 'PO % spans multiple close_dates: %', p_po_id, v_close_dates;
  END IF;

  v_close_date := COALESCE(v_close_dates[1], NULL);

  -- 3. GR header
  v_gr_no := public.rpc_next_gr_no();
  INSERT INTO goods_receipts (
    tenant_id, gr_no, po_id, supplier_id, dest_location_id,
    status, supplier_invoice_no, received_by, notes, created_by, updated_by
  ) VALUES (
    v_po.tenant_id, v_gr_no, v_po.id, v_po.supplier_id, v_po.dest_location_id,
    'draft', p_invoice_no, p_operator, p_notes, p_operator, p_operator
  ) RETURNING id INTO v_gr_id;

  -- 4. GR items
  FOR v_arrival IN SELECT * FROM jsonb_array_elements(p_arrivals) LOOP
    v_po_item_id   := (v_arrival->>'po_item_id')::BIGINT;
    v_sku_id       := (v_arrival->>'sku_id')::BIGINT;
    v_qty_received := (v_arrival->>'qty_received')::NUMERIC;
    v_qty_damaged  := COALESCE((v_arrival->>'qty_damaged')::NUMERIC, 0);
    v_unit_cost    := (v_arrival->>'unit_cost')::NUMERIC;

    IF v_qty_received IS NULL OR v_qty_received <= 0 THEN
      RAISE EXCEPTION 'arrival sku_id % has invalid qty_received', v_sku_id;
    END IF;

    IF v_unit_cost IS NULL THEN
      SELECT unit_cost INTO v_default_cost FROM purchase_order_items WHERE id = v_po_item_id;
      v_unit_cost := COALESCE(v_default_cost, 0);
    END IF;

    INSERT INTO goods_receipt_items (
      gr_id, po_item_id, sku_id,
      qty_expected, qty_received, qty_damaged, unit_cost,
      batch_no, expiry_date, variance_reason, created_by, updated_by
    ) VALUES (
      v_gr_id, v_po_item_id, v_sku_id,
      (SELECT qty_ordered FROM purchase_order_items WHERE id = v_po_item_id),
      v_qty_received, v_qty_damaged, v_unit_cost,
      v_arrival->>'batch_no',
      NULLIF(v_arrival->>'expiry_date','')::DATE,
      v_arrival->>'variance_reason',
      p_operator, p_operator
    );
  END LOOP;

  -- 5. confirm GR（入總倉庫存）
  PERFORM rpc_confirm_gr(v_gr_id, p_operator);

  -- 6. （已移除）撿貨單由工作站建立
  --    若 p_arrivals 帶了 allocations，無作用，純粹忽略。

  RETURN jsonb_build_object(
    'gr_id',      v_gr_id,
    'gr_no',      v_gr_no,
    'wave_id',    NULL,
    'wave_code',  NULL,
    'close_date', v_close_date
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_arrive_and_distribute IS
  '進貨確認：GR 入倉（不再自動建 picking_wave；撿貨改由工作站手動建立）';

-- ============================================================================
-- 一次性：把過往自動建出來、尚未真撿貨的 wave 標 cancelled
--   - note LIKE 'auto from PO %': 由 rpc_arrive_and_distribute 自動建立的 wave
--   - status = 'picking': 還沒進入 picked / shipped
--   - 該 wave 內所有 wave_items.picked_qty 都為 0: 確認沒人手動撿過
-- ============================================================================
WITH stale_waves AS (
  SELECT pw.id
    FROM picking_waves pw
   WHERE pw.status = 'picking'
     AND pw.note LIKE 'auto from PO %'
     AND NOT EXISTS (
       SELECT 1 FROM picking_wave_items pwi
        WHERE pwi.wave_id = pw.id
          AND COALESCE(pwi.picked_qty, 0) > 0
     )
)
UPDATE picking_waves
   SET status = 'cancelled',
       note = COALESCE(note, '') || ' [auto-cancelled by 20260512000002: 改為工作站手動建單]',
       updated_at = NOW()
 WHERE id IN (SELECT id FROM stale_waves);

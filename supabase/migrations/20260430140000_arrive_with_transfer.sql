-- ============================================================================
-- 升級 rpc_arrive_and_distribute：撿完同時建 transfer(shipped) + 出總倉庫存
-- 業務：撿完 = 派貨中 (transfer.status='shipped')，等分店簽收 → received
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
  v_wave_id         BIGINT := NULL;
  v_wave_code       TEXT := NULL;
  v_arrival         JSONB;
  v_alloc           JSONB;
  v_po_item_id      BIGINT;
  v_sku_id          BIGINT;
  v_qty_received    NUMERIC(18,3);
  v_qty_damaged     NUMERIC(18,3);
  v_unit_cost       NUMERIC(18,4);
  v_alloc_total     NUMERIC(18,3);
  v_default_cost    NUMERIC(18,4);
  v_item_count      INTEGER;
  v_store_count     INTEGER;
  v_total_qty       NUMERIC(18,3);
  v_store_rec       RECORD;
  v_dest_loc        BIGINT;
  v_xfer_id         BIGINT;
  v_xfer_no         TEXT;
  v_xfer_ids        BIGINT[] := ARRAY[]::BIGINT[];
  v_pwi             RECORD;
  v_out_mov_id      BIGINT;
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

  -- 2. 反查 close_date
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

  -- 5. confirm GR (rpc_inbound 入總倉)
  PERFORM rpc_confirm_gr(v_gr_id, p_operator);

  -- 6. picking_wave + items（若有 close_date 對應分店訂單）
  IF v_close_date IS NOT NULL THEN
    v_wave_code := public.rpc_next_wave_code();

    INSERT INTO picking_waves (
      tenant_id, wave_code, wave_date, status, note, created_by, updated_by
    ) VALUES (
      v_po.tenant_id, v_wave_code, v_close_date, 'picking',
      'auto from PO ' || p_po_id::text || ' / GR ' || v_gr_no,
      p_operator, p_operator
    ) RETURNING id INTO v_wave_id;

    FOR v_arrival IN SELECT * FROM jsonb_array_elements(p_arrivals) LOOP
      v_sku_id    := (v_arrival->>'sku_id')::BIGINT;
      v_qty_received := (v_arrival->>'qty_received')::NUMERIC;
      v_alloc_total := 0;

      IF v_arrival ? 'allocations' AND jsonb_array_length(v_arrival->'allocations') > 0 THEN
        FOR v_alloc IN SELECT * FROM jsonb_array_elements(v_arrival->'allocations') LOOP
          IF (v_alloc->>'qty')::NUMERIC > 0 THEN
            INSERT INTO picking_wave_items (
              tenant_id, wave_id, sku_id, store_id, qty, picked_qty,
              created_by, updated_by
            ) VALUES (
              v_po.tenant_id, v_wave_id, v_sku_id,
              (v_alloc->>'store_id')::BIGINT,
              (v_alloc->>'qty')::NUMERIC,
              (v_alloc->>'qty')::NUMERIC,
              p_operator, p_operator
            )
            ON CONFLICT (wave_id, sku_id, store_id) DO UPDATE
              SET qty = picking_wave_items.qty + EXCLUDED.qty,
                  picked_qty = COALESCE(picking_wave_items.picked_qty, 0) + EXCLUDED.picked_qty,
                  updated_by = p_operator;
            v_alloc_total := v_alloc_total + (v_alloc->>'qty')::NUMERIC;
          END IF;
        END LOOP;

        IF v_alloc_total > v_qty_received THEN
          RAISE EXCEPTION 'sku % allocation total % exceeds received %', v_sku_id, v_alloc_total, v_qty_received;
        END IF;
      END IF;
    END LOOP;

    SELECT COUNT(*), COUNT(DISTINCT store_id), COALESCE(SUM(qty),0)
      INTO v_item_count, v_store_count, v_total_qty
      FROM picking_wave_items WHERE wave_id = v_wave_id;

    UPDATE picking_waves
       SET item_count = v_item_count, store_count = v_store_count, total_qty = v_total_qty,
           status = 'picked', updated_at = NOW()
     WHERE id = v_wave_id;

    INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, created_by)
    VALUES (v_po.tenant_id, v_wave_id, 'wave_created',
            jsonb_build_object('wave_code', v_wave_code, 'po_id', p_po_id, 'gr_id', v_gr_id,
                               'item_count', v_item_count, 'store_count', v_store_count),
            p_operator);

    -- 7. 撿完即派貨：對每分店建 transfer(shipped) + 從總倉 outbound
    FOR v_store_rec IN
      SELECT DISTINCT pwi.store_id, s.location_id
        FROM picking_wave_items pwi
        JOIN stores s ON s.id = pwi.store_id
       WHERE pwi.wave_id = v_wave_id AND pwi.picked_qty > 0
    LOOP
      v_dest_loc := v_store_rec.location_id;
      IF v_dest_loc IS NULL THEN
        RAISE EXCEPTION 'store % has no location_id', v_store_rec.store_id;
      END IF;

      v_xfer_no := 'TR' || to_char(NOW(), 'YYMMDD') || '-W' || v_wave_id || '-S' || v_store_rec.store_id;

      INSERT INTO transfers (
        tenant_id, transfer_no, source_location, dest_location,
        status, transfer_type, requested_by, shipped_by, shipped_at,
        created_by, updated_by
      ) VALUES (
        v_po.tenant_id, v_xfer_no, v_po.dest_location_id, v_dest_loc,
        'shipped', 'hq_to_store', p_operator, p_operator, NOW(),
        p_operator, p_operator
      ) RETURNING id INTO v_xfer_id;

      -- 寫 transfer_items + 從總倉 outbound
      FOR v_pwi IN
        SELECT id, sku_id, picked_qty
          FROM picking_wave_items
         WHERE wave_id = v_wave_id
           AND store_id = v_store_rec.store_id
           AND picked_qty > 0
      LOOP
        v_out_mov_id := rpc_outbound(
          p_tenant_id       => v_po.tenant_id,
          p_location_id     => v_po.dest_location_id,
          p_sku_id          => v_pwi.sku_id,
          p_quantity        => v_pwi.picked_qty,
          p_movement_type   => 'transfer_out',
          p_source_doc_type => 'transfer',
          p_source_doc_id   => v_xfer_id,
          p_operator        => p_operator,
          p_allow_negative  => FALSE
        );

        INSERT INTO transfer_items (
          transfer_id, sku_id, qty_requested, qty_shipped, out_movement_id,
          created_by, updated_by
        ) VALUES (
          v_xfer_id, v_pwi.sku_id, v_pwi.picked_qty, v_pwi.picked_qty, v_out_mov_id,
          p_operator, p_operator
        );

        UPDATE picking_wave_items
           SET generated_transfer_id = v_xfer_id, updated_by = p_operator
         WHERE id = v_pwi.id;
      END LOOP;

      v_xfer_ids := v_xfer_ids || v_xfer_id;
    END LOOP;

    UPDATE picking_waves SET status = 'shipped', updated_by = p_operator WHERE id = v_wave_id;
  END IF;

  RETURN jsonb_build_object(
    'gr_id', v_gr_id,
    'gr_no', v_gr_no,
    'wave_id', v_wave_id,
    'wave_code', v_wave_code,
    'transfer_ids', to_jsonb(v_xfer_ids),
    'close_date', v_close_date
  );
END;
$$;

-- ============================================================================
-- v_pr_progress 升級：加 transfer 統計
-- ============================================================================
DROP VIEW IF EXISTS public.v_pr_progress;
CREATE VIEW public.v_pr_progress AS
SELECT
  pr.id   AS pr_id,
  pr.tenant_id,
  pr.source_close_date,
  COALESCE(po_agg.po_total, 0)          AS po_total,
  COALESCE(po_agg.po_sent, 0)           AS po_sent,
  COALESCE(po_agg.po_received_fully, 0) AS po_received_fully,
  COALESCE(xfer_agg.xfer_total, 0)      AS transfer_total,
  COALESCE(xfer_agg.xfer_shipped, 0)    AS transfer_shipped,
  COALESCE(xfer_agg.xfer_delivered, 0)  AS transfer_delivered,
  CASE
    WHEN pr.source_close_date IS NULL THEN FALSE
    WHEN cmp.total_campaigns = 0 THEN FALSE
    ELSE cmp.completed_campaigns = cmp.total_campaigns
  END AS all_campaigns_finalized
FROM purchase_requests pr
LEFT JOIN LATERAL (
  SELECT
    COUNT(DISTINCT po.id)                                                         AS po_total,
    COUNT(DISTINCT po.id) FILTER (WHERE po.status IN ('sent','partially_received','fully_received','closed')) AS po_sent,
    COUNT(DISTINCT po.id) FILTER (WHERE po.status IN ('fully_received','closed')) AS po_received_fully
    FROM purchase_request_items pri
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
    JOIN purchase_orders po       ON po.id  = poi.po_id
   WHERE pri.pr_id = pr.id
) po_agg ON TRUE
LEFT JOIN LATERAL (
  SELECT
    COUNT(DISTINCT t.id)                                                AS xfer_total,
    COUNT(DISTINCT t.id) FILTER (WHERE t.status IN ('shipped','received','closed')) AS xfer_shipped,
    COUNT(DISTINCT t.id) FILTER (WHERE t.status IN ('received','closed')) AS xfer_delivered
    FROM picking_waves pw
    JOIN picking_wave_items pwi ON pwi.wave_id = pw.id
    JOIN transfers t            ON t.id = pwi.generated_transfer_id
   WHERE pw.tenant_id = pr.tenant_id
     AND pr.source_close_date IS NOT NULL
     AND pw.wave_date = pr.source_close_date
) xfer_agg ON TRUE
LEFT JOIN LATERAL (
  SELECT
    COUNT(*)                                                AS total_campaigns,
    COUNT(*) FILTER (WHERE gbc.status = 'completed')        AS completed_campaigns
    FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = pr.tenant_id
     AND pr.source_close_date IS NOT NULL
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = pr.source_close_date
     AND gbc.status NOT IN ('cancelled')
) cmp ON TRUE;

GRANT SELECT ON public.v_pr_progress TO authenticated;

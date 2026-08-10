-- ============================================================
-- 2026-08-10: 收貨短收要落到補貨申請的 ride-along 內部單
--
-- 回報案例（松山店 RR-360 / WAVE-1149-S2、WAVE-1153-S2）：
--   補貨申請 #360 出 9 件、店端實收 5 件（4 件短收、實收填 0）。
--   收最後一張時 _restock_wave_progress 的 all_arrived 只看「調撥單
--   都收過了」、fully_dispatched 只看出貨量，兩者都不看 qty_received，
--   於是申請照樣推 received、RR-360 內部單照樣整張推 ready ——
--   店身上掛著 4 件根本沒收到的貨（庫存本身沒進帳，帳是對的，
--   單據是錯的）。
--
-- 修法：
--   1. 新 helper _restock_received_by_sku(request_id)：
--      歸屬出貨（wave＋直派，歸屬原則同 _restock_wave_progress）中
--      「已收貨」調撥的實收量，逐 SKU 對上申請量。混合波次
--      （同 SKU 帶 campaign 份額）時 campaign 份額優先拿到貨，
--      補貨份額先吃短收（顧客訂單優先的營運直覺）。
--   2. 新 helper _settle_restock_ride_along(request_id, operator, at)：
--      RR 推 received 時呼叫。RR- 內部單 pending 品項對齊實收 ——
--      實收 0 → status='cancelled'＋notes 加 [短收未到]；
--      部分到貨 → 拆行（同 20260805000100 拆行＋折扣分攤算法），
--      缺的那行 cancelled＋[短收未到|拆分自#<id>]。
--      之後：仍有有效品項 → 推 ready；全取消且沒收過錢 →
--      整單 cancelled＋[短收全未到自動取消]。
--      尾端依 CLAUDE.md 規則接 _close_orders_all_items_settled。
--   3. 新 helper _unsettle_restock_ride_along(request_id, operator)：
--      退回收貨（rpc_unreceive_transfer）時的反向：拆行併回原行、
--      [短收未到] 還原 pending、短收自動取消的單重開 pending。
--   4. rpc_receive_transfer：邏輯 D / D2 的 ride-along 推 ready
--      改為呼叫 _settle_restock_ride_along。
--   5. rpc_unreceive_transfer：反向邏輯 D / D2 加 _unsettle 呼叫。
--   6. _stockout_propagate_restock：received 補推分支同改。
--
-- 注意：不改 _restock_wave_progress 的語意 —— fully_dispatched /
--   all_arrived 仍以「出貨量／單子都收過」判定流程終點（短收時申請
--   還是收尾成 received，缺口進 /wms/exceptions 短收待處理，由
--   rpc_resolve_transfer_item_shortage 決定補出貨或認賠）。若改成
--   實收判定，短收的申請會永遠卡在 shipped 收不了尾。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   - rpc_receive_transfer / rpc_unreceive_transfer：
--     20260717000000_restock_wave_status_sync.sql（邏輯 D/D2 段改寫）
--   - _stockout_propagate_restock：20260720000010_stockout_restock_propagation.sql
--     （僅 received 補推分支一段改寫）
--
-- Rollback：
--   - rpc_receive_transfer / rpc_unreceive_transfer 還原 20260717000000 版本
--   - _stockout_propagate_restock 還原 20260720000010 版本
--   - DROP FUNCTION public._restock_received_by_sku(BIGINT);
--     DROP FUNCTION public._settle_restock_ride_along(BIGINT, UUID, TIMESTAMPTZ);
--     DROP FUNCTION public._unsettle_restock_ride_along(BIGINT, UUID);
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _restock_received_by_sku — 歸屬出貨的逐 SKU 實收量
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._restock_received_by_sku(p_request_id BIGINT)
RETURNS TABLE (sku_id BIGINT, need NUMERIC, received NUMERIC)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH req AS (
    SELECT rr.id, rr.tenant_id, rr.requesting_store_id, rr.linked_pr_id, rr.linked_transfer_id
      FROM restock_requests rr
     WHERE rr.id = p_request_id
  ),
  req_pos AS (
    SELECT DISTINCT poi.po_id
      FROM req
      JOIN purchase_request_items pri ON pri.pr_id = req.linked_pr_id
      JOIN purchase_order_items poi ON poi.id = pri.po_item_id
  ),
  active_lines AS (
    SELECT rrl.sku_id, SUM(rrl.qty) AS need
      FROM req
      JOIN restock_request_lines rrl ON rrl.request_id = req.id
     WHERE rrl.cancelled_at IS NULL
     GROUP BY rrl.sku_id
  ),
  -- 本申請在各「已收貨」調撥中的份額（歸屬原則同 _restock_wave_progress）
  wave_share AS (
    SELECT pwi.sku_id, t.id AS transfer_id, SUM(pwi.qty) AS rr_qty
      FROM req
      JOIN picking_wave_items pwi ON pwi.store_id = req.requesting_store_id
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN transfers t ON t.id = pwi.generated_transfer_id AND t.status IN ('received','closed')
     WHERE (pw.source_restock_request_id = req.id
            OR (pwi.campaign_id IS NULL
                AND pw.source_po_id IN (SELECT po_id FROM req_pos)))
       AND pwi.sku_id IN (SELECT al.sku_id FROM active_lines al)
     GROUP BY pwi.sku_id, t.id
  ),
  ti_agg AS (
    SELECT ti.transfer_id, ti.sku_id,
           SUM(ti.qty_shipped) AS shipped, SUM(ti.qty_received) AS recvd
      FROM transfer_items ti
     WHERE ti.transfer_id IN (SELECT ws.transfer_id FROM wave_share ws)
        OR ti.transfer_id IN (SELECT req.linked_transfer_id FROM req
                               WHERE req.linked_transfer_id IS NOT NULL)
     GROUP BY ti.transfer_id, ti.sku_id
  ),
  -- 混合波次同 SKU 可能同時載 campaign 份額：campaign 優先拿到貨、
  -- 補貨份額先吃短收 → 本申請實收 = min(份額, max(0, 實收 − 其他份額))
  wave_recv AS (
    SELECT ws.sku_id,
           SUM(LEAST(ws.rr_qty, GREATEST(ta.recvd - (ta.shipped - ws.rr_qty), 0))) AS received
      FROM wave_share ws
      JOIN ti_agg ta ON ta.transfer_id = ws.transfer_id AND ta.sku_id = ws.sku_id
     GROUP BY ws.sku_id
  ),
  direct_recv AS (
    SELECT ta.sku_id, SUM(ta.recvd) AS received
      FROM req
      JOIN transfers t ON t.id = req.linked_transfer_id AND t.status IN ('received','closed')
      JOIN ti_agg ta ON ta.transfer_id = t.id
     GROUP BY ta.sku_id
  )
  SELECT al.sku_id, al.need,
         COALESCE(w.received, 0) + COALESCE(d.received, 0) AS received
    FROM active_lines al
    LEFT JOIN wave_recv w ON w.sku_id = al.sku_id
    LEFT JOIN direct_recv d ON d.sku_id = al.sku_id;
$$;

REVOKE ALL ON FUNCTION public._restock_received_by_sku(BIGINT) FROM PUBLIC;

COMMENT ON FUNCTION public._restock_received_by_sku(BIGINT) IS
  '補貨申請逐 SKU「申請量 vs 歸屬實收量」（settle helper 內部用）。'
  '只算已收貨(received/closed)調撥的 qty_received；混合波次 campaign 份額優先拿到貨。';

-- ----------------------------------------------------------------
-- 2. _settle_restock_ride_along — RR 收尾時把內部單對齊實收
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._settle_restock_ride_along(
  p_request_id BIGINT,
  p_operator   UUID,
  p_at         TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req             restock_requests%ROWTYPE;
  v_order           customer_orders%ROWTYPE;
  v_row             RECORD;
  v_item            RECORD;
  v_remaining       NUMERIC;
  v_taken           NUMERIC;
  v_new_disc        NUMERIC;
  v_active          INTEGER;
  v_items_cancelled INTEGER := 0;
  v_items_split     INTEGER := 0;
  v_order_state     TEXT := 'unchanged';
BEGIN
  SELECT * INTO v_req FROM restock_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('order', 'no_request');
  END IF;

  SELECT * INTO v_order
    FROM customer_orders
   WHERE tenant_id   = v_req.tenant_id
     AND order_kind  = 'restock'
     AND order_no    = 'RR-' || p_request_id::TEXT
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('order', 'none');
  END IF;

  -- 逐 SKU 把實收量分配給品項；分配不到的 → 取消 / 拆行取消
  FOR v_row IN
    SELECT * FROM public._restock_received_by_sku(p_request_id) r
     WHERE r.received < r.need
  LOOP
    -- 非 pending 品項（已取貨/已轉手等）視為已消耗實收
    SELECT COALESCE(SUM(qty), 0) INTO v_taken
      FROM customer_order_items
     WHERE order_id = v_order.id
       AND sku_id   = v_row.sku_id
       AND status NOT IN ('pending', 'cancelled', 'expired');
    v_remaining := GREATEST(v_row.received - v_taken, 0);

    FOR v_item IN
      SELECT * FROM customer_order_items
       WHERE order_id = v_order.id
         AND sku_id   = v_row.sku_id
         AND status   = 'pending'
       ORDER BY id
       FOR UPDATE
    LOOP
      IF v_remaining >= v_item.qty THEN
        v_remaining := v_remaining - v_item.qty;
      ELSIF v_remaining > 0 THEN
        -- 部分到貨：拆行（折扣按數量比例分攤，同 20260805000100）
        v_new_disc := COALESCE(v_item.discount_amount, 0)
                      - round(COALESCE(v_item.discount_amount, 0) * v_remaining / v_item.qty);
        INSERT INTO customer_order_items (
          tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
          status, source, notes, discount_amount, discount_percent,
          created_by, updated_by, created_at, updated_at
        ) VALUES (
          v_item.tenant_id, v_item.order_id, v_item.campaign_item_id, v_item.sku_id,
          v_item.qty - v_remaining, v_item.unit_price,
          'cancelled', v_item.source,
          TRIM(BOTH E'\n' FROM COALESCE(v_item.notes || E'\n', '')
               || '[短收未到|拆分自#' || v_item.id || ']'),
          v_new_disc, v_item.discount_percent,
          p_operator, p_operator, NOW(), NOW()
        );
        UPDATE customer_order_items
           SET qty             = v_remaining,
               discount_amount = COALESCE(v_item.discount_amount, 0) - v_new_disc,
               updated_by      = p_operator,
               updated_at      = NOW()
         WHERE id = v_item.id;
        v_items_split := v_items_split + 1;
        v_remaining   := 0;
      ELSE
        -- 全沒到：整行取消（不設 stockout_at —— 短收不是斷貨）
        UPDATE customer_order_items
           SET status     = 'cancelled',
               notes      = TRIM(BOTH E'\n' FROM COALESCE(notes || E'\n', '') || '[短收未到]'),
               updated_by = p_operator,
               updated_at = NOW()
         WHERE id = v_item.id;
        v_items_cancelled := v_items_cancelled + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- 單頭：還有有效品項 → ready（店端才能轉手）；
  -- 全取消且沒收過錢 → 整單取消，不再掛在店身上
  SELECT COUNT(*) INTO v_active
    FROM customer_order_items
   WHERE order_id = v_order.id
     AND status NOT IN ('cancelled', 'expired');

  IF v_active > 0 THEN
    UPDATE customer_orders
       SET status = 'ready', ready_at = NOW(), updated_by = p_operator, updated_at = NOW()
     WHERE id = v_order.id AND status IN ('pending', 'confirmed', 'shipping');
    IF FOUND THEN v_order_state := 'ready'; END IF;
  ELSIF COALESCE(v_order.payment_status, 'unpaid') <> 'paid'
        AND COALESCE(v_order.wallet_paid_amount, 0) = 0 THEN
    UPDATE customer_orders
       SET status       = 'cancelled',
           cancelled_at = p_at,
           notes        = TRIM(BOTH E'\n' FROM COALESCE(notes || E'\n', '') || '[短收全未到自動取消]'),
           updated_by   = p_operator,
           updated_at   = NOW()
     WHERE id = v_order.id AND status IN ('pending', 'confirmed', 'shipping');
    IF FOUND THEN v_order_state := 'cancelled'; END IF;
  END IF;

  -- CLAUDE.md：任何把品項改成 cancelled 的路徑，後面接單頭收尾
  PERFORM public._close_orders_all_items_settled(ARRAY[v_order.id], p_operator, p_at);

  RETURN jsonb_build_object(
    'order_id',        v_order.id,
    'items_cancelled', v_items_cancelled,
    'items_split',     v_items_split,
    'order',           v_order_state
  );
END;
$$;

REVOKE ALL ON FUNCTION public._settle_restock_ride_along(BIGINT, UUID, TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION public._settle_restock_ride_along(BIGINT, UUID, TIMESTAMPTZ) IS
  '補貨申請推 received 時收尾 RR- 內部單：pending 品項對齊歸屬實收'
  '（0 → cancelled＋[短收未到]、部分 → 拆行），仍有有效品項推 ready、'
  '全取消且未收款整單取消；尾端接 _close_orders_all_items_settled。';

-- ----------------------------------------------------------------
-- 3. _unsettle_restock_ride_along — 退回收貨時的反向
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._unsettle_restock_ride_along(
  p_request_id BIGINT,
  p_operator   UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req         restock_requests%ROWTYPE;
  v_order       customer_orders%ROWTYPE;
  v_item        RECORD;
  v_origin_id   BIGINT;
  v_cnt         INTEGER;
  v_merged      INTEGER := 0;
  v_restored    INTEGER := 0;
  v_order_state TEXT := 'unchanged';
BEGIN
  SELECT * INTO v_req FROM restock_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('order', 'no_request');
  END IF;

  SELECT * INTO v_order
    FROM customer_orders
   WHERE tenant_id  = v_req.tenant_id
     AND order_kind = 'restock'
     AND order_no   = 'RR-' || p_request_id::TEXT
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('order', 'none');
  END IF;

  -- 拆行出去的短收列：數量/折扣併回原行後刪除
  FOR v_item IN
    SELECT * FROM customer_order_items
     WHERE order_id = v_order.id
       AND status   = 'cancelled'
       AND notes ~ '\[短收未到\|拆分自#[0-9]+\]'
     ORDER BY id
     FOR UPDATE
  LOOP
    v_origin_id := (substring(v_item.notes FROM '\[短收未到\|拆分自#([0-9]+)\]'))::BIGINT;
    UPDATE customer_order_items
       SET qty             = qty + v_item.qty,
           discount_amount = COALESCE(discount_amount, 0) + COALESCE(v_item.discount_amount, 0),
           updated_by      = p_operator,
           updated_at      = NOW()
     WHERE id = v_origin_id AND order_id = v_order.id;
    IF FOUND THEN
      DELETE FROM customer_order_items WHERE id = v_item.id;
      v_merged := v_merged + 1;
    ELSE
      -- 原行不見了（不應發生）：退而求其次，本列還原 pending
      UPDATE customer_order_items
         SET status     = 'pending',
             notes      = NULLIF(TRIM(BOTH E'\n' FROM
                            regexp_replace(notes, '\s*\[短收未到\|拆分自#[0-9]+\]', '', 'g')), ''),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = v_item.id;
      v_restored := v_restored + 1;
    END IF;
  END LOOP;

  -- 整行取消的短收列：還原 pending、去標記
  UPDATE customer_order_items
     SET status     = 'pending',
         notes      = NULLIF(TRIM(BOTH E'\n' FROM
                        regexp_replace(notes, '\s*\[短收未到\]', '', 'g')), ''),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE order_id = v_order.id
     AND status   = 'cancelled'
     AND notes LIKE '%[短收未到]%';
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  v_restored := v_restored + v_cnt;

  -- 整單被短收自動取消的：重開 pending
  IF v_order.status = 'cancelled' AND v_order.notes LIKE '%[短收全未到自動取消]%' THEN
    UPDATE customer_orders
       SET status       = 'pending',
           cancelled_at = NULL,
           ready_at     = NULL,
           notes        = NULLIF(TRIM(BOTH E'\n' FROM
                            regexp_replace(notes, '\s*\[短收全未到自動取消\]', '', 'g')), ''),
           updated_by   = p_operator,
           updated_at   = NOW()
     WHERE id = v_order.id;
    v_order_state := 'reopened';
  END IF;

  RETURN jsonb_build_object(
    'order_id', v_order.id,
    'merged',   v_merged,
    'restored', v_restored,
    'order',    v_order_state
  );
END;
$$;

REVOKE ALL ON FUNCTION public._unsettle_restock_ride_along(BIGINT, UUID) FROM PUBLIC;

COMMENT ON FUNCTION public._unsettle_restock_ride_along(BIGINT, UUID) IS
  '_settle_restock_ride_along 的反向（退回收貨用）：拆行併回原行、'
  '[短收未到] 品項還原 pending、[短收全未到自動取消] 的單重開 pending。';

-- ----------------------------------------------------------------
-- 4. rpc_receive_transfer — 邏輯 D / D2 改走 settle helper
--    基底：20260717000000 逐字保留，僅改 D 與 D2 的 ride-along 段。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(p_transfer_id bigint, p_lines jsonb, p_operator uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id            UUID;
  v_status               TEXT;
  v_transfer_type        TEXT;
  v_dest_location        BIGINT;
  v_existing_notes       TEXT;
  v_customer_order_id    BIGINT;
  v_next_transfer_id     BIGINT;
  v_item                 RECORD;
  v_qty_received         NUMERIC;
  v_unit_cost            NUMERIC;
  v_in_mov_id            BIGINT;
  v_total_qty            NUMERIC := 0;
  v_total_variance       NUMERIC := 0;
  v_items_received       INTEGER := 0;
  v_lines_consumed       INTEGER := 0;
  v_lines_count          INTEGER;
  v_orders_advanced      INTEGER := 0;
  v_next_shipped         BOOLEAN := FALSE;
  v_leg2                 transfers%ROWTYPE;
  v_leg2_item            RECORD;
  v_leg2_mov             BIGINT;
  v_dest_store_id        BIGINT;
  v_restock_received     INTEGER := 0;
  v_rr                   RECORD;
  v_prog                 RECORD;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is in status %, expected shipped', p_transfer_id, v_status;
  END IF;

  IF p_lines IS NOT NULL THEN
    v_lines_count := jsonb_array_length(p_lines);
    IF EXISTS (
      SELECT 1
        FROM jsonb_array_elements(p_lines) AS l
        LEFT JOIN transfer_items ti
          ON ti.id = (l->>'transfer_item_id')::BIGINT
         AND ti.transfer_id = p_transfer_id
       WHERE ti.id IS NULL
    ) THEN
      RAISE EXCEPTION 'p_lines contains transfer_item_id not belonging to transfer %', p_transfer_id;
    END IF;
  END IF;

  -- ===== 原有邏輯：寫 qty_received + dest_location inbound =====
  FOR v_item IN
    SELECT ti.id, ti.sku_id, ti.qty_shipped, sm.unit_cost AS out_cost
      FROM transfer_items ti
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE ti.transfer_id = p_transfer_id
     ORDER BY ti.id
  LOOP
    v_qty_received := v_item.qty_shipped;

    IF p_lines IS NOT NULL THEN
      SELECT (l->>'qty_received')::NUMERIC
        INTO v_qty_received
        FROM jsonb_array_elements(p_lines) AS l
       WHERE (l->>'transfer_item_id')::BIGINT = v_item.id
       LIMIT 1;

      IF FOUND THEN
        v_lines_consumed := v_lines_consumed + 1;
      ELSE
        v_qty_received := v_item.qty_shipped;
      END IF;
    END IF;

    IF v_qty_received IS NULL OR v_qty_received < 0 THEN
      RAISE EXCEPTION 'transfer_item % qty_received must be >= 0, got %', v_item.id, v_qty_received;
    END IF;
    IF v_qty_received > v_item.qty_shipped THEN
      RAISE EXCEPTION 'transfer_item % over-receipt: qty_received=% > qty_shipped=%',
        v_item.id, v_qty_received, v_item.qty_shipped;
    END IF;

    IF v_qty_received > 0 THEN
      v_unit_cost := COALESCE(ABS(v_item.out_cost), 0);

      v_in_mov_id := rpc_inbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_dest_location,
        p_sku_id          => v_item.sku_id,
        p_quantity        => v_qty_received,
        p_unit_cost       => v_unit_cost,
        p_movement_type   => 'transfer_in',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );

      UPDATE transfer_items
         SET qty_received   = v_qty_received,
             in_movement_id = v_in_mov_id,
             updated_by     = p_operator
       WHERE id = v_item.id;
    ELSE
      UPDATE transfer_items
         SET qty_received = 0,
             updated_by   = p_operator
       WHERE id = v_item.id;
    END IF;

    v_total_qty      := v_total_qty + v_qty_received;
    v_total_variance := v_total_variance + (v_qty_received - v_item.qty_shipped);
    v_items_received := v_items_received + 1;
  END LOOP;

  UPDATE transfers
     SET status      = 'received',
         received_by = p_operator,
         received_at = NOW(),
         notes       = CASE
                         WHEN p_notes IS NULL OR p_notes = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN p_notes
                         ELSE v_existing_notes || E'\n' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- ===== 邏輯 A：自動 ship 下一段（aid chain B 模型）=====
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_leg2 FROM transfers
     WHERE id = v_next_transfer_id FOR UPDATE;

    IF v_leg2.id IS NOT NULL AND v_leg2.status = 'draft' THEN
      FOR v_leg2_item IN
        SELECT ti.id AS leg2_item_id, ti.sku_id, ti2.qty_received
          FROM transfer_items ti
          JOIN transfer_items ti2
            ON ti2.transfer_id = p_transfer_id AND ti2.sku_id = ti.sku_id
         WHERE ti.transfer_id = v_leg2.id
      LOOP
        IF v_leg2_item.qty_received > 0 THEN
          v_leg2_mov := rpc_outbound(
            p_tenant_id       => v_leg2.tenant_id,
            p_location_id     => v_leg2.source_location,
            p_sku_id          => v_leg2_item.sku_id,
            p_quantity        => v_leg2_item.qty_received,
            p_movement_type   => 'transfer_out',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_leg2.id,
            p_operator        => p_operator
          );
          UPDATE transfer_items
             SET qty_shipped     = v_leg2_item.qty_received,
                 qty_requested   = v_leg2_item.qty_received,
                 out_movement_id = v_leg2_mov,
                 updated_by      = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        ELSE
          UPDATE transfer_items
             SET qty_shipped   = 0,
                 qty_requested = 0,
                 updated_by    = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        END IF;
      END LOOP;

      UPDATE transfers
         SET status      = 'shipped',
             shipped_by  = p_operator,
             shipped_at  = NOW(),
             updated_by  = p_operator
       WHERE id = v_leg2.id;
      v_next_shipped := TRUE;
    END IF;
  END IF;

  -- ===== 邏輯 B：aid 單 FK 直接推 customer_order → ready =====
  IF v_customer_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = NOW(),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_customer_order_id
       AND status = 'shipping';
    GET DIAGNOSTICS v_orders_advanced = ROW_COUNT;

  -- ===== 邏輯 C：hq_to_store wave transfer → 推該分店訂單 → ready =====
  -- 修：不再無條件推該店「所有」shipping 訂單；改成只推
  --     is_order_pickup_ready=true（依該訂單的團真的到齊、shortage-aware）的訂單，
  --     避免收到別團波次時把尚未出貨的團一起誤標為可取貨。
  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      WITH advanced AS (
        UPDATE customer_orders co
           SET status     = 'ready',
               ready_at   = NOW(),
               updated_by = p_operator,
               updated_at = NOW()
         WHERE co.tenant_id      = v_tenant_id
           AND co.pickup_store_id = v_dest_store_id
           AND co.status          = 'shipping'
           AND public.is_order_pickup_ready(co.id)
        RETURNING co.id
      )
      SELECT COUNT(*) INTO v_orders_advanced FROM advanced;
    END IF;
  END IF;

  -- ===== 邏輯 D：linked 補貨申請 → 已收貨；ride-along 單 → ready =====
  -- 店家收貨即補貨流程終點：把 linked_transfer_id 指向本單的補貨申請
  -- 推到 received。approved_transfer 為 legacy 防禦（現行直派皆直接 shipped）。
  FOR v_rr IN
    SELECT id FROM restock_requests
     WHERE linked_transfer_id = p_transfer_id
       AND status IN ('shipped', 'approved_transfer')
  LOOP
    UPDATE restock_requests
       SET status = 'received', updated_by = p_operator
     WHERE id = v_rr.id;
    v_restock_received := v_restock_received + 1;

    -- 20260810：ride-along 內部單改由 settle helper 收尾 —— 品項先對齊實收
    -- （短收 0 → cancelled、部分 → 拆行），再推 ready / 全未到自動取消。
    PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
  END LOOP;

  -- ===== 邏輯 D2（20260717）：wave 路徑補貨申請 → 已出貨/已收貨 =====
  -- 本調撥若為撿貨單產物（picking_wave_items.generated_transfer_id 指向本單），
  -- 歸屬的補貨申請（歸屬原則同 20260715000020）「全數出貨且全數到店」→ received、
  -- ride-along 單推 ready；已全數出貨但仍有他張在途 → 至少推 shipped。
  FOR v_rr IN
    SELECT DISTINCT rr.id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN restock_requests rr
        ON rr.tenant_id = v_tenant_id
       AND rr.requesting_store_id = pwi.store_id
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND rr.status IN ('approved_pr', 'approved_transfer', 'shipped')
       AND (pw.source_restock_request_id = rr.id
            OR (pwi.campaign_id IS NULL
                AND rr.linked_pr_id IS NOT NULL
                AND pw.source_po_id IN (
                  SELECT DISTINCT poi.po_id
                    FROM purchase_request_items pri
                    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
                   WHERE pri.pr_id = rr.linked_pr_id)))
       AND pwi.sku_id IN (SELECT sku_id FROM restock_request_lines
                           WHERE request_id = rr.id AND cancelled_at IS NULL)
  LOOP
    SELECT * INTO v_prog FROM public._restock_wave_progress(v_rr.id);
    IF v_prog.fully_dispatched AND v_prog.all_arrived THEN
      UPDATE restock_requests
         SET status = 'received', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer', 'shipped');
      v_restock_received := v_restock_received + 1;

      -- 20260810：ride-along 單交給 settle helper —— 短收品項對齊實收後
      -- 才推 ready；全未到則整單自動取消，不再掛在店身上。
      PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
    ELSIF v_prog.fully_dispatched THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer');
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped,
    'restock_received',       v_restock_received
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT) IS
  '店家收貨：入庫 + transfer received；邏輯 A 接力自動出後段、B/C 推訂單 ready、'
  'D 直派補貨申請推 received、D2 wave 路徑補貨申請「全數出貨且全數到店」推 received；'
  '20260810 起 D/D2 的 ride-along 內部單改由 _settle_restock_ride_along 收尾'
  '（品項對齊實收：短收 0 → cancelled、部分 → 拆行，之後才推 ready / 全未到自動取消）。';

-- ----------------------------------------------------------------
-- 5. rpc_unreceive_transfer — 反向邏輯 D / D2 加 unsettle
--    基底：20260717000000 逐字保留，僅改反向 D 與反向 D2。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_unreceive_transfer(
  p_transfer_id bigint,
  p_operator    uuid,
  p_notes       text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
-- 邏輯 C 需重掃該店所有 ready 訂單並逐張跑 is_order_pickup_ready，覆寫 PostgREST
-- 預設 statement_timeout，避免大店退回時中途被砍。
SET statement_timeout TO '60000'
AS $function$
DECLARE
  v_tenant_id         UUID;
  v_status            TEXT;
  v_transfer_type     TEXT;
  v_dest_location     BIGINT;
  v_existing_notes    TEXT;
  v_customer_order_id BIGINT;
  v_next_transfer_id  BIGINT;
  v_leg2_status       TEXT;
  v_item              RECORD;
  v_orig              stock_movements%ROWTYPE;
  v_on_hand           NUMERIC;
  v_rev_id            BIGINT;
  v_items_reversed    INTEGER := 0;
  v_total_qty         NUMERIC := 0;
  v_dest_store_id     BIGINT;
  v_orders_reverted   INTEGER := 0;
  v_ord               RECORD;
  v_restock_reverted  INTEGER := 0;
  v_rr                RECORD;
  v_prog              RECORD;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'received' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，僅「已收貨(received)」可退回取消收貨', p_transfer_id, v_status;
  END IF;

  -- 守衛：多段接力且後段已自動出貨（收貨時 ship 過），不允許直接退回本段
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT status INTO v_leg2_status FROM transfers WHERE id = v_next_transfer_id FOR UPDATE;
    IF v_leg2_status IS NOT NULL AND v_leg2_status <> 'draft' THEN
      RAISE EXCEPTION '此調撥為多段接力，後段調撥 %（狀態 %）已出貨，請先處理後段後再退回本段收貨',
        v_next_transfer_id, v_leg2_status;
    END IF;
  END IF;

  -- 逐項沖銷 transfer_in 入庫、並把 qty_received 歸零
  FOR v_item IN
    SELECT id, sku_id, qty_received, in_movement_id
      FROM transfer_items
     WHERE transfer_id = p_transfer_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.qty_received > 0 AND v_item.in_movement_id IS NOT NULL THEN
      SELECT * INTO v_orig FROM stock_movements WHERE id = v_item.in_movement_id;

      IF v_orig.id IS NULL
         OR v_orig.movement_type <> 'transfer_in'
         OR v_orig.source_doc_type <> 'transfer'
         OR v_orig.source_doc_id <> p_transfer_id THEN
        RAISE EXCEPTION 'transfer_item % 的 movement % 非本調撥入庫，無法退回收貨',
          v_item.id, v_item.in_movement_id;
      END IF;
      IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
        RAISE EXCEPTION 'movement % 已被沖銷過，不可重複退回收貨', v_orig.id;
      END IF;

      -- 物理守衛：入庫貨若已被取貨/售出使 on_hand 不足以沖銷 → 擋（避免庫存變負）
      SELECT on_hand INTO v_on_hand
        FROM stock_balances
       WHERE tenant_id   = v_orig.tenant_id
         AND location_id = v_orig.location_id
         AND sku_id      = v_orig.sku_id
       FOR UPDATE;
      IF COALESCE(v_on_hand, 0) < v_orig.quantity THEN
        RAISE EXCEPTION '分店庫存不足以退回收貨（SKU %：現有 %、需沖銷 %）：該批貨可能已被取貨/售出，無法退回',
          v_orig.sku_id, COALESCE(v_on_hand, 0), v_orig.quantity;
      END IF;

      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
      ) VALUES (
        v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
        -v_orig.quantity, v_orig.unit_cost, 'reversal',
        'transfer', p_transfer_id, v_item.id, v_orig.id,
        format('退回收貨 transfer=%s item=%s（沖銷 movement %s）%s',
               p_transfer_id, v_item.id, v_orig.id,
               COALESCE('：' || NULLIF(TRIM(p_notes), ''), '')),
        p_operator
      ) RETURNING id INTO v_rev_id;

      v_total_qty      := v_total_qty + v_orig.quantity;
      v_items_reversed := v_items_reversed + 1;
    END IF;

    UPDATE transfer_items
       SET qty_received   = 0,
           in_movement_id = NULL,
           updated_by     = p_operator,
           updated_at     = NOW()
     WHERE id = v_item.id;
  END LOOP;

  -- 調撥單退回 shipped
  UPDATE transfers
     SET status      = 'shipped',
         received_by = NULL,
         received_at = NULL,
         notes       = CASE
                         WHEN p_notes IS NULL OR TRIM(p_notes) = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN '退回收貨：' || p_notes
                         ELSE v_existing_notes || E'\n退回收貨：' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- 反向邏輯 B（aid 單 FK）/ 邏輯 C（hq_to_store）：
  -- 把因本次收貨被推到 ready、沖銷後已不再 pickup_ready 的訂單退回 shipping。
  -- 因其他已收波次而仍到貨的訂單維持 ready。已取貨(partially_completed/completed)不動。
  IF v_customer_order_id IS NOT NULL THEN
    FOR v_ord IN
      SELECT id FROM customer_orders
       WHERE id = v_customer_order_id AND status = 'ready'
       FOR UPDATE
    LOOP
      IF NOT public.is_order_pickup_ready(v_ord.id) THEN
        UPDATE customer_orders
           SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
         WHERE id = v_ord.id;
        PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
          format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
        v_orders_reverted := v_orders_reverted + 1;
      END IF;
    END LOOP;

  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      FOR v_ord IN
        SELECT id FROM customer_orders
         WHERE tenant_id       = v_tenant_id
           AND pickup_store_id = v_dest_store_id
           AND status          = 'ready'
         FOR UPDATE
      LOOP
        IF NOT public.is_order_pickup_ready(v_ord.id) THEN
          UPDATE customer_orders
             SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
           WHERE id = v_ord.id;
          PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
            format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
          v_orders_reverted := v_orders_reverted + 1;
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- ===== 反向邏輯 D：linked 補貨申請退回 shipped；ride-along 單退回 pending =====
  FOR v_rr IN
    SELECT id FROM restock_requests
     WHERE linked_transfer_id = p_transfer_id
       AND status = 'received'
  LOOP
    UPDATE restock_requests
       SET status = 'shipped', updated_by = p_operator
     WHERE id = v_rr.id;
    v_restock_reverted := v_restock_reverted + 1;

    -- 20260810：settle 的反向 —— 短收被取消/拆行的品項還原，整單短收取消的單重開
    PERFORM public._unsettle_restock_ride_along(v_rr.id, p_operator);
  END LOOP;

  UPDATE customer_orders co
     SET status     = 'pending',
         ready_at   = NULL,
         updated_by = p_operator,
         updated_at = NOW()
    FROM restock_requests rr
   WHERE rr.linked_transfer_id = p_transfer_id
     AND co.tenant_id  = rr.tenant_id
     AND co.order_no   = 'RR-' || rr.id::TEXT
     AND co.order_kind = 'restock'
     AND co.status = 'ready';

  -- ===== 反向邏輯 D2（20260717）：wave 路徑申請退回 shipped =====
  -- 本調撥退回在途後，歸屬的 received 申請若不再「全數出貨且全數到店」
  -- → 退回 shipped、ride-along 單 ready → pending。
  FOR v_rr IN
    SELECT DISTINCT rr.id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN restock_requests rr
        ON rr.tenant_id = v_tenant_id
       AND rr.requesting_store_id = pwi.store_id
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND rr.status = 'received'
       AND (pw.source_restock_request_id = rr.id
            OR (pwi.campaign_id IS NULL
                AND rr.linked_pr_id IS NOT NULL
                AND pw.source_po_id IN (
                  SELECT DISTINCT poi.po_id
                    FROM purchase_request_items pri
                    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
                   WHERE pri.pr_id = rr.linked_pr_id)))
       AND pwi.sku_id IN (SELECT sku_id FROM restock_request_lines
                           WHERE request_id = rr.id AND cancelled_at IS NULL)
  LOOP
    SELECT * INTO v_prog FROM public._restock_wave_progress(v_rr.id);
    IF NOT (v_prog.fully_dispatched AND v_prog.all_arrived) THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = p_operator
       WHERE id = v_rr.id AND status = 'received';
      v_restock_reverted := v_restock_reverted + 1;

      -- 20260810：settle 的反向（同反向邏輯 D）
      PERFORM public._unsettle_restock_ride_along(v_rr.id, p_operator);

      UPDATE customer_orders co
         SET status     = 'pending',
             ready_at   = NULL,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE co.tenant_id  = v_tenant_id
         AND co.order_no   = 'RR-' || v_rr.id::TEXT
         AND co.order_kind = 'restock'
         AND co.status = 'ready';
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'transfer_id',        p_transfer_id,
    'items_reversed',     v_items_reversed,
    'total_qty_reversed', v_total_qty,
    'orders_reverted',    v_orders_reverted,
    'restock_reverted',   v_restock_reverted
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) IS
  '退回收貨：rpc_receive_transfer 的反向。沖銷 transfer_in 入庫(reversal movement)、'
  'qty_received 歸零、調撥單 received→shipped；沖銷後不再 pickup_ready 的訂單退回 shipping；'
  'linked / wave 路徑補貨申請 received→shipped；20260810 起同時反向還原短收結算'
  '（_unsettle_restock_ride_along：拆行併回、[短收未到] 還原 pending、短收取消單重開）。'
  '守衛：非 received / 後段已出貨 / movement 已沖銷 / on_hand 不足(貨已取用) 皆擋下。';

-- ----------------------------------------------------------------
-- 6. _stockout_propagate_restock — received 補推分支改走 settle helper
--    基底：20260720000010 逐字保留，僅改該一段。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._stockout_propagate_restock(
  p_po_id         BIGINT,
  p_stockout_skus BIGINT[],
  p_operator      UUID,
  p_at            TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_line_ids         BIGINT[];
  v_req              RECORD;
  v_prog             RECORD;
  v_active           INTEGER;
  v_cnt              INTEGER;
  v_lines            INTEGER := 0;
  v_order_items      INTEGER := 0;
  v_req_cancelled    INTEGER := 0;
  v_orders_cancelled INTEGER := 0;
  v_req_advanced     INTEGER := 0;
BEGIN
  IF p_stockout_skus IS NOT NULL AND COALESCE(array_length(p_stockout_skus, 1), 0) > 0 THEN

    -- 受影響明細：明細的 PR 有品項轉入本 PO、SKU 屬斷貨集合、未取消，
    -- 且沒有任何歸屬出貨（wave 歸屬原則同 20260715000020 ＋ 直派 transfer）
    SELECT ARRAY_AGG(rrl.id) INTO v_line_ids
      FROM restock_request_lines rrl
      JOIN restock_requests rr ON rr.id = rrl.request_id
      JOIN purchase_request_items pri
        ON pri.pr_id = COALESCE(rrl.linked_pr_id, rr.linked_pr_id)
       AND pri.sku_id = rrl.sku_id
      JOIN purchase_order_items poi ON poi.id = pri.po_item_id
     WHERE poi.po_id = p_po_id
       AND rrl.sku_id = ANY (p_stockout_skus)
       AND rrl.cancelled_at IS NULL
       AND rr.status IN ('pending','approved_pr','approved_transfer','shipped')
       AND NOT EXISTS (
             SELECT 1
               FROM picking_wave_items pwi
               JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
               JOIN transfers t ON t.id = pwi.generated_transfer_id AND t.status <> 'cancelled'
              WHERE pwi.store_id = rr.requesting_store_id
                AND pwi.sku_id = rrl.sku_id
                AND (pw.source_restock_request_id = rr.id
                     OR (pwi.campaign_id IS NULL
                         AND pw.source_po_id IN (
                               SELECT DISTINCT poi2.po_id
                                 FROM purchase_request_items pri2
                                 JOIN purchase_order_items poi2 ON poi2.id = pri2.po_item_id
                                WHERE pri2.pr_id = rr.linked_pr_id
                                   OR pri2.pr_id IN (
                                        SELECT l2.linked_pr_id
                                          FROM restock_request_lines l2
                                         WHERE l2.request_id = rr.id
                                           AND l2.linked_pr_id IS NOT NULL))))
           )
       AND NOT EXISTS (
             SELECT 1
               FROM transfers t
               JOIN transfer_items ti ON ti.transfer_id = t.id
              WHERE t.id = rr.linked_transfer_id
                AND t.status <> 'cancelled'
                AND ti.sku_id = rrl.sku_id
           );

    IF v_line_ids IS NOT NULL AND COALESCE(array_length(v_line_ids, 1), 0) > 0 THEN

      -- (a) 明細取消＋斷貨標記
      UPDATE restock_request_lines
         SET cancelled_at = p_at,
             cancelled_by = p_operator,
             stockout_at  = p_at,
             updated_by   = p_operator
       WHERE id = ANY (v_line_ids);
      GET DIAGNOSTICS v_lines = ROW_COUNT;

      -- (b) RR- 內部單對應品項：pending → cancelled + 斷貨標記
      UPDATE customer_order_items coi
         SET status      = 'cancelled',
             stockout_at = p_at,
             updated_by  = p_operator,
             updated_at  = NOW()
        FROM customer_orders co, restock_request_lines rrl
       WHERE rrl.id = ANY (v_line_ids)
         AND co.tenant_id  = rrl.tenant_id
         AND co.order_kind = 'restock'
         AND co.order_no   = 'RR-' || rrl.request_id::TEXT
         AND coi.order_id  = co.id
         AND coi.sku_id    = rrl.sku_id
         AND coi.status    = 'pending'
         AND coi.stockout_at IS NULL;
      GET DIAGNOSTICS v_order_items = ROW_COUNT;

      -- (c) 單頭流轉
      FOR v_req IN
        SELECT rr.* FROM restock_requests rr
         WHERE rr.id IN (SELECT l.request_id FROM restock_request_lines l
                          WHERE l.id = ANY (v_line_ids))
         ORDER BY rr.id
         FOR UPDATE
      LOOP
        SELECT COUNT(*) INTO v_active
          FROM restock_request_lines
         WHERE request_id = v_req.id AND cancelled_at IS NULL;

        IF v_active = 0 THEN
          -- 全品項斷貨/刪除 → 申請取消（斷貨標記）。
          -- shipped/received 不動 — 歸屬出貨守衛下有出貨的明細不會被取消。
          UPDATE restock_requests
             SET status      = 'cancelled',
                 stockout_at = p_at,
                 updated_by  = p_operator
           WHERE id = v_req.id
             AND status IN ('pending','approved_pr','approved_transfer');
          GET DIAGNOSTICS v_cnt = ROW_COUNT;
          v_req_cancelled := v_req_cancelled + v_cnt;

          -- RR- 內部單：全品項已取消/過期＋沒收過錢 → 整單取消（斷貨標記）
          IF v_cnt > 0 THEN
            UPDATE customer_orders co
               SET status       = 'cancelled',
                   cancelled_at = p_at,
                   stockout_at  = p_at,
                   updated_by   = p_operator,
                   updated_at   = NOW()
             WHERE co.tenant_id  = v_req.tenant_id
               AND co.order_kind = 'restock'
               AND co.order_no   = 'RR-' || v_req.id::TEXT
               AND co.status IN ('pending','confirmed')
               AND COALESCE(co.payment_status, 'unpaid') <> 'paid'
               AND COALESCE(co.wallet_paid_amount, 0) = 0
               AND NOT EXISTS (
                     SELECT 1 FROM customer_order_items x
                      WHERE x.order_id = co.id
                        AND x.status NOT IN ('cancelled','expired')
                   );
            GET DIAGNOSTICS v_cnt = ROW_COUNT;
            v_orders_cancelled := v_orders_cancelled + v_cnt;
          END IF;

        ELSIF v_req.status IN ('approved_pr','approved_transfer','shipped') THEN
          -- 部分斷貨：剩餘品項若其實已全數出貨(/到店) → 補推
          -- shipped / received（同 20260717000000 backfill 規則）
          SELECT * INTO v_prog FROM public._restock_wave_progress(v_req.id);

          IF v_prog.fully_dispatched AND v_prog.all_arrived AND v_prog.any_received THEN
            UPDATE restock_requests
               SET status = 'received', updated_by = p_operator
             WHERE id = v_req.id;
            v_req_advanced := v_req_advanced + 1;

            -- 20260810：ride-along 單交給 settle helper（短收品項對齊實收）
            PERFORM public._settle_restock_ride_along(v_req.id, p_operator, p_at);

          ELSIF v_prog.fully_dispatched
                AND v_req.status IN ('approved_pr','approved_transfer') THEN
            UPDATE restock_requests
               SET status = 'shipped', updated_by = p_operator
             WHERE id = v_req.id;
            v_req_advanced := v_req_advanced + 1;
          END IF;
        END IF;
      END LOOP;

    END IF;
  END IF;

  RETURN jsonb_build_object(
    'restock_lines',            v_lines,
    'restock_order_items',      v_order_items,
    'restock_cancelled',        v_req_cancelled,
    'restock_orders_cancelled', v_orders_cancelled,
    'restock_advanced',         v_req_advanced
  );
END;
$$;

REVOKE ALL ON FUNCTION public._stockout_propagate_restock(BIGINT, BIGINT[], UUID, TIMESTAMPTZ) FROM PUBLIC;

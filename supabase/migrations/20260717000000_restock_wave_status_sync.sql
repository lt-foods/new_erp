-- ============================================================
-- 2026-07-17: wave 路徑補貨申請隨出貨/收貨推進狀態（補 20260714000080 自承的缺口）
--
-- 問題：
--   走「補貨 → PR → PO → 撿貨波次」路徑的補貨申請，波次產生的調撥單
--   沒有 back-link 到 restock（linked_transfer_id 維持 NULL），整條
--   出貨/收貨鏈沒人推它的 status —— 永遠卡在 approved_pr /
--   approved_transfer，店端補貨列表看不到「已出貨/已收貨」；ride-along
--   單（RR-<id>）也跟著卡 pending，貨到了卻不能轉手給客人。
--   實例：PR2607070440（restock #46，平鎮店）：PO2607070727 全收 →
--   WV260713000526 → WAVE-381-S1 於 2026-07-13 由店家收訖、庫存 +3，
--   restock #46 仍 approved_pr、RR-46 仍 pending。
--   20260714000080 修直派路徑時已註明「wave 路徑是另一個獨立缺口」，本檔補之。
--
-- 修法（歸屬原則沿用 20260715000020 防重複派貨守衛，兩者必須一致）：
--   「歸屬本申請的出貨」= 撿貨單 wave items 中
--     a) pw.source_restock_request_id = 本申請，或
--     b) campaign_id IS NULL 且 pw.source_po_id ∈ 本申請 PR 拆出的 PO、
--        且派給申請分店、品項在申請 lines 內
--   ＋ 補貨直派 transfer（linked_transfer_id）。
--   刻意不回填 linked_transfer_id：該欄位被 rpc_ship_restock_pr_received /
--   rpc_create_wave_from_restock 當「已直派」守衛用，wave 可分多次派、
--   回填會擋掉剩餘量的後續派貨。
--
--   1. 新 helper _restock_wave_progress(request_id)：算歸屬出貨的
--      fully_dispatched（每條有效 line 出貨量 ≥ 申請量）/ all_arrived
--      （歸屬 transfer 無 in-transit）/ any_received。
--   2. generate_transfer_from_wave：派貨後，歸屬補貨申請若已全數出貨
--      → approved_pr / approved_transfer 推 'shipped'。部分派貨不動
--      （保留 approved_* 才能對剩餘量直派/再建 wave）。
--   3. rpc_receive_transfer 加邏輯 D2：本調撥為 wave 產物時，歸屬補貨
--      申請若「全數出貨且全數到店」→ 推 'received'、ride-along 單推
--      'ready'（與邏輯 D 直派路徑同規則）。batch 版內部呼叫本函式，一併生效。
--   4. rpc_unreceive_transfer 加反向 D2：退回收貨後不再「全到」的
--      wave 路徑申請 received → shipped、ride-along ready → pending。
--   5. Backfill：存量卡住的申請（含 #46）依 helper 判定補推
--      shipped / received；received 者 ride-along 單補推 ready。
--
-- 基底版本（均已核對線上 pg_proc 與 repo 一致）：
--   generate_transfer_from_wave = 20260705000000（Part 2，逐字保留＋末段新增推進）
--   rpc_receive_transfer        = 20260714000090（逐字保留＋邏輯 D2）
--   rpc_unreceive_transfer      = 20260714000090（逐字保留＋反向 D2）
-- Rollback：
--   CREATE OR REPLACE 回上列基底版本＋
--   DROP FUNCTION public._restock_wave_progress(BIGINT);
--   backfill 如需回復（不建議）：本檔 RAISE NOTICE 會列出被改的 request id。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. helper：歸屬本申請的 wave＋直派出貨進度
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._restock_wave_progress(p_request_id BIGINT)
RETURNS TABLE (fully_dispatched BOOLEAN, all_arrived BOOLEAN, any_received BOOLEAN)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH req AS (
    SELECT rr.id, rr.requesting_store_id, rr.linked_pr_id, rr.linked_transfer_id
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
    SELECT rrl.sku_id, SUM(rrl.qty) AS qty
      FROM req
      JOIN restock_request_lines rrl ON rrl.request_id = req.id
     WHERE rrl.cancelled_at IS NULL
     GROUP BY rrl.sku_id
  ),
  wave_ship AS (
    SELECT pwi.sku_id, t.id AS transfer_id, t.status, SUM(pwi.qty) AS qty
      FROM req
      JOIN picking_wave_items pwi ON pwi.store_id = req.requesting_store_id
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN transfers t ON t.id = pwi.generated_transfer_id AND t.status <> 'cancelled'
     WHERE (pw.source_restock_request_id = req.id
            OR (pwi.campaign_id IS NULL
                AND pw.source_po_id IN (SELECT po_id FROM req_pos)))
       AND pwi.sku_id IN (SELECT sku_id FROM active_lines)
     GROUP BY pwi.sku_id, t.id, t.status
  ),
  direct_ship AS (
    SELECT ti.sku_id, t.id AS transfer_id, t.status, SUM(ti.qty_requested) AS qty
      FROM req
      JOIN transfers t ON t.id = req.linked_transfer_id AND t.status <> 'cancelled'
      JOIN transfer_items ti ON ti.transfer_id = t.id
     GROUP BY ti.sku_id, t.id, t.status
  ),
  all_ship AS (
    SELECT * FROM wave_ship
    UNION ALL
    SELECT * FROM direct_ship
  ),
  per_line AS (
    SELECT al.sku_id, al.qty AS need,
           COALESCE(SUM(s.qty) FILTER (WHERE s.status IN ('shipped','received','closed')), 0) AS shipped
      FROM active_lines al
      LEFT JOIN all_ship s ON s.sku_id = al.sku_id
     GROUP BY al.sku_id, al.qty
  )
  SELECT
    COALESCE(BOOL_AND(pl.shipped >= pl.need), FALSE)                       AS fully_dispatched,
    NOT EXISTS (SELECT 1 FROM all_ship WHERE status = 'shipped')           AS all_arrived,
    EXISTS (SELECT 1 FROM all_ship WHERE status IN ('received','closed'))  AS any_received
  FROM per_line pl;
$$;

GRANT EXECUTE ON FUNCTION public._restock_wave_progress(BIGINT) TO authenticated;

COMMENT ON FUNCTION public._restock_wave_progress(BIGINT) IS
  '補貨申請的出貨進度（wave 歸屬原則同 20260715000020 防重複派貨守衛 ＋ 直派 transfer）。'
  'fully_dispatched=每條有效 line 出貨 ≥ 申請量；all_arrived=歸屬 transfer 無 in-transit；'
  'any_received=至少一張歸屬 transfer 已收。供出貨/收貨鏈推進 restock status 用。';

-- ----------------------------------------------------------------
-- 2. generate_transfer_from_wave — 派貨後歸屬補貨申請推 shipped
--    基底：20260705000000 逐字保留（picked_qty 修補 / 缺價守衛 / 後備成本 /
--    advisory lock / so_generated audit / 張數核對 / 訂單狀態更新），
--    僅在張數核對後新增推進區塊。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_transfer_from_wave(
  p_wave_id        BIGINT,
  p_hq_location_id BIGINT,
  p_operator       UUID
) RETURNS JSONB AS $$
DECLARE
  v_tenant_id            UUID;
  v_wave_status          TEXT;
  v_expected_store_count INTEGER;
  v_expected_item_count  INTEGER;
  v_actual_xfer_count    INTEGER;
  v_store_rec            RECORD;
  v_dest_location_id     BIGINT;
  v_new_xfer_id          BIGINT;
  v_inserted_items       INTEGER;
  v_xfer_ids             BIGINT[] := ARRAY[]::BIGINT[];
  v_pwi                  RECORD;
  v_out_mov_id           BIGINT;
  v_missing              TEXT;
  v_fallback_cost        NUMERIC;
  v_rr                   RECORD;
  v_prog                 RECORD;
BEGIN
  PERFORM pg_advisory_xact_lock(p_wave_id);

  SELECT tenant_id, status INTO v_tenant_id, v_wave_status
    FROM picking_waves WHERE id = p_wave_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到撿貨單 %', p_wave_id;
  END IF;

  IF v_wave_status <> 'picked' THEN
    RAISE EXCEPTION '撿貨單 % 目前狀態為「%」，需先確認撿貨完成（picked）才能派貨', p_wave_id, v_wave_status;
  END IF;

  -- 防禦性修補：若有 picked_qty IS NULL（未手動填），補成 qty
  UPDATE picking_wave_items
     SET picked_qty = qty,
         updated_by = p_operator
   WHERE wave_id   = p_wave_id
     AND picked_qty IS NULL;

  -- 檢查是否有任何品項有撿貨量
  SELECT COUNT(DISTINCT store_id), COUNT(*)
    INTO v_expected_store_count, v_expected_item_count
    FROM picking_wave_items
   WHERE wave_id = p_wave_id AND picked_qty > 0;

  IF v_expected_item_count = 0 THEN
    -- 區分「根本沒有品項」vs「全部撿貨量為 0」
    PERFORM 1 FROM picking_wave_items WHERE wave_id = p_wave_id LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION '撿貨單 % 沒有任何品項，無法產生出倉單', p_wave_id;
    ELSE
      RAISE EXCEPTION '撿貨單 % 所有品項撿貨數量均為 0，無法產生出倉單。請先在「修正數量」輸入實際撿貨量再派貨。', p_wave_id;
    END IF;
  END IF;

  -- 出貨價格防呆：要出的每個（非虛擬）SKU 必須已設定現行成本價 + 分店價，
  -- 否則整張擋下 — 0 成本/0 分店價出貨會讓店月結算出 0 元、無人發現。
  SELECT public._missing_dispatch_prices(
           v_tenant_id,
           (SELECT array_agg(DISTINCT sku_id)
              FROM picking_wave_items
             WHERE wave_id = p_wave_id AND picked_qty > 0))
    INTO v_missing;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '無法派貨：以下品項尚未設定成本價／分店價，請先補價再出貨（商品頁 SKU 區塊或派貨工作台可直接補）→ %', v_missing;
  END IF;

  FOR v_store_rec IN
    SELECT DISTINCT pwi.store_id, s.location_id
      FROM picking_wave_items pwi
      JOIN stores s ON s.id = pwi.store_id
     WHERE pwi.wave_id = p_wave_id AND pwi.picked_qty > 0
  LOOP
    v_dest_location_id := v_store_rec.location_id;
    IF v_dest_location_id IS NULL THEN
      RAISE EXCEPTION '分店 % 未設定倉庫位置（location_id）', v_store_rec.store_id;
    END IF;

    INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                           status, transfer_type, requested_by, shipped_by, shipped_at,
                           created_by, updated_by)
    VALUES (v_tenant_id,
            'WAVE-' || p_wave_id || '-S' || v_store_rec.store_id,
            p_hq_location_id, v_dest_location_id,
            'shipped', 'hq_to_store', p_operator, p_operator, NOW(),
            p_operator, p_operator)
    RETURNING id INTO v_new_xfer_id;

    FOR v_pwi IN
      SELECT id, sku_id, picked_qty
        FROM picking_wave_items
       WHERE wave_id  = p_wave_id
         AND store_id = v_store_rec.store_id
         AND picked_qty > 0
    LOOP
      -- avg_cost = 0（0 成本入庫）時，出庫以現行成本價計價，月結才不會 0 元
      v_fallback_cost := public._current_cost_price(v_tenant_id, v_pwi.sku_id);

      v_out_mov_id := rpc_outbound(
        p_tenant_id          => v_tenant_id,
        p_location_id        => p_hq_location_id,
        p_sku_id             => v_pwi.sku_id,
        p_quantity           => v_pwi.picked_qty,
        p_movement_type      => 'transfer_out',
        p_source_doc_type    => 'transfer',
        p_source_doc_id      => v_new_xfer_id,
        p_operator           => p_operator,
        p_allow_negative     => FALSE,
        p_fallback_unit_cost => v_fallback_cost
      );

      INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped,
                                  out_movement_id, created_by, updated_by)
      VALUES (v_new_xfer_id, v_pwi.sku_id, v_pwi.picked_qty, v_pwi.picked_qty,
              v_out_mov_id, p_operator, p_operator);
    END LOOP;

    GET DIAGNOSTICS v_inserted_items = ROW_COUNT;

    UPDATE picking_wave_items
       SET generated_transfer_id = v_new_xfer_id, updated_by = p_operator
     WHERE wave_id  = p_wave_id
       AND store_id = v_store_rec.store_id
       AND picked_qty > 0;

    INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, created_by)
    VALUES (v_tenant_id, p_wave_id, 'so_generated',
            jsonb_build_object('transfer_id', v_new_xfer_id,
                               'store_id', v_store_rec.store_id,
                               'items_count', v_inserted_items),
            p_operator);

    v_xfer_ids := v_xfer_ids || v_new_xfer_id;
  END LOOP;

  UPDATE picking_waves SET status = 'shipped', updated_by = p_operator WHERE id = p_wave_id;

  -- 呼叫訂單狀態更新（若 function 存在）
  BEGIN
    PERFORM rpc_mark_orders_shipping_for_wave(p_wave_id, p_operator);
  EXCEPTION WHEN undefined_function THEN NULL;
  END;

  SELECT COUNT(DISTINCT generated_transfer_id)
    INTO v_actual_xfer_count
    FROM picking_wave_items
   WHERE wave_id = p_wave_id AND picked_qty > 0 AND generated_transfer_id IS NOT NULL;

  IF v_actual_xfer_count <> v_expected_store_count THEN
    RAISE EXCEPTION '出倉單數量不符：預期 % 張，實際建立 % 張', v_expected_store_count, v_actual_xfer_count;
  END IF;

  -- ===== 20260717 新增：歸屬本 wave 的補貨申請，全數出貨者推「已出貨」 =====
  -- 歸屬原則同 20260715000020 防重複派貨守衛；部分派貨者維持 approved_*，
  -- 剩餘量才能繼續走直派（需 approved_pr）或再建 wave（需 approved_transfer）。
  FOR v_rr IN
    SELECT DISTINCT rr.id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id
      JOIN restock_requests rr
        ON rr.tenant_id = v_tenant_id
       AND rr.requesting_store_id = pwi.store_id
     WHERE pwi.wave_id = p_wave_id
       AND pwi.generated_transfer_id IS NOT NULL
       AND rr.status IN ('approved_pr', 'approved_transfer')
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
    IF v_prog.fully_dispatched THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer');
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'wave_id',      p_wave_id,
    'transfer_ids', to_jsonb(v_xfer_ids),
    'store_count',  v_expected_store_count,
    'item_count',   v_expected_item_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION generate_transfer_from_wave(BIGINT, BIGINT, UUID) TO authenticated;
COMMENT ON FUNCTION generate_transfer_from_wave IS
  '根據撿貨單產生分店出倉 transfer；需 status=picked 且至少一項 picked_qty > 0；'
  '20260705 起：出貨前守衛缺成本價/分店價（非虛擬 SKU），avg_cost=0 時出庫以現行成本價計價；'
  '20260717 起：歸屬本 wave 的補貨申請全數出貨時推 shipped（部分派貨維持 approved_*）。';

-- ----------------------------------------------------------------
-- 3. rpc_receive_transfer — 邏輯 D2：wave 路徑補貨申請推 received
--    基底：20260714000090 逐字保留，僅在邏輯 D 之後新增 D2。
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
  UPDATE restock_requests
     SET status     = 'received',
         updated_by = p_operator
   WHERE linked_transfer_id = p_transfer_id
     AND status IN ('shipped', 'approved_transfer');
  GET DIAGNOSTICS v_restock_received = ROW_COUNT;

  -- ride-along 內部單（order_no='RR-<id>'、掛【內部】xx店）推 ready：
  -- 之後店端才能對它「轉手」拆給客人（rpc_transfer_order_partial 要求 ready）。
  UPDATE customer_orders co
     SET status     = 'ready',
         ready_at   = NOW(),
         updated_by = p_operator,
         updated_at = NOW()
    FROM restock_requests rr
   WHERE rr.linked_transfer_id = p_transfer_id
     AND co.tenant_id  = rr.tenant_id
     AND co.order_no   = 'RR-' || rr.id::TEXT
     AND co.order_kind = 'restock'
     AND co.status IN ('pending', 'confirmed', 'shipping');

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

      UPDATE customer_orders co
         SET status     = 'ready',
             ready_at   = NOW(),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE co.tenant_id  = v_tenant_id
         AND co.order_no   = 'RR-' || v_rr.id::TEXT
         AND co.order_kind = 'restock'
         AND co.status IN ('pending', 'confirmed', 'shipping');
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

-- ----------------------------------------------------------------
-- 4. rpc_unreceive_transfer — 反向 D2：wave 路徑申請退回 shipped
--    基底：20260714000090 逐字保留，僅在反向邏輯 D 之後新增反向 D2。
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
  UPDATE restock_requests
     SET status     = 'shipped',
         updated_by = p_operator
   WHERE linked_transfer_id = p_transfer_id
     AND status = 'received';
  GET DIAGNOSTICS v_restock_reverted = ROW_COUNT;

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
  'linked 補貨申請 received→shipped、ride-along 單 ready→pending；'
  '20260717 起 wave 路徑補貨申請亦同（不再全到者退回 shipped）。'
  '守衛：非 received / 後段已出貨 / movement 已沖銷 / on_hand 不足(貨已取用) 皆擋下。';

COMMENT ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT) IS
  '店家收貨：入庫 + transfer received；邏輯 A 接力自動出後段、B/C 推訂單 ready、'
  'D 直派補貨申請推 received + ride-along 單推 ready；'
  '20260717 起邏輯 D2：wave 路徑補貨申請「全數出貨且全數到店」推 received + ride-along 推 ready。';

-- ----------------------------------------------------------------
-- 5. Backfill：存量卡住的 wave 路徑補貨申請（含 restock #46 / PR2607070440）
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_uid          UUID;
  v_rr           RECORD;
  v_prog         RECORD;
  v_received_ids BIGINT[] := ARRAY[]::BIGINT[];
  v_shipped_ids  BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  FOR v_rr IN
    SELECT id, status FROM restock_requests
     WHERE status IN ('approved_pr', 'approved_transfer', 'shipped')
     ORDER BY id
  LOOP
    SELECT * INTO v_prog FROM public._restock_wave_progress(v_rr.id);

    IF v_prog.fully_dispatched AND v_prog.all_arrived AND v_prog.any_received THEN
      UPDATE restock_requests
         SET status = 'received', updated_by = v_uid
       WHERE id = v_rr.id;

      UPDATE customer_orders co
         SET status     = 'ready',
             ready_at   = NOW(),
             updated_by = v_uid,
             updated_at = NOW()
       WHERE co.order_no   = 'RR-' || v_rr.id::TEXT
         AND co.order_kind = 'restock'
         AND co.status IN ('pending', 'confirmed', 'shipping');

      v_received_ids := v_received_ids || v_rr.id;

    ELSIF v_prog.fully_dispatched AND v_rr.status IN ('approved_pr', 'approved_transfer') THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = v_uid
       WHERE id = v_rr.id;

      v_shipped_ids := v_shipped_ids || v_rr.id;
    END IF;
  END LOOP;

  RAISE NOTICE 'Backfill: % 張補貨申請 → received（ids=%）、% 張 → shipped（ids=%）',
    COALESCE(array_length(v_received_ids, 1), 0), v_received_ids,
    COALESCE(array_length(v_shipped_ids, 1), 0), v_shipped_ids;
END $$;

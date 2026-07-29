-- ============================================================
-- 採購單「已收量修正」補收改建正式進貨單（GR）+ 歷史補收 backfill
--
-- 現象（2026-07-29 使用者回報，PO2606260632 元寶磁吸收納盒 G00564-01/02）：
--   操作者在採購單「編輯頁」的已收欄輸入進貨數量（看起來就是收貨），
--   PO 變部分到貨、總倉庫存也入了，但派貨工作台完全不顯示該品項。
--
-- 根因：
--   收貨有兩條路，只有一條產生工作台認的「到貨」事實：
--     1. 收貨頁 rpc_arrive_and_distribute → 建 confirmed goods_receipt ✔
--     2. 編輯頁 rpc_adjust_po_item_received（20260708000000）→ 只動
--        purchase_order_items.qty_received + 庫存 manual_adjust，不建 GR ✘
--   而 v_picking_demand_by_po 的 gr_qty 與 rpc_create_wave_from_po 的守衛
--   都只算 confirmed goods_receipt → 走路 2 的貨對工作台「從未到貨」
--   （has_stock_left=false，整列被過濾）。
--
-- 修法：
--   A) rpc_adjust_po_item_received 補收（delta > 0）不再裸呼 rpc_inbound，
--      改為「建一張 delta 進貨單（draft）→ PERFORM rpc_confirm_gr」：
--      入庫（purchase_receipt）、qty_received += delta、PO 狀態 refresh
--      全部由 rpc_confirm_gr 連動，兩條收貨路殊途同歸。
--      view 與 wave 守衛同源讀 GR，因此**兩者都不用動**。
--   B) 調降（delta < 0）維持原樣：manual_adjust 出庫修正。
--      已知不對稱：下修不會扣 view 的 gr_qty（goods_receipt_items 有
--      qty_received > 0 CHECK，無法寫負向 GR）。風險僅止於工作台顯示面
--      —— 真派貨時 rpc_outbound 仍被實際庫存擋。先記錄，不在本次擴 scope。
--   C) Backfill：歷史上走路 2 補收、至今沒有對應 GR 的量，補建一張
--      status='confirmed' 的 GR（**不動庫存、不動 qty_received、不改 PO 狀態**
--      —— 這些當時都已由 adjust 做完，只補「到貨事實」讓工作台看得到）。
--      認定方式：qty_received − confirmed GR 加總 > 0，且該 po_item 有
--      source_doc_type='po_item_received_adjust' 的正向淨額（兩者取小）。
--
-- 基底：
--   rpc_adjust_po_item_received — 20260708000000（唯一版本）
--   rpc_confirm_gr — 20260422120004（唯一版本；守衛=GR 須 draft）
--   rpc_next_gr_no — 20260430120000
-- Rollback：
--   CREATE OR REPLACE FUNCTION rpc_adjust_po_item_received 回 20260708000000 版；
--   backfill GR 可由 notes LIKE 'backfill 20260729000020%' 找到，
--   UPDATE goods_receipts SET status='cancelled' 即可自 view 消失（勿刪列）。
-- TEST: docs/TEST-po-adjust-received-gr.md
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_adjust_po_item_received(
  p_po_item_id BIGINT,
  p_new_qty    NUMERIC,
  p_operator   UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item    purchase_order_items%ROWTYPE;
  v_po      purchase_orders%ROWTYPE;
  v_shipped NUMERIC;
  v_floor   NUMERIC;
  v_delta   NUMERIC;
  v_avail   NUMERIC;
  v_cost    NUMERIC;
  v_tot_ord NUMERIC;
  v_tot_rcv NUMERIC;
  v_status  TEXT;
  v_gr_id   BIGINT;
  v_gr_no   TEXT;
BEGIN
  -- 1. 鎖品項 + 母單
  SELECT * INTO v_item FROM purchase_order_items WHERE id = p_po_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單品項 %', p_po_item_id;
  END IF;

  SELECT * INTO v_po FROM purchase_orders WHERE id = v_item.po_id FOR UPDATE;

  -- 2. 狀態閘：草稿請改訂購量；已結案/已取消鎖定
  IF v_po.status NOT IN ('sent', 'partially_received', 'fully_received') THEN
    RAISE EXCEPTION '採購單狀態為 %,僅 已發送/部分到貨/全部到貨 可調整已收量', v_po.status;
  END IF;

  IF p_new_qty IS NULL OR p_new_qty < 0 THEN
    RAISE EXCEPTION '已收量不可為負';
  END IF;

  -- 3. 已出（已揀/出貨）
  SELECT COALESCE(SUM(COALESCE(pwi.picked_qty, pwi.qty)), 0)
    INTO v_shipped
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
   WHERE pw.source_po_id = v_item.po_id
     AND pw.status IN ('picked', 'shipped')
     AND pwi.sku_id = v_item.sku_id;

  -- 4. 邊界：下限 = 已退 + 已出，上限 = 訂購
  v_floor := v_item.qty_returned + v_shipped;
  IF p_new_qty < v_floor THEN
    RAISE EXCEPTION '已收量 % 不可低於 已退(%)+已出(%) = %',
      p_new_qty, v_item.qty_returned, v_shipped, v_floor;
  END IF;
  IF p_new_qty > v_item.qty_ordered THEN
    RAISE EXCEPTION '已收量 % 不可高於 訂購量 %', p_new_qty, v_item.qty_ordered;
  END IF;

  v_delta := p_new_qty - v_item.qty_received;
  IF v_delta = 0 THEN
    RETURN jsonb_build_object(
      'po_item_id', p_po_item_id, 'qty_received', p_new_qty,
      'qty_shipped', v_shipped, 'changed', FALSE
    );
  END IF;

  -- 5. 連動庫存
  IF v_delta > 0 THEN
    -- 補收 → 建 delta 進貨單並確認。
    -- 入庫（purchase_receipt）、qty_received += delta、PO 狀態 refresh
    -- 皆由 rpc_confirm_gr 連動；派貨工作台（只認 confirmed GR）因此看得到這批貨。
    v_gr_no := public.rpc_next_gr_no();
    INSERT INTO goods_receipts (
      tenant_id, gr_no, po_id, supplier_id, dest_location_id,
      status, received_by, notes, created_by, updated_by
    ) VALUES (
      v_po.tenant_id, v_gr_no, v_po.id, v_po.supplier_id, v_po.dest_location_id,
      'draft', p_operator, '已收量修正補收（編輯頁）', p_operator, p_operator
    ) RETURNING id INTO v_gr_id;

    INSERT INTO goods_receipt_items (
      gr_id, po_item_id, sku_id,
      qty_expected, qty_received, qty_damaged, unit_cost,
      variance_reason, created_by, updated_by
    ) VALUES (
      v_gr_id, p_po_item_id, v_item.sku_id,
      v_item.qty_ordered, v_delta, 0, v_item.unit_cost,
      'po_item_received_adjust', p_operator, p_operator
    );

    PERFORM rpc_confirm_gr(v_gr_id, p_operator);
  ELSE
    -- 改少 → 出庫修正（不可做出負庫存）
    SELECT on_hand, avg_cost INTO v_avail, v_cost
      FROM stock_balances
     WHERE tenant_id = v_po.tenant_id
       AND location_id = v_po.dest_location_id
       AND sku_id = v_item.sku_id
     FOR UPDATE;
    IF NOT FOUND THEN v_avail := 0; v_cost := 0; END IF;

    IF v_avail < (-v_delta) THEN
      RAISE EXCEPTION '調降已收需扣庫存 %,但目的倉現有 % 不足', (-v_delta), v_avail;
    END IF;

    INSERT INTO stock_movements
      (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
       source_doc_type, source_doc_id, operator_id)
    VALUES
      (v_po.tenant_id, v_po.dest_location_id, v_item.sku_id, v_delta, v_cost,
       'manual_adjust', 'po_item_received_adjust', p_po_item_id, p_operator);
  END IF;

  -- 6. 更新品項（補收路徑 rpc_confirm_gr 已 += 到位，此處冪等收斂 + 落 updated_by）
  UPDATE purchase_order_items
     SET qty_received = p_new_qty,
         updated_by   = p_operator,
         updated_at   = NOW()
   WHERE id = p_po_item_id;

  -- 7. 重算母單狀態（含 全部到貨 → 部分到貨 降級；_refresh_po_status 不降級故保留）
  SELECT SUM(qty_ordered), SUM(qty_received)
    INTO v_tot_ord, v_tot_rcv
    FROM purchase_order_items WHERE po_id = v_item.po_id;

  IF v_tot_rcv >= v_tot_ord THEN
    v_status := 'fully_received';
  ELSIF v_tot_rcv > 0 THEN
    v_status := 'partially_received';
  ELSE
    v_status := 'sent';
  END IF;

  UPDATE purchase_orders
     SET status = v_status, updated_at = NOW()
   WHERE id = v_item.po_id
     AND status IN ('sent', 'partially_received', 'fully_received');

  RETURN jsonb_build_object(
    'po_item_id',  p_po_item_id,
    'qty_received', p_new_qty,
    'qty_shipped', v_shipped,
    'delta',       v_delta,
    'po_status',   v_status,
    'gr_no',       v_gr_no,
    'changed',     TRUE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_adjust_po_item_received(BIGINT, NUMERIC, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_adjust_po_item_received IS
  '調整採購單明細已收量。補收→建 delta 進貨單並 confirm（入庫+qty_received+PO 狀態由 rpc_confirm_gr 連動，'
  '派貨工作台因此看得到）；改少→manual_adjust 出庫修正。下限=已退+已出、上限=訂購量。';

-- ============================================================
-- Backfill：歷史「編輯頁補收」補建 confirmed GR
--   只補「到貨事實」：不動庫存、不動 qty_received、不改 PO 狀態。
--   量 = LEAST(qty_received − confirmed GR 加總, 該品項 adjust 正向淨額)。
--   received_by 取最後一筆 adjust 的 operator，退而求其次 PO.created_by；
--   兩者皆缺則跳過該 PO 並 RAISE NOTICE（不擋 migration）。
-- ============================================================
DO $$
DECLARE
  v_po_rec  RECORD;
  v_item    RECORD;
  v_gr_id   BIGINT;
  v_gr_no   TEXT;
  v_count   INT := 0;
BEGIN
  FOR v_po_rec IN
    WITH gr_sums AS (
      SELECT gri.po_item_id, SUM(gri.qty_received) AS gr_qty
        FROM goods_receipt_items gri
        JOIN goods_receipts gr ON gr.id = gri.gr_id
       WHERE gr.status = 'confirmed' AND gri.po_item_id IS NOT NULL
       GROUP BY gri.po_item_id
    ),
    adjust_net AS (
      SELECT sm.source_doc_id AS po_item_id,
             SUM(sm.quantity) AS net_qty,
             (ARRAY_AGG(sm.operator_id ORDER BY sm.id DESC))[1] AS last_operator
        FROM stock_movements sm
       WHERE sm.source_doc_type = 'po_item_received_adjust'
       GROUP BY sm.source_doc_id
    ),
    missing AS (
      SELECT poi.po_id,
             poi.id AS po_item_id, poi.sku_id, poi.qty_ordered, poi.unit_cost,
             LEAST(poi.qty_received - COALESCE(g.gr_qty, 0), a.net_qty) AS backfill_qty,
             a.last_operator
        FROM purchase_order_items poi
        JOIN adjust_net a ON a.po_item_id = poi.id
        LEFT JOIN gr_sums g ON g.po_item_id = poi.id
       WHERE poi.qty_received - COALESCE(g.gr_qty, 0) > 0
         AND a.net_qty > 0
    )
    SELECT m.po_id,
           po.tenant_id, po.supplier_id, po.dest_location_id, po.created_by AS po_created_by,
           jsonb_agg(jsonb_build_object(
             'po_item_id', m.po_item_id, 'sku_id', m.sku_id,
             'qty_ordered', m.qty_ordered, 'unit_cost', m.unit_cost,
             'backfill_qty', m.backfill_qty)) AS items,
           MAX(m.last_operator::TEXT)::UUID AS any_operator
      FROM missing m
      JOIN purchase_orders po ON po.id = m.po_id
     GROUP BY m.po_id, po.tenant_id, po.supplier_id, po.dest_location_id, po.created_by
  LOOP
    IF COALESCE(v_po_rec.any_operator, v_po_rec.po_created_by) IS NULL THEN
      RAISE NOTICE 'backfill 20260729000020: PO % 無可用 operator，跳過', v_po_rec.po_id;
      CONTINUE;
    END IF;

    v_gr_no := public.rpc_next_gr_no();
    INSERT INTO goods_receipts (
      tenant_id, gr_no, po_id, supplier_id, dest_location_id,
      status, received_by, confirmed_at, confirmed_by, notes, created_by, updated_by
    ) VALUES (
      v_po_rec.tenant_id, v_gr_no, v_po_rec.po_id, v_po_rec.supplier_id, v_po_rec.dest_location_id,
      'confirmed', COALESCE(v_po_rec.any_operator, v_po_rec.po_created_by), NOW(),
      COALESCE(v_po_rec.any_operator, v_po_rec.po_created_by),
      'backfill 20260729000020: 編輯頁已收量修正之歷史補收，補建到貨事實（未動庫存/已收量）',
      COALESCE(v_po_rec.any_operator, v_po_rec.po_created_by),
      COALESCE(v_po_rec.any_operator, v_po_rec.po_created_by)
    ) RETURNING id INTO v_gr_id;

    FOR v_item IN SELECT * FROM jsonb_to_recordset(v_po_rec.items)
      AS x(po_item_id BIGINT, sku_id BIGINT, qty_ordered NUMERIC, unit_cost NUMERIC, backfill_qty NUMERIC)
    LOOP
      INSERT INTO goods_receipt_items (
        gr_id, po_item_id, sku_id,
        qty_expected, qty_received, qty_damaged, unit_cost,
        variance_reason
      ) VALUES (
        v_gr_id, v_item.po_item_id, v_item.sku_id,
        v_item.qty_ordered, v_item.backfill_qty, 0, v_item.unit_cost,
        'backfill_po_item_received_adjust'
      );
      v_count := v_count + 1;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'backfill 20260729000020: 補建 % 筆 GR 明細', v_count;
END;
$$;

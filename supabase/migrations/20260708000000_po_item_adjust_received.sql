-- ============================================================
-- 採購單明細「已收量」可編輯 + 「已出」衍生欄位
--
-- 背景（來源：與通路客戶的 LINE 設計討論）：
--   採購單明細目前有 訂購 / 已收 / 已退 三欄，皆唯讀。實務上會「誤按
--   採購數量」或進貨後想修正已收量。需求：
--     1. 明細顯示四欄 訂購 / 已收 / 已退 / 已出。
--     2. 「已收」可調整，但
--          下限 = 已退 + 已出（已離開庫存的量不能再被「未收」回去；
--                 對應討論：「出去了就不能再少於出去的」）
--          上限 = 訂購量（對應討論：「上限值就是總採購數量」）
--     3. 調整已收量會連動庫存：補收 → 入庫；改少 → 出庫修正。
--        例：總請購20、入倉10、已出5，可把已收改成5（庫存歸0）或補到20。
--
-- 「已出」定義（衍生，不另存欄位）：
--   = 該 PO（picking_waves.source_po_id）已揀貨/已出貨波次中，本 sku 的
--     COALESCE(picked_qty, qty) 加總，僅計 status IN ('picked','shipped')。
--   PO 明細以 (po_id, sku_id) 唯一（rpc_merge_prs_to_po 依 sku 彙整），故
--   依 sku 對應回品項。此為設計取捨，若日後同單同 sku 拆多列需再調整。
--
-- 安全網：
--   已出/已退僅作為 UX 下限；真正防呆是 rpc_adjust_po_item_received 改少時
--   會檢查 stock_balances 可用量，庫存不足直接 RAISE，不會做出負庫存。
--
-- 基底依賴：
--   - purchase_order_items.qty_received/qty_returned：20260422120004_purchase_schema.sql
--   - picking_waves.source_po_id：20260513000000_pr_multi_campaigns_and_po_picking.sql
--   - rpc_inbound / stock_movements trigger：20260422120003_inventory_schema.sql
--   - movement_type 'manual_adjust'：同上 CHECK 清單
--
-- Rollback：
--   DROP FUNCTION public.rpc_adjust_po_item_received(BIGINT, NUMERIC, UUID);
--   DROP FUNCTION public.rpc_po_items_shipped(BIGINT);
-- ============================================================

-- ------------------------------------------------------------
-- 1. 衍生「已出」：依 PO 回傳每個明細的已揀/出貨量（唯讀）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_po_items_shipped(p_po_id BIGINT)
RETURNS TABLE (po_item_id BIGINT, qty_shipped NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT poi.id AS po_item_id,
         COALESCE((
           SELECT SUM(COALESCE(pwi.picked_qty, pwi.qty))
             FROM picking_wave_items pwi
             JOIN picking_waves pw ON pw.id = pwi.wave_id
            WHERE pw.source_po_id = poi.po_id
              AND pw.status IN ('picked', 'shipped')
              AND pwi.sku_id = poi.sku_id
         ), 0) AS qty_shipped
    FROM purchase_order_items poi
   WHERE poi.po_id = p_po_id
   ORDER BY poi.id;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_po_items_shipped(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_po_items_shipped IS
  '回傳採購單每個明細的「已出」(已揀/已出貨波次本 sku 加總，status picked/shipped)。唯讀衍生值。';

-- ------------------------------------------------------------
-- 2. 調整明細「已收量」（連動庫存）
-- ------------------------------------------------------------
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
    -- 補收 → 入庫（以本品項成本計價）
    PERFORM rpc_inbound(
      p_tenant_id       => v_po.tenant_id,
      p_location_id     => v_po.dest_location_id,
      p_sku_id          => v_item.sku_id,
      p_quantity        => v_delta,
      p_unit_cost       => v_item.unit_cost,
      p_movement_type   => 'manual_adjust',
      p_source_doc_type => 'po_item_received_adjust',
      p_source_doc_id   => p_po_item_id,
      p_operator        => p_operator
    );
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

  -- 6. 更新品項
  UPDATE purchase_order_items
     SET qty_received = p_new_qty,
         updated_by   = p_operator,
         updated_at   = NOW()
   WHERE id = p_po_item_id;

  -- 7. 重算母單狀態（含 全部到貨 → 部分到貨 降級）
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
    'changed',     TRUE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_adjust_po_item_received(BIGINT, NUMERIC, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_adjust_po_item_received IS
  '調整採購單明細已收量並連動庫存（補收→入庫 manual_adjust；改少→出庫修正）。'
  '下限=已退+已出、上限=訂購量；改少時檢查目的倉可用量，不足則 RAISE。';

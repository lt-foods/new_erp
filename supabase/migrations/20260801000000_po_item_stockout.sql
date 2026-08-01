-- ============================================================
-- 採購單「品項斷貨」：斷貨從整張單改成單一品項
--
-- 需求（cktalex 2026-08-01）：
--   採購單常常只有其中幾個品項斷貨（例：PO2607281072 六項中
--   鮭魚頭 223 個全未到，其餘品項照常到貨），整張單標記斷貨會把
--   還在等貨的其他品項一起結掉。要能「依品項」標記斷貨：
--     - 斷貨品項：未到量不再等待，下游連動同整單版（開團 / 顧客
--       訂單 / 補貨鏈 / 通知）
--     - 其他品項照常收貨；全部品項定案（全到 or 斷貨）後單據自動
--       結掉（有到貨 → closed、全無 → cancelled，同整單版規則）
--   UI 端整張單的「標記斷貨」按鈕移除，改為明細列逐項操作。
--
-- 設計：
--   - purchase_order_items 加 stockout_at / stockout_by / stockout_reason
--     （沿用整單版欄位設計；不加 status 值）。
--   - 共用核心 _stockout_po_items(po_id, item_ids[], operator, reason, at)：
--     標記品項 → 下游連動（scope 縮到被標記品項的 SKU / 其 PR 連到的
--     campaign，不再是整張 PO）→ 母單自動收尾判定。
--   - rpc_stockout_po_item：單一品項入口（UI 用）。
--   - rpc_stockout_purchase_order v4：改為「把所有未定案品項標記斷貨」
--     再走同一核心，行為與 v3 等價（一定收單、closed/cancelled 規則同），
--     並補上品項層標記，資料層與品項版一致。保留給既有呼叫端。
--   - 母單收尾條件 =「不存在 未斷貨且未收滿 的品項」。收貨側兩條路
--     （rpc_confirm_gr → _refresh_po_status、rpc_adjust_po_item_received）
--     的狀態重算加入同一條件：品項斷貨後其餘品項到齊 → 自動 closed，
--     不會卡在 partially_received。
--   - 連動規則不變（20260702020000）：qty_received = 0 的品項才連動
--     下游取消；部分到貨品項標斷貨只停止等待餘量，已到的貨走正常分貨。
--   - 通知 (d) 改為只通知「本次真的被取消」的訂單品項（RETURNING 收集
--     id），修掉 v3 同 SKU 重複斷貨會重複通知的問題 — 品項版觸發頻率
--     比整單版高，必須去重。
--   - v_order_shortage：在途供給排除已斷貨品項（PO 未關前該量已確定
--     不會到，不該再抵銷短缺）。
--   - rpc_po_list：rows 加 stockout_items 計數，列表可顯示「部分斷貨」。
--   - 已斷貨品項鎖已收量調整（rpc_adjust_po_item_received 擋下），
--     收貨頁 UI 亦排除該品項。
--
-- 基底版本（依 CLAUDE.md 規則 grep 全歷史）：
--   rpc_stockout_purchase_order ← 20260720000010_stockout_restock_propagation.sql（v3，最新）
--   _stockout_propagate_restock ← 20260720000010（唯一版本，原樣沿用不改）
--   _refresh_po_status          ← 20260422120004_purchase_schema.sql（唯一版本）
--   rpc_adjust_po_item_received ← 20260729000020_po_adjust_received_creates_gr.sql（v2，最新）
--   v_order_shortage            ← 20260731000010_v_order_shortage_settled_po_gate.sql（v3，最新）
--   rpc_po_list                 ← 20260729000000_po_pr_list_server_side.sql（唯一版本）
--
-- Rollback：
--   - rpc_stockout_purchase_order 還原為 20260720000010 版本
--   - _refresh_po_status 還原為 20260422120004 版本
--   - rpc_adjust_po_item_received 還原為 20260729000020 版本
--   - v_order_shortage 還原為 20260731000010 版本
--   - rpc_po_list 還原為 20260729000000 版本
--   - DROP FUNCTION public.rpc_stockout_po_item(BIGINT, UUID, TEXT);
--     DROP FUNCTION public._stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ);
--   - ALTER TABLE purchase_order_items
--       DROP COLUMN IF EXISTS stockout_at,
--       DROP COLUMN IF EXISTS stockout_by,
--       DROP COLUMN IF EXISTS stockout_reason;
-- ============================================================

-- ------------------------------------------------------------
-- Part 1: purchase_order_items 斷貨欄位
-- ------------------------------------------------------------

ALTER TABLE purchase_order_items
  ADD COLUMN IF NOT EXISTS stockout_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS stockout_by     UUID,
  ADD COLUMN IF NOT EXISTS stockout_reason TEXT;

COMMENT ON COLUMN purchase_order_items.stockout_at IS
  '品項標記斷貨的時間；NULL = 未斷貨。斷貨品項未到量不再等待、不再列入在途供給，'
  '已收量鎖定；全部品項定案（全到 or 斷貨）後母單自動 closed / cancelled';

-- ------------------------------------------------------------
-- Part 2: 核心 — _stockout_po_items
--   標記指定品項斷貨 + 下游連動 + 母單收尾。
--   呼叫端負責：鎖母單、驗 PO 狀態（sent / partially_received）。
--   下游連動內容基於 20260720000010 v3 逐字保留，僅：
--     - scope 從「整張 PO」縮到「本次被標記的品項」
--     - (d) 通知改以 RETURNING 收集本次取消的品項，杜絕重複通知
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._stockout_po_items(
  p_po_id    BIGINT,
  p_item_ids BIGINT[],
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_po            purchase_orders%ROWTYPE;
  v_marked        BIGINT[];
  v_stockout_skus BIGINT[];
  v_campaign_ids  BIGINT[];
  v_coi_ids       BIGINT[];
  v_ci_count      INTEGER := 0;
  v_coi_count     INTEGER := 0;
  v_order_count   INTEGER := 0;
  v_notified      INTEGER := 0;
  v_restock       JSONB := '{}'::jsonb;
  v_outstanding   INTEGER;
  v_received      NUMERIC(18,3);
  v_new_status    TEXT;
BEGIN
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;

  -- 1. 品項標記（冪等：已標記過的跳過）
  WITH upd AS (
    UPDATE purchase_order_items
       SET stockout_at     = p_at,
           stockout_by     = p_operator,
           stockout_reason = NULLIF(BTRIM(p_reason), ''),
           updated_by      = p_operator,
           updated_at      = NOW()
     WHERE po_id = p_po_id
       AND id = ANY (COALESCE(p_item_ids, '{}'::BIGINT[]))
       AND stockout_at IS NULL
     RETURNING id
  )
  SELECT ARRAY_AGG(id) INTO v_marked FROM upd;

  -- 2. 下游連動範圍（沿用 20260702020000 規則）：
  --    完全沒到貨的品項才連動取消下游；部分到貨的品項只停止等待餘量，
  --    已到的貨走正常撿貨 / 分貨流程。
  SELECT ARRAY_AGG(sku_id) INTO v_stockout_skus
    FROM purchase_order_items
   WHERE id = ANY (COALESCE(v_marked, '{}'::BIGINT[]))
     AND COALESCE(qty_received, 0) = 0;

  -- 受影響開團：本次標記品項 → PR → purchase_request_campaigns
  SELECT ARRAY_AGG(DISTINCT prc.campaign_id) INTO v_campaign_ids
    FROM purchase_order_items poi
    JOIN purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
   WHERE poi.id = ANY (COALESCE(v_marked, '{}'::BIGINT[]));

  IF v_stockout_skus IS NOT NULL AND v_campaign_ids IS NOT NULL THEN

    -- (a) 開團商品標記斷貨
    UPDATE campaign_items
       SET stockout_at = p_at,
           updated_by  = p_operator,
           updated_at  = NOW()
     WHERE campaign_id = ANY(v_campaign_ids)
       AND sku_id = ANY(v_stockout_skus)
       AND stockout_at IS NULL;
    GET DIAGNOSTICS v_ci_count = ROW_COUNT;

    -- (b) 顧客訂單品項：pending → cancelled + 斷貨標記
    --     （RETURNING 收集本次取消的品項，供 (d) 只通知這一批）
    WITH upd AS (
      UPDATE customer_order_items coi
         SET status      = 'cancelled',
             stockout_at = p_at,
             updated_by  = p_operator,
             updated_at  = NOW()
        FROM customer_orders co
       WHERE co.id = coi.order_id
         AND co.campaign_id = ANY(v_campaign_ids)
         AND coi.sku_id = ANY(v_stockout_skus)
         AND coi.status = 'pending'
         AND coi.stockout_at IS NULL
       RETURNING coi.id
    )
    SELECT ARRAY_AGG(id) INTO v_coi_ids FROM upd;
    v_coi_count := COALESCE(array_length(v_coi_ids, 1), 0);

    -- (c) 訂單單頭：全部品項都已取消/過期 + 沒收過錢 → 整單取消（斷貨標記）
    --     有付款 / 用過儲值金的單不自動取消，留給人工退款流程
    UPDATE customer_orders co
       SET status       = 'cancelled',
           cancelled_at = p_at,
           stockout_at  = p_at,
           updated_by   = p_operator,
           updated_at   = NOW()
     WHERE co.campaign_id = ANY(v_campaign_ids)
       AND co.status IN ('pending','confirmed')
       AND COALESCE(co.payment_status, 'unpaid') <> 'paid'
       AND COALESCE(co.wallet_paid_amount, 0) = 0
       AND EXISTS (
             SELECT 1 FROM customer_order_items x
              WHERE x.order_id = co.id
                AND x.stockout_at IS NOT NULL
           )
       AND NOT EXISTS (
             SELECT 1 FROM customer_order_items x
              WHERE x.order_id = co.id
                AND x.status NOT IN ('cancelled','expired')
           );
    GET DIAGNOSTICS v_order_count = ROW_COUNT;

    -- (d) 顧客通知（in-app 通知中心留底；綁定會員的訂單才發得了）
    --     只通知本次被取消的品項 — 同 SKU 之前已斷貨/取消過的不再重發
    IF v_coi_ids IS NOT NULL THEN
      INSERT INTO notifications (tenant_id, member_id, category, title, body, url)
      SELECT
        co.tenant_id,
        co.member_id,
        'stockout',
        '商品斷貨通知',
        '您訂購的「' || string_agg(DISTINCT COALESCE(sk.product_name, sk.sku_code)
                                    || COALESCE('-' || sk.variant_name, ''), '、')
          || '」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。',
        '/orders'
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
      JOIN skus sk ON sk.id = coi.sku_id
      WHERE coi.id = ANY(v_coi_ids)
        AND co.member_id IS NOT NULL
      GROUP BY co.tenant_id, co.member_id;
      GET DIAGNOSTICS v_notified = ROW_COUNT;
    END IF;

  END IF;

  -- 補貨申請連動（restock PR 不掛 campaign，走獨立鏈；helper 內自帶空集合守衛）
  v_restock := public._stockout_propagate_restock(
                 p_po_id, v_stockout_skus, p_operator, p_at);

  -- 3. 母單收尾：不存在「未斷貨且未收滿」的品項 → 結單
  --    （有到貨 → closed、全無 → cancelled，同整單版規則）
  SELECT COUNT(*) FILTER (WHERE stockout_at IS NULL
                            AND COALESCE(qty_received, 0) < qty_ordered),
         COALESCE(SUM(qty_received), 0)
    INTO v_outstanding, v_received
    FROM purchase_order_items
   WHERE po_id = p_po_id;

  IF v_outstanding = 0 AND v_po.status IN ('sent','partially_received') THEN
    v_new_status := CASE WHEN v_received > 0 THEN 'closed' ELSE 'cancelled' END;
    UPDATE purchase_orders
       SET status          = v_new_status,
           stockout_at     = COALESCE(stockout_at, p_at),
           stockout_by     = COALESCE(stockout_by, p_operator),
           stockout_reason = COALESCE(stockout_reason, NULLIF(BTRIM(p_reason), '')),
           updated_by      = p_operator,
           updated_at      = NOW()
     WHERE id = p_po_id;
  ELSE
    v_new_status := v_po.status;
  END IF;

  RETURN jsonb_build_object(
    'po_no',            v_po.po_no,
    'po_status',        v_new_status,
    'new_status',       v_new_status,   -- 向後相容：v3 回傳鍵名
    'items_marked',     COALESCE(array_length(v_marked, 1), 0),
    'stockout_skus',    COALESCE(array_length(v_stockout_skus, 1), 0),
    'campaign_items',   v_ci_count,
    'order_items',      v_coi_count,
    'orders_cancelled', v_order_count,
    'members_notified', v_notified
  ) || COALESCE(v_restock, '{}'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public._stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION public._stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ) IS
  '品項斷貨核心（rpc_stockout_po_item / rpc_stockout_purchase_order 內部用）：'
  '標記品項 stockout_at → 下游連動（開團 / 顧客訂單 / 補貨鏈 / 通知，scope 限被標記品項）'
  '→ 全品項定案時母單自動 closed / cancelled。呼叫端需先鎖母單並驗狀態。';

-- ------------------------------------------------------------
-- Part 3: RPC — rpc_stockout_po_item（單一品項斷貨，UI 入口）
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_stockout_po_item(
  p_po_item_id BIGINT,
  p_operator   UUID,
  p_reason     TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item purchase_order_items%ROWTYPE;
  v_po   purchase_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_item FROM purchase_order_items WHERE id = p_po_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單品項 %', p_po_item_id;
  END IF;

  SELECT * INTO v_po FROM purchase_orders WHERE id = v_item.po_id FOR UPDATE;

  IF v_po.status NOT IN ('sent','partially_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可標記斷貨（需為「已發送」或「部分到貨」）',
      v_po.po_no, v_po.status;
  END IF;
  IF v_item.stockout_at IS NOT NULL THEN
    RAISE EXCEPTION '品項已於 % 標記斷貨', to_char(v_item.stockout_at, 'YYYY-MM-DD HH24:MI');
  END IF;
  IF COALESCE(v_item.qty_received, 0) >= v_item.qty_ordered THEN
    RAISE EXCEPTION '品項已全數到貨，無需標記斷貨';
  END IF;

  RETURN public._stockout_po_items(
           v_po.id, ARRAY[p_po_item_id], p_operator, p_reason, NOW());
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_stockout_po_item(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_stockout_po_item(BIGINT, UUID, TEXT) IS
  '單一採購品項標記斷貨：未到量不再等待（qty_received=0 才連動取消下游），'
  '其餘品項照常收貨；全部品項定案後母單自動 closed / cancelled。';

-- ------------------------------------------------------------
-- Part 4: rpc_stockout_purchase_order v4 — 改走品項核心
--   行為與 v3 等價（狀態守衛、closed/cancelled 規則、下游連動、回傳統計），
--   並補上品項層 stockout 標記。保留給既有呼叫端；admin UI 已改品項版。
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_stockout_purchase_order(
  p_po_id    BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_po       purchase_orders%ROWTYPE;
  v_item_ids BIGINT[];
BEGIN
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;

  IF v_po.status NOT IN ('sent','partially_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可標記斷貨（需為「已發送」或「部分到貨」）',
      v_po.po_no, v_po.status;
  END IF;

  -- 所有未定案品項（未斷貨且未收滿）全數標記 → 核心必然判定收單，
  -- closed / cancelled 結果與 v3 相同
  SELECT ARRAY_AGG(id) INTO v_item_ids
    FROM purchase_order_items
   WHERE po_id = p_po_id
     AND stockout_at IS NULL
     AND COALESCE(qty_received, 0) < qty_ordered;

  RETURN public._stockout_po_items(
           p_po_id, COALESCE(v_item_ids, '{}'::BIGINT[]), p_operator, p_reason, NOW());
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_stockout_purchase_order TO authenticated;

COMMENT ON FUNCTION public.rpc_stockout_purchase_order IS
  '整張採購單斷貨（v4）：把所有未定案品項標記斷貨後走 _stockout_po_items 核心，'
  '行為與 v3 等價（有到貨→closed、無到貨→cancelled；下游連動同）並補品項層標記。'
  'admin UI 已改用 rpc_stockout_po_item 逐品項操作，本函式保留給既有呼叫端。';

-- ------------------------------------------------------------
-- Part 5: _refresh_po_status v2 — 品項斷貨收尾
--   基底 20260422120004 逐字保留，僅加「未定案品項 = 0 且存在斷貨品項
--   → closed / cancelled」分支：品項斷貨後其餘品項到齊，收貨
--   （rpc_confirm_gr）即自動結單，不再卡 partially_received。
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION _refresh_po_status(p_po_id BIGINT)
RETURNS VOID AS $$
DECLARE
  v_total_ordered  NUMERIC;
  v_total_received NUMERIC;
  v_outstanding    INTEGER;
  v_stockout_cnt   INTEGER;
  v_new_status     TEXT;
BEGIN
  SELECT SUM(qty_ordered), SUM(qty_received),
         COUNT(*) FILTER (WHERE stockout_at IS NULL
                            AND COALESCE(qty_received, 0) < qty_ordered),
         COUNT(*) FILTER (WHERE stockout_at IS NOT NULL)
    INTO v_total_ordered, v_total_received, v_outstanding, v_stockout_cnt
    FROM purchase_order_items WHERE po_id = p_po_id;

  IF v_total_received >= v_total_ordered THEN
    v_new_status := 'fully_received';
  ELSIF v_stockout_cnt > 0 AND v_outstanding = 0 THEN
    -- 品項斷貨收尾：其餘品項全數到貨 → 結掉（有到貨 closed、全無 cancelled）
    v_new_status := CASE WHEN v_total_received > 0 THEN 'closed' ELSE 'cancelled' END;
  ELSIF v_total_received > 0 THEN
    v_new_status := 'partially_received';
  ELSE
    RETURN;
  END IF;

  UPDATE purchase_orders
     SET status = v_new_status, updated_at = NOW()
   WHERE id = p_po_id AND status IN ('sent','partially_received');
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- Part 6: rpc_adjust_po_item_received v3
--   基底 20260729000020 逐字保留，僅：
--     - 加「已斷貨品項不可調整已收量」守衛（斷貨=該品項收貨已定案）
--     - 步驟 7 母單狀態重算加入品項斷貨收尾分支（同 Part 5 規則）
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
  v_item     purchase_order_items%ROWTYPE;
  v_po       purchase_orders%ROWTYPE;
  v_shipped  NUMERIC;
  v_floor    NUMERIC;
  v_delta    NUMERIC;
  v_avail    NUMERIC;
  v_cost     NUMERIC;
  v_tot_ord  NUMERIC;
  v_tot_rcv  NUMERIC;
  v_outstanding  INTEGER;
  v_stockout_cnt INTEGER;
  v_status   TEXT;
  v_gr_id    BIGINT;
  v_gr_no    TEXT;
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

  -- 2b. 已斷貨品項收貨已定案，鎖定
  IF v_item.stockout_at IS NOT NULL THEN
    RAISE EXCEPTION '品項已標記斷貨（%），不可調整已收量',
      to_char(v_item.stockout_at, 'YYYY-MM-DD HH24:MI');
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
  --    品項斷貨收尾：未定案品項歸零且存在斷貨品項 → closed / cancelled
  SELECT SUM(qty_ordered), SUM(qty_received),
         COUNT(*) FILTER (WHERE stockout_at IS NULL
                            AND COALESCE(qty_received, 0) < qty_ordered),
         COUNT(*) FILTER (WHERE stockout_at IS NOT NULL)
    INTO v_tot_ord, v_tot_rcv, v_outstanding, v_stockout_cnt
    FROM purchase_order_items WHERE po_id = v_item.po_id;

  IF v_tot_rcv >= v_tot_ord THEN
    v_status := 'fully_received';
  ELSIF v_stockout_cnt > 0 AND v_outstanding = 0 THEN
    v_status := CASE WHEN v_tot_rcv > 0 THEN 'closed' ELSE 'cancelled' END;
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
  '派貨工作台因此看得到）；改少→manual_adjust 出庫修正。下限=已退+已出、上限=訂購量。'
  '已斷貨品項鎖定；品項斷貨後其餘品項收滿 → 母單自動 closed。';

-- ------------------------------------------------------------
-- Part 7: v_order_shortage v4 — 在途供給排除已斷貨品項
--   基底 20260731000010 v3 原樣重建，僅 total_in_transit 的 CASE 加
--   poi.stockout_at IS NULL：品項斷貨後（PO 未關前）該未到量已確定
--   不會到，不該再抵銷短缺判定。其餘（closed PO 已收量不歸零、
--   採購定案閘門、比例分攤）完全不動。
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW public.v_order_shortage AS
WITH
-- 1. SKU 維度供給:sent/partial/fully 算「已收 + 在途(未收餘量)」,
--    closed 只算已收(差額不會再到)。cancelled / draft 不入列。
--    已斷貨品項不算在途(20260801:未到量已確定不會到)。
--    這個 CTE 同時是「採購已定案」閘門:沒有列 = 該 SKU 不判短缺。
settled_po_supply AS (
  SELECT
    poi.sku_id,
    SUM(COALESCE(g.gr_qty, 0)) AS total_gr,
    SUM(
      CASE WHEN po.status IN ('sent', 'partially_received')
             AND poi.stockout_at IS NULL
           THEN GREATEST(0, poi.qty_ordered - COALESCE(g.gr_qty, 0))
           ELSE 0
      END
    ) AS total_in_transit
  FROM purchase_orders po
  JOIN purchase_order_items poi ON poi.po_id = po.id
  LEFT JOIN (
    SELECT gri.po_item_id, SUM(gri.qty_received) AS gr_qty
    FROM goods_receipt_items gri
    JOIN goods_receipts gr ON gr.id = gri.gr_id
    WHERE gr.status = 'confirmed'
    GROUP BY gri.po_item_id
  ) g ON g.po_item_id = poi.id
  WHERE po.status IN ('sent', 'partially_received', 'fully_received', 'closed')
  GROUP BY poi.sku_id
),
-- 已撿+已派(沿用 v2:每 (sku, store) 算一次,不重複)
allocated_per_sku_store AS (
  SELECT
    sku_id, store_id,
    SUM(wave_qty)    AS total_wave,
    SUM(shipped_qty) AS total_shipped
  FROM v_picking_demand_by_po
  WHERE store_id IS NOT NULL
  GROUP BY sku_id, store_id
),
allocated_per_sku AS (
  SELECT sku_id,
    SUM(total_wave)    AS total_wave,
    SUM(total_shipped) AS total_shipped
  FROM allocated_per_sku_store
  GROUP BY sku_id
),
-- 2. SKU 維度 demand(沿用 v2)
demand_per_sku_store AS (
  SELECT
    coi.sku_id,
    co.pickup_store_id AS store_id,
    SUM(coi.qty) AS demand_qty
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed','partially_completed')
    AND coi.status NOT IN ('cancelled','expired')
    AND co.transferred_from_order_id IS NULL
    AND co.pickup_store_id IS NOT NULL
  GROUP BY coi.sku_id, co.pickup_store_id
),
demand_per_sku AS (
  SELECT sku_id, SUM(demand_qty) AS total_demand
  FROM demand_per_sku_store
  GROUP BY sku_id
),
-- 3. SKU 層級短缺判定:INNER JOIN settled_po_supply = 採購定案閘門
sku_shortage AS (
  SELECT
    d.sku_id,
    d.total_demand,
    COALESCE(s.total_gr, 0)         AS total_gr,
    COALESCE(s.total_in_transit, 0) AS total_in_transit,
    COALESCE(a.total_wave, 0)       AS total_wave,
    COALESCE(a.total_shipped, 0)    AS total_shipped,
    GREATEST(0,
      d.total_demand - COALESCE(s.total_gr, 0) - COALESCE(s.total_in_transit, 0)
    ) AS sku_shortage_qty
  FROM demand_per_sku d
  JOIN settled_po_supply s ON s.sku_id = d.sku_id
  LEFT JOIN allocated_per_sku a ON a.sku_id = d.sku_id
  WHERE
    -- 只列總供給 < 總需求 的 SKU
    d.total_demand > COALESCE(s.total_gr, 0) + COALESCE(s.total_in_transit, 0)
)
-- 4. 展開到 order_item:該訂單按 (sku, store) demand 比例承擔短缺(沿用 v2)
SELECT
  co.tenant_id,
  co.id              AS order_id,
  co.order_no,
  co.member_id,
  co.pickup_store_id AS store_id,
  st.name            AS store_name,
  co.status          AS order_status,
  co.shortage_notified_at,
  co.shortage_resolution,
  co.shortage_resolution_at,
  coi.id             AS order_item_id,
  coi.sku_id,
  s.sku_code,
  s.product_name,
  s.variant_name,
  coi.qty            AS order_qty,
  ss.total_demand,
  ss.total_gr,
  ss.total_in_transit,
  ss.total_wave,
  ss.total_shipped,
  ss.sku_shortage_qty AS total_supplier_shortage,
  -- 每張 order_item 的短缺量 = 比例分配
  ROUND(coi.qty::NUMERIC * ss.sku_shortage_qty / NULLIF(ss.total_demand, 0), 2) AS demand_unfulfillable,
  co.created_at      AS order_created_at,
  co.updated_at      AS order_updated_at
FROM customer_orders co
JOIN customer_order_items coi ON coi.order_id = co.id
JOIN sku_shortage ss ON ss.sku_id = coi.sku_id
LEFT JOIN skus s ON s.id = coi.sku_id
LEFT JOIN stores st ON st.id = co.pickup_store_id
WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed','partially_completed')
  AND coi.status NOT IN ('cancelled','expired')
  AND co.transferred_from_order_id IS NULL
  AND ss.sku_shortage_qty > 0;

GRANT SELECT ON public.v_order_shortage TO authenticated;

COMMENT ON VIEW public.v_order_shortage IS
  '短缺訂單看板 v4:只對「採購已定案」(存在 sent/partial/fully/closed PO)的 SKU 判定短缺;'
  '供給直接從 PO/GR 計算,closed PO 的已收量不歸零(關單≠貨消失);'
  '已斷貨品項不算在途(未到量確定不會到)。'
  '完全沒 PO 的 SKU = 等採購開單,不列;只剩 cancelled PO 的 SKU 由斷貨連動處理,不列。'
  '展開到 order_item 按比例分攤短缺量,欄位與 v2 相容。';

-- ------------------------------------------------------------
-- Part 8: rpc_po_list v2 — rows 加 stockout_items 計數
--   基底 20260729000000 逐字保留，僅 page CTE 的品項 lateral 多算
--   count(*) FILTER (WHERE poi.stockout_at IS NOT NULL)，
--   列表頁可顯示「部分斷貨 n 項」。
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_po_list(
  p_status      text   DEFAULT NULL,
  p_supplier_id bigint DEFAULT NULL,
  p_search      text   DEFAULT NULL,
  p_date_from   date   DEFAULT NULL,
  p_date_to     date   DEFAULT NULL,
  p_sort        text   DEFAULT 'updated_at',
  p_dir         text   DEFAULT 'desc',
  p_page        int    DEFAULT 1,
  p_page_size   int    DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_tenant uuid := public._current_tenant_id();
  v_sort   text;
  v_dir    text;
  v_size   int  := GREATEST(1, LEAST(COALESCE(p_page_size, 30), 200));
  v_offset int;
  v_rows   jsonb;
  v_total  bigint;
BEGIN
  -- 排序欄位白名單（絕不把 p_sort 原字串塞進 SQL）
  v_sort := CASE lower(COALESCE(p_sort, 'updated_at'))
              WHEN 'po_no'         THEN 'b.po_no'
              WHEN 'total'         THEN 'b.total'
              WHEN 'expected_date' THEN 'b.expected_date'
              WHEN 'supplier'      THEN 'b.supplier_name'
              ELSE                      'b.updated_at'
            END;
  v_dir    := CASE WHEN lower(COALESCE(p_dir, 'desc')) = 'asc' THEN 'ASC' ELSE 'DESC' END;
  v_offset := GREATEST(0, (GREATEST(1, COALESCE(p_page, 1)) - 1) * v_size);

  EXECUTE format($q$
    WITH base AS (
      -- 篩選條件只寫一次；只取 id + 排序鍵，撐不大
      SELECT po.id, po.po_no, po.total, po.expected_date, po.updated_at,
             s.name AS supplier_name
      FROM purchase_orders po
      LEFT JOIN suppliers s ON s.id = po.supplier_id
      WHERE po.tenant_id = $1
        AND ($2 IS NULL OR $2 = 'all' OR po.status = $2)
        AND ($3 IS NULL OR po.supplier_id = $3)
        AND ($4 IS NULL OR po.created_at >= $4::timestamptz)
        AND ($5 IS NULL OR po.created_at < ($5::date + 1)::timestamptz)
        AND ($6 IS NULL OR (
              po.po_no ILIKE '%%' || $6 || '%%'
           OR s.name   ILIKE '%%' || $6 || '%%'
           OR EXISTS (
                SELECT 1 FROM purchase_order_items poi
                JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                JOIN purchase_requests pr       ON pr.id = pri.pr_id
                WHERE poi.po_id = po.id AND pr.pr_no ILIKE '%%' || $6 || '%%')
           OR EXISTS (
                SELECT 1 FROM purchase_order_items poi
                JOIN skus sk     ON sk.id = poi.sku_id
                JOIN products pd ON pd.id = sk.product_id
                WHERE poi.po_id = po.id AND pd.name ILIKE '%%' || $6 || '%%')
        ))
    ),
    picked AS (
      SELECT b.id, row_number() OVER (ORDER BY %s %s NULLS LAST, b.id DESC) AS rn
      FROM base b
      ORDER BY %s %s NULLS LAST, b.id DESC
      LIMIT $7 OFFSET $8
    ),
    -- 只對「當前頁」做昂貴的 lateral 補值（品項數 / 商品名 / 來源 PR）
    page AS (
      SELECT
        po.id, po.po_no, po.supplier_id, s.name AS supplier_name, po.status,
        po.total, po.expected_date, po.sent_at, po.sent_channel, po.stockout_at,
        po.created_at, po.updated_at,
        src.pr_id, src.pr_no,
        COALESCE(it.item_count, 0)                  AS item_count,
        COALESCE(it.stockout_items, 0)              AS stockout_items,
        COALESCE(it.product_names, ARRAY[]::text[]) AS product_names,
        pk.rn
      FROM picked pk
      JOIN purchase_orders po ON po.id = pk.id
      LEFT JOIN suppliers s   ON s.id = po.supplier_id
      LEFT JOIN LATERAL (
        SELECT count(*) AS item_count,
               count(*) FILTER (WHERE poi.stockout_at IS NOT NULL) AS stockout_items,
               array_agg(DISTINCT pd.name) FILTER (WHERE pd.name IS NOT NULL) AS product_names
        FROM purchase_order_items poi
        LEFT JOIN skus sk     ON sk.id = poi.sku_id
        LEFT JOIN products pd ON pd.id = sk.product_id
        WHERE poi.po_id = po.id
      ) it ON true
      LEFT JOIN LATERAL (
        SELECT pr.id AS pr_id, pr.pr_no
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN purchase_requests pr       ON pr.id = pri.pr_id
        WHERE poi.po_id = po.id
        LIMIT 1
      ) src ON true
    )
    SELECT
      (SELECT count(*) FROM base),
      COALESCE((SELECT jsonb_agg(to_jsonb(page) - 'rn' ORDER BY page.rn) FROM page), '[]'::jsonb)
  $q$, v_sort, v_dir, v_sort, v_dir)
  INTO v_total, v_rows
  USING v_tenant, p_status, p_supplier_id, p_date_from, p_date_to,
        NULLIF(btrim(COALESCE(p_search, '')), ''), v_size, v_offset;

  RETURN jsonb_build_object(
    'total', v_total,
    'counts', (
      SELECT jsonb_build_object(
        'all',                count(*),
        'draft',              count(*) FILTER (WHERE status = 'draft'),
        'sent',               count(*) FILTER (WHERE status = 'sent'),
        'partially_received', count(*) FILTER (WHERE status = 'partially_received'),
        'fully_received',     count(*) FILTER (WHERE status = 'fully_received'),
        'closed',             count(*) FILTER (WHERE status = 'closed'),
        'cancelled',          count(*) FILTER (WHERE status = 'cancelled')
      )
      FROM purchase_orders WHERE tenant_id = v_tenant
    ),
    'kpi', (
      SELECT jsonb_build_object(
        'draft',           count(*) FILTER (WHERE status = 'draft'),
        'pending_arrival', count(*) FILTER (WHERE status IN ('sent','partially_received')),
        -- 逾期＝已發送/部分到貨且預計到貨日已過（對齊原前端：只看在途單）
        'overdue',         count(*) FILTER (
                             WHERE status IN ('sent','partially_received')
                               AND expected_date IS NOT NULL
                               AND expected_date < current_date),
        'pending_amount',  COALESCE(sum(total) FILTER (
                             WHERE status IN ('sent','partially_received')), 0)
      )
      FROM purchase_orders WHERE tenant_id = v_tenant
    ),
    'suppliers', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name) ORDER BY d.name), '[]'::jsonb)
      FROM (
        SELECT DISTINCT s.id, s.name
        FROM purchase_orders po
        JOIN suppliers s ON s.id = po.supplier_id
        WHERE po.tenant_id = v_tenant
      ) d
    ),
    'rows', v_rows
  );
END;
$fn$;

COMMENT ON FUNCTION public.rpc_po_list(text,bigint,text,date,date,text,text,int,int) IS
  '採購單列表 server-side 篩選/排序/分頁：回傳 { total, counts, kpi, suppliers, rows(當前頁) }。'
  '搜尋以 ILIKE 比對單號/廠商/來源請購單單號/商品名。rows 含 stockout_items（已斷貨品項數）。';

GRANT EXECUTE ON FUNCTION public.rpc_po_list(text,bigint,text,date,date,text,text,int,int) TO authenticated;

-- ============================================================
-- 2026-08-08: 剩餘品項斷貨取消後，已取完的訂單要自動結單
--
-- 回報案例（訂單 GRP-20260712-004-0046, id=49469, 湖口店）：
--   4 個品項裡 3 個在 7/15 取貨完成（status='picked_up'），剩下的
--   「滷虱目魚肚」在 7/21 因採購單 PO2607140844 整張斷貨被連動取消
--   （coi.status='cancelled' + stockout_at）。此時訂單已經沒有任何
--   待取品項了，卻永遠停在 'partially_completed'（部分取貨），
--   店端在取貨頁「部分取貨」分頁一直看得到這張結不掉的單。
--
--   根因：斷貨連動只有「全部品項都沒了 → 整單 cancelled」這一條收尾
--   規則（_stockout_po_items (c) / rpc_cancel_backorder_items），
--   而該規則的 NOT EXISTS 守衛把 picked_up 品項也算成 active，
--   所以「已取了一部分 + 剩下的斷貨」這種單兩邊都不符合：
--     - 不符合整單取消（有 picked_up 品項，錢已收）
--     - 也沒有任何東西再去重算單頭 → 卡在 partially_completed
--   訂單單頭的狀態只有 rpc_record_pickup 會重算，但斷貨發生在取貨
--   之後，不會再有下一次取貨事件來觸發重算。
--
--   線上受影響：18 張（PO2607140844 連動 10 張、2026-08-06 品項斷貨
--   連動 8 張），全部 payment_status='unpaid'（本系統 completed 單
--   20479 張也全是 unpaid，付款不走 payment_status，故自動結單不影響金流）。
--
-- 修法（與 20260801000000_full_return_closes_order 的「全數退貨收尾」同型）：
--   1. 新 helper _close_orders_all_items_settled(order_ids, operator, at)：
--      沒有任何待取品項（pending/reserved/ready）+ 至少一個 picked_up
--      → status='completed'、completed_at 補上。判定條件與
--      rpc_record_pickup 的 v_active_remaining 同一套（同樣的 active 集合），
--      所以「先斷貨後取貨」與「先取貨後斷貨」兩個順序結果一致。
--      有 picked_up 才收尾 → 與既有「整單取消」規則天然互斥
--      （整單取消要求所有品項都 cancelled/expired，有 picked_up 就不成立）。
--   2. _stockout_po_items：(c) 整單取消之後加 (c2) 呼叫 helper。
--      這是採購斷貨的唯一核心（rpc_stockout_po_item /
--      rpc_stockout_purchase_order 都走它），改一處兩個入口都涵蓋。
--   3. rpc_cancel_backorder_items：「待補貨確定補不到 → 取消」同樣收尾。
--   4. 資料治理（冪等）：把線上既有 18 張卡住的單收尾成 completed。
--
--   rpc_delete_order_item 不動：它的狀態閘只放行 status='pending' 的訂單，
--   pending 單不可能有 picked_up 品項，helper 必然 no-op。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   - _stockout_po_items：20260801000000_po_item_stockout.sql
--     （逐字保留，僅加 v_close_ids / v_order_completed 宣告、(c2) 一段、
--      回傳多一個 orders_completed 鍵）
--   - rpc_cancel_backorder_items：20260805000060_shortage_allocation.sql
--     （逐字保留，僅加 helper 呼叫與 orders_completed 回傳鍵）
--
-- Rollback：
--   - _stockout_po_items 還原為 20260801000000 版本
--   - rpc_cancel_backorder_items 還原為 20260805000060 版本
--   - DROP FUNCTION public._close_orders_all_items_settled(BIGINT[], UUID, TIMESTAMPTZ);
--   - 資料治理不自動回滾；被收尾的單可依 completed_at = 本次執行時間
--     對照 customer_order_items.stockout_at 後手動改回 partially_completed
--
-- TEST: docs/TEST-stockout-closes-picked-order.md
-- ============================================================

-- ------------------------------------------------------------
-- 1. helper：沒有待取品項且取過貨 → 結單
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._close_orders_all_items_settled(
  p_order_ids BIGINT[],
  p_operator  UUID,
  p_at        TIMESTAMPTZ DEFAULT NOW()
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  IF p_order_ids IS NULL OR array_length(p_order_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE customer_orders co
     SET status       = 'completed',
         completed_at = COALESCE(co.completed_at, p_at),
         updated_by   = p_operator,
         updated_at   = NOW()
   WHERE co.id = ANY(p_order_ids)
     AND co.status IN ('pending','confirmed','ready','shipping','partially_completed')
     -- 取過貨才叫「完成」；一件都沒取走的單交給既有的整單取消規則
     AND EXISTS (
           SELECT 1 FROM customer_order_items x
            WHERE x.order_id = co.id
              AND x.status = 'picked_up'
         )
     -- active 集合與 rpc_record_pickup 的 v_active_remaining 同一套
     AND NOT EXISTS (
           SELECT 1 FROM customer_order_items x
            WHERE x.order_id = co.id
              AND x.status IN ('pending','reserved','ready')
         );
  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public._close_orders_all_items_settled(BIGINT[], UUID, TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION public._close_orders_all_items_settled(BIGINT[], UUID, TIMESTAMPTZ) IS
  '訂單收尾 helper（品項被取消 / 斷貨後呼叫）：已無待取品項（pending/reserved/ready）'
  '且至少取過一件（picked_up）→ status=completed、補 completed_at。'
  '一件都沒取的單不動（走既有「全品項取消 → 整單 cancelled」規則）。';

-- ------------------------------------------------------------
-- 2. _stockout_po_items v2 — 斷貨連動後收尾已取完的訂單
--    基底 20260801000000 逐字保留，僅加 (c2)
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
  v_close_ids     BIGINT[];
  v_ci_count      INTEGER := 0;
  v_coi_count     INTEGER := 0;
  v_order_count   INTEGER := 0;
  v_order_done    INTEGER := 0;
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

    -- (c2) 20260808000000：已取走一部分、剩下的這次被斷貨取消 →
    --      沒有待取品項了，訂單收尾成 completed（不然永遠卡「部分取貨」）。
    --      與 (c) 互斥：(c) 要求全品項 cancelled/expired，有 picked_up 就不成立。
    IF v_coi_ids IS NOT NULL THEN
      SELECT ARRAY_AGG(DISTINCT order_id) INTO v_close_ids
        FROM customer_order_items
       WHERE id = ANY(v_coi_ids);

      v_order_done := public._close_orders_all_items_settled(
                        v_close_ids, p_operator, p_at);
    END IF;

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
    'orders_completed', v_order_done,
    'members_notified', v_notified
  ) || COALESCE(v_restock, '{}'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public._stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION public._stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ) IS
  '品項斷貨核心（rpc_stockout_po_item / rpc_stockout_purchase_order 內部用）：'
  '標記品項 stockout_at → 下游連動（開團 / 顧客訂單 / 補貨鏈 / 通知，scope 限被標記品項）'
  '→ 全品項定案時母單自動 closed / cancelled。呼叫端需先鎖母單並驗狀態。'
  '20260808000000：連動取消後若訂單已無待取品項且取過貨 → 收尾成 completed（orders_completed）。';

-- ------------------------------------------------------------
-- 3. rpc_cancel_backorder_items v2 — 同樣收尾已取完的訂單
--    基底 20260805000060 逐字保留，僅加 helper 呼叫
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_cancel_backorder_items(
  p_item_ids BIGINT[],
  p_operator UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_items     INT := 0;
  v_orders    INT := 0;
  v_completed INT := 0;
  v_ids       BIGINT[] := COALESCE(p_item_ids, ARRAY[]::BIGINT[]);
  v_order_ids BIGINT[];
BEGIN
  UPDATE customer_order_items coi
     SET status = 'cancelled', stockout_at = NOW(),
         updated_by = p_operator, updated_at = NOW()
   WHERE coi.id = ANY(v_ids)
     AND coi.backorder_at IS NOT NULL       -- 只准取消待補貨的，避免誤砍正常品項
     AND coi.status IN ('pending', 'reserved', 'ready');
  GET DIAGNOSTICS v_items = ROW_COUNT;

  UPDATE customer_orders co
     SET status = 'cancelled', cancelled_at = NOW(), stockout_at = NOW(),
         updated_by = p_operator, updated_at = NOW()
   WHERE co.id IN (SELECT order_id FROM customer_order_items WHERE id = ANY(v_ids))
     AND co.status IN ('pending', 'confirmed', 'ready', 'shipping')
     AND COALESCE(co.payment_status, 'unpaid') <> 'paid'
     AND COALESCE(co.wallet_paid_amount, 0) = 0
     AND NOT EXISTS (
           SELECT 1 FROM customer_order_items x
            WHERE x.order_id = co.id AND x.status NOT IN ('cancelled', 'expired')
         );
  GET DIAGNOSTICS v_orders = ROW_COUNT;

  -- 20260808000000：已取走一部分、剩下的待補貨這次被取消 → 訂單收尾成 completed
  SELECT ARRAY_AGG(DISTINCT order_id) INTO v_order_ids
    FROM customer_order_items WHERE id = ANY(v_ids);
  v_completed := public._close_orders_all_items_settled(v_order_ids, p_operator, NOW());

  RETURN jsonb_build_object(
    'items_cancelled',  v_items,
    'orders_cancelled', v_orders,
    'orders_completed', v_completed
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_cancel_backorder_items(BIGINT[], UUID) IS
  '待補貨確定補不到 → 品項 cancelled + stockout_at（沿用斷貨語意）。'
  '整單品項都沒了且沒收過錢 → 訂單一併取消；'
  '已取走一部分、剩下的這次取消掉 → 訂單收尾成 completed（20260808000000）。';

-- ------------------------------------------------------------
-- 4. 資料治理：收尾線上既有卡在「部分取貨」的單（冪等）
-- ------------------------------------------------------------

DO $$
DECLARE
  v_ids  BIGINT[];
  v_done INTEGER;
BEGIN
  SELECT ARRAY_AGG(co.id) INTO v_ids
    FROM customer_orders co
   WHERE co.status = 'partially_completed'
     AND EXISTS (
           SELECT 1 FROM customer_order_items x
            WHERE x.order_id = co.id AND x.status = 'picked_up'
         )
     AND NOT EXISTS (
           SELECT 1 FROM customer_order_items x
            WHERE x.order_id = co.id
              AND x.status IN ('pending','reserved','ready')
         );

  v_done := public._close_orders_all_items_settled(v_ids, NULL, NOW());
  RAISE NOTICE '[20260808000000] 收尾卡在部分取貨的訂單: %', v_done;
END;
$$;

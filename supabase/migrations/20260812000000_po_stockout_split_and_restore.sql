-- ============================================================
-- 採購斷貨：自動拆「斷貨單」＋ 歸類斷貨分頁 ＋ 一鍵回復
--
-- 需求（cktalex 2026-08-12）：
--   1. 採購單斷貨 → 自動把斷貨品項拆成一張獨立的單
--   2. 那張單歸類到「斷貨」類別（PO 列表獨立分頁）
--   3. 受影響的店家/顧客訂單一併變成斷貨狀態（既有連動，本檔補上「是哪張
--      斷貨單造成的」連結，回復時才知道要還原哪些列）
--   4. 一顆按鈕可以把斷貨回復成「正常未採購」狀態，接著繼續走原本流程
--      （草稿 → 發送供應商 → 到貨 → 收貨 → 分貨）
--
-- 設計：
--
--   A. 為什麼「不」新增 purchase_orders.status = 'stockout'
--      沿用 20260702020000 對 customer_order_items 的同一套判斷：
--      十幾支 view / RPC 用 `po.status IN ('sent','partially_received',
--      'fully_received','closed')` 當供給 / 閘門條件（v_order_shortage v5、
--      v_picking_demand_by_po、v_pr_progress…），加一個 status 值等於要
--      同時改完那些地方，漏一個就是靜默錯帳。
--      斷貨單沿用 status='cancelled'（既有過濾自動正確：不算在途、不算供給、
--      不進撿貨需求），用 stockout_at 區分「斷貨」與「一般取消」，
--      列表的「斷貨」分頁＝ stockout_at IS NOT NULL。
--
--   B. 只搬「完全沒到貨」的斷貨品項（qty_received = 0）
--      這正好是既有下游連動的集合（v_stockout_skus）。部分到貨的品項留在
--      原單、維持既有語意（只停止等待餘量，已到的貨走正常分貨）— 硬要拆會
--      讓「已收的貨」和「PR → campaign 對應」被拆到兩張單上，
--      po_campaigns（v_picking_demand_by_po / v_order_shortage 的
--      campaign 對應）只認得 purchase_request_items.po_item_id 這一條 1:1
--      連結，拆錯邊會讓手上的貨配不出去。
--      搬的是**同一列**（UPDATE po_id），不是複製 —— po_item_id 不變，
--      PR 連結 / vendor_bill_items / goods_receipt_items 的外鍵全都跟著走，
--      回復後重新發送、收貨、分貨才接得回原本的團。
--
--   C. 整張單都斷貨時不拆單
--      原單自己就是那張斷貨單（避免生出一張空殼 PO）。
--      同一張來源單再次斷貨時，沿用既有那張未回復的斷貨單，不會越拆越多張。
--
--   D. 回復（rpc_restore_stockout_po）
--      斷貨單 → draft（＝「正常未採購」：未發送供應商，可再送一次或改廠商），
--      並反向還原下游：開團商品 / 顧客訂單品項（cancelled+斷貨 → pending）/
--      整單取消的訂單 / 補貨申請鏈 / RR- 內部單，另發一則「斷貨已恢復」通知。
--      還原範圍靠本檔新增的 stockout_po_id 連結（舊資料 fallback：
--      斷貨時間 + SKU + campaign 三者對得上才還原）。
--      守衛：有到貨量 / 有未取消的進貨單 / 有撿貨波次 → 擋下（那不是純斷貨單）。
--
-- 基底版本（依 CLAUDE.md 規則 grep 全歷史）：
--   _stockout_po_items          ← 20260808000000_close_order_when_remaining_items_stockout.sql（v2，最新）
--   rpc_po_list                 ← 20260801000000_po_item_stockout.sql（v2，最新）
--   _stockout_propagate_restock ← 20260810000000_short_receipt_settles_restock.sql（最新，本檔不動）
--   rpc_stockout_po_item        ← 20260801000000（本檔不動）
--
-- Rollback：
--   - _stockout_po_items 還原為 20260808000000 版本
--   - rpc_po_list        還原為 20260801000000 版本
--   - DROP FUNCTION public.rpc_restore_stockout_po(BIGINT, UUID);
--     DROP FUNCTION public._split_stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ);
--   - ALTER TABLE purchase_orders
--       DROP COLUMN IF EXISTS stockout_split_from_po_id,
--       DROP COLUMN IF EXISTS stockout_restored_at,
--       DROP COLUMN IF EXISTS stockout_restored_by;
--     ALTER TABLE campaign_items / customer_order_items / customer_orders /
--                 restock_request_lines / restock_requests
--       DROP COLUMN IF EXISTS stockout_po_id;
--   - 已拆出去的斷貨單不會自動併回（品項的 po_id 要手動搬回來源單）
-- ============================================================

-- ------------------------------------------------------------
-- Part 1: 欄位
-- ------------------------------------------------------------

ALTER TABLE purchase_orders
  ADD COLUMN IF NOT EXISTS stockout_split_from_po_id BIGINT,
  ADD COLUMN IF NOT EXISTS stockout_restored_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS stockout_restored_by      UUID;

COMMENT ON COLUMN purchase_orders.stockout_split_from_po_id IS
  '斷貨拆單的來源採購單 id；非 NULL = 這張是從該單拆出來的斷貨單';
COMMENT ON COLUMN purchase_orders.stockout_restored_at IS
  '斷貨回復（rpc_restore_stockout_po）的時間；回復後 status 回到 draft，可重新發送供應商';

-- 下游斷貨列 → 是哪張斷貨單造成的（回復時據此還原）。
-- 刻意不加 FK：PO 可被 rpc_delete_purchase_order 硬刪，
-- 且 customer_order_items 是大表，加 FK 只換來一次全表驗證與鎖。
ALTER TABLE campaign_items        ADD COLUMN IF NOT EXISTS stockout_po_id BIGINT;
ALTER TABLE customer_order_items  ADD COLUMN IF NOT EXISTS stockout_po_id BIGINT;
ALTER TABLE customer_orders       ADD COLUMN IF NOT EXISTS stockout_po_id BIGINT;
ALTER TABLE restock_request_lines ADD COLUMN IF NOT EXISTS stockout_po_id BIGINT;
ALTER TABLE restock_requests      ADD COLUMN IF NOT EXISTS stockout_po_id BIGINT;

COMMENT ON COLUMN customer_order_items.stockout_po_id IS
  '造成這列斷貨的採購單（斷貨單）id；rpc_restore_stockout_po 依此還原成 pending';

CREATE INDEX IF NOT EXISTS idx_coi_stockout_po
  ON customer_order_items (stockout_po_id) WHERE stockout_po_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ci_stockout_po
  ON campaign_items (stockout_po_id) WHERE stockout_po_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rrl_stockout_po
  ON restock_request_lines (stockout_po_id) WHERE stockout_po_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_po_stockout_split_from
  ON purchase_orders (stockout_split_from_po_id) WHERE stockout_split_from_po_id IS NOT NULL;

-- ------------------------------------------------------------
-- Part 2: helper — 斷貨品項拆單
--   把「本次標記斷貨且完全沒到貨」的品項搬到一張斷貨單（cancelled + stockout_at）。
--   回傳斷貨單 id；不需要拆（整張都斷貨 / 沒有可搬品項）時回 NULL。
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._split_stockout_po_items(
  p_po_id    BIGINT,
  p_item_ids BIGINT[],
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_po        purchase_orders%ROWTYPE;
  v_move      BIGINT[];
  v_remaining INTEGER;
  v_target    BIGINT;
  v_po_no     TEXT;
BEGIN
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- 可搬的品項：本次標記斷貨、完全沒到貨、且沒有掛在任何未取消的進貨單上
  --（草稿進貨單若還掛著這一列，搬走會讓它確認後把貨收到斷貨單上）
  SELECT ARRAY_AGG(poi.id) INTO v_move
    FROM purchase_order_items poi
   WHERE poi.po_id = p_po_id
     AND poi.id = ANY (COALESCE(p_item_ids, '{}'::BIGINT[]))
     AND poi.stockout_at IS NOT NULL
     AND COALESCE(poi.qty_received, 0) = 0
     AND NOT EXISTS (
           SELECT 1
             FROM goods_receipt_items gri
             JOIN goods_receipts gr ON gr.id = gri.gr_id
            WHERE gri.po_item_id = poi.id
              AND gr.status <> 'cancelled'
         );

  IF v_move IS NULL OR array_length(v_move, 1) IS NULL THEN
    RETURN NULL;
  END IF;

  -- 整張單都要搬 → 不拆（原單自己就是斷貨單，不生空殼 PO）
  SELECT COUNT(*) INTO v_remaining
    FROM purchase_order_items
   WHERE po_id = p_po_id
     AND NOT (id = ANY (v_move));

  IF v_remaining = 0 THEN
    RETURN NULL;
  END IF;

  -- 同一張來源單已經有一張還沒回復的斷貨單 → 併進去，不要越拆越多張
  SELECT id INTO v_target
    FROM purchase_orders
   WHERE stockout_split_from_po_id = p_po_id
     AND status = 'cancelled'
     AND stockout_at IS NOT NULL
     AND stockout_restored_at IS NULL
   ORDER BY id DESC
   LIMIT 1
   FOR UPDATE;

  IF v_target IS NULL THEN
    v_po_no := public.rpc_next_po_no();

    INSERT INTO purchase_orders (
      tenant_id, po_no, supplier_id, dest_location_id, status,
      order_date, expected_date, payment_terms, notes,
      stockout_at, stockout_by, stockout_reason, stockout_split_from_po_id,
      created_by, updated_by
    ) VALUES (
      v_po.tenant_id, v_po_no, v_po.supplier_id, v_po.dest_location_id, 'cancelled',
      CURRENT_DATE, NULL, v_po.payment_terms,
      '斷貨拆單：自 ' || v_po.po_no || ' 拆出未到貨品項'
        || COALESCE('（' || NULLIF(BTRIM(p_reason), '') || '）', ''),
      p_at, p_operator, NULLIF(BTRIM(p_reason), ''), p_po_id,
      p_operator, p_operator
    ) RETURNING id INTO v_target;
  END IF;

  -- 搬列：po_item_id 不變 → PR 連結 / 帳單 / 進貨明細的外鍵全跟著走
  UPDATE purchase_order_items
     SET po_id      = v_target,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = ANY (v_move);

  -- 兩張單的金額重算（稅額沿用 rpc_split_pr_to_pos：total = subtotal）
  UPDATE purchase_orders po
     SET subtotal   = COALESCE((SELECT SUM(qty_ordered * unit_cost)
                                  FROM purchase_order_items WHERE po_id = po.id), 0),
         total      = COALESCE((SELECT SUM(qty_ordered * unit_cost)
                                  FROM purchase_order_items WHERE po_id = po.id), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE po.id IN (p_po_id, v_target);

  RETURN v_target;
END;
$$;

REVOKE ALL ON FUNCTION public._split_stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION public._split_stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ) IS
  '斷貨拆單（_stockout_po_items 內部用）：把本次標記斷貨且完全沒到貨的品項整列搬到'
  '一張「斷貨單」（status=cancelled + stockout_at + stockout_split_from_po_id），'
  '兩張單金額重算。整張單都斷貨 → 回 NULL（原單自己就是斷貨單）；'
  '同來源單已有未回復的斷貨單則併入。';

-- ------------------------------------------------------------
-- Part 3: _stockout_po_items v3 — 連動後自動拆斷貨單
--   基底 20260808000000（v2）逐字保留，改動：
--     - (a)(c) 改用 RETURNING 收集受影響列（原本只取 ROW_COUNT）
--     - 補貨鏈連動之後呼叫 _split_stockout_po_items 拆單
--       （順序不可對調：_stockout_propagate_restock 的「已有歸屬出貨」守衛
--        會走 pri → poi.po_id → pw.source_po_id，品項先搬走會讓守衛失效、
--        把真的已出貨的補貨明細誤判成可取消）
--     - 受影響的下游列寫上 stockout_po_id = 斷貨單（沒拆單時 = 原單），
--       回復時據此還原
--     - 母單收尾：品項搬走後若剩下的都收滿了 → fully_received
--       （斷貨已經在另一張單上，原單不該再掛 stockout_at 跑到斷貨分頁）
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
  v_ci_ids        BIGINT[];
  v_ord_ids       BIGINT[];
  v_close_ids     BIGINT[];
  v_ci_count      INTEGER := 0;
  v_coi_count     INTEGER := 0;
  v_order_count   INTEGER := 0;
  v_order_done    INTEGER := 0;
  v_notified      INTEGER := 0;
  v_restock       JSONB := '{}'::jsonb;
  v_outstanding   INTEGER;
  v_stockout_cnt  INTEGER;
  v_item_cnt      INTEGER;
  v_received      NUMERIC(18,3);
  v_new_status    TEXT;
  v_split_po      BIGINT;
  v_target_po     BIGINT;
  v_split_no      TEXT;
  v_split_items   INTEGER := 0;
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
    WITH upd AS (
      UPDATE campaign_items
         SET stockout_at = p_at,
             updated_by  = p_operator,
             updated_at  = NOW()
       WHERE campaign_id = ANY(v_campaign_ids)
         AND sku_id = ANY(v_stockout_skus)
         AND stockout_at IS NULL
       RETURNING id
    )
    SELECT ARRAY_AGG(id) INTO v_ci_ids FROM upd;
    v_ci_count := COALESCE(array_length(v_ci_ids, 1), 0);

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
    WITH upd AS (
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
             )
       RETURNING co.id
    )
    SELECT ARRAY_AGG(id) INTO v_ord_ids FROM upd;
    v_order_count := COALESCE(array_length(v_ord_ids, 1), 0);

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
  -- 必須在拆單「之前」：helper 的歸屬出貨守衛靠 poi.po_id = p_po_id
  v_restock := public._stockout_propagate_restock(
                 p_po_id, v_stockout_skus, p_operator, p_at);

  -- 2b. 20260812：拆斷貨單（只搬完全沒到貨的品項；整張斷貨則不拆）
  v_split_po  := public._split_stockout_po_items(
                   p_po_id, v_marked, p_operator, p_reason, p_at);
  v_target_po := COALESCE(v_split_po, p_po_id);

  IF v_split_po IS NOT NULL THEN
    SELECT po_no, (SELECT COUNT(*) FROM purchase_order_items WHERE po_id = v_split_po)
      INTO v_split_no, v_split_items
      FROM purchase_orders WHERE id = v_split_po;
  END IF;

  -- 2c. 下游斷貨列掛上「是哪張斷貨單造成的」，rpc_restore_stockout_po 據此還原
  IF v_ci_ids IS NOT NULL THEN
    UPDATE campaign_items SET stockout_po_id = v_target_po
     WHERE id = ANY(v_ci_ids) AND stockout_po_id IS NULL;
  END IF;
  IF v_coi_ids IS NOT NULL THEN
    UPDATE customer_order_items SET stockout_po_id = v_target_po
     WHERE id = ANY(v_coi_ids) AND stockout_po_id IS NULL;
  END IF;
  IF v_ord_ids IS NOT NULL THEN
    UPDATE customer_orders SET stockout_po_id = v_target_po
     WHERE id = ANY(v_ord_ids) AND stockout_po_id IS NULL;
  END IF;
  -- 補貨鏈：helper 不回傳 id，用本次的標記時間圈出剛剛被它動到的列
  UPDATE restock_request_lines SET stockout_po_id = v_target_po
   WHERE stockout_at = p_at AND stockout_po_id IS NULL;
  UPDATE restock_requests SET stockout_po_id = v_target_po
   WHERE stockout_at = p_at AND stockout_po_id IS NULL;
  UPDATE customer_order_items coi SET stockout_po_id = v_target_po
    FROM customer_orders co
   WHERE co.id = coi.order_id
     AND co.order_kind = 'restock'
     AND coi.stockout_at = p_at
     AND coi.stockout_po_id IS NULL;
  UPDATE customer_orders SET stockout_po_id = v_target_po
   WHERE order_kind = 'restock' AND stockout_at = p_at AND stockout_po_id IS NULL;

  -- 3. 母單收尾：不存在「未斷貨且未收滿」的品項 → 結單
  --    斷貨品項已搬到斷貨單時，原單剩下的若都收滿了 → fully_received
  --    （斷貨掛在另一張單上，原單不該再被歸到斷貨分頁）
  SELECT COUNT(*) FILTER (WHERE stockout_at IS NULL
                            AND COALESCE(qty_received, 0) < qty_ordered),
         COUNT(*) FILTER (WHERE stockout_at IS NOT NULL),
         COUNT(*),
         COALESCE(SUM(qty_received), 0)
    INTO v_outstanding, v_stockout_cnt, v_item_cnt, v_received
    FROM purchase_order_items
   WHERE po_id = p_po_id;

  IF v_outstanding = 0 AND v_item_cnt > 0 AND v_po.status IN ('sent','partially_received') THEN
    IF v_stockout_cnt = 0 THEN
      -- 斷貨的都搬走了，剩下的全數到貨
      v_new_status := 'fully_received';
      UPDATE purchase_orders
         SET status     = v_new_status,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = p_po_id;
    ELSE
      -- 還留著斷貨品項（部分到貨的那種）→ 沿用既有規則
      v_new_status := CASE WHEN v_received > 0 THEN 'closed' ELSE 'cancelled' END;
      UPDATE purchase_orders
         SET status          = v_new_status,
             stockout_at     = COALESCE(stockout_at, p_at),
             stockout_by     = COALESCE(stockout_by, p_operator),
             stockout_reason = COALESCE(stockout_reason, NULLIF(BTRIM(p_reason), '')),
             updated_by      = p_operator,
             updated_at      = NOW()
       WHERE id = p_po_id;
    END IF;
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
    'members_notified', v_notified,
    'stockout_po_id',   v_split_po,
    'stockout_po_no',   v_split_no,
    'stockout_po_items', v_split_items
  ) || COALESCE(v_restock, '{}'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public._stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION public._stockout_po_items(BIGINT, BIGINT[], UUID, TEXT, TIMESTAMPTZ) IS
  '品項斷貨核心 v3（rpc_stockout_po_item / rpc_stockout_purchase_order 內部用）：'
  '標記品項 → 下游連動（開團 / 顧客訂單 / 已取完的訂單收尾 / 補貨鏈 / 通知）'
  '→ 把完全沒到貨的斷貨品項拆到一張「斷貨單」（整張斷貨則原單即斷貨單）'
  '→ 下游列寫上 stockout_po_id 供回復使用 → 原單狀態重算。'
  '呼叫端需先鎖母單並驗狀態。';

-- ------------------------------------------------------------
-- Part 4: RPC — rpc_restore_stockout_po（回復斷貨）
--   斷貨單 → draft（正常未採購），下游斷貨全部還原，可重新走發送 → 到貨流程。
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_restore_stockout_po(
  p_po_id    BIGINT,
  p_operator UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_po           purchase_orders%ROWTYPE;
  v_skus         BIGINT[];
  v_ts           TIMESTAMPTZ[];
  v_campaign_ids BIGINT[];
  v_coi_ids      BIGINT[];
  v_line_ids     BIGINT[];
  v_req_ids      BIGINT[];
  v_items        INTEGER := 0;
  v_ci_count     INTEGER := 0;
  v_coi_count    INTEGER := 0;
  v_order_count  INTEGER := 0;
  v_reopened     INTEGER := 0;
  v_notified     INTEGER := 0;
  v_lines        INTEGER := 0;
  v_reqs         INTEGER := 0;
  v_rr_items     INTEGER := 0;
  v_rr_orders    INTEGER := 0;
BEGIN
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;

  IF v_po.stockout_at IS NULL THEN
    RAISE EXCEPTION '採購單 % 沒有斷貨紀錄，無需回復', v_po.po_no;
  END IF;

  IF v_po.status NOT IN ('cancelled','closed') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」，不是斷貨單、不可回復', v_po.po_no, v_po.status;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM purchase_order_items WHERE po_id = p_po_id) THEN
    RAISE EXCEPTION '採購單 % 沒有品項、不可回復', v_po.po_no;
  END IF;

  -- 有到貨的單不是「純斷貨單」：回到 draft 會讓已入庫的貨對不上單據
  IF EXISTS (SELECT 1 FROM purchase_order_items
              WHERE po_id = p_po_id AND COALESCE(qty_received, 0) > 0) THEN
    RAISE EXCEPTION '採購單 % 已有到貨量、不可整張回復（請另開採購單補訂未到的量）', v_po.po_no;
  END IF;

  IF EXISTS (SELECT 1 FROM goods_receipts
              WHERE po_id = p_po_id AND status <> 'cancelled') THEN
    RAISE EXCEPTION '採購單 % 已有進貨單、不可回復', v_po.po_no;
  END IF;

  IF EXISTS (SELECT 1 FROM picking_waves
              WHERE source_po_id = p_po_id AND status <> 'cancelled') THEN
    RAISE EXCEPTION '採購單 % 已建立撿貨波次、不可回復', v_po.po_no;
  END IF;

  -- 還原範圍：本單品項的 SKU、斷貨時間戳（舊資料沒有 stockout_po_id 時的 fallback）
  SELECT ARRAY_AGG(DISTINCT sku_id),
         ARRAY_AGG(DISTINCT stockout_at) FILTER (WHERE stockout_at IS NOT NULL),
         COUNT(*)
    INTO v_skus, v_ts, v_items
    FROM purchase_order_items
   WHERE po_id = p_po_id;

  v_ts := COALESCE(v_ts, ARRAY[]::TIMESTAMPTZ[]) || v_po.stockout_at;

  SELECT ARRAY_AGG(DISTINCT prc.campaign_id) INTO v_campaign_ids
    FROM purchase_order_items poi
    JOIN purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
   WHERE poi.po_id = p_po_id;

  -- 1. 採購單本身：斷貨標記清掉、回到草稿（＝正常未採購，可重新發送供應商）
  UPDATE purchase_order_items
     SET stockout_at     = NULL,
         stockout_by     = NULL,
         stockout_reason = NULL,
         updated_by      = p_operator,
         updated_at      = NOW()
   WHERE po_id = p_po_id;

  UPDATE purchase_orders
     SET status               = 'draft',
         stockout_at          = NULL,
         stockout_by          = NULL,
         stockout_reason      = NULL,
         stockout_restored_at = NOW(),
         stockout_restored_by = p_operator,
         sent_at              = NULL,
         sent_by              = NULL,
         sent_channel         = NULL,
         updated_by           = p_operator,
         updated_at           = NOW()
   WHERE id = p_po_id;

  -- 2. 開團 / 顧客訂單還原
  IF v_campaign_ids IS NOT NULL AND v_skus IS NOT NULL THEN

    UPDATE campaign_items ci
       SET stockout_at    = NULL,
           stockout_po_id = NULL,
           updated_by     = p_operator,
           updated_at     = NOW()
     WHERE ci.campaign_id = ANY(v_campaign_ids)
       AND ci.sku_id = ANY(v_skus)
       AND ci.stockout_at IS NOT NULL
       AND (ci.stockout_po_id = p_po_id
            OR (ci.stockout_po_id IS NULL AND ci.stockout_at = ANY(v_ts)));
    GET DIAGNOSTICS v_ci_count = ROW_COUNT;

    -- 品項：斷貨取消 → pending。transferred_out 的來源單不還原
    -- （貨已經掛在轉入的新單上，還原會兩張單重複算需求）
    WITH upd AS (
      UPDATE customer_order_items coi
         SET status         = 'pending',
             stockout_at    = NULL,
             stockout_po_id = NULL,
             updated_by     = p_operator,
             updated_at     = NOW()
        FROM customer_orders co
       WHERE co.id = coi.order_id
         AND co.campaign_id = ANY(v_campaign_ids)
         AND coi.sku_id = ANY(v_skus)
         AND coi.status = 'cancelled'
         AND coi.stockout_at IS NOT NULL
         AND co.status <> 'transferred_out'
         AND (coi.stockout_po_id = p_po_id
              OR (coi.stockout_po_id IS NULL AND coi.stockout_at = ANY(v_ts)))
       RETURNING coi.id
    )
    SELECT ARRAY_AGG(id) INTO v_coi_ids FROM upd;
    v_coi_count := COALESCE(array_length(v_coi_ids, 1), 0);

    IF v_coi_ids IS NOT NULL THEN
      -- 單頭：整單被斷貨取消的 → 回到取消前的狀態
      UPDATE customer_orders co
         SET status         = CASE WHEN co.confirmed_at IS NOT NULL
                                   THEN 'confirmed' ELSE 'pending' END,
             cancelled_at   = NULL,
             stockout_at    = NULL,
             stockout_po_id = NULL,
             updated_by     = p_operator,
             updated_at     = NOW()
       WHERE co.status = 'cancelled'
         AND co.stockout_at IS NOT NULL
         AND EXISTS (SELECT 1 FROM customer_order_items x
                      WHERE x.order_id = co.id AND x.id = ANY(v_coi_ids));
      GET DIAGNOSTICS v_order_count = ROW_COUNT;

      -- 曾因「剩下的都斷貨了」被收尾成 completed 的單：又有待取品項了
      -- → 退回部分取貨（_close_orders_all_items_settled 的反向）
      UPDATE customer_orders co
         SET status       = 'partially_completed',
             completed_at = NULL,
             updated_by   = p_operator,
             updated_at   = NOW()
       WHERE co.status = 'completed'
         AND EXISTS (SELECT 1 FROM customer_order_items x
                      WHERE x.order_id = co.id AND x.id = ANY(v_coi_ids))
         AND EXISTS (SELECT 1 FROM customer_order_items x
                      WHERE x.order_id = co.id AND x.status = 'picked_up');
      GET DIAGNOSTICS v_reopened = ROW_COUNT;

      -- 通知：先前發過「斷貨取消」，恢復也要講一聲，不然客人以為單子自己長回來
      INSERT INTO notifications (tenant_id, member_id, category, title, body, url)
      SELECT
        co.tenant_id,
        co.member_id,
        'stockout',
        '斷貨商品已恢復',
        '您先前因斷貨取消的「' || string_agg(DISTINCT COALESCE(sk.product_name, sk.sku_code)
                                            || COALESCE('-' || sk.variant_name, ''), '、')
          || '」已重新採購，訂單已為您恢復，到貨後會再通知您取貨。',
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

  -- 3. 補貨鏈還原（_stockout_propagate_restock 的反向）
  WITH upd AS (
    UPDATE restock_request_lines rrl
       SET cancelled_at   = NULL,
           cancelled_by   = NULL,
           stockout_at    = NULL,
           stockout_po_id = NULL,
           updated_by     = p_operator
     WHERE rrl.stockout_at IS NOT NULL
       AND (rrl.stockout_po_id = p_po_id
            OR (rrl.stockout_po_id IS NULL
                AND rrl.stockout_at = ANY(v_ts)
                AND rrl.sku_id = ANY(COALESCE(v_skus, ARRAY[]::BIGINT[]))))
     RETURNING rrl.id, rrl.request_id
  )
  SELECT ARRAY_AGG(id), ARRAY_AGG(DISTINCT request_id), COUNT(*)::INTEGER
    INTO v_line_ids, v_req_ids, v_lines
    FROM upd;

  IF v_req_ids IS NOT NULL THEN
    UPDATE restock_requests rr
       SET status         = CASE
                              WHEN rr.linked_pr_id IS NOT NULL       THEN 'approved_pr'
                              WHEN rr.linked_transfer_id IS NOT NULL THEN 'approved_transfer'
                              ELSE 'pending'
                            END,
           stockout_at    = NULL,
           stockout_po_id = NULL,
           updated_by     = p_operator
     WHERE rr.id = ANY(v_req_ids)
       AND rr.status = 'cancelled'
       AND rr.stockout_at IS NOT NULL;
    GET DIAGNOSTICS v_reqs = ROW_COUNT;

    -- RR- 內部單品項
    UPDATE customer_order_items coi
       SET status         = 'pending',
           stockout_at    = NULL,
           stockout_po_id = NULL,
           updated_by     = p_operator,
           updated_at     = NOW()
      FROM customer_orders co, restock_request_lines rrl
     WHERE rrl.id = ANY(COALESCE(v_line_ids, ARRAY[]::BIGINT[]))
       AND co.tenant_id  = rrl.tenant_id
       AND co.order_kind = 'restock'
       AND co.order_no   = 'RR-' || rrl.request_id::TEXT
       AND coi.order_id  = co.id
       AND coi.sku_id    = rrl.sku_id
       AND coi.status    = 'cancelled'
       AND coi.stockout_at IS NOT NULL;
    GET DIAGNOSTICS v_rr_items = ROW_COUNT;

    -- RR- 內部單單頭
    UPDATE customer_orders co
       SET status         = CASE WHEN co.confirmed_at IS NOT NULL
                                 THEN 'confirmed' ELSE 'pending' END,
           cancelled_at   = NULL,
           stockout_at    = NULL,
           stockout_po_id = NULL,
           updated_by     = p_operator,
           updated_at     = NOW()
     WHERE co.order_kind = 'restock'
       AND co.status = 'cancelled'
       AND co.stockout_at IS NOT NULL
       AND co.order_no IN (SELECT 'RR-' || x::TEXT FROM unnest(v_req_ids) x);
    GET DIAGNOSTICS v_rr_orders = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'po_no',                  v_po.po_no,
    'po_status',              'draft',
    'items_restored',         v_items,
    'campaign_items',         v_ci_count,
    'order_items',            v_coi_count,
    'orders_restored',        v_order_count,
    'orders_reopened',        v_reopened,
    'members_notified',       v_notified,
    'restock_lines',          v_lines,
    'restock_restored',       v_reqs,
    'restock_order_items',    v_rr_items,
    'restock_orders_restored', v_rr_orders
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_restore_stockout_po(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_restore_stockout_po(BIGINT, UUID) IS
  '回復斷貨：斷貨單 → draft（正常未採購，可重新發送供應商繼續走流程），'
  '並反向還原下游（開團商品 / 顧客訂單品項 cancelled+斷貨 → pending / 整單取消的訂單 / '
  '收尾成 completed 的單退回部分取貨 / 補貨申請鏈 / RR- 內部單），另發「斷貨已恢復」通知。'
  '還原範圍靠 stockout_po_id；舊資料 fallback 為「斷貨時間 + SKU + campaign」三者相符。'
  '守衛：有到貨量 / 未取消的進貨單 / 撿貨波次 → 擋下。';

-- ------------------------------------------------------------
-- Part 5: rpc_po_list v3 — 「斷貨」分頁
--   基底 20260801000000（v2）逐字保留，改動：
--     - p_status 多吃一個虛擬值 'stockout' = stockout_at IS NOT NULL
--     - 其餘狀態分頁排除斷貨單（斷貨獨立成一類，分頁加總才等於總數）
--     - counts 多 'stockout'，closed / cancelled 扣掉斷貨的
--     - rows 多 stockout_reason / 拆單來源 / stockout_restorable（回復按鈕用）
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
        AND ($2 IS NULL OR $2 = 'all'
             OR ($2 = 'stockout' AND po.stockout_at IS NOT NULL)
             OR ($2 <> 'stockout' AND po.status = $2 AND po.stockout_at IS NULL))
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
        po.stockout_reason, po.stockout_split_from_po_id, src_po.po_no AS stockout_split_from_po_no,
        po.created_at, po.updated_at,
        src.pr_id, src.pr_no,
        COALESCE(it.item_count, 0)                  AS item_count,
        COALESCE(it.stockout_items, 0)              AS stockout_items,
        COALESCE(it.product_names, ARRAY[]::text[]) AS product_names,
        -- 回復按鈕的可用性：純斷貨單（沒到貨、沒進貨單、沒波次）才給按
        (po.stockout_at IS NOT NULL
          AND po.status IN ('cancelled','closed')
          AND COALESCE(it.item_count, 0) > 0
          AND COALESCE(it.received_qty, 0) = 0
          AND NOT EXISTS (SELECT 1 FROM goods_receipts gr
                           WHERE gr.po_id = po.id AND gr.status <> 'cancelled')
          AND NOT EXISTS (SELECT 1 FROM picking_waves pw
                           WHERE pw.source_po_id = po.id AND pw.status <> 'cancelled')
        ) AS stockout_restorable,
        pk.rn
      FROM picked pk
      JOIN purchase_orders po ON po.id = pk.id
      LEFT JOIN suppliers s   ON s.id = po.supplier_id
      LEFT JOIN purchase_orders src_po ON src_po.id = po.stockout_split_from_po_id
      LEFT JOIN LATERAL (
        SELECT count(*) AS item_count,
               count(*) FILTER (WHERE poi.stockout_at IS NOT NULL) AS stockout_items,
               COALESCE(sum(poi.qty_received), 0) AS received_qty,
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
        'draft',              count(*) FILTER (WHERE status = 'draft'              AND stockout_at IS NULL),
        'sent',               count(*) FILTER (WHERE status = 'sent'               AND stockout_at IS NULL),
        'partially_received', count(*) FILTER (WHERE status = 'partially_received' AND stockout_at IS NULL),
        'fully_received',     count(*) FILTER (WHERE status = 'fully_received'     AND stockout_at IS NULL),
        'closed',             count(*) FILTER (WHERE status = 'closed'             AND stockout_at IS NULL),
        'cancelled',          count(*) FILTER (WHERE status = 'cancelled'          AND stockout_at IS NULL),
        'stockout',           count(*) FILTER (WHERE stockout_at IS NOT NULL)
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
                             WHERE status IN ('sent','partially_received')), 0),
        'stockout',        count(*) FILTER (WHERE stockout_at IS NOT NULL)
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
  '搜尋以 ILIKE 比對單號/廠商/來源請購單單號/商品名。'
  'p_status 支援虛擬值 ''stockout''（= stockout_at IS NOT NULL）；其餘狀態分頁會排除斷貨單，'
  '斷貨自成一類、分頁加總 = 全部。rows 含 stockout_items / 拆單來源 / stockout_restorable。';

GRANT EXECUTE ON FUNCTION public.rpc_po_list(text,bigint,text,date,date,text,text,int,int) TO authenticated;

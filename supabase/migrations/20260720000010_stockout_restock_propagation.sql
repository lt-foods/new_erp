-- ============================================================
-- 斷貨連動補完：採購單斷貨 → 補貨申請 / RR- 內部單
--
-- 問題（cktalex 2026-07-20 回報）：
--   補貨申請走「approved_pr → PR → PO」路徑後，若 PO 被標記斷貨，
--   20260702020000 的連動只處理「開團 → 顧客訂單」（經
--   purchase_request_campaigns），補貨申請的 PR 不掛 campaign，
--   整條 restock 鏈完全沒被連動：
--     - restock_requests 永遠卡在 approved_pr（店端顯示「處理中/在途」）
--     - RR-<id> 內部單品項維持 pending，繼續被算進撿貨需求
--   店端看不出「不用再等了」，HQ 也沒有任何單據推進。
--
-- 修法：
--   Part 1  restock_requests / restock_request_lines 加 stockout_at
--           （沿用 20260702020000 設計：不加 status 值，斷貨沿用既有
--           cancelled 語意 + stockout_at 區分「斷貨」與「一般取消」）。
--   Part 2  新 helper _stockout_propagate_restock(po_id, skus, operator, at)：
--     - 受影響明細 = 明細的 PR（明細層 linked_pr_id、舊資料 fallback 單頭）
--       有品項轉入本 PO、SKU 屬斷貨集合（qty_received=0）、未取消，
--       且「沒有任何歸屬出貨」— 歸屬原則同 20260715000020 /
--       _restock_wave_progress（wave ＋ 直派 transfer）。已有貨在途/
--       到店的明細不動（貨可能出自總倉現貨或其他 PO）。
--     - 明細：cancelled_at + stockout_at（cancelled_at 讓
--       _restock_wave_progress 的 active_lines 排除它，部分斷貨的申請
--       剩餘品項才能被出貨/收貨鏈正常推進）。
--     - RR- 內部單對應品項：pending → cancelled + stockout_at
--       （只動 pending，沿用 20260702020000 訂單品項規則）。
--     - 單頭：無剩餘有效明細 → status='cancelled' + stockout_at；
--       RR- 單全品項取消且沒收過錢 → 整單 cancelled + stockout_at。
--       仍有有效明細 → 重算 _restock_wave_progress，剩餘品項其實已
--       全數出貨(/到店) → 補推 shipped / received（同 20260717000000
--       backfill 規則），否則維持原狀態。
--   Part 3  rpc_stockout_purchase_order v3：v2 逐字保留，僅加
--           _stockout_propagate_restock 呼叫並把統計併入回傳 JSON。
--   Part 4  Backfill：已斷貨的 PO（stockout_at IS NOT NULL）重跑連動，
--           解卡存量申請（以 PO 的 stockout_at 當標記時間）。
--
-- 已知限制（本檔不處理）：PO 部分到貨的 SKU 不視為斷貨（同
--   20260702020000 規則），該明細申請量若大於實際到貨量，申請仍需
--   人工收尾 — 已到的貨走正常派貨，出貨量恆小於申請量時不會自動 received。
--
-- 基底版本（依 CLAUDE.md 規則 grep 全歷史）：
--   rpc_stockout_purchase_order ← 20260702020000_stockout_propagation.sql
--     （v2，唯一後續版本；20260702010000 為 v1）
--
-- Rollback：
--   - rpc_stockout_purchase_order 還原為 20260702020000 版本
--   - DROP FUNCTION public._stockout_propagate_restock(BIGINT, BIGINT[], UUID, TIMESTAMPTZ);
--   - ALTER TABLE restock_requests      DROP COLUMN IF EXISTS stockout_at;
--     ALTER TABLE restock_request_lines DROP COLUMN IF EXISTS stockout_at;
--   - backfill 如需回復（不建議）：本檔 RAISE NOTICE 會列出被改的單據。
-- ============================================================

-- ------------------------------------------------------------
-- Part 1: 斷貨標記欄位
-- ------------------------------------------------------------

ALTER TABLE restock_requests
  ADD COLUMN IF NOT EXISTS stockout_at TIMESTAMPTZ;

ALTER TABLE restock_request_lines
  ADD COLUMN IF NOT EXISTS stockout_at TIMESTAMPTZ;

COMMENT ON COLUMN restock_requests.stockout_at IS
  '整張申請因採購斷貨而取消的時間；非 NULL 時 status=cancelled 是因斷貨而非一般取消，UI 顯示「斷貨」';
COMMENT ON COLUMN restock_request_lines.stockout_at IS
  '採購斷貨取消標記；非 NULL 時 cancelled_at 是因斷貨而非「刪除不再補貨」，UI 顯示「斷貨」';

-- ------------------------------------------------------------
-- Part 2: helper — 單一 PO 斷貨對補貨鏈的連動
-- ------------------------------------------------------------

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

            UPDATE customer_orders co
               SET status     = 'ready',
                   ready_at   = NOW(),
                   updated_by = p_operator,
                   updated_at = NOW()
             WHERE co.tenant_id  = v_req.tenant_id
               AND co.order_no   = 'RR-' || v_req.id::TEXT
               AND co.order_kind = 'restock'
               AND co.status IN ('pending','confirmed','shipping');

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

COMMENT ON FUNCTION public._stockout_propagate_restock(BIGINT, BIGINT[], UUID, TIMESTAMPTZ) IS
  'PO 斷貨對補貨鏈的連動（rpc_stockout_purchase_order / backfill 內部用）：'
  '受影響且無歸屬出貨的補貨明細取消＋斷貨標記、RR- 內部單品項 pending→cancelled、'
  '全品項斷貨的申請 status→cancelled＋RR- 單整單取消；'
  '部分斷貨的申請重算 _restock_wave_progress 補推 shipped/received。';

-- ------------------------------------------------------------
-- Part 3: rpc_stockout_purchase_order v3 — 加補貨申請連動
--         （基底 20260702020000 逐字保留，僅加 helper 呼叫＋回傳統計）
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_stockout_purchase_order(
  p_po_id    BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_po              purchase_orders%ROWTYPE;
  v_received        NUMERIC(18,3);
  v_new_status      TEXT;
  v_stockout_skus   BIGINT[];
  v_campaign_ids    BIGINT[];
  v_ci_count        INTEGER := 0;
  v_coi_count       INTEGER := 0;
  v_order_count     INTEGER := 0;
  v_notified        INTEGER := 0;
  v_restock         JSONB;
BEGIN
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;

  IF v_po.status NOT IN ('sent','partially_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可標記斷貨（需為「已發送」或「部分到貨」）',
      v_po.po_no, v_po.status;
  END IF;

  SELECT COALESCE(SUM(qty_received), 0) INTO v_received
    FROM purchase_order_items
   WHERE po_id = p_po_id;

  v_new_status := CASE WHEN v_received > 0 THEN 'closed' ELSE 'cancelled' END;

  UPDATE purchase_orders
     SET status          = v_new_status,
         stockout_at     = NOW(),
         stockout_by     = p_operator,
         stockout_reason = NULLIF(BTRIM(p_reason), ''),
         updated_by      = p_operator,
         updated_at      = NOW()
   WHERE id = p_po_id;

  -- ── 連動範圍 ─────────────────────────────────────────────
  -- 斷貨 SKU：此 PO 完全沒到貨的品項（部分到貨的 SKU 走正常分貨）
  SELECT ARRAY_AGG(sku_id) INTO v_stockout_skus
    FROM purchase_order_items
   WHERE po_id = p_po_id
     AND COALESCE(qty_received, 0) = 0;

  -- 受影響開團：PO → PR → purchase_request_campaigns
  SELECT ARRAY_AGG(DISTINCT prc.campaign_id) INTO v_campaign_ids
    FROM purchase_order_items poi
    JOIN purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
   WHERE poi.po_id = p_po_id;

  IF v_stockout_skus IS NOT NULL AND v_campaign_ids IS NOT NULL THEN

    -- (a) 開團商品標記斷貨
    UPDATE campaign_items
       SET stockout_at = NOW(),
           updated_by  = p_operator,
           updated_at  = NOW()
     WHERE campaign_id = ANY(v_campaign_ids)
       AND sku_id = ANY(v_stockout_skus)
       AND stockout_at IS NULL;
    GET DIAGNOSTICS v_ci_count = ROW_COUNT;

    -- (b) 顧客訂單品項：pending → cancelled + 斷貨標記
    UPDATE customer_order_items coi
       SET status      = 'cancelled',
           stockout_at = NOW(),
           updated_by  = p_operator,
           updated_at  = NOW()
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND co.campaign_id = ANY(v_campaign_ids)
       AND coi.sku_id = ANY(v_stockout_skus)
       AND coi.status = 'pending'
       AND coi.stockout_at IS NULL;
    GET DIAGNOSTICS v_coi_count = ROW_COUNT;

    -- (c) 訂單單頭：全部品項都已取消/過期 + 沒收過錢 → 整單取消（斷貨標記）
    --     有付款 / 用過儲值金的單不自動取消，留給人工退款流程
    UPDATE customer_orders co
       SET status       = 'cancelled',
           cancelled_at = NOW(),
           stockout_at  = NOW(),
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
    WHERE co.campaign_id = ANY(v_campaign_ids)
      AND coi.sku_id = ANY(v_stockout_skus)
      AND coi.stockout_at IS NOT NULL
      AND co.member_id IS NOT NULL
    GROUP BY co.tenant_id, co.member_id;
    GET DIAGNOSTICS v_notified = ROW_COUNT;

  END IF;

  -- ── 20260720：補貨申請連動（restock PR 不掛 campaign，走獨立鏈）──
  v_restock := public._stockout_propagate_restock(
                 p_po_id, v_stockout_skus, p_operator, NOW());

  RETURN jsonb_build_object(
    'po_no',            v_po.po_no,
    'new_status',       v_new_status,
    'stockout_skus',    COALESCE(array_length(v_stockout_skus, 1), 0),
    'campaign_items',   v_ci_count,
    'order_items',      v_coi_count,
    'orders_cancelled', v_order_count,
    'members_notified', v_notified
  ) || COALESCE(v_restock, '{}'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_stockout_purchase_order TO authenticated;

COMMENT ON FUNCTION public.rpc_stockout_purchase_order IS
  '供應商斷貨：PO 結掉（有到貨→closed、無到貨→cancelled）＋連動標記開團商品 / '
  '顧客訂單品項（pending→cancelled+stockout_at）／未付款全斷訂單整單取消／寫入顧客通知；'
  '20260720 起連動補貨申請鏈（明細取消＋斷貨標記、RR- 內部單品項取消、'
  '全品項斷貨的申請 status→cancelled、部分斷貨補推 shipped/received）。';

-- ------------------------------------------------------------
-- Part 4: Backfill — 已斷貨的 PO 重跑補貨連動，解卡存量申請
-- ------------------------------------------------------------

DO $$
DECLARE
  v_uid       UUID;
  v_po        RECORD;
  v_skus      BIGINT[];
  v_res       JSONB;
  v_lines     INTEGER := 0;
  v_items     INTEGER := 0;
  v_cancelled INTEGER := 0;
  v_orders    INTEGER := 0;
  v_advanced  INTEGER := 0;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  FOR v_po IN
    SELECT id, po_no, stockout_at, stockout_by
      FROM purchase_orders
     WHERE stockout_at IS NOT NULL
     ORDER BY id
  LOOP
    SELECT ARRAY_AGG(sku_id) INTO v_skus
      FROM purchase_order_items
     WHERE po_id = v_po.id AND COALESCE(qty_received, 0) = 0;

    CONTINUE WHEN v_skus IS NULL;

    v_res := public._stockout_propagate_restock(
               v_po.id, v_skus, COALESCE(v_po.stockout_by, v_uid), v_po.stockout_at);

    IF (v_res ->> 'restock_lines')::INT > 0 THEN
      RAISE NOTICE 'Backfill %: %', v_po.po_no, v_res;
      v_lines     := v_lines     + (v_res ->> 'restock_lines')::INT;
      v_items     := v_items     + (v_res ->> 'restock_order_items')::INT;
      v_cancelled := v_cancelled + (v_res ->> 'restock_cancelled')::INT;
      v_orders    := v_orders    + (v_res ->> 'restock_orders_cancelled')::INT;
      v_advanced  := v_advanced  + (v_res ->> 'restock_advanced')::INT;
    END IF;
  END LOOP;

  RAISE NOTICE 'Backfill 合計：補貨明細斷貨 % 條、RR-單品項取消 % 條、申請取消 % 張、RR-單整單取消 % 張、申請補推 % 張',
    v_lines, v_items, v_cancelled, v_orders, v_advanced;
END $$;

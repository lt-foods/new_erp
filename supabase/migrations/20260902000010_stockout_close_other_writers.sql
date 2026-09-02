-- ============================================================
-- 20260902000010_stockout_close_other_writers.sql
--
-- 斷貨自動結案改判 fully_received —— **另外兩支寫入點**
--
-- ⚠️⚠️ 這一檔是阿寫 2026-09-02 施工時自行判斷追加的，
--      **不在 8/19 需求單 §七 第 4 步的範圍內**（那一步只寫 _refresh_po_status）。
--      CEO／老闆若不同意擴大範圍，**整檔刪掉即可**，20260902000000 不受影響。
--
-- ── 為什麼要追加 ──────────────────────────────────────────
-- 重新 grep 全歷史後，把採購單寫成 'closed' 的斷貨分支一共有三處（去重取最新版）：
--   git grep -nE "THEN 'closed' ELSE 'cancelled'" origin/main -- supabase/migrations
--     20260801000000:390  _refresh_po_status            ← 20260902000000 已改
--     20260801000000:551  rpc_adjust_po_item_received   ← 本檔 Part 1
--     20260812000000:468  _stockout_po_items            ← 本檔 Part 2
--   （20260702010000:149 / 20260702020000:94 / 20260720000010:303 / 20260808000000:281
--     都是 _stockout_po_items 的舊版，已被 20260812000000 覆寫，⛔ 不要動）
--
-- 只改 _refresh_po_status 的話，這兩條路還是會把單鎖回去：
--   1. _stockout_po_items（按「斷貨」那一刻跑）
--      —— 其餘品項**已經收滿了才按斷貨**時，是這一支結案，不是 _refresh_po_status。
--      ⭐ 這正是老闆講的實務情境：「廠商常常是最後一刻才通知斷貨」
--        （需求單 §10.3），那時貨多半早就收完了。⇒ 不改這支，等於沒修到主要路徑。
--   2. rpc_adjust_po_item_received（採購單編輯頁改「已收量」）
--      —— 改完已收量會重算母單狀態，同一條規則、同樣寫 'closed'。
--
-- ── 基底 ─────────────────────────────────────────────────
-- Part 1：20260801000000_po_item_stockout.sql:410-580 逐字保留，只改 :551
-- Part 2：20260812000000_po_stockout_split_and_restore.sql:233-507 逐字保留，只改 :468
-- 兩支都用「最新版查法」重驗過（2026-09-02，origin/main 17cd4166）：
--   rpc_adjust_po_item_received → 20260708000000 / 20260729000020 / 20260801000000（最新）
--   _stockout_po_items          → 20260808000000 / 20260812000000（最新）
--
-- ⛔ cancelled 那半一樣不動（完全沒到貨的仍然 cancelled）。
-- ⛔ _stockout_po_items 照舊在母單蓋 stockout_at —— 那是採購單列表「斷貨」分頁的
--    唯一判準（rpc_po_list 20260812000000:850 `$2='stockout' AND po.stockout_at IS NOT NULL`），
--    拿掉的話這些單會從斷貨分頁消失。
--
-- ── 回滾 ─────────────────────────────────────────────────
-- 公司\01_進行中\斷貨修法C_回滾_2026-09-02.sql
-- ============================================================

-- ------------------------------------------------------------
-- Part 1: rpc_adjust_po_item_received v4
--   基底 20260801000000:410-580（v3）逐字保留，只改步驟 7 的斷貨收尾分支
--   closed → fully_received（外加該段兩句過期註解）。
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
  --    品項斷貨收尾：未定案品項歸零且存在斷貨品項 → fully_received / cancelled
  --    （20260902000010 起由 closed 改成 fully_received，理由同 _refresh_po_status：
  --      closed 不在派貨需求 view 白名單 20260818000030:77，會鎖住已收未派的貨）
  SELECT SUM(qty_ordered), SUM(qty_received),
         COUNT(*) FILTER (WHERE stockout_at IS NULL
                            AND COALESCE(qty_received, 0) < qty_ordered),
         COUNT(*) FILTER (WHERE stockout_at IS NOT NULL)
    INTO v_tot_ord, v_tot_rcv, v_outstanding, v_stockout_cnt
    FROM purchase_order_items WHERE po_id = v_item.po_id;

  IF v_tot_rcv >= v_tot_ord THEN
    v_status := 'fully_received';
  ELSIF v_stockout_cnt > 0 AND v_outstanding = 0 THEN
    v_status := CASE WHEN v_tot_rcv > 0 THEN 'fully_received' ELSE 'cancelled' END;
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
  '已斷貨品項鎖定；品項斷貨後其餘品項收滿 → 母單自動 fully_received（20260902000010，'
  '原為 closed；closed 會讓已收未派的貨從派貨工作台消失）。';

-- ------------------------------------------------------------
-- Part 2: _stockout_po_items v4
--   基底 20260812000000:233-507（v3）逐字保留，只改「母單收尾」的斷貨分支
--   closed → fully_received（外加該段一句過期註解）。
--   ⛔ 拆斷貨單、下游連動（開團／客人訂單／補貨鏈／通知）、stockout_po_id 回填
--      通通不動。
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
      -- 還留著斷貨品項（部分到貨的那種）→ 同 _refresh_po_status 的規則
      -- ⚠️ 20260902000010 起由 closed 改成 fully_received：這一支是「其餘品項都收滿了
      --    才按斷貨」時真正結案的那一支（廠商最後一刻才通知斷貨＝實務上最常見的路），
      --    留著 closed 的話這條路仍然會把已收未派的貨鎖在總倉。
      v_new_status := CASE WHEN v_received > 0 THEN 'fully_received' ELSE 'cancelled' END;
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

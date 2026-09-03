-- ============================================================
-- 2026-09-03：取消收貨的沖銷條件改成只看 in_movement_id
--
-- 為什麼：同一天上線的「已收貨再調整實收數量」（rpc_adjust_received_transfer,
--   20260903000005）是**純紀錄**——它只改 qty_received，一筆庫存都不動
--   （老闆 2026-09-03：「調整只是對總倉的紀錄，月結跟提醒總倉多來貨或少來貨」，
--     而且要跟會員端／取貨完全脫鉤）。
--   於是會出現「qty_received = 0，但 in_movement_id 還指著當初真的入過庫的異動」。
--   rpc_unreceive_transfer 的逐項沖銷原本要求 qty_received > 0 才沖 ⇒ 這種列會被跳過
--   ⇒ 取消收貨後貨還在店裡、單子卻回到 shipped，再收一次就再入庫一遍＝憑空生貨。
--
-- 改了什麼：**只有那一個 IF 條件**（去掉 v_item.qty_received > 0）。
--   沖銷的量本來就取自 v_orig.quantity（當初入庫的異動本身），不是 qty_received，
--   所以拿掉這個條件之後沖的量一樣正確。
--   對既有資料是 no-op：收貨路徑（rpc_receive_transfer）只有在 qty_received > 0
--   時才寫 in_movement_id，「有 in_movement_id 卻 qty_received = 0」在調整功能
--   上線前不存在（已對正式庫查證）。
--
-- 基底：線上 pg_get_functiondef() 現況（2026-09-03 取出，與
--   20260901000020_shortage_return_booking_guards.sql 的版本逐字一致，已 diff 確認）。
--   本檔以該全文逐字複製、只動上述一行。
-- Rollback：把該 IF 條件改回 `IF v_item.qty_received > 0 AND v_item.in_movement_id IS NOT NULL THEN`
--   （即 20260901000020 的版本）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_unreceive_transfer(p_transfer_id bigint, p_operator uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
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
  v_surplus_orders    BIGINT[] := '{}'::BIGINT[];
  v_received_at       TIMESTAMPTZ;
  v_backorder_cleared INTEGER := 0;
  v_pullback_restored INTEGER := 0;
  v_hq                RECORD;
  v_hq_orig           stock_movements%ROWTYPE;
  v_hq_onhand         NUMERIC;
  v_marks_cleared     INTEGER := 0;
  v_restock_reversed  NUMERIC := 0;
  v_waves_cancelled   INTEGER := 0;
  v_batch_skus        BIGINT[];   -- 20260828：本批品項的 SKU（反向邏輯 C 前濾用）
  v_gate_candidates   BIGINT[];
  -- 2026-09-01 切片 1.5 補強：短收沖帳記帳單
  v_ret_cancelled     INTEGER := 0;
  v_locked            TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id, received_at
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id, v_received_at
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'received' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，僅「已收貨(received)」可退回取消收貨', p_transfer_id, v_status;
  END IF;

  -- ===== 守衛 A（2026-09-01）：沖帳記帳單本身，一律不准取消收貨 =====
  -- 這種單沒有實體貨（in_movement_id 全為 NULL），它 status='received' 只是為了
  -- 讓月結的退貨段沖得到帳。一旦被退回 shipped，它就會混進總倉收貨待辦
  -- （v_hq_inbox 20260818000040:118 把 shipped 的 return_to_hq 當 pending），
  -- 被照常收貨後 rpc_receive_transfer 會寫出真的入庫異動 ＝ 憑空生出不存在的貨。
  IF EXISTS (
    SELECT 1 FROM transfer_items ti
     WHERE ti.shortage_return_transfer_id = p_transfer_id) THEN
    RAISE EXCEPTION '調撥單 % 是短收沖帳用的記帳單，沒有實體貨，不能取消收貨、也不能再收一次。要撤銷這筆沖帳，請對「原本那張短收的調撥單」按取消收貨。', p_transfer_id;
  END IF;

  -- ===== 守衛 B-1（2026-09-01）：沖帳已落在鎖定月份 → 擋 =====
  -- 下面反向邏輯 H 會連帶作廢沖帳單，但鎖定月份的對帳單生成器不會重算
  -- （20260901000000:130 跳過 confirmed/settled/remitted/cancelled）
  -- ⇒ 硬放行的話，已鎖定的對帳單上會留下一筆沒有憑證的退款，而且永遠算不回來。
  SELECT string_agg(DISTINCT st.name || '（' || sms.status || '）', '、')
    INTO v_locked
    FROM transfer_items ti
    JOIN transfers rt  ON rt.id = ti.shortage_return_transfer_id
    JOIN stores    st  ON st.location_id = rt.source_location
    JOIN store_monthly_settlements sms
      ON sms.store_id = st.id
     AND sms.settlement_month = DATE_TRUNC('month', rt.received_at AT TIME ZONE 'Asia/Taipei')::DATE
   WHERE ti.transfer_id = p_transfer_id
     AND rt.status IN ('received','closed')
     AND sms.status IN ('confirmed','settled','remitted');
  IF v_locked IS NOT NULL THEN
    RAISE EXCEPTION '這張單的短收已經沖帳，而那筆沖帳所在月份的對帳單已經鎖定：%。鎖定後不能自動撤回，請聯繫總倉人工處理。', v_locked;
  END IF;

  -- ===== 邏輯 H 守衛（20260824030000）：總倉已做出不可逆的短少處理 → 擋 =====
  -- cancel_orders：客戶訂單已被取消（客人已收到通知），不可自動復原。
  -- redispatch 且重派單已離開 draft：貨已在重撿/重派路上，退回原單會兩頭錯帳。
  IF EXISTS (
    SELECT 1 FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id
       AND ti.shortage_resolution = 'cancel_orders') THEN
    RAISE EXCEPTION '總倉已依這張單的短少取消客戶訂單，無法一鍵返回 — 請聯繫總倉人工處理';
  END IF;
  IF EXISTS (
    SELECT 1 FROM transfer_items ti
     JOIN picking_waves pw ON pw.id = ti.shortage_redispatch_wave_id
     WHERE ti.transfer_id = p_transfer_id
       AND pw.status NOT IN ('draft','cancelled')) THEN
    RAISE EXCEPTION '總倉已為這張單的短少開重派撿貨單且已在進行中，無法一鍵返回 — 請先聯繫總倉處理重派單';
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
    -- 20260903000010：條件從「qty_received > 0 AND in_movement_id IS NOT NULL」
    -- 改成只看 in_movement_id。理由：已收貨的實收調整（rpc_adjust_received_transfer,
    -- 20260903000005）是**純紀錄**、不動庫存，所以一列可能是
    -- qty_received = 0 但 in_movement_id 還指著當初真的入過庫的那筆異動。
    -- 舊條件會把它跳過 ⇒ 取消收貨後貨還留在店裡、單子卻回到 shipped，
    -- 再收一次就再入庫一遍 ＝ 憑空生貨。
    -- 對既有資料是 no-op：收貨路徑只有 qty_received > 0 才寫 in_movement_id，
    -- 所以「in_movement_id IS NOT NULL 但 qty_received = 0」在調整功能上線前不存在。
    IF v_item.in_movement_id IS NOT NULL THEN
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

    -- 20260828000000：只對「有本批 SKU active 品項」的 ready 訂單重驗閘門。
    -- 閘門 ~8ms/張，原本掃該店**全部** ready 單（中和 2,280 張＝18 秒；線上
    -- 實測古華 788 張仍要 10.5 秒，8/28 06:44 / 07:06 兩次 DB 當機前都跑過它）。
    -- 撤銷收貨只把本批 SKU 的貨退回在途，沒有這些 SKU 的訂單閘門結果不變
    -- （撤銷前是 ready＝閘門 true，撤銷後仍 true），濾掉語意相同。
    -- **兩步走**：同一句 IN (子查詢) 會被 planner 把閘門下推到掃描層先跑，
    -- 等於沒濾（見 CLAUDE.md「昂貴函式當 WHERE 條件」）。
    SELECT ARRAY_AGG(DISTINCT ti.sku_id) INTO v_batch_skus
      FROM transfer_items ti WHERE ti.transfer_id = p_transfer_id;

    IF v_dest_store_id IS NOT NULL AND v_batch_skus IS NOT NULL THEN
      SELECT COALESCE(ARRAY_AGG(DISTINCT coi.order_id), '{}'::BIGINT[])
        INTO v_gate_candidates
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id
       WHERE co.tenant_id       = v_tenant_id
         AND co.pickup_store_id = v_dest_store_id
         AND co.status          = 'ready'
         AND coi.status IN ('pending','reserved','ready')
         AND coi.sku_id = ANY (v_batch_skus);

      FOR v_ord IN
        SELECT id FROM customer_orders
         WHERE id = ANY (v_gate_candidates)
           AND status = 'ready'
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

  -- ===== 反向邏輯 F（20260814(2)）：收貨多給掛進現貨池的列跟著沖銷 =====
  -- 手動收貨會把本批沒有訂單主人的剩餘量掛進【內部】xx 店現貨池
  -- （notes 標 [收貨多給|TF#<ids>]）。退回收貨後這批貨已不在店裡，
  -- 池子繼續掛著＝店員會把不存在的貨轉出去（20260811000030 忠順同型）。
  -- 已被轉單吃掉的部分（qty 遞減 / 整列 cancelled）不再處理 ——
  -- 重新收貨時 _grow_internal_pool 依當下自由量重算，不會重複掛回。
  WITH hit AS (
    UPDATE customer_order_items coi
       SET status     = 'cancelled',
           notes      = TRIM(BOTH E'\n' FROM COALESCE(coi.notes || E'\n', '')
                        || '[退回收貨沖銷|TF#' || p_transfer_id || ']'),
           updated_by = p_operator,
           updated_at = NOW()
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND co.tenant_id = v_tenant_id
       AND coi.status IN ('pending','reserved','ready')
       AND coi.notes ~ ('\[收貨多給\|TF#([0-9]+,)*' || p_transfer_id::TEXT || '(,[0-9]+)*\]')
    RETURNING coi.order_id
  )
  SELECT COALESCE(ARRAY_AGG(DISTINCT order_id), '{}'::BIGINT[])
    INTO v_surplus_orders FROM hit;

  IF cardinality(v_surplus_orders) > 0 THEN
    -- CLAUDE.md：品項改 cancelled 後接單頭收尾；OV- 容器整張被沖光且
    -- 一件都沒取過 → 整單 cancelled（不留空殼佔 trio 唯一索引 slot）。
    PERFORM public._close_orders_all_items_settled(v_surplus_orders, p_operator, NOW());

    UPDATE customer_orders co
       SET status     = 'cancelled',
           updated_by = p_operator,
           updated_at = NOW()
     WHERE co.id = ANY (v_surplus_orders)
       AND co.status IN ('pending','confirmed','ready','shipping')
       AND NOT EXISTS (SELECT 1 FROM customer_order_items x
                        WHERE x.order_id = co.id
                          AND x.status NOT IN ('cancelled','expired'));
  END IF;

  -- ===== 反向邏輯 G（20260824020000）：一鍵返回配單決策 =====
  -- 手動配單在收貨同一交易做了兩類決策，退回收貨要一起還原：
  --   G1 沒勾的候選標了 backorder_at（值 = 本單 received_at —— 同交易 NOW()
  --      恆等）→ 清掉，否則退回重來後那些人仍被鎖住。
  --   G2 沒勾的派貨中單被拉回 confirmed（updated_at 同樣 = received_at，該
  --      交易裡唯一會把單寫成 confirmed 的就是拉回）→ 還原 shipping，
  --      下次配單才會再被預設勾選。
  -- 範圍限本店 ＋ 本單 SKU；照 received_at 精準對時（timestamptz 微秒級，
  -- 別次操作不可能撞到同一個值）。
  IF v_dest_store_id IS NULL THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id AND location_id = v_dest_location
     LIMIT 1;
  END IF;

  IF v_received_at IS NOT NULL AND v_dest_store_id IS NOT NULL THEN
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = NOW()
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND co.tenant_id       = v_tenant_id
       AND co.pickup_store_id = v_dest_store_id
       AND coi.backorder_at   = v_received_at
       AND coi.sku_id IN (SELECT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id);
    GET DIAGNOSTICS v_backorder_cleared = ROW_COUNT;

    FOR v_ord IN
      SELECT co.id FROM customer_orders co
       WHERE co.tenant_id       = v_tenant_id
         AND co.pickup_store_id = v_dest_store_id
         AND co.status          = 'confirmed'
         AND co.updated_at      = v_received_at
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND EXISTS (SELECT 1 FROM customer_order_items coi
                      WHERE coi.order_id = co.id
                        AND coi.status IN ('pending','reserved','ready')
                        AND coi.sku_id IN (SELECT sku_id FROM transfer_items
                                            WHERE transfer_id = p_transfer_id))
       FOR UPDATE
    LOOP
      UPDATE customer_orders
         SET status = 'shipping', updated_by = p_operator, updated_at = NOW()
       WHERE id = v_ord.id;
      PERFORM rpc_log_order_status_change(v_ord.id, 'confirmed', 'shipping', p_operator,
        format('退回收貨（調撥 %s）：還原配單時拉回的派貨中狀態', p_transfer_id));
      v_pullback_restored := v_pullback_restored + 1;
    END LOOP;
  END IF;

  -- ===== 反向邏輯 H（20260824030000）：撤回開給總倉的短少/多收處理 =====
  -- 待處理中的短少/多收列不用動 —— v_hq_exceptions 兩個分支都掛
  -- t.status='received'，本函式把單退回 shipped 它們就自動從收件匣消失。
  -- 要撤的是總倉**已經按過處理**留下的東西：
  --   純標記（accept / vendor_claim / replenish / over_ack）→ 清掉，
  --     否則重新收貨再短少/多收時會被 shortage_resolution IS NOT NULL 濾掉、
  --     總倉再也看不到新的異常。
  --   restock_hq / redispatch 沖回總倉的庫存（transfer_cancel movement）→
  --     反向沖銷，否則重新全收之後總倉會多出這批幽靈庫存。
  --   redispatch 開的 draft 重派撿貨單 → 取消（離開 draft 的在守衛就擋掉了）。
  --   cancel_orders 在守衛擋下，走不到這裡。
  FOR v_hq IN
    SELECT ti.id, ti.sku_id, ti.shortage_resolution,
           ti.shortage_restock_movement_id, ti.shortage_redispatch_wave_id,
           ti.shortage_return_transfer_id
      FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id
       AND ti.shortage_resolution IS NOT NULL
     ORDER BY ti.id
     FOR UPDATE
  LOOP
    IF v_hq.shortage_restock_movement_id IS NOT NULL THEN
      SELECT * INTO v_hq_orig FROM stock_movements
       WHERE id = v_hq.shortage_restock_movement_id;
      IF v_hq_orig.id IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM stock_movements sm
                          WHERE sm.reverses = v_hq_orig.id) THEN
        SELECT on_hand INTO v_hq_onhand
          FROM stock_balances
         WHERE tenant_id   = v_hq_orig.tenant_id
           AND location_id = v_hq_orig.location_id
           AND sku_id      = v_hq_orig.sku_id
         FOR UPDATE;
        IF COALESCE(v_hq_onhand, 0) < v_hq_orig.quantity THEN
          RAISE EXCEPTION '總倉庫存不足以撤回短少沖回（SKU %：現有 %、需沖銷 %）— 沖回的貨可能已被派出，請聯繫總倉',
            v_hq_orig.sku_id, COALESCE(v_hq_onhand, 0), v_hq_orig.quantity;
        END IF;
        INSERT INTO stock_movements (
          tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
          source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
        ) VALUES (
          v_hq_orig.tenant_id, v_hq_orig.location_id, v_hq_orig.sku_id,
          -v_hq_orig.quantity, v_hq_orig.unit_cost, 'reversal',
          'transfer', p_transfer_id, v_hq.id, v_hq_orig.id,
          format('返回收貨撤回短少沖回 transfer=%s item=%s（沖銷 movement %s）',
                 p_transfer_id, v_hq.id, v_hq_orig.id),
          p_operator
        );
        v_restock_reversed := v_restock_reversed + v_hq_orig.quantity;
      END IF;
    END IF;

    IF v_hq.shortage_redispatch_wave_id IS NOT NULL THEN
      UPDATE picking_waves
         SET status = 'cancelled', updated_by = p_operator, updated_at = NOW()
       WHERE id = v_hq.shortage_redispatch_wave_id
         AND status = 'draft';
      IF FOUND THEN
        INSERT INTO picking_wave_audit_log (
          tenant_id, wave_id, action, after_value, note, created_by
        ) VALUES (
          v_tenant_id, v_hq.shortage_redispatch_wave_id, 'wave_cancelled',
          jsonb_build_object('unreceive_transfer_id', p_transfer_id,
                             'transfer_item_id', v_hq.id),
          '分店返回收貨，撤回短收重派', p_operator
        );
        v_waves_cancelled := v_waves_cancelled + 1;
      END IF;
    END IF;

    -- 2026-09-01：連帶作廢短收沖帳的記帳單（守衛 B-2）。
    -- ⛔ 只改狀態，不碰庫存 —— 那張單本來就沒有任何庫存異動，
    --   貨是由 transfer_cancel 記回去的（上面剛剛才反向沖銷掉）。
    -- F 段白名單只吃 received/closed ⇒ 改成 cancelled 就自動不再沖帳。
    IF v_hq.shortage_return_transfer_id IS NOT NULL THEN
      UPDATE transfers
         SET status     = 'cancelled',
             notes      = COALESCE(notes, '')
                          || ' [原單取消收貨，連帶作廢 '
                          || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD') || ']',
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = v_hq.shortage_return_transfer_id
         AND status IN ('received','closed');
      IF FOUND THEN
        v_ret_cancelled := v_ret_cancelled + 1;
      END IF;
    END IF;

    UPDATE transfer_items
       SET shortage_resolution          = NULL,
           shortage_resolution_at       = NULL,
           shortage_resolution_by       = NULL,
           shortage_resolution_notes    = NULL,
           shortage_restock_movement_id = NULL,
           shortage_redispatch_wave_id  = NULL,
           shortage_return_transfer_id  = NULL,
           updated_by                   = p_operator,
           updated_at                   = NOW()
     WHERE id = v_hq.id;
    v_marks_cleared := v_marks_cleared + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'transfer_id',        p_transfer_id,
    'items_reversed',     v_items_reversed,
    'total_qty_reversed', v_total_qty,
    'orders_reverted',    v_orders_reverted,
    'restock_reverted',   v_restock_reverted,
    'surplus_reversed',   COALESCE(cardinality(v_surplus_orders), 0),
    'backorder_cleared',  v_backorder_cleared,
    'pullback_restored',  v_pullback_restored,
    'hq_marks_cleared',   v_marks_cleared,
    'hq_restock_reversed_qty', v_restock_reversed,
    'hq_redispatch_cancelled', v_waves_cancelled,
    'shortage_return_cancelled', v_ret_cancelled
  );
END;
$function$;

-- ============================================================
-- 2026-09-02: 撤銷取貨要把儲值金退回去（rpc_undo_pickup）
--             ＋ 儲值金沖銷要同步訂單的 wallet_paid_amount（rpc_wallet_reverse）
--
-- 症狀（Alex 2026-09-02 回報）：門市誤點取貨、按「⎌ 撤銷取貨」之後，貨還回
--   門市庫存、品項回到待取，但客人被扣走的儲值金**沒有退回去**。
--
-- 根因 1：這是 20260704000010 的原始設計 ——「金流不動，錢留在訂單上，之後
--   正常取貨不用再付」。單張單一路取到底時這說得通，但誤點取貨的單常常不會
--   立刻再取（換人取、改期、直接取消），客人的餘額就一直少一截；
--   會員自己在 LIFF 看到的餘額也對不上。
--
-- 根因 2：店員的變通做法是去會員頁的儲值金明細按「↩ 沖銷」。
--   rpc_wallet_reverse 只寫 wallet_ledger + wallet_balances，**完全不碰
--   customer_orders**，於是錢退回去了、訂單卻還記著 wallet_paid_amount 與
--   payment_status='paid' → 下次取貨時 PickupDialog 看到 isPaid 就把可扣上限
--   算成 0（rpc_wallet_pay_order 也會 RAISE 'already paid'），貨等於白送。
--   線上就有一張：GRP-20260723-022-0090（order 61472，$185）。
--
-- 改法
--   A. rpc_undo_pickup：撤銷後把「這一趟取貨收的儲值金」用 rpc_wallet_refund
--      退回會員餘額（type='refund'、source_type='customer_order'），並同步扣減
--      wallet_paid_amount、清 payment_status / paid_at。
--        撤完整張單沒有 picked_up 品項 → 全退（誤點取貨的常見情形，也接得住
--          舊資料）。
--        還有別趟取走的品項 → 退 LEAST(wallet_paid_amount, 本趟收的儲值金)，
--          「本趟收的」＝掛在本單、落在（上一次取貨事件, 本次取貨事件] 時間窗內、
--          尚未被沖銷的 spend。前端一律「先 rpc_wallet_pay_order 再
--          rpc_record_pickup」（PickupDialog 與 pickup 頁 bulk 同一個順序），
--          這個窗口就是這趟的收款。
--      ⚠ 不用「已取品項價值」回推：同一張單前一趟收現金、這一趟刷儲值金時會被
--        回推成 0，該退的退不掉。
--      ⚠ 會員不是 active（merged/deleted）時**不退、也不擋撤銷** —— 貨的還原
--        才是這支 RPC 的本職，rpc_wallet_refund 對非 active 會員會 RAISE，直接
--        呼叫等於讓整筆 rollback。改成回傳 wallet_note 讓 UI 提示人工處理。
--   B. rpc_wallet_reverse：沖銷的 ledger 若是掛在訂單上的 spend / refund，
--      同步 customer_orders.wallet_paid_amount += change（spend 的 change 是負的
--      → 訂單少收；refund 的 change 是正的 → 訂單加回來），歸零時 payment_status
--      回 'unpaid' 並清 paid_at。
--   C. 補既有兩張卡住的單（見檔尾 DO 區塊，有守衛、重跑不會加倍）。
--
-- 沒有動的部分：庫存 reversal、品項還原、補償事件、狀態重算、權限 gate 全部
--   逐字保留。多次取貨仍是「一次撤一個事件」。
--
-- 基底版本：
--   rpc_undo_pickup    → 20260807000010_undo_pickup_allow_store_manager.sql
--                        （2026-09-02 對線上 pg_get_functiondef 核對過，一致）
--   rpc_wallet_reverse → 20260606000000_wallet_write_rpcs.sql（唯一版本，同上核對）
-- Rollback：重跑上面兩支 migration 內的 CREATE OR REPLACE FUNCTION 即回舊行為
--   （已退出去的 refund ledger 不會自動收回，需人工 reverse）；
--   audit_log 的 field CHECK 要改回 10 值版前，先確認沒有 wallet_paid_amount 列。
-- ============================================================

-- ----------------------------------------------------------------
-- 0. customer_order_audit_log.field 白名單加 'wallet_paid_amount'
--    （下面兩處要記錄訂單金流的變動；白名單擋著就整筆 rollback）
-- ----------------------------------------------------------------
ALTER TABLE customer_order_audit_log DROP CONSTRAINT IF EXISTS customer_order_audit_log_field_check;
ALTER TABLE customer_order_audit_log
  ADD CONSTRAINT customer_order_audit_log_field_check
  CHECK (field IN ('unit_price','item_notes','item_discount_amount','item_discount_percent',
                   'discount_amount','discount_percent','order_notes','qty','status','is_gift',
                   'wallet_paid_amount'));

-- ----------------------------------------------------------------
-- A. rpc_undo_pickup：撤銷取貨連帶退儲值金
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_undo_pickup(
  p_order_id bigint,
  p_operator uuid,
  p_reason   text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_order    customer_orders%ROWTYPE;
  v_event    order_pickup_events%ROWTYPE;
  v_item     customer_order_items%ROWTYPE;
  v_orig     stock_movements%ROWTYPE;
  v_item_id  BIGINT;
  v_rev_id   BIGINT;
  v_count    INT := 0;
  v_picked_remaining INT;
  v_new_status TEXT;
  v_undo_event_id BIGINT;
  v_now      TIMESTAMPTZ := NOW();
  -- 儲值金退款
  v_member_status  TEXT;
  v_prev_event_at  TIMESTAMPTZ;
  v_charged        NUMERIC := 0;
  v_wallet_refund  NUMERIC := 0;
  v_wallet_left    NUMERIC := 0;
  v_wallet_note    TEXT    := NULL;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: role「%」無權撤銷取貨', v_role;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_pickup:' || p_order_id::text));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 %', p_order_id;
  END IF;
  IF v_order.status IN ('cancelled','expired','transferred_out') THEN
    RAISE EXCEPTION '訂單 % 狀態為「%」，無法撤銷取貨', p_order_id, v_order.status;
  END IF;

  -- 最近一次取貨事件
  SELECT * INTO v_event
    FROM order_pickup_events
   WHERE order_id = p_order_id
     AND event_type IN ('picked_up','partial_pickup')
   ORDER BY id DESC
   LIMIT 1;
  IF v_event.id IS NULL THEN
    RAISE EXCEPTION '訂單 % 沒有取貨事件可撤銷', p_order_id;
  END IF;

  -- 逐品項：驗證 → reversal 沖庫存 → 還原 pending
  FOR v_item_id IN SELECT (jsonb_array_elements_text(v_event.item_ids))::bigint
  LOOP
    SELECT * INTO v_item FROM customer_order_items
     WHERE id = v_item_id AND order_id = p_order_id FOR UPDATE;
    IF v_item.id IS NULL THEN
      RAISE EXCEPTION '取貨事件 #% 的品項 % 不存在', v_event.id, v_item_id;
    END IF;
    IF v_item.status <> 'picked_up' OR v_item.pickup_movement_id IS NULL THEN
      RAISE EXCEPTION '品項 % 狀態「%」非已取貨，無法撤銷（事件 #% 可能已撤銷過）',
        v_item_id, v_item.status, v_event.id;
    END IF;

    SELECT * INTO v_orig FROM stock_movements WHERE id = v_item.pickup_movement_id;
    IF v_orig.id IS NULL
       OR v_orig.movement_type <> 'sale'
       OR v_orig.source_doc_type <> 'customer_order'
       OR v_orig.source_doc_id <> p_order_id THEN
      RAISE EXCEPTION '品項 % 的 movement % 非本單取貨扣帳，無法撤銷', v_item_id, v_item.pickup_movement_id;
    END IF;
    IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
      RAISE EXCEPTION 'movement % 已被沖銷過，不可重複撤銷', v_orig.id;
    END IF;

    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
      source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
    ) VALUES (
      v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
      -v_orig.quantity, v_orig.unit_cost, 'reversal',
      'customer_order', p_order_id, v_item.id, v_orig.id,
      format('撤銷取貨 order=%s item=%s (沖銷 movement %s, 取貨事件 #%s)%s',
             p_order_id, v_item.id, v_orig.id, v_event.id,
             COALESCE('：' || NULLIF(TRIM(p_reason), ''), '')),
      p_operator
    ) RETURNING id INTO v_rev_id;

    UPDATE customer_order_items
       SET status = 'pending',
           pickup_movement_id = NULL,
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_item.id;

    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_order.tenant_id, p_order_id, 'item', v_item.id, 'status',
      to_jsonb('picked_up'::text), to_jsonb('pending'::text),
      format('撤銷取貨（事件 #%s），庫存以 reversal movement %s 沖回%s',
             v_event.id, v_rev_id, COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
      p_operator
    );

    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION '取貨事件 #% 無品項可撤銷', v_event.id;
  END IF;

  -- 補償事件（order_pickup_events 為 append-only，不刪原事件）
  INSERT INTO order_pickup_events (
    tenant_id, order_id, pickup_store_id, event_type, item_ids, notes, created_by
  ) VALUES (
    v_order.tenant_id, p_order_id, v_order.pickup_store_id, 'pickup_undone',
    v_event.item_ids,
    format('撤銷取貨事件 #%s%s', v_event.id, COALESCE('：' || NULLIF(TRIM(p_reason), ''), '')),
    p_operator
  ) RETURNING id INTO v_undo_event_id;

  -- 重算訂單狀態。
  -- 先把訂單置為中性 active 狀態：is_order_pickup_ready 對 completed 等終態
  -- 一律回 false，必須先脫離 completed 再判定「是否全到貨」。
  UPDATE customer_orders
     SET status       = 'shipping',
         completed_at = NULL,
         updated_by   = p_operator,
         updated_at   = v_now
   WHERE id = p_order_id;

  SELECT COUNT(*) INTO v_picked_remaining
    FROM customer_order_items
   WHERE order_id = p_order_id AND status = 'picked_up';

  IF v_picked_remaining > 0 THEN
    v_new_status := 'partially_completed';
  ELSIF public.is_order_pickup_ready(p_order_id) THEN
    v_new_status := 'ready';
  ELSE
    v_new_status := 'shipping';
  END IF;

  IF v_new_status <> 'shipping' THEN
    UPDATE customer_orders
       SET status     = v_new_status,
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  END IF;

  -- ------------------------------------------------------------
  -- 儲值金：把這一次取貨收的錢退回會員餘額（2026-09-02 新增）
  --   退款額 = LEAST(訂單還記著的 wallet_paid_amount, 本次取貨收的儲值金)
  --   「本次取貨收的」= 掛在本單、落在（上一次取貨事件, 本次取貨事件] 這個
  --   時間窗內、且尚未被沖銷的 spend —— 前端一律「先扣款再寫 pickup」
  --   （PickupDialog / pickup 頁 bulkPickAllConfirmed 同一個順序），所以這個
  --   窗口就是這趟取貨的收款。不用「已取品項價值」回推：同一張單前一趟收現金、
  --   這一趟刷儲值金時會回推成 0，該退的退不掉。
  --   撤完整張單已無 picked_up 品項時直接全退 —— 誤點取貨的常見情形，
  --   也接得住舊資料 / 對不上時間窗的收款。
  -- ------------------------------------------------------------
  v_wallet_left := COALESCE(v_order.wallet_paid_amount, 0);
  IF v_wallet_left > 0 AND v_order.member_id IS NOT NULL THEN
    IF v_picked_remaining = 0 THEN
      v_wallet_refund := v_wallet_left;
    ELSE
      SELECT MAX(e.created_at) INTO v_prev_event_at
        FROM order_pickup_events e
       WHERE e.order_id = p_order_id
         AND e.event_type IN ('picked_up','partial_pickup')
         AND e.id < v_event.id;

      SELECT COALESCE(SUM(-w.change), 0) INTO v_charged
        FROM wallet_ledger w
       WHERE w.tenant_id    = v_order.tenant_id
         AND w.source_type  = 'customer_order'
         AND w.source_id    = p_order_id
         AND w.type         = 'spend'
         AND w.created_at  <= v_event.created_at
         AND (v_prev_event_at IS NULL OR w.created_at > v_prev_event_at)
         AND NOT EXISTS (SELECT 1 FROM wallet_ledger r WHERE r.reverses = w.id);

      v_wallet_refund := GREATEST(0, LEAST(v_wallet_left, v_charged));
    END IF;

    IF v_wallet_refund > 0 THEN
      SELECT status INTO v_member_status
        FROM members
       WHERE id = v_order.member_id AND tenant_id = v_order.tenant_id;

      IF COALESCE(v_member_status, '') <> 'active' THEN
        -- rpc_wallet_refund 對非 active 會員會 RAISE；不能讓金流把貨的還原一起 rollback
        v_wallet_note := format('會員狀態為「%s」，$%s 儲值金未自動退回，請人工處理',
                                COALESCE(v_member_status, '查無此會員'), v_wallet_refund);
        v_wallet_refund := 0;
      ELSE
        PERFORM public.rpc_wallet_refund(
          v_order.tenant_id,
          v_order.member_id,
          v_wallet_refund,
          'customer_order',
          p_order_id,
          format('撤銷取貨 %s（取貨事件 #%s）%s',
                 v_order.order_no, v_event.id,
                 COALESCE('：' || NULLIF(TRIM(p_reason), ''), '')),
          p_operator
        );

        v_wallet_left := v_wallet_left - v_wallet_refund;

        -- 退了任何一塊錢就代表這張單已經不是付清狀態（撤銷後必有待取品項）
        UPDATE customer_orders
           SET wallet_paid_amount = v_wallet_left,
               payment_status     = 'unpaid',
               paid_at            = NULL,
               updated_by         = p_operator,
               updated_at         = v_now
         WHERE id = p_order_id;

        INSERT INTO customer_order_audit_log (
          tenant_id, order_id, entity_type, entity_id, field,
          before_value, after_value, edit_reason, operator_id
        ) VALUES (
          v_order.tenant_id, p_order_id, 'order', p_order_id, 'wallet_paid_amount',
          to_jsonb(v_order.wallet_paid_amount), to_jsonb(v_wallet_left),
          format('撤銷取貨（事件 #%s）退回儲值金 $%s 到會員餘額%s',
                 v_event.id, v_wallet_refund,
                 COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
          p_operator
        );
      END IF;
    END IF;
  END IF;

  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_order.tenant_id, p_order_id, 'order', p_order_id, 'status',
    to_jsonb(v_order.status), to_jsonb(v_new_status),
    format('撤銷取貨（事件 #%s → 補償事件 #%s）%s',
           v_event.id, v_undo_event_id, COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
    p_operator
  );

  RETURN jsonb_build_object(
    'undone_event_id',    v_event.id,
    'undo_event_id',      v_undo_event_id,
    'items_restored',     v_count,
    'new_status',         v_new_status,
    'wallet_refunded',    v_wallet_refund,
    'wallet_paid_amount', v_wallet_left,
    'wallet_note',        v_wallet_note
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_undo_pickup(bigint, uuid, text) IS
  '撤銷最近一次取貨：庫存 reversal 沖回、品項還原 pending、補償事件、狀態重算，'
  '並把沒有已取品項撐著的儲值金退回會員餘額（20260902040000）';

GRANT EXECUTE ON FUNCTION public.rpc_undo_pickup(bigint, uuid, text) TO authenticated;

-- ----------------------------------------------------------------
-- B. rpc_wallet_reverse：沖銷掛在訂單上的 spend / refund 要同步訂單金流
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_wallet_reverse(
  p_tenant_id UUID,
  p_ledger_id BIGINT,
  p_reason    TEXT,
  p_operator  UUID
) RETURNS BIGINT AS $$
DECLARE
  v_orig wallet_ledger;
  v_cur_balance NUMERIC;
  v_new_balance NUMERIC;
  v_id BIGINT;
  v_already_reversed BOOLEAN;
  v_order_paid NUMERIC;
BEGIN
  IF p_reason IS NULL OR LENGTH(TRIM(p_reason)) < 4 THEN
    RAISE EXCEPTION 'reason required (>=4 chars)';
  END IF;

  -- 鎖原 ledger row (FOR UPDATE 只是 row-lock，不觸發 UPDATE trigger)
  SELECT * INTO v_orig FROM wallet_ledger
   WHERE id = p_ledger_id AND tenant_id = p_tenant_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'ledger % not found', p_ledger_id;
  END IF;

  -- 拒絕反向 reversal
  IF v_orig.type = 'reversal' THEN
    RAISE EXCEPTION 'cannot reverse a reversal (id=%)', p_ledger_id;
  END IF;

  -- 拒絕重複反向 (用 reverses 反查；不寫 reversed_by 避開 append-only trigger)
  SELECT EXISTS(
    SELECT 1 FROM wallet_ledger
     WHERE tenant_id = p_tenant_id AND reverses = p_ledger_id
  ) INTO v_already_reversed;
  IF v_already_reversed THEN
    RAISE EXCEPTION 'ledger % already reversed', p_ledger_id;
  END IF;

  -- 鎖餘額 row
  SELECT balance INTO v_cur_balance FROM wallet_balances
  WHERE tenant_id = p_tenant_id AND member_id = v_orig.member_id FOR UPDATE;
  IF v_cur_balance IS NULL THEN
    RAISE EXCEPTION 'wallet_balances row missing for member %', v_orig.member_id;
  END IF;

  v_new_balance := v_cur_balance - v_orig.change;
  IF v_new_balance < 0 THEN
    RAISE EXCEPTION 'reverse would make balance negative: current=%, undoing=%',
      v_cur_balance, v_orig.change;
  END IF;

  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after,
                             type, source_type, source_id, reverses,
                             reason, operator_id)
  VALUES (p_tenant_id, v_orig.member_id, -v_orig.change, v_new_balance,
          'reversal', v_orig.source_type, v_orig.source_id, p_ledger_id,
          p_reason, p_operator)
  RETURNING id INTO v_id;

  UPDATE wallet_balances
     SET balance = v_new_balance, version = version + 1,
         last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND member_id = v_orig.member_id;

  -- 2026-09-02：掛在訂單上的 spend / refund 被沖銷時，訂單身上那本帳要跟著動，
  -- 否則錢退回會員了、訂單還記著 wallet_paid_amount / payment_status='paid'
  -- → 下次取貨扣不到款，貨白送（線上 order 61472 就是這樣）。
  --   spend.change 為負 → wallet_paid_amount 減；refund.change 為正 → 加回來。
  IF v_orig.type IN ('spend','refund')
     AND v_orig.source_type = 'customer_order'
     AND v_orig.source_id IS NOT NULL THEN
    SELECT GREATEST(0, COALESCE(co.wallet_paid_amount, 0) + v_orig.change)
      INTO v_order_paid
      FROM customer_orders co
     WHERE co.id = v_orig.source_id AND co.tenant_id = p_tenant_id
     FOR UPDATE;

    IF v_order_paid IS NOT NULL THEN
      UPDATE customer_orders
         SET wallet_paid_amount = v_order_paid,
             payment_status = CASE WHEN v_order_paid <= 0 THEN 'unpaid' ELSE payment_status END,
             paid_at        = CASE WHEN v_order_paid <= 0 THEN NULL ELSE paid_at END,
             updated_by     = p_operator,
             updated_at     = NOW()
       WHERE id = v_orig.source_id AND tenant_id = p_tenant_id;
    END IF;
  END IF;

  INSERT INTO member_audit_log (tenant_id, entity_type, entity_id, action,
                                before_value, after_value, reason, operator_id)
  VALUES (p_tenant_id, 'wallet', v_orig.member_id, 'reverse',
          jsonb_build_object('balance', v_cur_balance,
                             'reversing_ledger_id', p_ledger_id,
                             'reversing_type', v_orig.type,
                             'reversing_change', v_orig.change),
          jsonb_build_object('balance', v_new_balance,
                             'new_ledger_id', v_id,
                             'order_wallet_paid_amount', v_order_paid),
          p_reason, p_operator);

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.rpc_wallet_reverse(UUID, BIGINT, TEXT, UUID) IS
  '沖銷一筆 wallet_ledger（append-only，插反向列不改原列）；'
  '掛在訂單上的 spend / refund 會同步 customer_orders.wallet_paid_amount / '
  'payment_status（20260902040000）';

GRANT EXECUTE ON FUNCTION public.rpc_wallet_reverse(UUID, BIGINT, TEXT, UUID) TO authenticated;

-- ----------------------------------------------------------------
-- C. 補既有卡住的兩張單（2026-09-02 全站掃描的結果，其餘 9 張撤銷後都已
--    重新取貨、錢是真的收掉了，不用動）
--      order 51718 GRP-20260715-009-0001：撤銷後 $77 沒退，會員餘額少一截
--      order 61472 GRP-20260723-022-0090：店員手動沖銷過 $185（錢已回會員），
--        但訂單還記著 paid → 只清訂單那半，不能再退一次
--    兩段都有守衛，重跑不會加倍。
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_o customer_orders%ROWTYPE;
BEGIN
  -- 51718：錢還沒退 → 退款 + 清訂單
  SELECT * INTO v_o FROM customer_orders WHERE id = 51718 FOR UPDATE;
  IF v_o.id IS NOT NULL
     AND v_o.wallet_paid_amount = 77
     AND NOT EXISTS (
       SELECT 1 FROM customer_order_items i
        WHERE i.order_id = v_o.id AND i.status = 'picked_up')
     AND NOT EXISTS (
       SELECT 1 FROM wallet_ledger w
        WHERE w.source_type = 'customer_order' AND w.source_id = v_o.id
          AND w.type IN ('refund','reversal'))
  THEN
    PERFORM public.rpc_wallet_refund(
      v_o.tenant_id, v_o.member_id, 77,
      'customer_order', v_o.id,
      '補退：2026-09-02 撤銷取貨當時未退儲值金（20260902040000）',
      v_o.updated_by
    );
    UPDATE customer_orders
       SET wallet_paid_amount = 0, payment_status = 'unpaid', paid_at = NULL,
           updated_at = NOW()
     WHERE id = v_o.id;
    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_o.tenant_id, v_o.id, 'order', v_o.id, 'wallet_paid_amount',
      to_jsonb(77::numeric), to_jsonb(0::numeric),
      '補退撤銷取貨未退的儲值金（20260902040000）', v_o.updated_by
    );
    RAISE NOTICE 'order 51718: refunded 77';
  END IF;

  -- 61472：錢已經被手動沖銷回會員 → 只清訂單這半
  SELECT * INTO v_o FROM customer_orders WHERE id = 61472 FOR UPDATE;
  IF v_o.id IS NOT NULL
     AND v_o.wallet_paid_amount = 185
     AND NOT EXISTS (
       SELECT 1 FROM customer_order_items i
        WHERE i.order_id = v_o.id AND i.status = 'picked_up')
     AND EXISTS (
       SELECT 1 FROM wallet_ledger w
        WHERE w.source_type = 'customer_order' AND w.source_id = v_o.id
          AND w.type = 'reversal' AND w.change = 185)
  THEN
    UPDATE customer_orders
       SET wallet_paid_amount = 0, payment_status = 'unpaid', paid_at = NULL,
           updated_at = NOW()
     WHERE id = v_o.id;
    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_o.tenant_id, v_o.id, 'order', v_o.id, 'wallet_paid_amount',
      to_jsonb(185::numeric), to_jsonb(0::numeric),
      '儲值金已於 2026-09-02 手動沖銷退回會員，訂單金流補齊（20260902040000）',
      v_o.updated_by
    );
    RAISE NOTICE 'order 61472: cleared wallet_paid_amount';
  END IF;
END $$;

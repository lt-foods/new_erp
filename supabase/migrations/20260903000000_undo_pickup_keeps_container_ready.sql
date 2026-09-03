-- ============================================================
-- 2026-09-03: 撤銷取貨不可以把「內部容器單」踢出 ready（rpc_undo_pickup）
-- ============================================================
-- 症狀（Alex 2026-09-03 回報）：松山店的【內部】現貨池 OV-2-0001 按「轉給別人」，
--   勾了「金山老街阿里巷阿公手捲蛋捲」按確認轉出 → 被擋下，店裡明明有 2 件庫存。
--   彈窗還顯示「貨還沒到店：目前僅可同店換客人」，接收店被鎖成松山店本身。
--
-- 根因：這張池子單的 status 是 'shipping'，不是 'ready'。
--   rpc_transfer_order_partial 對「status NOT IN (ready, partially_completed)」的來源單
--   只放行同店換客人，且要求 order_kind='normal'（20260807000000 起的 gate）——
--   池子單是 order_kind='restock'，於是逐字撞上
--   「訂單 % 不是一般團購單（restock），須等分店收貨後再轉單」。整店的池子一件都轉不出去。
--
--   而它會變成 'shipping'，是 rpc_undo_pickup 幹的（audit_log #76375：
--   partially_completed → shipping，理由「撤銷取貨（事件 #53610 → 補償事件 #53640）」）：
--   撤銷取貨後重算單頭時，只有 `is_order_pickup_ready(order)` 為真才回 ready，
--   否則落在中性的 'shipping'。**而容器單的 ready 從來不是閘門給的** ——
--   OV- 由 _get_or_create_surplus_pool_order / _grow_internal_pool 直接寫
--   （20260814010000：「單頭 ready 以便轉單」），RR- 由 _settle_restock_ride_along 推。
--   閘門對容器單本來就答不出 true：is_order_pickup_ready 是全品項 AND，
--   而松山池子裡掛著兩列 MISC-01「虛擬轉貨商品」（自由轉貨用的虛擬 SKU，永遠沒有實體
--   庫存、閘門永遠 false），一列就把整張單的閘門釘死 —— 其餘 29 列（含這條蛋捲，
--   單品閘門 = true、on_hand = 2）陪葬。
--
--   同一張單被這樣踢出 ready 已經是第三次（8/28、9/1、9/3）。前兩次是碰巧有新的收貨
--   多給進池子、_get_or_create_surplus_pool_order 順手把它寫回 ready 才自己好的；
--   沒有那趟收貨就永遠卡著，而且畫面不會報錯，只有按下轉出才看得到那句錯誤訊息。
--
-- 改法：重算單頭時多一條分支 —— 非一般團購單（order_kind <> 'normal'：OV-/RR- 容器、
--   offset 減抵單）撤銷取貨後回 'ready'，不看全品項閘門。
--   理由：撤銷取貨已經用 reversal movement 把貨沖回本店 on_hand，貨就在店裡；
--   這些單的 ready 本來就由各自的建立/收尾路徑維護，閘門不是它們的真相來源。
--   守衛：身上還有未收的調撥（draft/shipped）就不套用 —— 那種單的 ready 要等
--   rpc_receive_transfer 收貨才給，不能在這裡搶跑。
--   一般團購單（normal）一字未動，維持原本「閘門說了算」。
--
-- 逐字取自線上 pg_get_functiondef 後只插入那一個 ELSIF，其餘一行未動。
-- 基底版本：20260902040000_undo_pickup_refunds_wallet.sql
--   （2026-09-03 對線上核對過，一致）
-- Rollback：重跑 20260902040000 內的 rpc_undo_pickup CREATE OR REPLACE。
-- 檔尾 DO 區塊補回已經卡住的 OV-2-0001（有守衛，重跑不會重複）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_undo_pickup(p_order_id bigint, p_operator uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  ELSIF COALESCE(v_order.order_kind, 'normal') <> 'normal'
    AND NOT EXISTS (
          SELECT 1 FROM transfers t
           WHERE t.customer_order_id = p_order_id
             AND t.status IN ('draft','shipped')
        ) THEN
    -- 非一般團購單（OV- 現貨池 / RR- ride-along / offset 減抵單）：ready 由各自的
    -- 建立、收尾路徑維護，全品項閘門不是它們的真相來源（池子裡一列 MISC-01
    -- 虛擬轉貨商品就能把整張單釘成 false）。撤銷取貨已經用 reversal 把貨沖回本店
    -- on_hand，貨就在店裡 → 回 ready，否則整店的池子會被 rpc_transfer_order_*
    -- 的「order_kind 必須是 normal」gate 擋死、一件都轉不出去。
    -- 身上還有未收調撥（draft/shipped）時不套用：那種單要等收貨才給 ready。
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

COMMENT ON FUNCTION public.rpc_undo_pickup(BIGINT, UUID, TEXT) IS
  '撤銷最近一次取貨：reversal 沖回庫存、品項回 pending、補償事件、退回該趟收的儲值金，'
  '並重算單頭。非一般團購單（容器單 / 減抵單）身上沒有未收調撥時一律回 ready —— '
  '它們的 ready 由建立/收尾路徑維護，全品項閘門不是真相來源（20260903000000）。';


-- ----------------------------------------------------------------
-- 補既有卡住的容器單：撤銷取貨踢出 ready、又沒有下一趟收貨把它寫回去的
--   （線上只有 OV-2-0001 一張；RR- 那幾張 shipping 沒有 active 品項、不動它們）
-- 守衛：order_kind='restock' + 還有 active 品項 + 沒有未收調撥 + 沒有 picked_up 品項
--   （有 picked_up 的正解是 partially_completed，不在這裡處理）
-- ----------------------------------------------------------------
DO $fix$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT co.id, co.order_no, co.status
      FROM customer_orders co
     WHERE co.order_kind = 'restock'
       AND co.status     = 'shipping'
       AND EXISTS (SELECT 1 FROM customer_order_items i
                    WHERE i.order_id = co.id
                      AND i.status IN ('pending','reserved','ready'))
       AND NOT EXISTS (SELECT 1 FROM customer_order_items i
                        WHERE i.order_id = co.id AND i.status = 'picked_up')
       AND NOT EXISTS (SELECT 1 FROM transfers t
                        WHERE t.customer_order_id = co.id
                          AND t.status IN ('draft','shipped'))
  LOOP
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = COALESCE(ready_at, NOW()),
           updated_at = NOW()
     WHERE id = r.id;

    -- operator_id 是 NOT NULL；補資料沒有操作者，掛回這張單最後的操作者
    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    )
    SELECT co.tenant_id, co.id, 'order', co.id, 'status',
           to_jsonb(r.status), to_jsonb('ready'::text),
           '20260903000000：撤銷取貨誤把內部容器單踢出 ready，補回可轉單狀態',
           COALESCE(co.updated_by, co.created_by)
      FROM customer_orders co
     WHERE co.id = r.id
       AND COALESCE(co.updated_by, co.created_by) IS NOT NULL;

    RAISE NOTICE '補回容器單 % (#%)：% → ready', r.order_no, r.id, r.status;
  END LOOP;
END
$fix$;

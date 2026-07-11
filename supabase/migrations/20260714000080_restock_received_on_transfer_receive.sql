-- ============================================================
-- 2026-07-12: 店家收貨時，把 linked 補貨申請推到「已收貨」
--
-- 問題：
--   restock_requests.status 有 'received' 值、列表也有「已收貨」分頁，
--   但整條收貨鏈（rpc_receive_transfer / rpc_receive_transfer_batch /
--   前端）從來沒有任何人把補貨申請從 shipped 推到 received。
--   實例：RESTOCK#18 的轉貨單 TR2607060160 於 2026-07-07 由松山店收貨
--   （status=received），補貨申請卻永遠卡在「已出貨」。
--
-- 修法：
--   1. rpc_receive_transfer 加「邏輯 D」：收貨後把 linked_transfer_id
--      指向本單、status IN ('shipped','approved_transfer') 的補貨申請
--      推到 'received'（approved_transfer 為 legacy 防禦：20260515000004
--      之後直派皆直接 shipped）。batch 版內部呼叫本函式，一併生效。
--   2. rpc_unreceive_transfer 加反向：退回收貨時 received → shipped。
--   3. Backfill：已卡住的單（status='shipped' 且 linked transfer 已
--      received/closed）補推到 received。
--
--   注意：wave 流程的補貨（approved_transfer、linked_transfer_id=NULL、
--   靠 customer_order 走波次）不在本修範圍 — 該路徑的 transfer 沒有
--   back-link 到 restock，是另一個獨立缺口。
--
-- 基底版本：
--   rpc_receive_transfer   = 20260703000000（線上現行版，整支複製 + 邏輯 D）
--   rpc_unreceive_transfer = 20260711000000（線上現行版，整支複製 + 反向）
-- Rollback：
--   重跑 20260703000000 的 rpc_receive_transfer 與
--   20260711000000 的 rpc_unreceive_transfer 定義即可（本檔僅追加邏輯，
--   不改既有行為）；backfill 如需回復：
--   UPDATE restock_requests SET status='shipped'
--    WHERE status='received' AND linked_transfer_id IS NOT NULL; （不建議）
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_receive_transfer + 邏輯 D
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(p_transfer_id bigint, p_lines jsonb, p_operator uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id            UUID;
  v_status               TEXT;
  v_transfer_type        TEXT;
  v_dest_location        BIGINT;
  v_existing_notes       TEXT;
  v_customer_order_id    BIGINT;
  v_next_transfer_id     BIGINT;
  v_item                 RECORD;
  v_qty_received         NUMERIC;
  v_unit_cost            NUMERIC;
  v_in_mov_id            BIGINT;
  v_total_qty            NUMERIC := 0;
  v_total_variance       NUMERIC := 0;
  v_items_received       INTEGER := 0;
  v_lines_consumed       INTEGER := 0;
  v_lines_count          INTEGER;
  v_orders_advanced      INTEGER := 0;
  v_next_shipped         BOOLEAN := FALSE;
  v_leg2                 transfers%ROWTYPE;
  v_leg2_item            RECORD;
  v_leg2_mov             BIGINT;
  v_dest_store_id        BIGINT;
  v_restock_received     INTEGER := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is in status %, expected shipped', p_transfer_id, v_status;
  END IF;

  IF p_lines IS NOT NULL THEN
    v_lines_count := jsonb_array_length(p_lines);
    IF EXISTS (
      SELECT 1
        FROM jsonb_array_elements(p_lines) AS l
        LEFT JOIN transfer_items ti
          ON ti.id = (l->>'transfer_item_id')::BIGINT
         AND ti.transfer_id = p_transfer_id
       WHERE ti.id IS NULL
    ) THEN
      RAISE EXCEPTION 'p_lines contains transfer_item_id not belonging to transfer %', p_transfer_id;
    END IF;
  END IF;

  -- ===== 原有邏輯：寫 qty_received + dest_location inbound =====
  FOR v_item IN
    SELECT ti.id, ti.sku_id, ti.qty_shipped, sm.unit_cost AS out_cost
      FROM transfer_items ti
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE ti.transfer_id = p_transfer_id
     ORDER BY ti.id
  LOOP
    v_qty_received := v_item.qty_shipped;

    IF p_lines IS NOT NULL THEN
      SELECT (l->>'qty_received')::NUMERIC
        INTO v_qty_received
        FROM jsonb_array_elements(p_lines) AS l
       WHERE (l->>'transfer_item_id')::BIGINT = v_item.id
       LIMIT 1;

      IF FOUND THEN
        v_lines_consumed := v_lines_consumed + 1;
      ELSE
        v_qty_received := v_item.qty_shipped;
      END IF;
    END IF;

    IF v_qty_received IS NULL OR v_qty_received < 0 THEN
      RAISE EXCEPTION 'transfer_item % qty_received must be >= 0, got %', v_item.id, v_qty_received;
    END IF;
    IF v_qty_received > v_item.qty_shipped THEN
      RAISE EXCEPTION 'transfer_item % over-receipt: qty_received=% > qty_shipped=%',
        v_item.id, v_qty_received, v_item.qty_shipped;
    END IF;

    IF v_qty_received > 0 THEN
      v_unit_cost := COALESCE(ABS(v_item.out_cost), 0);

      v_in_mov_id := rpc_inbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_dest_location,
        p_sku_id          => v_item.sku_id,
        p_quantity        => v_qty_received,
        p_unit_cost       => v_unit_cost,
        p_movement_type   => 'transfer_in',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );

      UPDATE transfer_items
         SET qty_received   = v_qty_received,
             in_movement_id = v_in_mov_id,
             updated_by     = p_operator
       WHERE id = v_item.id;
    ELSE
      UPDATE transfer_items
         SET qty_received = 0,
             updated_by   = p_operator
       WHERE id = v_item.id;
    END IF;

    v_total_qty      := v_total_qty + v_qty_received;
    v_total_variance := v_total_variance + (v_qty_received - v_item.qty_shipped);
    v_items_received := v_items_received + 1;
  END LOOP;

  UPDATE transfers
     SET status      = 'received',
         received_by = p_operator,
         received_at = NOW(),
         notes       = CASE
                         WHEN p_notes IS NULL OR p_notes = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN p_notes
                         ELSE v_existing_notes || E'\n' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- ===== 邏輯 A：自動 ship 下一段（aid chain B 模型）=====
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_leg2 FROM transfers
     WHERE id = v_next_transfer_id FOR UPDATE;

    IF v_leg2.id IS NOT NULL AND v_leg2.status = 'draft' THEN
      FOR v_leg2_item IN
        SELECT ti.id AS leg2_item_id, ti.sku_id, ti2.qty_received
          FROM transfer_items ti
          JOIN transfer_items ti2
            ON ti2.transfer_id = p_transfer_id AND ti2.sku_id = ti.sku_id
         WHERE ti.transfer_id = v_leg2.id
      LOOP
        IF v_leg2_item.qty_received > 0 THEN
          v_leg2_mov := rpc_outbound(
            p_tenant_id       => v_leg2.tenant_id,
            p_location_id     => v_leg2.source_location,
            p_sku_id          => v_leg2_item.sku_id,
            p_quantity        => v_leg2_item.qty_received,
            p_movement_type   => 'transfer_out',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_leg2.id,
            p_operator        => p_operator
          );
          UPDATE transfer_items
             SET qty_shipped     = v_leg2_item.qty_received,
                 qty_requested   = v_leg2_item.qty_received,
                 out_movement_id = v_leg2_mov,
                 updated_by      = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        ELSE
          UPDATE transfer_items
             SET qty_shipped   = 0,
                 qty_requested = 0,
                 updated_by    = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        END IF;
      END LOOP;

      UPDATE transfers
         SET status      = 'shipped',
             shipped_by  = p_operator,
             shipped_at  = NOW(),
             updated_by  = p_operator
       WHERE id = v_leg2.id;
      v_next_shipped := TRUE;
    END IF;
  END IF;

  -- ===== 邏輯 B：aid 單 FK 直接推 customer_order → ready =====
  IF v_customer_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = NOW(),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_customer_order_id
       AND status = 'shipping';
    GET DIAGNOSTICS v_orders_advanced = ROW_COUNT;

  -- ===== 邏輯 C：hq_to_store wave transfer → 推該分店訂單 → ready =====
  -- 修：不再無條件推該店「所有」shipping 訂單；改成只推
  --     is_order_pickup_ready=true（依該訂單的團真的到齊、shortage-aware）的訂單，
  --     避免收到別團波次時把尚未出貨的團一起誤標為可取貨。
  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      WITH advanced AS (
        UPDATE customer_orders co
           SET status     = 'ready',
               ready_at   = NOW(),
               updated_by = p_operator,
               updated_at = NOW()
         WHERE co.tenant_id      = v_tenant_id
           AND co.pickup_store_id = v_dest_store_id
           AND co.status          = 'shipping'
           AND public.is_order_pickup_ready(co.id)
        RETURNING co.id
      )
      SELECT COUNT(*) INTO v_orders_advanced FROM advanced;
    END IF;
  END IF;

  -- ===== 邏輯 D（本次新增）：linked 補貨申請 → 已收貨 =====
  -- 店家收貨即補貨流程終點：把 linked_transfer_id 指向本單的補貨申請
  -- 推到 received。approved_transfer 為 legacy 防禦（現行直派皆直接 shipped）。
  UPDATE restock_requests
     SET status     = 'received',
         updated_by = p_operator
   WHERE linked_transfer_id = p_transfer_id
     AND status IN ('shipped', 'approved_transfer');
  GET DIAGNOSTICS v_restock_received = ROW_COUNT;

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped,
    'restock_received',       v_restock_received
  );
END;
$function$;

-- ----------------------------------------------------------------
-- 2. rpc_unreceive_transfer + 反向（received → shipped）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_unreceive_transfer(
  p_transfer_id bigint,
  p_operator    uuid,
  p_notes       text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
-- 邏輯 C 需重掃該店所有 ready 訂單並逐張跑 is_order_pickup_ready，覆寫 PostgREST
-- 預設 statement_timeout，避免大店退回時中途被砍。
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
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'received' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，僅「已收貨(received)」可退回取消收貨', p_transfer_id, v_status;
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
    IF v_item.qty_received > 0 AND v_item.in_movement_id IS NOT NULL THEN
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

    IF v_dest_store_id IS NOT NULL THEN
      FOR v_ord IN
        SELECT id FROM customer_orders
         WHERE tenant_id       = v_tenant_id
           AND pickup_store_id = v_dest_store_id
           AND status          = 'ready'
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

  -- ===== 反向邏輯 D（本次新增）：linked 補貨申請退回 shipped =====
  UPDATE restock_requests
     SET status     = 'shipped',
         updated_by = p_operator
   WHERE linked_transfer_id = p_transfer_id
     AND status = 'received';
  GET DIAGNOSTICS v_restock_reverted = ROW_COUNT;

  RETURN jsonb_build_object(
    'transfer_id',        p_transfer_id,
    'items_reversed',     v_items_reversed,
    'total_qty_reversed', v_total_qty,
    'orders_reverted',    v_orders_reverted,
    'restock_reverted',   v_restock_reverted
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) IS
  '退回收貨：rpc_receive_transfer 的反向。沖銷 transfer_in 入庫(reversal movement)、'
  'qty_received 歸零、調撥單 received→shipped；沖銷後不再 pickup_ready 的訂單退回 shipping；'
  'linked 補貨申請 received→shipped。'
  '守衛：非 received / 後段已出貨 / movement 已沖銷 / on_hand 不足(貨已取用) 皆擋下。';

-- ----------------------------------------------------------------
-- 3. Backfill：已卡住的補貨申請（transfer 已收、restock 仍 shipped）
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_uid   UUID;
  v_fixed INTEGER;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  UPDATE restock_requests rr
     SET status     = 'received',
         updated_by = v_uid
    FROM transfers t
   WHERE t.id = rr.linked_transfer_id
     AND rr.status = 'shipped'
     AND t.status IN ('received', 'closed');
  GET DIAGNOSTICS v_fixed = ROW_COUNT;

  RAISE NOTICE 'Backfill: % 張補貨申請 shipped→received（linked transfer 已收貨）', v_fixed;
END $$;

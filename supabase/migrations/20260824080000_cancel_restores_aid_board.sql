-- ============================================================
-- 2026-08-24: 取消／退回互助轉單時，把數量還給互助板貼文
--
-- 症狀：松山取消了提供給 #249 的那一趟，貼文的「尚需」停在 1 沒有回到 2。
--   rpc_cancel_aid_order / rpc_return_aid_order 從頭到尾不碰 mutual_aid_board
--  （20260615000050 起刻意如此），CLAUDE.md 也記載「認領量要人工加回去」。
--   現在 links / orders 都有 aid_board_id（20260824060000），可以自動還了。
--
-- 基底：兩支函式都以**線上 prosrc** 為基底程式化插入（不是照 repo 檔重打），
--   已 diff 確認只有三處改動：declare 三個變數、還量迴圈、回傳多一個欄位。
--   還量迴圈逐 link 算各自的量（舊的併入單一張可能有多趟），並在品項被標
--   cancelled 之前執行；沒有 link 蓋章但單頭有的舊資料走備援路徑。
--
-- Rollback：兩支函式重跑上一版（線上 prosrc 存於 session scratchpad，或依
--   20260818000030 / 20260615000050 重建）；DROP FUNCTION _restore_aid_board_qty；
--   資料補回那段自行反向 UPDATE。
-- ============================================================

-- 內部 helper：把一趟互助的量還給貼文。
-- 上限夾在 qty_available（重複呼叫或資料異常也不會加超過原釋出量）；
-- exhausted 且未過期 → 回 active（重新開放），已過期 → 標 expired。
CREATE OR REPLACE FUNCTION public._restore_aid_board_qty(
  p_board_id BIGINT, p_qty NUMERIC, p_operator UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE mutual_aid_board b
     SET qty_remaining = LEAST(b.qty_available, b.qty_remaining + p_qty),
         status = CASE
                    WHEN b.status = 'exhausted' AND b.expires_at > NOW() THEN 'active'
                    WHEN b.status = 'exhausted' THEN 'expired'
                    ELSE b.status
                  END,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE b.id = p_board_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._restore_aid_board_qty(BIGINT, NUMERIC, UUID)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._restore_aid_board_qty IS
  '取消/退回互助轉單時把該趟數量還給 mutual_aid_board 貼文（20260824080000）。'
  '只由 rpc_cancel_aid_order / rpc_return_aid_order 內部呼叫。';


CREATE OR REPLACE FUNCTION public.rpc_cancel_aid_order(p_order_id bigint, p_reason text, p_operator uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_terminal_id      BIGINT;
  v_xfer             transfers%ROWTYPE;
  v_ti               RECORD;
  v_cancelled_ids    BIGINT[] := ARRAY[]::BIGINT[];
  v_reason_note      TEXT;
  v_refund_ledger_id BIGINT;
  v_refunded_amount  NUMERIC := 0;
  v_src_id           BIGINT;
  v_src_pickable     BOOLEAN := FALSE;
  v_is_aid           BOOLEAN := FALSE;
  v_restored         INTEGER := 0;
  v_ab               RECORD;
  v_ab_qty           NUMERIC := 0;
  v_aid_restored     INTEGER := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  -- 現貨直配（SP-）單一建立就是 'ready'（貨就在店裡、等客人來拿），
  -- 但它**還沒扣庫存**（配單＝待取，rpc_record_pickup 才扣）→ 取消是安全的，
  -- 只是把可分配量放回去。原本的守衛把它擋在外面，等於做得出單卻取消不掉
  -- （2026-08-16 回報）。其餘單型維持原規則不動。
  IF v_order.status NOT IN ('pending', 'confirmed', 'shipping')
     AND NOT (v_order.status = 'ready' AND v_order.order_no LIKE 'SP-%') THEN
    RAISE EXCEPTION 'order % is %, only pending/confirmed/shipping can be cancelled', p_order_id, v_order.status;
  END IF;

  -- ── 互助板數量歸還 ──（20260824080000）
  -- 這張單是互助板帶來的 → 取消／退回時把量還給貼文，貼文若還沒過期就從
  -- exhausted 轉回 active，釋出店才放得出去。先前這裡完全不碰互助板，
  -- 取消完貼文永遠卡在「已認領」（2026-08-24 松山取消 #249 那趟就是）。
  -- 一張單可能有多趟（舊的併入資料），逐 link 還各自的量；
  -- 要在品項被標 cancelled **之前**算。
  FOR v_ab IN
    SELECT l.aid_board_id AS board_id,
           (SELECT COALESCE(SUM(i.qty), 0) FROM customer_order_items i
             WHERE i.id = ANY (l.dest_item_ids)
               AND i.order_id = p_order_id
               AND i.status IN ('pending','reserved','ready')) AS qty
      FROM customer_order_transfer_links l
     WHERE l.dest_order_id = p_order_id
       AND l.aid_board_id IS NOT NULL
  LOOP
    IF v_ab.qty > 0 THEN
      PERFORM public._restore_aid_board_qty(v_ab.board_id, v_ab.qty, p_operator);
      v_aid_restored := v_aid_restored + 1;
    END IF;
  END LOOP;
  -- 舊資料：links 沒蓋章但單頭有（新單兩邊都有，這條只是備援）
  IF v_aid_restored = 0 AND v_order.aid_board_id IS NOT NULL THEN
    SELECT COALESCE(SUM(i.qty), 0) INTO v_ab_qty
      FROM customer_order_items i
     WHERE i.order_id = p_order_id
       AND i.status IN ('pending','reserved','ready');
    IF v_ab_qty > 0 THEN
      PERFORM public._restore_aid_board_qty(v_order.aid_board_id, v_ab_qty, p_operator);
      v_aid_restored := 1;
    END IF;
  END IF;

  v_reason_note := '[cancelled by source: ' || COALESCE(p_reason, '') || ']';

  -- 場景 B：已派貨，要回收 transfer chain
  IF v_order.status = 'shipping' THEN
    SELECT id INTO v_terminal_id
      FROM transfers
     WHERE customer_order_id = p_order_id
       AND tenant_id = v_order.tenant_id
     LIMIT 1;

    -- 沒有掛在此單上的 transfer：
    --   互助單 → 真的資料不一致，擋下來；
    --   一般（波次出貨）訂單 → 本來就沒有 per-order transfer，直接往下取消。
    IF v_terminal_id IS NULL THEN
      v_is_aid := v_order.transferred_from_order_id IS NOT NULL
                  OR EXISTS (
                       SELECT 1 FROM customer_order_items coi
                        WHERE coi.order_id = p_order_id
                          AND coi.source = 'aid_transfer'
                          AND coi.status <> 'cancelled'
                     );
      IF v_is_aid THEN
        RAISE EXCEPTION 'order % is shipping but has no terminal transfer', p_order_id;
      END IF;
    END IF;

    IF v_terminal_id IS NOT NULL THEN
      FOR v_xfer IN
        WITH RECURSIVE chain_back AS (
          SELECT * FROM transfers WHERE id = v_terminal_id
          UNION ALL
          SELECT t.* FROM transfers t
            JOIN chain_back c ON c.id = ANY(
              SELECT id FROM transfers WHERE next_transfer_id = c.id
            )
        ),
        head AS (
          SELECT id FROM chain_back
           WHERE id NOT IN (SELECT next_transfer_id FROM transfers WHERE next_transfer_id IS NOT NULL)
           LIMIT 1
        ),
        chain_forward AS (
          SELECT * FROM transfers WHERE id = (SELECT id FROM head)
          UNION ALL
          SELECT t.* FROM transfers t
            JOIN chain_forward c ON t.id = c.next_transfer_id
        )
        SELECT * FROM chain_forward ORDER BY id
      LOOP
        IF v_xfer.status = 'received' THEN
          RAISE EXCEPTION 'transfer % already received, cannot cancel chain', v_xfer.id;
        END IF;

        IF v_xfer.status = 'shipped' THEN
          FOR v_ti IN
            SELECT id, sku_id, qty_shipped FROM transfer_items
             WHERE transfer_id = v_xfer.id AND qty_shipped > 0
          LOOP
            PERFORM rpc_inbound(
              p_tenant_id       => v_xfer.tenant_id,
              p_location_id     => v_xfer.source_location,
              p_sku_id          => v_ti.sku_id,
              p_quantity        => v_ti.qty_shipped,
              p_unit_cost       => 0,
              p_movement_type   => 'transfer_cancel',
              p_source_doc_type => 'transfer',
              p_source_doc_id   => v_xfer.id,
              p_operator        => p_operator
            );
          END LOOP;
        END IF;

        UPDATE transfers
           SET status = 'cancelled',
               notes = CASE
                         WHEN notes IS NULL OR notes = '' THEN v_reason_note
                         ELSE notes || E'\n' || v_reason_note
                       END,
               updated_by = p_operator
         WHERE id = v_xfer.id;
        v_cancelled_ids := v_cancelled_ids || v_xfer.id;
      END LOOP;
    END IF;
  END IF;

  -- 若有用儲值金結帳，自動 refund 回會員餘額
  IF v_order.wallet_paid_amount > 0 AND v_order.member_id IS NOT NULL THEN
    v_refund_ledger_id := rpc_wallet_refund(
      v_order.tenant_id,
      v_order.member_id,
      v_order.wallet_paid_amount,
      'customer_order',
      p_order_id,
      'order_cancelled: ' || COALESCE(p_reason, '(no reason)'),
      p_operator
    );
    v_refunded_amount := v_order.wallet_paid_amount;
    -- wallet_paid_amount 保留歷史值，不清零
  END IF;

  -- 標記訂單 cancelled
  -- 現貨直配單取消 → 把它開的 DN 減抵單一併作廢。
  -- 留著不會讓庫存算錯（自由量不看 DN），但 is_order_item_pickup_ready 的
  -- Path D 是以 (tenant, campaign, store, sku) 整組查有效減抵，而現貨直配全部
  -- 掛在共用 sentinel 團底下 —— 一張孤兒 DN 會讓**同團同店同 SKU 的其他單**
  -- （RR- / OV- 容器單也在這個團）憑空通過到貨閘門。
  IF v_order.order_no LIKE 'SP-%' THEN
    UPDATE inventory_deduction_notes n
       SET cancelled_at = NOW(), cancelled_by = p_operator
     WHERE n.cancelled_at IS NULL
       AND EXISTS (SELECT 1 FROM inventory_deduction_note_items li
                    WHERE li.note_id = n.id AND li.order_id = p_order_id);
  END IF;

  UPDATE customer_orders
     SET status       = 'cancelled',
         cancelled_at = NOW(),
         updated_by   = p_operator,
         updated_at   = NOW()
   WHERE id = p_order_id;

  -- ── 來源單品項回補 ──（2026-08-18）
  -- 部分轉出（rpc_transfer_order_partial）把來源列扣掉了（等量→整列 cancelled、
  -- 部分→qty 遞減），下面那段只還單頭，品項不會自己長回來 → 取消之後貨在來源單
  -- 上憑空消失。必須排在單頭 UPDATE **之前**：helper 要靠 source.status 還是不是
  -- 'transferred_out' 來分辨整單轉出（品項沒被動過，不能重複加）。
  v_restored := public._restore_transfer_source_items(p_order_id, p_operator, NOW());

  -- ── source order 退回 ──（2026-07-13）
  -- 先解除轉出鎖定回到 confirmed；若原店的貨其實已到（波次已收 → is_order_pickup_ready），
  -- 直接推到 ready 讓它立刻可取貨，避免波次早跑完、confirmed 再也不會被 mark_shipping 推進而永遠卡住。
  v_src_id := v_order.transferred_from_order_id;
  IF v_src_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status                   = 'confirmed',
           transferred_to_order_id  = NULL,
           updated_by               = p_operator,
           updated_at               = NOW()
     WHERE id = v_src_id
       AND status = 'transferred_out';

    v_src_pickable := public.is_order_pickup_ready(v_src_id);
    IF v_src_pickable THEN
      UPDATE customer_orders
         SET status     = 'ready',
             ready_at   = COALESCE(ready_at, NOW()),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = v_src_id
         AND status = 'confirmed';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'cancelled_transfer_ids', to_jsonb(v_cancelled_ids),
    'source_order_reverted', v_src_id IS NOT NULL,
    'source_order_pickable', v_src_pickable,
    'source_items_restored', v_restored,
    'wallet_refunded',       v_refunded_amount,
    'wallet_refund_ledger_id', v_refund_ledger_id,
    'aid_board_restored',    v_aid_restored
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_return_aid_order(p_order_id bigint, p_reason text, p_operator uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_src_order        customer_orders%ROWTYPE;
  v_src_store_id     BIGINT;
  v_src_location     BIGINT;
  v_recv_xfer        transfers%ROWTYPE;
  v_dest_location    BIGINT;
  v_ret_id           BIGINT;
  v_ret_no           TEXT;
  v_ti               RECORD;
  v_out_mov          BIGINT;
  v_in_mov           BIGINT;
  v_epoch            BIGINT;
  v_reason_note      TEXT;
  v_items            INTEGER := 0;
  v_total_qty        NUMERIC := 0;
  v_refund_ledger_id BIGINT;
  v_refunded_amount  NUMERIC := 0;
  v_ab               RECORD;
  v_ab_qty           NUMERIC := 0;
  v_aid_restored     INTEGER := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;

  -- 必須是互助單
  IF v_order.transferred_from_order_id IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM customer_order_items
        WHERE order_id = p_order_id AND source = 'aid_transfer'
     ) THEN
    RAISE EXCEPTION 'order % is not an aid order', p_order_id;
  END IF;

  -- 狀態閘
  IF v_order.status IN ('pending','confirmed','shipping') THEN
    RAISE EXCEPTION 'aid order % is % (not yet received) — use rpc_cancel_aid_order to cancel before receipt',
      p_order_id, v_order.status;
  ELSIF v_order.status = 'completed' THEN
    RAISE EXCEPTION 'aid order % already completed (picked up) — goods no longer at store; handle customer return first. rpc_return_aid_order only supports received-not-picked (status=ready)',
      p_order_id;
  ELSIF v_order.status <> 'ready' THEN
    RAISE EXCEPTION 'aid order % status=% cannot be returned (expected ready)', p_order_id, v_order.status;
  END IF;

  -- ── 互助板數量歸還 ──（20260824080000）
  -- 這張單是互助板帶來的 → 取消／退回時把量還給貼文，貼文若還沒過期就從
  -- exhausted 轉回 active，釋出店才放得出去。先前這裡完全不碰互助板，
  -- 取消完貼文永遠卡在「已認領」（2026-08-24 松山取消 #249 那趟就是）。
  -- 一張單可能有多趟（舊的併入資料），逐 link 還各自的量；
  -- 要在品項被標 cancelled **之前**算。
  FOR v_ab IN
    SELECT l.aid_board_id AS board_id,
           (SELECT COALESCE(SUM(i.qty), 0) FROM customer_order_items i
             WHERE i.id = ANY (l.dest_item_ids)
               AND i.order_id = p_order_id
               AND i.status IN ('pending','reserved','ready')) AS qty
      FROM customer_order_transfer_links l
     WHERE l.dest_order_id = p_order_id
       AND l.aid_board_id IS NOT NULL
  LOOP
    IF v_ab.qty > 0 THEN
      PERFORM public._restore_aid_board_qty(v_ab.board_id, v_ab.qty, p_operator);
      v_aid_restored := v_aid_restored + 1;
    END IF;
  END LOOP;
  -- 舊資料：links 沒蓋章但單頭有（新單兩邊都有，這條只是備援）
  IF v_aid_restored = 0 AND v_order.aid_board_id IS NOT NULL THEN
    SELECT COALESCE(SUM(i.qty), 0) INTO v_ab_qty
      FROM customer_order_items i
     WHERE i.order_id = p_order_id
       AND i.status IN ('pending','reserved','ready');
    IF v_ab_qty > 0 THEN
      PERFORM public._restore_aid_board_qty(v_order.aid_board_id, v_ab_qty, p_operator);
      v_aid_restored := 1;
    END IF;
  END IF;

  -- dest-facing 已收貨 transfer（air = 唯一 store_to_store；經總倉 = Leg-2 hq_to_store）
  SELECT * INTO v_recv_xfer
    FROM transfers
   WHERE customer_order_id = p_order_id
     AND tenant_id = v_order.tenant_id
     AND status = 'received'
   ORDER BY id DESC
   LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no received transfer found for aid order %', p_order_id;
  END IF;
  v_dest_location := v_recv_xfer.dest_location;

  -- 原 source 店 location（同 rpc_ship_aid_order 的推導）
  SELECT * INTO v_src_order
    FROM customer_orders WHERE id = v_order.transferred_from_order_id;
  IF NOT FOUND OR v_src_order.pickup_store_id IS NULL THEN
    RAISE EXCEPTION 'source order % has no pickup_store', v_order.transferred_from_order_id;
  END IF;
  v_src_store_id := v_src_order.pickup_store_id;
  SELECT location_id INTO v_src_location FROM stores WHERE id = v_src_store_id;
  IF v_src_location IS NULL THEN
    RAISE EXCEPTION 'source store % has no location_id', v_src_store_id;
  END IF;
  IF v_src_location = v_dest_location THEN
    RAISE EXCEPTION 'source and dest share location_id %, cannot return', v_src_location;
  END IF;

  v_epoch := EXTRACT(EPOCH FROM NOW())::BIGINT;
  v_ret_no := 'AT-RET-O' || p_order_id || '-' || v_epoch;
  v_reason_note := '[aid return: ' || COALESCE(p_reason, '') || ']';

  -- 退貨 transfer：dest 店 → 原 source 店，一次反向（status=received 紙上即完成）
  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, customer_order_id, next_transfer_id,
    requested_by, shipped_by, shipped_at, received_by, received_at,
    notes, created_by, updated_by
  ) VALUES (
    v_order.tenant_id, v_ret_no, v_dest_location, v_src_location,
    'received', 'store_to_store', NULL, NULL,
    p_operator, p_operator, NOW(), p_operator, NOW(),
    v_reason_note, p_operator, p_operator
  ) RETURNING id INTO v_ret_id;

  -- 依實收量反向：dest outbound → source inbound
  FOR v_ti IN
    SELECT sku_id, COALESCE(qty_received, qty_shipped) AS qty
      FROM transfer_items
     WHERE transfer_id = v_recv_xfer.id
       AND COALESCE(qty_received, qty_shipped) > 0
  LOOP
    v_out_mov := rpc_outbound(
      p_tenant_id       => v_order.tenant_id,
      p_location_id     => v_dest_location,
      p_sku_id          => v_ti.sku_id,
      p_quantity        => v_ti.qty,
      p_movement_type   => 'transfer_out',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_ret_id,
      p_operator        => p_operator
    );
    v_in_mov := rpc_inbound(
      p_tenant_id       => v_order.tenant_id,
      p_location_id     => v_src_location,
      p_sku_id          => v_ti.sku_id,
      p_quantity        => v_ti.qty,
      p_unit_cost       => 0,
      p_movement_type   => 'transfer_in',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_ret_id,
      p_operator        => p_operator
    );
    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped, qty_received,
      out_movement_id, in_movement_id, created_by, updated_by
    ) VALUES (
      v_ret_id, v_ti.sku_id, v_ti.qty, v_ti.qty, v_ti.qty,
      v_out_mov, v_in_mov, p_operator, p_operator
    );
    v_items := v_items + 1;
    v_total_qty := v_total_qty + v_ti.qty;
  END LOOP;

  IF v_items = 0 THEN
    RAISE EXCEPTION 'received transfer % has no items to return', v_recv_xfer.id;
  END IF;

  -- 串接 timeline（received aid leg 是終端、next 應為 NULL）
  UPDATE transfers
     SET next_transfer_id = v_ret_id, updated_by = p_operator
   WHERE id = v_recv_xfer.id AND next_transfer_id IS NULL;

  -- aid 單 → cancelled
  UPDATE customer_orders
     SET status       = 'cancelled',
         cancelled_at = NOW(),
         updated_by   = p_operator,
         updated_at   = NOW()
   WHERE id = p_order_id;

  -- 來源單回 confirmed（mirror rpc_cancel_aid_order）
  IF v_order.transferred_from_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status                  = 'confirmed',
           transferred_to_order_id = NULL,
           updated_by              = p_operator,
           updated_at              = NOW()
     WHERE id = v_order.transferred_from_order_id
       AND status = 'transferred_out';
  END IF;

  -- wallet 有付則 refund（mirror rpc_cancel_aid_order）
  IF v_order.wallet_paid_amount > 0 AND v_order.member_id IS NOT NULL THEN
    v_refund_ledger_id := rpc_wallet_refund(
      v_order.tenant_id,
      v_order.member_id,
      v_order.wallet_paid_amount,
      'customer_order',
      p_order_id,
      'aid_order_returned: ' || COALESCE(p_reason, '(no reason)'),
      p_operator
    );
    v_refunded_amount := v_order.wallet_paid_amount;
  END IF;

  RETURN jsonb_build_object(
    'order_id',                p_order_id,
    'return_transfer_id',      v_ret_id,
    'reversed_items',          v_items,
    'reversed_qty',            v_total_qty,
    'source_order_reverted',   v_order.transferred_from_order_id IS NOT NULL,
    'wallet_refunded',         v_refunded_amount,
    'wallet_refund_ledger_id', v_refund_ledger_id,
    'aid_board_restored',    v_aid_restored
  );
END;
$function$;

-- 一次性資料補回：松山提供給 #249 的那趟（TF0506）在本修正上線前被取消，
-- 量沒還。守衛齊全，重跑不會重複加。
UPDATE mutual_aid_board b
   SET qty_remaining = LEAST(b.qty_available, b.qty_remaining + 1),
       status = CASE WHEN b.status = 'exhausted' AND b.expires_at > NOW()
                     THEN 'active' ELSE b.status END,
       updated_at = NOW()
 WHERE b.id = 249
   AND b.qty_remaining = 1
   AND EXISTS (SELECT 1 FROM customer_orders co
                WHERE co.id = 83362 AND co.status = 'cancelled'
                  AND co.aid_board_id = 249);

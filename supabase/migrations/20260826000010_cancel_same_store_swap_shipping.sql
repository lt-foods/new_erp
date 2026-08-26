-- ============================================================
-- 2026-08-26: 同店變更取貨人停在 shipping 也要能撤銷
--
-- 回報：互助頁「同店變更取貨人」GRP-20260729-010-0003 → GRP-20260729-010-TF0001
--   （派貨中）按 ↩ 撤銷失敗。
--
-- 原因：20260825050000 放行了 ready 的同店互轉，但轉入單是 mirror 來源單的
--   狀態 —— 來源單轉出當下是 'shipping' 時，轉入單也掛 'shipping'。
--   'shipping' 本來就在狀態守衛的放行清單裡，卻會走進「場景 B：已派貨，
--   要回收 transfer chain」：同店互轉沒有調撥單（_air_ship_order_items 判到
--   source location = dest location 回 NULL 不建單），v_terminal_id 撈不到，
--   而 transferred_from_order_id 有值 → 被當成「互助單資料不一致」直接
--   RAISE 'order % is shipping but has no terminal transfer'。
--
-- 修法：場景 B 的一致性檢查排除 v_same_store_swap（該變數在守衛前就算好了，
--   且自帶「沒有未取消的 transfers」條件）。沒有調撥單不是資料不一致，
--   是同店互轉的常態；直接往下走一般取消（還原來源單品項與單頭）。
--   跨店互助單維持原檢查不動。
--
-- 基底：rpc_cancel_aid_order 線上 prosrc md5 048263860c65b71952e1cbdba780f760
--       （= 20260825050000 的版本，2026-08-26 驗證相符），逐字保留，
--       只改場景 B 裡 v_is_aid 的判斷式。
-- Rollback：重跑 20260825050000_cancel_same_store_swap.sql。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_cancel_aid_order(p_order_id bigint, p_reason text, p_operator uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$

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
  v_same_store_swap  BOOLEAN := FALSE;
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
  -- 同店變更取貨人（轉出店＝接收店）：貨從頭到尾沒離開本店，沒有調撥單、
  -- 也沒有任何庫存異動（庫存只在取貨那一刻扣），所以停在 'ready' 也能撤銷 ——
  -- 撤銷＝把品項還給原客人的單。已經取走的（partially_completed / completed）
  -- 仍然擋著，那不是撤銷得掉的事（2026-08-25 老闆要求）。
  SELECT (v_order.transferred_from_order_id IS NOT NULL
          AND EXISTS (SELECT 1 FROM customer_orders s
                       WHERE s.id = v_order.transferred_from_order_id
                         AND s.pickup_store_id IS NOT DISTINCT FROM v_order.pickup_store_id)
          AND NOT EXISTS (SELECT 1 FROM transfers t
                           WHERE t.customer_order_id = p_order_id
                             AND t.status <> 'cancelled'))
    INTO v_same_store_swap;

  IF v_order.status NOT IN ('pending', 'confirmed', 'shipping')
     AND NOT (v_order.status = 'ready' AND v_order.order_no LIKE 'SP-%')
     AND NOT (v_order.status = 'ready' AND v_same_store_swap) THEN
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
    --   同店變更取貨人 → 本來就沒有調撥單（_air_ship_order_items 判到
    --     source location = dest location 回 NULL），shipping 只是 mirror
    --     來源單的狀態，不是資料不一致 → 直接往下取消（2026-08-26 回報：
    --     GRP-20260729-010-TF0001 按 ↩ 被這裡擋住）；
    --   跨店互助單 → 真的資料不一致，擋下來；
    --   一般（波次出貨）訂單 → 本來就沒有 per-order transfer，直接往下取消。
    IF v_terminal_id IS NULL THEN
      v_is_aid := NOT v_same_store_swap
                  AND (v_order.transferred_from_order_id IS NOT NULL
                       OR EXISTS (
                            SELECT 1 FROM customer_order_items coi
                             WHERE coi.order_id = p_order_id
                               AND coi.source = 'aid_transfer'
                               AND coi.status <> 'cancelled'
                          ));
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
$fn$;

GRANT EXECUTE ON FUNCTION public.rpc_cancel_aid_order(bigint, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_cancel_aid_order(bigint, text, uuid) IS
  '取消轉入單：還原來源單品項與單頭、取消調撥鏈、退儲值金、歸還互助板數量。'
  '可取消狀態＝pending/confirmed/shipping，外加兩種 ready 例外：SP- 現貨直配、'
  '同店變更取貨人（轉出店＝接收店、無調撥單，貨沒離開本店）。'
  '同店互轉在 shipping 一樣沒有調撥單，不做 terminal transfer 一致性檢查。'
  '基底 20260825050000。';

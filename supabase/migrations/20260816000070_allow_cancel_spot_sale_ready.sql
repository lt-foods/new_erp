-- ============================================================
-- 現貨直配單可以取消（狀態守衛放寬）＋ 取消時作廢它的 DN 減抵單
--
-- 回報（Alex 2026-08-16）：「可以取消這個單再回庫存嗎？」
--
-- 現況：做不到。rpc_cancel_aid_order 的守衛是
--   status IN ('pending','confirmed','shipping')，
-- 而現貨直配單**一建立就是 'ready'**（貨就在店裡、等客人來拿）→ 直接被擋；
-- 前端 canCancel 用同一組狀態，所以連「取消」按鈕都不會出現。
-- 刪單一品項的 rpc_delete_order_item 也要 status='pending'（canEditQty）。
-- 結果是：做得出這種單，卻沒有任何路徑可以取消它 ——
-- CLAUDE.md「新增路徑要確認下游有人推得動」的反面案例，而且是自己種的。
--
-- 為什麼放寬是安全的：
--   現貨直配＝配單，**當下不扣庫存**（rpc_record_pickup 取貨時才扣）。
--   所以「取消再回庫存」實際上不需要回沖任何庫存異動 ——
--   單頭一變 cancelled，_sku_commitment 的 promised 就不再算它
--   （promised 看的是單頭 status IN ('ready','partially_completed','shipping')），
--   可分配量自動回來。這也是為什麼不需要動 stock_movements。
--   SP- 單也沒有 transfer chain、沒有儲值金付款，原函式那兩段分支都不會跑到。
--
-- 只對 SP- 放寬，其餘單型維持原規則：一般團購單在 ready 代表貨已配到客人頭上，
-- 取消的語意與連動（池子、波次、到貨通知）完全不同，不在本次範圍。
--
-- 併帶：取消時作廢該單開的 DN 減抵單。留著不會讓庫存算錯（自由量不看 DN），
--   但 is_order_item_pickup_ready 的 Path D 是以 (tenant, campaign, store, sku)
--   整組查有效減抵，而現貨直配全掛在共用 sentinel 團底下 —— 一張孤兒 DN 會讓
--   同團同店同 SKU 的其他單（RR- / OV- 容器單也在這個團）憑空通過到貨閘門。
--
-- 基底：rpc_cancel_aid_order = 20260804000000（最新；本檔函式本體從該檔逐字
--   抽出後只改守衛＋插入作廢段，非手抄）
-- rollback: 重跑 20260804000000 的 rpc_cancel_aid_order。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_cancel_aid_order(
  p_order_id BIGINT,
  p_reason   TEXT,
  p_operator UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
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
    'wallet_refunded',       v_refunded_amount,
    'wallet_refund_ledger_id', v_refund_ledger_id
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_cancel_aid_order(BIGINT, TEXT, UUID) IS
  '取消訂單（互助/一般/派貨中皆走這支）：回收 transfer chain、退儲值金、寫 audit。'
  '20260816000070：現貨直配（SP-）單在 ready 也可取消（它還沒扣庫存，'
  '取消＝把可分配量放回去），並一併作廢該單開的 DN 減抵單。';

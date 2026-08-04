-- ============================================================
-- 2026-08-04: 一般團購單在 shipping 取消時被誤判成「資料不一致」而無法取消
--
-- 回報案例：
--   訂單 GRP-20260724-005-0012 (id=59534, campaign 3269, 平鎮店 store 1)
--   status='shipping'，按「取消」跳：
--     「取消失敗：訂單是 shipping 狀態但找不到對應的 transfer，資料不一致。請聯繫工程師。」
--   查證：transferred_from_order_id IS NULL、品項 source='manual'（不是互助單），
--   transfers 也確實沒有 customer_order_id=59534 的列。
--
-- 根因（守門條件把「正常狀態」當成 corrupt data）：
--   rpc_cancel_aid_order 的 shipping 分支假設「shipping ⇒ 一定有一條掛在該單上的
--   transfer chain 可以回收」，這只對**互助單**成立（rpc_ship_aid_order 會建
--   transfers.customer_order_id = 該單）。
--   一般團購單是走撿貨波次出貨：rpc_mark_orders_shipping_for_wave 依
--   picking_wave_items(campaign_id, store_id) 把整批訂單推到 'shipping'，
--   transfer 是「波次 ↔ 店」層級、customer_order_id 為 NULL，本來就沒有 per-order
--   transfer。線上目前 status='shipping' 且沒有對應 transfer 的訂單有 4278 筆
--   （而 transferred_from_order_id 非 NULL 的互助單則是 0 筆沒有 transfer）
--   → 這是正常狀態，不是資料不一致。
--
-- 修法：
--   shipping 分支找不到 terminal transfer 時不要一律 RAISE：
--     · 訂單是互助單（transferred_from_order_id 非 NULL，或有未取消的
--       source='aid_transfer' 品項）→ 維持原本 RAISE（那才是真的資料不一致）。
--     · 否則（波次出貨的一般訂單）→ 沒有 chain 可回收，直接照 pending/confirmed
--       的路徑取消即可，不動庫存。
--   不動庫存是對的：波次撿的貨是 campaign+store 整批進到店端庫存，並沒有綁在
--   單一訂單上（顧客取貨時才由 rpc_record_pickup 出庫），取消一張單只是讓那批
--   貨變回店端可用庫存，與取消 confirmed 單的效果一致。
--
-- 其餘行為（advisory lock、status gate、transfer chain 回收、wallet refund、
--   原單退回 confirmed/ready）全部逐字保留。
--
-- 基底版本：20260713000000_aid_cancel_revert_source_to_ready_if_stocked.sql
--   （線上現行版，已比對 pg_proc.prosrc）
-- Rollback：CREATE OR REPLACE 回 20260713000000 版本
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
  IF v_order.status NOT IN ('pending', 'confirmed', 'shipping') THEN
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

COMMENT ON FUNCTION rpc_cancel_aid_order IS
  'Aid order 取消 / 撤回派貨：早期 status only；shipping 有掛單的 transfer chain 就反向回收，'
  '波次出貨的一般訂單沒有 per-order transfer → 直接取消不動庫存（2026-08-04）；'
  '有 wallet_paid 自動 refund。原單退回時若貨已在店(is_order_pickup_ready) 直接推到 ready（2026-07-13）。';

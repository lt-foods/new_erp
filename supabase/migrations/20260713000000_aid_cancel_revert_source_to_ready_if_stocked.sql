-- ============================================================
-- 2026-07-13: 總倉取消互助單後，原單若「貨已在店」要直接回到可取貨(ready)，不要卡在 confirmed
--
-- 回報案例：
--   訂單 GB20260529-C000564-0014 (id=18397, campaign 2169, 松山店 store 2)：
--   會員在畫面上「不能取貨」。查證：
--     - 該單 status='confirmed'、item G00260-01 (sku 1290) status='pending'
--     - 撿貨波次 WAVE-73-S2 (transfer 596, hq_to_store 總倉→松山) 已 received，
--       qty_received=3；松山店該 SKU onhand=3 → 貨明明就在店裡
--     - transferred_from/to 皆 null、cancelled_at null
--
-- 根因（狀態機漏洞，不是 transfer 被取消）：
--   1. 此原單曾被轉手成互助單 (status='transferred_out')；
--   2. 在它 transferred_out 期間，該 campaign+store 的撿貨波次已跑完並收貨，
--      rpc_mark_orders_shipping_for_wave（只收 pending/confirmed/reserved）與
--      rpc_receive_transfer（只把 shipping→ready）都**略過**了它；
--   3. 總倉在「收件匣 > 互助訂單 > 取消」呼叫 rpc_cancel_aid_order，
--      把互助單設 cancelled，原單從 transferred_out **退回 'confirmed'**
--      並清掉 transferred_to_order_id（＝現在看到的 null/null）。
--   4. 波次早已跑完不會再重跑 → 這張 confirmed 單再也不會被推進到
--      shipping→ready → 取貨頁 pickableItems() 對 confirmed 一律回 []
--      → 永遠「不能取貨」，但貨其實就在店裡。
--
-- 修法：
--   凡是「取消互助/拒收後把原單退回」的路徑，退回時不要一律 confirmed —
--   若該原單此刻已 is_order_pickup_ready（貨到＝波次已收）就直接推到 'ready'
--   (+ ready_at)，讓它立刻可取貨；否則維持 'confirmed'（貨還沒到，日後波次到貨
--   會照常 mark_shipping→receive 推進，不破壞缺貨防呆）。
--   同一漏洞存在於兩支 sibling RPC，一起補：
--     - rpc_cancel_aid_order  （本案入口：HQ 收件匣互助單取消）
--     - rpc_reject_transfer   （dest 端拒收；同樣把 source order 退回 confirmed）
--   另做一次性 backfill：把所有 status='confirmed' 且 is_order_pickup_ready=true
--   的訂單推到 'ready'，撈回過去已被卡住的同類單（含 18397）。
--
-- 基底版本（append-only，逐字保留所有 prior fix、僅改「原單退回」那一段）：
--   - rpc_cancel_aid_order：20260606000040_rpc_cancel_aid_order_wallet_refund.sql（線上現行版）
--   - rpc_reject_transfer ：20260510000007_rpc_reject_transfer.sql（唯一版本）
-- Rollback：
--   - rpc_cancel_aid_order：CREATE OR REPLACE 回 20260606000040 版本
--   - rpc_reject_transfer ：CREATE OR REPLACE 回 20260510000007 版本
--   - backfill 無法自動 rollback（狀態已推進）；如需回退，手動把誤推的單改回 confirmed
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_cancel_aid_order（基底 20260606000040，僅改「source order 回到 confirmed」段）
-- ----------------------------------------------------------------
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

    IF v_terminal_id IS NULL THEN
      RAISE EXCEPTION 'order % is shipping but has no terminal transfer', p_order_id;
    END IF;

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

  -- ── source order 退回 ──（本次修法）
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
  'Aid order 取消 / 撤回派貨：早期 status only；shipping 反向 transfer chain；有 wallet_paid 自動 refund。'
  '原單退回時若貨已在店(is_order_pickup_ready) 直接推到 ready 讓它可取貨，否則 confirmed（2026-07-13）。';

-- ----------------------------------------------------------------
-- 2. rpc_reject_transfer（基底 20260510000007，僅改「source order 回到 confirmed」段）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_reject_transfer(
  p_transfer_id BIGINT,
  p_reason      TEXT,
  p_operator    UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_xfer            transfers%ROWTYPE;
  v_ti              RECORD;
  v_next            transfers%ROWTYPE;
  v_prev            transfers%ROWTYPE;
  v_co_id           BIGINT;
  v_co              customer_orders%ROWTYPE;
  v_leg3_id         BIGINT;
  v_leg3_no         TEXT;
  v_leg3_dest_loc   BIGINT;
  v_leg3_mov        BIGINT;
  v_reason_note     TEXT;
  v_cancelled_ids   BIGINT[] := ARRAY[]::BIGINT[];
  v_epoch           BIGINT;
  v_src_pickable    BOOLEAN := FALSE;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT * INTO v_xfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;
  IF v_xfer.status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is %, only shipped can be rejected', p_transfer_id, v_xfer.status;
  END IF;

  v_reason_note := '[rejected: ' || COALESCE(p_reason, '') || ']';

  -- 1. 反向：把 outbound 過的貨退回 source_location
  FOR v_ti IN
    SELECT id, sku_id, qty_shipped FROM transfer_items
     WHERE transfer_id = p_transfer_id AND qty_shipped > 0
  LOOP
    PERFORM rpc_inbound(
      p_tenant_id       => v_xfer.tenant_id,
      p_location_id     => v_xfer.source_location,
      p_sku_id          => v_ti.sku_id,
      p_quantity        => v_ti.qty_shipped,
      p_unit_cost       => 0,
      p_movement_type   => 'transfer_reject',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => p_transfer_id,
      p_operator        => p_operator
    );
  END LOOP;

  UPDATE transfers
     SET status = 'cancelled',
         notes = CASE
                   WHEN notes IS NULL OR notes = '' THEN v_reason_note
                   ELSE notes || E'\n' || v_reason_note
                 END,
         updated_by = p_operator
   WHERE id = p_transfer_id;
  v_cancelled_ids := v_cancelled_ids || p_transfer_id;

  -- 2. 往後 walk：next chain 的 draft/shipped cancel 掉
  IF v_xfer.next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_next FROM transfers WHERE id = v_xfer.next_transfer_id FOR UPDATE;
    IF v_next.id IS NOT NULL AND v_next.status IN ('draft', 'shipped') THEN
      IF v_next.status = 'shipped' THEN
        FOR v_ti IN
          SELECT id, sku_id, qty_shipped FROM transfer_items
           WHERE transfer_id = v_next.id AND qty_shipped > 0
        LOOP
          PERFORM rpc_inbound(
            p_tenant_id       => v_next.tenant_id,
            p_location_id     => v_next.source_location,
            p_sku_id          => v_ti.sku_id,
            p_quantity        => v_ti.qty_shipped,
            p_unit_cost       => 0,
            p_movement_type   => 'transfer_reject',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_next.id,
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
       WHERE id = v_next.id;
      v_cancelled_ids := v_cancelled_ids || v_next.id;
    END IF;
  END IF;

  -- 3. 找 customer_order
  v_co_id := v_xfer.customer_order_id;
  IF v_co_id IS NULL AND v_next.id IS NOT NULL THEN
    v_co_id := v_next.customer_order_id;
  END IF;

  IF v_co_id IS NOT NULL THEN
    SELECT * INTO v_co FROM customer_orders WHERE id = v_co_id;
    UPDATE customer_orders
       SET status       = 'cancelled',
           cancelled_at = NOW(),
           updated_by   = p_operator,
           updated_at   = NOW()
     WHERE id = v_co_id;

    -- ── source order 退回 ──（本次修法，與 rpc_cancel_aid_order 一致）
    IF v_co.transferred_from_order_id IS NOT NULL THEN
      UPDATE customer_orders
         SET status                  = 'confirmed',
             transferred_to_order_id = NULL,
             updated_by              = p_operator,
             updated_at              = NOW()
       WHERE id = v_co.transferred_from_order_id
         AND status = 'transferred_out';

      v_src_pickable := public.is_order_pickup_ready(v_co.transferred_from_order_id);
      IF v_src_pickable THEN
        UPDATE customer_orders
           SET status     = 'ready',
               ready_at   = COALESCE(ready_at, NOW()),
               updated_by = p_operator,
               updated_at = NOW()
         WHERE id = v_co.transferred_from_order_id
           AND status = 'confirmed';
      END IF;
    END IF;
  END IF;

  -- 4. 決策 Y：若往前有 received 的 leg，自動建 Leg-3 退回原 source
  SELECT * INTO v_prev
    FROM transfers
   WHERE next_transfer_id = p_transfer_id
   LIMIT 1;

  IF v_prev.id IS NOT NULL AND v_prev.status = 'received' THEN
    v_leg3_dest_loc := v_prev.source_location;  -- 退回原 source 店

    v_epoch := EXTRACT(EPOCH FROM NOW())::BIGINT;
    v_leg3_no := 'AT-RET-' || p_transfer_id || '-' || v_epoch;

    INSERT INTO transfers (
      tenant_id, transfer_no, source_location, dest_location,
      status, transfer_type, customer_order_id, next_transfer_id,
      requested_by, shipped_by, shipped_at,
      created_by, updated_by, notes
    ) VALUES (
      v_xfer.tenant_id, v_leg3_no, v_xfer.source_location, v_leg3_dest_loc,
      'shipped', 'hq_to_store', NULL, NULL,
      p_operator, p_operator, NOW(),
      p_operator, p_operator, '[Leg-3 退回 source after reject]'
    ) RETURNING id INTO v_leg3_id;

    FOR v_ti IN
      SELECT sku_id, qty_shipped FROM transfer_items
       WHERE transfer_id = p_transfer_id AND qty_shipped > 0
    LOOP
      v_leg3_mov := rpc_outbound(
        p_tenant_id       => v_xfer.tenant_id,
        p_location_id     => v_xfer.source_location,
        p_sku_id          => v_ti.sku_id,
        p_quantity        => v_ti.qty_shipped,
        p_movement_type   => 'transfer_out',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => v_leg3_id,
        p_operator        => p_operator
      );
      INSERT INTO transfer_items (
        transfer_id, sku_id, qty_requested, qty_shipped,
        out_movement_id, created_by, updated_by
      ) VALUES (
        v_leg3_id, v_ti.sku_id, v_ti.qty_shipped, v_ti.qty_shipped,
        v_leg3_mov, p_operator, p_operator
      );
    END LOOP;

    UPDATE transfers SET next_transfer_id = v_leg3_id, updated_by = p_operator
     WHERE id = p_transfer_id;
  END IF;

  RETURN jsonb_build_object(
    'rejected_transfer_id', p_transfer_id,
    'cancelled_transfer_ids', to_jsonb(v_cancelled_ids),
    'cancelled_co_id', v_co_id,
    'leg3_transfer_id', v_leg3_id,
    'source_order_reverted', v_co.transferred_from_order_id IS NOT NULL,
    'source_order_pickable', v_src_pickable
  );
END;
$$;

COMMENT ON FUNCTION rpc_reject_transfer IS
  'Aid transfer 拒收：反向 inbound、cancel 後續 chain、customer_order 取消、source order 回 confirmed。'
  '經總倉 dest 拒 Leg-2 自動建 Leg-3 退回原 source（決策 Y）。'
  '原單退回時若貨已在店(is_order_pickup_ready) 直接推到 ready（2026-07-13）。';

-- ----------------------------------------------------------------
-- 3. Backfill：撈回過去已被卡住的同類單
--    status='confirmed' 且 is_order_pickup_ready=true（貨已在店、波次已收）→ 'ready'
--    （含回報案例 GB20260529-C000564-0014 / id=18397）
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_uid   UUID;
  v_fixed INTEGER;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  WITH stranded AS (
    SELECT co.id
      FROM customer_orders co
     WHERE co.status = 'confirmed'
       AND public.is_order_pickup_ready(co.id)
  ),
  upd AS (
    UPDATE customer_orders co
       SET status     = 'ready',
           ready_at   = COALESCE(co.ready_at, NOW()),
           updated_by = v_uid,
           updated_at = NOW()
     WHERE co.id IN (SELECT id FROM stranded)
    RETURNING co.id
  )
  SELECT COUNT(*) INTO v_fixed FROM upd;

  RAISE NOTICE 'Backfill: pushed % confirmed orders → ready (goods already at store)', v_fixed;
END $$;

-- ============================================================
-- 2026-08-01: 總倉拒收「退訂單回總倉」不得取消原顧客訂單
--
-- 事故案例（本次修法動機）：
--   訂單 GRP-20260623-022-INT0038（id=37587，湖口店長內部叫貨）7/31 到店
--   （ready）。8/1 店端以「退貨」建 return_to_hq 退貨單 TR2608010350
--   （transfer 8372，-1 件回總倉）。總倉判定「非退貨 是少收」拒收 →
--   rpc_reject_transfer：貨帳 +1 正確退回店端，但把 customer_order_id
--   連到的「原訂單 37587」一併設成 cancelled。
--   同型事故第二次發生：7/6 TR2607030151（transfer 3935）拒收誤取消
--   訂單 30709，當時以 scripts/PROD-fix-order-30709-restore-after-return-reject.sql
--   手修，未修 RPC 本體 → 本次再犯。
--
-- 根因：
--   rpc_reject_transfer 的「取消 customer_order」是為互助/派貨鏈設計
--   （customer_order_id = 該 transfer 履約中的互助訂單，拒收＝訂單作廢）。
--   return_to_hq（rpc_create_order_return）的 customer_order_id 卻是
--   「被退貨的原訂單」：建退貨單時訂單狀態保留不動（見 20260610000010
--   檔頭「訂單狀態保留、不取消」），拒收（退訂單取消）只應作廢退貨單、
--   貨帳退回店端，原訂單不得動。應收扣減 / 取貨守門 / 月結 return_out
--   都只認 status IN ('shipped','received') 的退貨單，拒收後自動不再計入，
--   無須額外沖回。
--
-- 修法：
--   step 3「找 customer_order 並取消」整段以
--   IF v_xfer.transfer_type <> 'return_to_hq' 包住。其餘逐字保留。
--   （step 2 chain / step 4 Leg-3 對 return_to_hq 本來就是 no-op：
--   退貨單無 next_transfer_id、也不會是任何 leg 的 next。）
--
-- 資料修復：訂單 37587 另以
--   scripts/PROD-fix-order-37587-restore-after-return-reject.sql 還原 ready。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   - rpc_reject_transfer：20260731000000_reject_transfer_wave_guard_and_rpc_unreject.sql
--     （該檔基底為 20260713000000；本檔僅將 step 3 包進 transfer_type 判斷）
-- Rollback：
--   - rpc_reject_transfer：CREATE OR REPLACE 回 20260731000000 版本
-- ============================================================

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

  -- ── 守衛（2026-07-31）：撿貨波次派貨單，分店不可拒收 ──
  -- 波次派貨單背後掛著多張顧客訂單（customer_order_id 為 NULL、訂單不會被
  -- 本 RPC 一併處理），店端拒收會讓訂單卡在 shipping、庫存虛回總倉。
  -- 只擋「JWT store scope 涵蓋 dest 的分店帳號」；總倉帳號維持可操作（清理用）。
  IF v_xfer.dest_location = ANY (public._jwt_store_location_ids())
     AND EXISTS (
       SELECT 1 FROM picking_wave_items pwi
        WHERE pwi.generated_transfer_id = p_transfer_id
     ) THEN
    RAISE EXCEPTION '總倉派貨單（%）不可由分店拒收：貨還沒到請等貨到再收；貨品有誤或毀損請聯繫總倉處理',
      v_xfer.transfer_no;
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

  -- 3. 找 customer_order 並取消 —— 僅互助/派貨鏈適用（2026-08-01 加判斷）。
  -- return_to_hq（分店退訂單回總倉）的 customer_order_id 是「被退貨的原訂單」：
  -- rpc_create_order_return 建單時訂單狀態保留不動，拒收（退訂單取消）只應
  -- 作廢退貨單本身、貨帳退回店端，原訂單不得取消（30709 / 37587 事故）。
  IF v_xfer.transfer_type <> 'return_to_hq' THEN
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

      -- ── source order 退回 ──（20260713 修法，與 rpc_cancel_aid_order 一致）
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
  '原單退回時若貨已在店(is_order_pickup_ready) 直接推到 ready（2026-07-13）。'
  '撿貨波次派貨單分店不可拒收，僅總倉帳號可操作（2026-07-31）。'
  'return_to_hq 拒收只作廢退貨單、貨帳退回店端，不取消原顧客訂單（2026-08-01）。';

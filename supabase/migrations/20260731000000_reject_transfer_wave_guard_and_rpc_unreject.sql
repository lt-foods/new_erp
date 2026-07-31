-- ============================================================
-- 2026-07-31: 店端誤拒收總倉派貨單防呆 + 拒收復原 RPC
--
-- 事故案例（本次修法動機）：
--   GRP-20260615-017 雞排團，撿貨波次 WV260729000833 派 3 件到湖口
--   （transfer 6780 / WAVE-688-S49）。湖口店 7/30 在收貨待辦按「拒收」
--   （原因填「未到貨」— 店家以為拒收＝「貨還沒到、先清掉」，
--   實際語意是「退貨作廢」）。結果：
--     - transfer 被 cancel、3 件帳面回流經總倉（貨實際不在總倉）
--     - 兩張訂單（-0013/-0027）卡在 shipping，退訂報
--       「訂單是 shipping 狀態但找不到對應的 transfer」
--     - 收貨清單只撈 status='shipped'，拒收後單子永遠消失、
--       又沒有任何「取消拒收」功能 → 只能工程手修
--
-- 修法（兩段）：
--   1. rpc_reject_transfer 加守衛：撿貨波次產生的派貨單
--      （picking_wave_items.generated_transfer_id 有連結），
--      若呼叫者的 JWT store scope（_jwt_store_location_ids()）涵蓋
--      dest_location（＝分店在拒收自己店的總倉派貨單）→ 直接擋下，
--      錯誤訊息引導「等貨到再收 / 聯繫總倉」。
--      總倉帳號（app_metadata.stores 不含該店）不受影響：
--      收件匣「退訂單取消」拒收的是 dest=HQ 的退貨單，不會命中此守衛。
--   2. 新增 rpc_unreject_transfer：把「已拒收(cancelled)」的調撥單恢復
--      「在途(shipped)」— 逐筆沖銷 transfer_reject 回流
--      （movement_type='reversal'、reverses=原 id，沿用 20260711000000
--      rpc_unreceive_transfer 的 append-only 沖銷慣例），單據回 shipped，
--      店端收貨待辦就會重新出現、可正常收貨。
--      防呆守衛（整筆 rollback）：
--        - 非 cancelled → 擋
--        - 綁定 customer_order_id（aid 單：拒收時訂單已被一併取消）→ 擋，
--          須工程處理，不可只復原 transfer 造成新的不一致
--        - 有 next_transfer_id 接力鏈 → 擋（後續 leg 狀態複雜，須工程處理）
--        - 無 transfer_reject 回流紀錄 / 已被沖銷過 → 擋（防重複復原）
--        - 出貨端 on_hand 不足以沖銷（貨已被重新派出）→ 擋（防負庫存）
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   - rpc_reject_transfer：20260713000000_aid_cancel_revert_source_to_ready_if_stocked.sql
--     （該檔基底為 20260510000007；本檔僅在 status 檢查後插入守衛一段）
--   - rpc_unreject_transfer：新函式（沖銷寫法對齊 20260711000000_rpc_unreceive_transfer.sql）
-- Rollback：
--   - rpc_reject_transfer：CREATE OR REPLACE 回 20260713000000 版本
--   - rpc_unreject_transfer：DROP FUNCTION public.rpc_unreject_transfer(BIGINT, UUID, TEXT);
--     （已寫入的 reversal movement 為 append-only，不隨 DROP 消失）
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_reject_transfer（基底 20260713000000，僅插入「波次派貨單店端不可拒收」守衛）
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
  '撿貨波次派貨單分店不可拒收，僅總倉帳號可操作（2026-07-31）。';

-- ----------------------------------------------------------------
-- 2. rpc_unreject_transfer：已拒收(cancelled) → 恢復在途(shipped)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_unreject_transfer(
  p_transfer_id BIGINT,
  p_operator    UUID,
  p_notes       TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_xfer        transfers%ROWTYPE;
  v_mov         stock_movements%ROWTYPE;
  v_next_status TEXT;
  v_on_hand     NUMERIC;
  v_reversed    INTEGER := 0;
  v_total_qty   NUMERIC := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT * INTO v_xfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;
  IF v_xfer.status <> 'cancelled' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，僅「已拒收/取消(cancelled)」可恢復在途', p_transfer_id, v_xfer.status;
  END IF;

  -- aid 單：拒收時 customer_order 已被一併取消，只復原 transfer 會造成新的不一致
  IF v_xfer.customer_order_id IS NOT NULL THEN
    RAISE EXCEPTION '調撥單 % 綁定顧客訂單（拒收時訂單已一併取消），無法自動恢復，請聯繫工程師', p_transfer_id;
  END IF;
  -- 多段接力鏈：後續 leg 的庫存/狀態要一併對齊，超出自動復原範圍
  IF v_xfer.next_transfer_id IS NOT NULL THEN
    SELECT status INTO v_next_status FROM transfers WHERE id = v_xfer.next_transfer_id;
    RAISE EXCEPTION '調撥單 % 有後續接力調撥 %（狀態 %），無法自動恢復，請聯繫工程師',
      p_transfer_id, v_xfer.next_transfer_id, COALESCE(v_next_status, '?');
  END IF;

  -- 逐筆沖銷拒收回流（append-only：reversal + reverses，原 movement 不動）
  FOR v_mov IN
    SELECT * FROM stock_movements
     WHERE source_doc_type = 'transfer'
       AND source_doc_id   = p_transfer_id
       AND movement_type   = 'transfer_reject'
     ORDER BY id
  LOOP
    IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_mov.id) THEN
      RAISE EXCEPTION 'movement % 已被沖銷過，不可重複恢復在途', v_mov.id;
    END IF;

    -- 物理守衛：回流的貨若已從出貨端被重新派出，沖銷會讓庫存變負 → 擋
    SELECT on_hand INTO v_on_hand
      FROM stock_balances
     WHERE tenant_id   = v_mov.tenant_id
       AND location_id = v_mov.location_id
       AND sku_id      = v_mov.sku_id
     FOR UPDATE;
    IF COALESCE(v_on_hand, 0) < v_mov.quantity THEN
      RAISE EXCEPTION '出貨端庫存不足以沖銷拒收回流（SKU %：現有 %、需 %）：該批貨可能已被重新派出，無法恢復在途',
        v_mov.sku_id, COALESCE(v_on_hand, 0), v_mov.quantity;
    END IF;

    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
      source_doc_type, source_doc_id, reverses, reason, operator_id
    ) VALUES (
      v_mov.tenant_id, v_mov.location_id, v_mov.sku_id,
      -v_mov.quantity, v_mov.unit_cost, 'reversal',
      'transfer', p_transfer_id, v_mov.id,
      format('恢復在途 transfer=%s（沖銷拒收回流 movement %s）%s',
             p_transfer_id, v_mov.id,
             COALESCE('：' || NULLIF(TRIM(p_notes), ''), '')),
      p_operator
    );

    v_reversed  := v_reversed + 1;
    v_total_qty := v_total_qty + v_mov.quantity;
  END LOOP;

  IF v_reversed = 0 THEN
    RAISE EXCEPTION '調撥單 % 沒有拒收回流紀錄可沖銷（非拒收取消、或已由工程處理過），無法恢復在途', p_transfer_id;
  END IF;

  UPDATE transfers
     SET status     = 'shipped',
         notes      = CASE
                        WHEN notes IS NULL OR notes = ''
                          THEN '[恢復在途' || COALESCE('：' || NULLIF(TRIM(p_notes), ''), '') || ']'
                        ELSE notes || E'\n' || '[恢復在途' || COALESCE('：' || NULLIF(TRIM(p_notes), ''), '') || ']'
                      END,
         updated_by = p_operator
   WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'transfer_id',        p_transfer_id,
    'movements_reversed', v_reversed,
    'total_qty_reversed', v_total_qty
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_unreject_transfer(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_unreject_transfer(BIGINT, UUID, TEXT) IS
  '誤拒收復原：cancelled → shipped，逐筆以 reversal 沖銷 transfer_reject 回流，'
  '單據重回店端收貨待辦。僅限無 customer_order FK、無接力鏈的單（波次派貨單）；'
  '重複復原 / 出貨端庫存不足會整筆擋下（2026-07-31）。';

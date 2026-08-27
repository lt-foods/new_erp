-- ============================================================
-- 2026-08-27: 退貨單拒收要把「因退貨被收尾」的訂單重開 —— 補回被同號檔蓋掉的分支
--
-- 事故（會員端金額對不上的掃描中發現）：線上 4 張單（GRP-20260701-024-0050 /
--   GRP-20260713-012-0002 / RR-433 / RR-545）單頭 completed 卻掛著未結金額。
--   路徑都一樣：店端建 return_to_hq 退貨（rpc_create_order_return 判定剩餘量
--   全被退貨覆蓋 → 單頭收尾 completed），之後總倉**拒收**退貨
--   （rpc_reject_transfer → 退貨單 cancelled、貨帳退回店端），
--   但單頭停在 completed 沒人重開。結果：
--     - v_customer_order_summary.outstanding_amount 復活（退貨單 cancelled
--       之後扣減不再計入）→ 會員首頁「未結單金額」算得到它；
--     - 訂單頁「應付總金額」只算 active tab（不含 completed）→ 算不到它；
--     - 兩個數字從此對不上，取貨頁也永遠不會再列出這張單。
--
-- 根因是撞號互蓋：20260801000000_full_return_closes_order.sql 的
--   rpc_reject_transfer 版本**有**「return_to_hq 拒收 → 復原訂單」分支
--   （cancelled→ready / completed→partially_completed），但同號的
--   20260801000000_reject_return_to_hq_keep_original_order.sql（只有
--   「跳過取消」的精簡版）後套，把復原分支整個蓋掉 —— 線上從來沒有過
--   這段邏輯。CLAUDE.md「開新 migration 前先看有沒有撞號」又一例。
--
-- 修法：以**線上現行版**（= keep_original_order 版，2026-08-27 以
--   pg_get_functiondef dump 逐字比對）為基底，把 full_return_closes_order
--   版的復原分支接回 return_to_hq 路徑，其餘逐字保留：
--     - 曾被收尾成 cancelled（有 active 品項、無已取）→ 回 ready
--     - 曾被收尾成 completed（仍有 active 品項）→ 回 partially_completed
--       （清 completed_at；outstanding 由 view 依品項自動復活）
--     - 其他 → 不動
--   result 加 restored_co_id / restored_status。
--
-- 資料修復（冪等）：上述 4 張線上壞單依同一規則改回 partially_completed
--   （四張都有已取品項）。條件鎖「completed + 有 active 品項 + 掛著
--   cancelled 的 return_to_hq + outstanding > 0」——「退貨覆蓋」的合法
--   completed 單（退貨單仍 shipped/received、outstanding = 0）不會被誤改。
--
-- 基底版本（append-only）：rpc_reject_transfer =
--   20260801000000_reject_return_to_hq_keep_original_order.sql（線上現行）。
-- Rollback：CREATE OR REPLACE 回該版本；資料修復以本檔 audit notes 反查改回。
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
  v_ret_co          customer_orders%ROWTYPE;
  v_restored_co_id  BIGINT;
  v_restored_status TEXT;
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
  ELSE
    -- ── return_to_hq 拒收 → 復原「因退貨被收尾」的原訂單（2026-08-27 補回）──
    -- 這段在 20260801000000_full_return_closes_order 寫過，被同號的
    -- keep_original_order 版蓋掉、從未上線（見檔頭）。貨已由上面的
    -- transfer_reject inbound 回到店端，原訂單要跟著復原可取：
    --   - 曾因全數退貨收尾成 cancelled（有 active 品項、無已取）→ 回 ready
    --   - 曾因收尾成 completed（仍有 active 品項）→ 回 partially_completed
    --   - 其他（正常 ready / partially_completed / expired…）→ 不動
    --     （退貨單已 cancelled，可取量／應收扣減查詢自動不再計入）
    IF v_xfer.customer_order_id IS NOT NULL THEN
      SELECT * INTO v_ret_co FROM customer_orders
       WHERE id = v_xfer.customer_order_id FOR UPDATE;
      IF v_ret_co.status = 'cancelled'
         AND EXISTS (SELECT 1 FROM customer_order_items
                      WHERE order_id = v_ret_co.id AND status IN ('pending','reserved','ready'))
         AND NOT EXISTS (SELECT 1 FROM customer_order_items
                          WHERE order_id = v_ret_co.id AND status = 'picked_up') THEN
        v_restored_co_id  := v_ret_co.id;
        v_restored_status := 'ready';
        UPDATE customer_orders
           SET status       = 'ready',
               ready_at     = COALESCE(ready_at, NOW()),
               cancelled_at = NULL,
               updated_by   = p_operator,
               updated_at   = NOW()
         WHERE id = v_ret_co.id;
      ELSIF v_ret_co.status = 'completed'
         AND EXISTS (SELECT 1 FROM customer_order_items
                      WHERE order_id = v_ret_co.id AND status IN ('pending','reserved','ready')) THEN
        v_restored_co_id  := v_ret_co.id;
        v_restored_status := 'partially_completed';
        UPDATE customer_orders
           SET status       = 'partially_completed',
               completed_at = NULL,
               updated_by   = p_operator,
               updated_at   = NOW()
         WHERE id = v_ret_co.id;
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
    'restored_co_id', v_restored_co_id,
    'restored_status', v_restored_status,
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
  'return_to_hq 拒收只作廢退貨單、貨帳退回店端，不取消原顧客訂單（2026-08-01）；'
  '並復原因退貨被收尾的訂單（cancelled→ready / completed→partially_completed，2026-08-27）。';

-- ------------------------------------------------------------
-- 資料修復（冪等）：4 張「退貨遭拒後單頭沒重開」的線上壞單
-- 條件鎖死：completed + 有 active 品項 + 有已取品項 + 掛 cancelled 的
-- return_to_hq + outstanding 會復活（active 量未被仍生效的退貨覆蓋）。
-- 「退貨覆蓋」的合法 completed 單（退貨單 shipped/received）不符合條件。
-- ------------------------------------------------------------
WITH broken AS (
  SELECT co.id
    FROM customer_orders co
   WHERE co.status = 'completed'
     AND EXISTS (SELECT 1 FROM customer_order_items i
                  WHERE i.order_id = co.id AND i.status IN ('pending','reserved','ready'))
     AND EXISTS (SELECT 1 FROM customer_order_items i
                  WHERE i.order_id = co.id AND i.status = 'picked_up')
     AND EXISTS (SELECT 1 FROM transfers t
                  WHERE t.customer_order_id = co.id
                    AND t.transfer_type = 'return_to_hq'
                    AND t.status = 'cancelled')
     AND NOT EXISTS (SELECT 1 FROM transfers t
                      WHERE t.customer_order_id = co.id
                        AND t.transfer_type = 'return_to_hq'
                        AND t.status IN ('shipped','received'))
)
UPDATE customer_orders co
   SET status       = 'partially_completed',
       completed_at = NULL,
       notes        = COALESCE(co.notes || E'\n', '') ||
                      '[20260827020000 資料修復] 退貨遭拒後單頭未重開，completed → partially_completed',
       updated_at   = NOW()
  FROM broken b
 WHERE co.id = b.id;

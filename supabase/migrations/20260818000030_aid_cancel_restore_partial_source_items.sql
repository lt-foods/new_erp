-- ============================================================
-- 取消互助 / 轉入單時，把「部分轉出」被扣掉的來源品項補回去
--
-- 回報（Alex 2026-08-18）：GRP-20260730-001-TF0002（三峽店，經總倉互助，
--   來源 = 南平店 GRP-20260730-001-TF0001）按了取消之後，那 1 件沒有回到南平。
--
-- 根因：兩條轉單路徑對來源品項的處理**完全不同**，而取消只認得其中一條。
--   - rpc_transfer_order_to_store（整單轉出）：來源品項原封不動，只把單頭推
--     'transferred_out'。→ 取消時單頭退回 confirmed/ready，品項本來就還在，正確。
--   - rpc_transfer_order_partial（部分轉出，互助認領走的就是這支）：來源列
--     **等量 → 整列 cancelled、部分 → qty 遞減**；單頭只有全部轉光才會變
--     'transferred_out'。→ rpc_cancel_aid_order 的復原段一行都沒動
--     customer_order_items，貨在來源單上憑空消失。
--
-- 這個假設在系統裡已經被當成事實了：rpc_restore_cancelled_order（20260818000000）
-- 守衛 3 直接寫「取消時貨已經還給來源單，請到來源單重新轉一次」並擋掉轉入單的
-- 復原 —— 部分轉出的情況下那句話是假的，於是兩邊都救不回來。
--
-- 修法：新增 _restore_transfer_source_items(aid_order, operator, at)，在
-- rpc_cancel_aid_order 把單頭退回**之前**呼叫。分辨兩條路徑的判準：
--   來源單 status = 'transferred_out' 且該 (campaign_item, sku) 還有 active 列
--   → 整單轉出，品項沒被動過，跳過（重複加會生出幽靈品項）。
--   其餘 → 部分轉出，照轉出時的動作反向還原：
--     (a) 來源還有 active 列 → qty += 轉走的量（反向 qty 遞減）
--     (b) 找得到 cancelled 列 → 復活成 pending（反向整列 cancelled）
--     (c) 都沒有 → 補一列
-- 同時把已取消轉入單上的品項標 cancelled，避免兩張單同時掛著同一批貨。
--
-- 不在範圍（維持既有行為，與 sibling RPC 一致）：
--   - mutual_aid_board 的認領量不會自動還（rpc_cancel_aid_order 從來沒動過 board，
--     rpc_return_aid_order 的檔頭也明講刻意不動）。要還請人工調 qty_remaining。
--   - rpc_reject_transfer 有同一段「來源單退回」邏輯、同一個缺口，但它處理的是
--     已出貨後拒收（還要反向庫存），不在本次一起改。
--
-- 基底：rpc_cancel_aid_order = 20260816000070（最新；本檔函式本體從該檔逐字抽出，
--   只加一個變數宣告、一行呼叫、回傳多一個 key、COMMENT 補一段）。
-- rollback: 重跑 20260816000070 的 rpc_cancel_aid_order；
--           DROP FUNCTION public._restore_transfer_source_items(BIGINT, UUID, TIMESTAMPTZ);
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _restore_transfer_source_items
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._restore_transfer_source_items(
  p_aid_order_id BIGINT,
  p_operator     UUID,
  p_at           TIMESTAMPTZ DEFAULT NOW()
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_aid      customer_orders%ROWTYPE;
  v_src      customer_orders%ROWTYPE;
  v_marker   TEXT;
  v_hit      BIGINT;
  v_restored INTEGER := 0;
  r          RECORD;
BEGIN
  SELECT * INTO v_aid FROM customer_orders WHERE id = p_aid_order_id;
  IF NOT FOUND OR v_aid.transferred_from_order_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_src FROM customer_orders
   WHERE id = v_aid.transferred_from_order_id FOR UPDATE;
  IF NOT FOUND OR v_src.status IN ('cancelled', 'expired') THEN
    RETURN 0;
  END IF;

  -- 同一張轉入單只回補一次（重跑 / 重複取消都不會加倍）
  v_marker := '[取消轉入單回補 ← 訂單 #' || v_aid.id || ']';
  IF position(v_marker IN COALESCE(v_src.notes, '')) > 0 THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT id, campaign_item_id, sku_id, qty, unit_price
      FROM customer_order_items
     WHERE order_id = p_aid_order_id
       AND source = 'aid_transfer'
       AND status IN ('pending', 'reserved', 'ready')
     ORDER BY id
  LOOP
    -- 整單轉出：來源品項沒被動過（只有單頭進 transferred_out）→ 不能再加一次
    IF v_src.status = 'transferred_out'
       AND EXISTS (
             SELECT 1 FROM customer_order_items s
              WHERE s.order_id = v_src.id
                AND s.sku_id = r.sku_id
                AND s.campaign_item_id = r.campaign_item_id
                AND s.status IN ('pending', 'reserved', 'ready')
           ) THEN
      CONTINUE;
    END IF;

    v_hit := NULL;

    -- (a) 部分轉出、qty 被遞減 → 加回去
    UPDATE customer_order_items
       SET qty = qty + r.qty, updated_by = p_operator, updated_at = p_at
     WHERE id = (SELECT s.id FROM customer_order_items s
                  WHERE s.order_id = v_src.id
                    AND s.sku_id = r.sku_id
                    AND s.campaign_item_id = r.campaign_item_id
                    AND s.status IN ('pending', 'reserved', 'ready')
                  ORDER BY s.id
                  LIMIT 1)
    RETURNING id INTO v_hit;

    -- (b) 等量轉出、整列被 cancelled → 復活。斷貨列（stockout_at）不碰，
    --     那是採購端的語意，只有 rpc_restore_stockout_po 能還原。
    IF v_hit IS NULL THEN
      UPDATE customer_order_items
         SET status = 'pending', qty = r.qty, updated_by = p_operator, updated_at = p_at
       WHERE id = (SELECT s.id FROM customer_order_items s
                    WHERE s.order_id = v_src.id
                      AND s.sku_id = r.sku_id
                      AND s.campaign_item_id = r.campaign_item_id
                      AND s.status = 'cancelled'
                      AND s.stockout_at IS NULL
                    ORDER BY s.id DESC
                    LIMIT 1)
      RETURNING id INTO v_hit;
    END IF;

    -- (c) 來源列已經不存在 → 補一列
    IF v_hit IS NULL THEN
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, notes, created_by, updated_by, created_at, updated_at
      ) VALUES (
        v_src.tenant_id, v_src.id, r.campaign_item_id, r.sku_id, r.qty, r.unit_price,
        'pending', 'manual', '取消轉入單回補', p_operator, p_operator, p_at, p_at
      );
    END IF;

    v_restored := v_restored + 1;
  END LOOP;

  IF v_restored = 0 THEN
    RETURN 0;
  END IF;

  -- 貨已經還回來源單 → 轉入單上的品項收掉，否則兩張單掛同一批貨
  UPDATE customer_order_items
     SET status = 'cancelled', updated_by = p_operator, updated_at = p_at
   WHERE order_id = p_aid_order_id
     AND source = 'aid_transfer'
     AND status IN ('pending', 'reserved', 'ready');

  UPDATE customer_orders
     SET notes = COALESCE(notes, '') || E'\n' || v_marker || ' ' ||
                 to_char(p_at, 'YYYY-MM-DD HH24:MI:SS'),
         updated_by = p_operator,
         updated_at = p_at
   WHERE id = v_src.id;

  RETURN v_restored;
END;
$fn$;

COMMENT ON FUNCTION public._restore_transfer_source_items(BIGINT, UUID, TIMESTAMPTZ) IS
  '取消轉入單時把來源單被扣掉的品項補回去（只針對部分轉出；整單轉出沒動過來源品項，'
  '以 source.status=transferred_out + 來源仍有 active 列判掉）。同一張轉入單只補一次。';

-- ----------------------------------------------------------------
-- 2. rpc_cancel_aid_order（基底 20260816000070，僅插入 helper 呼叫）
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
  v_is_aid           BOOLEAN := FALSE;
  v_restored         INTEGER := 0;
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
    'wallet_refund_ledger_id', v_refund_ledger_id
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_cancel_aid_order(BIGINT, TEXT, UUID) IS
  '取消訂單（互助/一般/派貨中皆走這支）：回收 transfer chain、退儲值金、寫 audit。'
  '20260816000070：現貨直配（SP-）單在 ready 也可取消（它還沒扣庫存，'
  '取消＝把可分配量放回去），並一併作廢該單開的 DN 減抵單。'
  '20260818000030：取消轉入單時呼叫 _restore_transfer_source_items，'
  '把部分轉出時被扣掉的來源品項補回去（整單轉出不受影響）。';

-- ----------------------------------------------------------------
-- 3. 修補已經踩到的那張單（回報案例）
--    GRP-20260730-001-TF0002 是在本修法上線**之前**取消的，來源單南平
--    GRP-20260730-001-TF0001 的品項還沒補回去 → 直接補跑 helper。
--    helper 自帶回補標記，重跑不會加倍；找不到單就是 no-op。
--
--    不做全站 backfill：歷史上被取消的轉入單，來源單多半早就結案 / 過期 /
--    重新轉給別人了，無差別補列會生出幽靈品項（正是本檔要防的事）。
--    要處理其他個案就照這段複製一行，人工確認來源單狀態後再跑。
-- ----------------------------------------------------------------
DO $backfill$
DECLARE
  v_id       BIGINT;
  v_restored INTEGER;
BEGIN
  SELECT id INTO v_id FROM customer_orders
   WHERE order_no = 'GRP-20260730-001-TF0002'
     AND status = 'cancelled'
     AND transferred_from_order_id IS NOT NULL;
  IF v_id IS NULL THEN
    RAISE NOTICE 'GRP-20260730-001-TF0002 不存在或不是已取消的轉入單，跳過';
    RETURN;
  END IF;
  v_restored := public._restore_transfer_source_items(v_id, NULL, NOW());
  RAISE NOTICE 'GRP-20260730-001-TF0002：回補 % 列到來源單', v_restored;
END
$backfill$;

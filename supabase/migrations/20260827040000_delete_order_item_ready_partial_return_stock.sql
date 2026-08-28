-- ============================================================================
-- 訂單頁「刪除品項」放寬到 ready／partially_completed，刪除時還回已配的庫存，
-- 刪光後訂單自動收尾（取過貨→completed，沒取過→cancelled）
-- ============================================================================
-- 需求（Alex 2026-08-27，訂單 GRP-20260724-002-0001 現場回報）：
--   「可取貨、部分取貨都要可以刪除，有收貨配單就返回庫存，部分取貨都沒來就
--   可以直接刪除 然後訂單都沒項目了就變成已完成」。
--
-- 現況（rpc_delete_order_item v1 = 20260707000040）：
--   狀態閘只放行 status='pending'，一旦訂單被 PR 鎖定變 confirmed / 到貨變
--   ready / 部分取貨變 partially_completed，就再也刪不掉任何品項 —— 例如附圖
--   那張單「部分取貨」，已取的那項沒問題，但另一項「待取」（已用『從庫存配貨』
--   開過 DN 覆蓋）想刪掉却完全沒有入口。
--   而且 v1 從未釋放過 DN 覆蓋 —— 就算之後放寬狀態閘，直接刪只會把「這批貨
--   已經有主人」的主張留在原地，那幾件不會回到別人的可配量。
--
-- 本檔新增／修改：
--   1. _release_order_item_stock_assignment(item_id, qty, operator, reason, at)
--      —— 新 helper，把這一行身上的 DN 覆蓋部分或全部釋放，需要時把當初扣掉
--      的【內部】店現貨池還回去。邏輯逐字對齊 rpc_unassign_stock_from_order_item
--      （20260825020000）的釋放段（明細 released_qty 遞增、單頭歸零就作廢、
--      先還自由量池子留最後），只是抽成獨立 helper 供 rpc_delete_order_item
--      共用；沒有配過貨的行是 no-op（回傳 qty=0）。
--      ⚠ rpc_unassign_stock_from_order_item 本身不動，仍保留自己那份釋放邏輯
--      （它還要做「配貨拆行的待補貨行併回來」「單頭 ready 退回 confirmed」等
--      delete 用不到的事，重寫它風險大於重複這一段）。
--   2. rpc_delete_order_item v2 —— 基底 20260707000040 逐字保留骨架，改動：
--      a. 狀態閘 pending → pending／ready／partially_completed。
--      b. 已取貨（picked_up）品項一律擋下，改走退貨流程（原本 pending 訂單
--         不可能出現 picked_up 品項，這條在 v1 是隱性成立；放寬狀態閘後
--         必須顯式擋）。
--      c. 軟刪之前先呼叫 (1) 還庫存。
--      d. 收尾規則由「刪到 0 個未取消品項」改成「刪到 0 個待取
--         （pending/reserved/ready）品項」再細分兩支：
--           - 有取過貨（picked_up）→ 呼叫既有 _close_orders_all_items_settled
--             （20260808000000）收尾成 completed，與斷貨連動同一套。
--           - 沒取過貨、也沒收過錢 → 沿用 v1 的「整單取消」規則（未付款 +
--             未用儲值金），適用範圍隨狀態閘一起擴大到 ready。
--
-- 基底版本：
--   rpc_delete_order_item        = 20260707000040（唯一版本）
--   _close_orders_all_items_settled = 20260808000000（唯一版本，本檔不改）
--   _restore_internal_pool          = 20260825020000（唯一版本，本檔不改）
--   _order_item_stock_budget        = 20260824070000（唯一版本，本檔不改）
-- Rollback：
--   重跑 20260707000040 還原 rpc_delete_order_item；
--   DROP FUNCTION public._release_order_item_stock_assignment(BIGINT,NUMERIC,UUID,TEXT,TIMESTAMPTZ);
--   已經還回庫存/池子的 DN 不會自動復原：要復原就重新配一次
--   （同 20260825020000 的取捨，該檔「取消配貨」也是同樣不可逆）。
--
-- 對應前端（同一個 commit）：
--   apps/admin/src/components/OrderDetail.tsx（刪除鈕的狀態閘 canDeleteItem，
--   放寬到 ready／partially_completed；提示文字依「有沒有取過貨」分流）。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. _release_order_item_stock_assignment —— 把這一行的 DN 覆蓋還回庫存/池子
--    邏輯對齊 rpc_unassign_stock_from_order_item（20260825020000）的釋放段
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._release_order_item_stock_assignment(
  p_item_id  BIGINT,
  p_qty      NUMERIC DEFAULT NULL,   -- NULL = 這一行配過的全部收回
  p_operator UUID    DEFAULT NULL,
  p_reason   TEXT    DEFAULT NULL,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_b          RECORD;
  v_qty        NUMERIC;
  v_left       NUMERIC;
  v_take       NUMERIC;
  v_pool_take  NUMERIC;
  v_pool_done  NUMERIC;
  v_pool_total NUMERIC := 0;
  v_pool_miss  NUMERIC := 0;
  v_free_rest  NUMERIC;
  v_pool_rest  NUMERIC;
  v_note_rest  NUMERIC;
  v_notes      TEXT[] := ARRAY[]::TEXT[];
  v_n          RECORD;
  v_tag        TEXT;
BEGIN
  SELECT * INTO v_b FROM public._order_item_stock_budget(p_item_id);
  IF NOT FOUND OR v_b.order_id IS NULL THEN
    RAISE EXCEPTION '找不到訂單品項 #%', p_item_id;
  END IF;

  -- 與配貨／取消配貨搶同一把鎖：三邊動的是同一批實體庫存的主張
  PERFORM pg_advisory_xact_lock(hashtext(format('spotsale:%s:%s:%s',
    v_b.tenant_id, v_b.store_id, v_b.sku_id)));

  SELECT * INTO v_b FROM public._order_item_stock_budget(p_item_id);

  -- 沒配過貨的行（多數情形）：no-op
  IF v_b.assigned <= 0 THEN
    RETURN jsonb_build_object('qty', 0, 'to_pool', 0, 'pool_missing', 0, 'notes', '[]'::jsonb);
  END IF;

  v_qty := COALESCE(p_qty, v_b.assigned);
  IF v_qty > v_b.assigned THEN
    RAISE EXCEPTION '這一行只從庫存配過 % 件，不能收回 % 件', v_b.assigned, v_qty;
  END IF;

  v_left := v_qty;
  v_tag  := COALESCE(NULLIF(TRIM(p_reason), ''), '刪除品項');

  -- 逐張 DN 釋放覆蓋（後配的先收回）。記法對齊 rpc_unassign_stock_from_order_item：
  -- 明細 released_qty 遞增、單頭 qty 遞減、整張歸零就作廢，不刪列。
  FOR v_n IN
    SELECT ni.id AS ni_id, ni.qty AS ni_qty, COALESCE(ni.released_qty, 0) AS ni_released,
           n.id AS note_id, n.note_no,
           COALESCE(n.pool_qty, 0) AS pool_qty,
           COALESCE(n.pool_restored_qty, 0) AS pool_restored
      FROM inventory_deduction_note_items ni
      JOIN inventory_deduction_notes n ON n.id = ni.note_id
     WHERE ni.order_item_id = p_item_id
       AND n.cancelled_at IS NULL
       AND ni.qty > COALESCE(ni.released_qty, 0)
     ORDER BY n.id DESC
       FOR UPDATE OF ni, n
  LOOP
    EXIT WHEN v_left <= 0;

    v_take := LEAST(v_n.ni_qty - v_n.ni_released, v_left);

    UPDATE inventory_deduction_note_items
       SET released_qty = v_n.ni_released + v_take
     WHERE id = v_n.ni_id;

    -- 這張單還沒還的池子量，以及「非池子」的那部分還剩多少 ——
    -- 先還自由量、池子留到最後才還（同 rpc_unassign_stock_from_order_item）
    v_pool_rest := GREATEST(v_n.pool_qty - v_n.pool_restored, 0);
    v_free_rest := GREATEST((v_n.ni_qty - v_n.ni_released) - v_pool_rest, 0);
    v_pool_take := GREATEST(v_take - v_free_rest, 0);

    IF v_pool_take > 0 THEN
      v_pool_done := public._restore_internal_pool(
        v_b.store_id, v_b.sku_id, v_pool_take, p_operator, p_at,
        '[已配給訂單 ' || v_b.order_no || ' ' || v_n.note_no || ']');
      -- 還不回去（池子那幾列已經被別的流程動過）就記帳、不擋下整筆刪除：
      -- 覆蓋已經釋放，那幾件會以「自由量」的身分回到可配量，總量不會憑空多出來。
      v_pool_miss  := v_pool_miss + (v_pool_take - v_pool_done);
      v_pool_total := v_pool_total + v_pool_done;
      UPDATE inventory_deduction_notes
         SET pool_restored_qty = v_n.pool_restored + v_pool_take
       WHERE id = v_n.note_id;
    END IF;

    -- 單頭：整張覆蓋歸零 → 作廢；還有剩 → qty 遞減
    SELECT COALESCE(SUM(GREATEST(x.qty - COALESCE(x.released_qty, 0), 0)), 0)
      INTO v_note_rest
      FROM inventory_deduction_note_items x
     WHERE x.note_id = v_n.note_id;

    IF v_note_rest <= 0 THEN
      UPDATE inventory_deduction_notes
         SET cancelled_at = p_at,
             cancelled_by = p_operator,
             reason = NULLIF(TRIM(COALESCE(reason, '')
                       || format(' [%s，覆蓋全數釋放]', v_tag)), '')
       WHERE id = v_n.note_id;
    ELSE
      UPDATE inventory_deduction_notes
         SET qty = v_note_rest,
             reason = NULLIF(TRIM(COALESCE(reason, '')
                       || format(' [%s，釋放 %s 件]', v_tag, trim_scale(v_take)::text)), '')
       WHERE id = v_n.note_id;
    END IF;

    v_notes := v_notes || v_n.note_no;
    v_left  := v_left - v_take;
  END LOOP;

  IF v_left > 0 THEN
    RAISE EXCEPTION '只收得回 % 件（要求 % 件），請重新整理後再試', v_qty - v_left, v_qty;
  END IF;

  RETURN jsonb_build_object(
    'qty',          v_qty,
    'to_pool',      v_pool_total,
    'pool_missing', v_pool_miss,
    'notes',        to_jsonb(v_notes)
  );
END;
$$;

COMMENT ON FUNCTION public._release_order_item_stock_assignment(BIGINT, NUMERIC, UUID, TEXT, TIMESTAMPTZ) IS
  '把這一行身上還有效的 DN 覆蓋（rpc_assign_stock_to_order_item 開的）部分或全部釋放，'
  '需要時把當初扣掉的【內部】店現貨池還回去（_restore_internal_pool）。邏輯對齊 '
  'rpc_unassign_stock_from_order_item（20260825020000）的釋放段，供 rpc_delete_order_item '
  '共用；p_qty=NULL 時收回全部，沒有配過貨的行是 no-op（回傳 qty=0）。不動 stock_balances —— '
  '配貨本來就沒扣庫存，這裡只是把「這批貨有主人」的主張拿掉。';

REVOKE ALL ON FUNCTION public._release_order_item_stock_assignment(BIGINT, NUMERIC, UUID, TEXT, TIMESTAMPTZ)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._release_order_item_stock_assignment(BIGINT, NUMERIC, UUID, TEXT, TIMESTAMPTZ)
  TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. rpc_delete_order_item v2 —— 基底 20260707000040，狀態閘放寬 + 先還庫存
--    + 收尾規則改用「待取品項數」與「有沒有取過貨」判斷
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_delete_order_item(
  p_order_id BIGINT,
  p_item_id  BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order           customer_orders%ROWTYPE;
  v_old_status      TEXT;
  v_tag             TEXT;
  v_released        JSONB := '{}'::jsonb;
  v_open_remaining  INTEGER;
  v_has_picked      BOOLEAN;
  v_order_cancelled BOOLEAN := FALSE;
  v_order_completed BOOLEAN := FALSE;
BEGIN
  -- 1. 權限 + 鎖訂單（HQ 全部 / 店長限自家 pickup_store）
  v_order := _check_order_edit_qty_perm(p_order_id);

  -- 2. 狀態閘：pending／ready／partially_completed
  --    20260827040000 起放寬（原僅 pending）：可取貨、部分取貨的訂單也能
  --    刪掉還沒取的品項。confirmed 仍被 PR 鎖定、shipping 貨還在路上，不放寬。
  IF v_order.status NOT IN ('pending', 'ready', 'partially_completed') THEN
    RAISE EXCEPTION '訂單狀態為 %,僅 待確認／可取貨／部分取貨 訂單可刪除品項', v_order.status;
  END IF;

  -- 3. 取品項並上鎖
  SELECT status INTO v_old_status
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  -- 4. 已取消/已過期視為已刪，no-op 短路
  IF v_old_status IN ('cancelled', 'expired') THEN
    RETURN jsonb_build_object(
      'item_id', p_item_id, 'already_removed', TRUE,
      'order_cancelled', FALSE, 'order_completed', FALSE
    );
  END IF;

  -- 5. 已取貨的品項不能刪 —— 貨已經交出去了，要收回請走退貨流程（不是這裡）。
  --    v1 沒有這條是因為狀態閘只放行 pending，pending 訂單不可能出現
  --    picked_up 品項；放寬到 ready/partially_completed 後必須顯式擋。
  IF v_old_status = 'picked_up' THEN
    RAISE EXCEPTION '品項已取貨，不能刪除（請走退貨流程）';
  END IF;

  v_tag := COALESCE(NULLIF(BTRIM(p_reason), ''), '刪除品項');

  -- 6. 有從庫存配過貨（rpc_assign_stock_to_order_item 開的 DN 覆蓋）先還回
  --    庫存／現貨池，再刪；沒配過貨的品項（多數情形）這一步是 no-op。
  v_released := public._release_order_item_stock_assignment(
                  p_item_id, NULL, p_operator, v_tag, NOW());

  -- 7. 軟刪：標記 cancelled（stockout_at 保持 NULL = 人工刪除）
  UPDATE customer_order_items
     SET status     = 'cancelled',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id;

  -- 8. 稽核
  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'status',
     to_jsonb(v_old_status), to_jsonb('cancelled'::TEXT), p_reason, p_operator);

  -- 9. 收尾：還有沒有待取品項（pending/reserved/ready）、有沒有取過貨。
  --    口徑同 _close_orders_all_items_settled / rpc_record_pickup 的 v_active_remaining。
  SELECT COUNT(*) FILTER (WHERE status IN ('pending','reserved','ready')),
         bool_or(status = 'picked_up')
    INTO v_open_remaining, v_has_picked
    FROM customer_order_items
   WHERE order_id = p_order_id;

  IF v_open_remaining = 0 THEN
    IF v_has_picked THEN
      -- 取過貨、已無待取品項 → 收尾成 completed（與斷貨連動同一支 helper，
      -- 20260808000000；即附圖情境：部分取貨單刪掉最後一項待取品項）
      v_order_completed := public._close_orders_all_items_settled(
                              ARRAY[p_order_id], p_operator, NOW()) > 0;
    ELSIF COALESCE(v_order.payment_status, 'unpaid') <> 'paid'
          AND COALESCE(v_order.wallet_paid_amount, 0) = 0 THEN
      -- 一件都沒取過、也沒收過錢 → 整單取消（沿用 v1 規則，適用範圍隨狀態閘
      -- 一起擴大到 ready；partially_completed 必有 picked_up，不會落到這支）
      UPDATE customer_orders
         SET status       = 'cancelled',
             cancelled_at = NOW(),
             updated_by   = p_operator,
             updated_at   = NOW()
       WHERE id = p_order_id
         AND status = v_order.status;
      v_order_cancelled := TRUE;

      INSERT INTO customer_order_audit_log
        (tenant_id, order_id, entity_type, entity_id, field,
         before_value, after_value, edit_reason, operator_id)
      VALUES
        (v_order.tenant_id, p_order_id, 'order', p_order_id, 'status',
         to_jsonb(v_order.status), to_jsonb('cancelled'::TEXT),
         COALESCE(NULLIF(BTRIM(p_reason), '') || ' / ', '') || '刪除最後一個品項自動取消整單',
         p_operator);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'item_id',         p_item_id,
    'already_removed', FALSE,
    'order_cancelled', v_order_cancelled,
    'order_completed', v_order_completed,
    'remaining_items', v_open_remaining,
    'stock_released',  v_released
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_delete_order_item(BIGINT, BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_order_item IS
  '刪除訂單的單一品項（軟刪：status->cancelled，stockout_at 留 NULL 代表人工刪除）。'
  'HQ tier 全部 / 店長限 app_metadata.stores 含訂單 pickup_store；'
  '訂單須為 pending／ready／partially_completed（20260827040000 起放寬 ready／'
  'partially_completed，原僅 pending）；已取貨的品項不能刪（走退貨流程）；'
  '有從庫存配過貨先還回庫存/現貨池（_release_order_item_stock_assignment）；'
  '寫 customer_order_audit_log；刪光後沒有待取品項時：取過貨 → 收尾成 completed'
  '（_close_orders_all_items_settled），沒取過且未收款 → 整單取消。';

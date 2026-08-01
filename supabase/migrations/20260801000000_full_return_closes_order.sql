-- ============================================================
-- 2026-08-01: 未取退貨退光後訂單自動收尾 + 退貨單拒收不再誤取消訂單
--
-- 回報案例（訂單 GRP-20260615-017-0013，湖口店）：
--   店端把唯一品項（2 件）全數退回總倉後，訂單仍留在取貨頁「未取訂單」
--   清單、還顯示「1 項可取」；點開取貨視窗才看得到「已全數退回總倉，
--   無可取貨項目」。根因：rpc_create_order_return 只建 return_to_hq
--   transfer + 庫存異動，訂單/品項狀態完全不動 → 訂單永遠掛在
--   ready，前端清單頁又只看品項狀態（不看退貨量）。
--
-- 三段修法 + 資料治理：
--   1. rpc_create_order_return 加「全數退貨收尾」：未取池（各 SKU
--      已收 R − 已取 P）被未取退貨（notes header 不含 |取貨後退回）
--      退光時：
--        - 無任何已取品項（ready/shipping）→ status='cancelled'
--          （對齊互助單 rpc_return_aid_order「全退＝取消」的語意）
--        - 已有已取品項（partially_completed）→ status='completed'
--          （客人已取的照收，剩餘退回，訂單結案）
--        - completed / expired → 不動（docs/TEST-return-scenarios.md E.7）
--      品項行狀態刻意不動（保持 active）：v_customer_order_summary /
--      rpc_wallet_pay_order 的未取退貨扣減（20260731000000）把退貨量
--      分攤到「非 cancelled/expired」品項行；若把行改 cancelled，
--      扣減會歸零、應收跳回全額。
--   2. rpc_reject_transfer 分流 return_to_hq：舊行為沿用互助單邏輯把
--      customer_order_id 指到的「原訂單」設 cancelled — 這是 30709 事故
--      根因（scripts/PROD-fix-order-30709-restore-after-return-reject.sql
--      手修過一次）。退貨單拒收＝貨退回店端，原訂單應復原可取而非取消：
--        - 曾被本次收尾成 cancelled（有 active 品項、無已取）→ 回 ready
--        - 曾被收尾成 completed（仍有 active 品項）→ 回 partially_completed
--        - 其他（正常 ready / partially_completed / expired…）→ 不動
--      並且 return_to_hq 一律不走互助單的「取消訂單＋還原來源單」邏輯。
--   3. rpc_record_pickup 的收尾判斷（active_remaining）扣掉退貨覆蓋：
--      部分退貨後取走剩餘可取量時（例：訂 5、退 2、取 3），殘留的
--      active 行量已被退貨覆蓋，訂單應 completed，否則永遠卡在
--      partially_completed（與修法 1 同型、發生在取貨端的變體）。
--   4. 資料治理（冪等）：線上既有「已全數退貨仍掛 shipping/ready/
--      partially_completed」的訂單，按修法 1 的規則收尾。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   - rpc_create_order_return：20260707000080_rpc_order_return_store_scope.sql
--     （僅在主迴圈後加收尾一段、result 加 order_closed_as）
--   - rpc_reject_transfer：20260731000000_reject_transfer_wave_guard_and_rpc_unreject.sql
--     （僅把「找 customer_order 後的取消/還原來源單」包進非 return_to_hq 分支，
--      並新增 return_to_hq 復原分支；result 加 restored_co_id / restored_status）
--   - rpc_record_pickup：20260731000000_return_deduct_payable_and_pickup_guard.sql
--     （僅改 v_active_remaining 計算式：排除「量已被未取退貨覆蓋」的 SKU）
-- Rollback：
--   - rpc_create_order_return 還原為 20260707000080 版本
--   - rpc_reject_transfer 還原為 20260731000000（wave guard）版本
--   - rpc_record_pickup 還原為 20260731000000（return guard）版本
--   - 資料治理不自動回滾；被收尾的單可依 customer_orders.updated_at 與
--     return transfer 對照後手動改回 ready/partially_completed
-- ============================================================

-- ------------------------------------------------------------
-- 1. rpc_create_order_return — 全數退貨收尾
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_create_order_return(
  p_order_id      BIGINT,
  p_lines         JSONB,
  p_reason        TEXT    DEFAULT NULL,
  p_operator      UUID    DEFAULT NULL,
  p_movement_type TEXT    DEFAULT 'customer_return',
  p_restock_first BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_user           UUID := COALESCE(p_operator, auth.uid());
  v_role           TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_order          customer_orders%ROWTYPE;
  v_store_loc      BIGINT;
  v_hq_loc         BIGINT;
  v_transfer_id    BIGINT;
  v_transfer_no    TEXT;
  v_line           JSONB;
  v_sku_id         BIGINT;
  v_qty            NUMERIC;
  v_delivered      NUMERIC;  -- R：該 SKU 已收(訂單)量（含已取貨）
  v_picked         NUMERIC;  -- P：該 SKU 已取貨量（status='picked_up'）
  v_ret_unpicked   NUMERIC;  -- 已退量：一般退貨（未帶 |取貨後退回 tag）
  v_ret_picked     NUMERIC;  -- 已退量：取貨後退回（帶 |取貨後退回 tag）
  v_returnable     NUMERIC;
  v_mov_id         BIGINT;
  v_count          INT := 0;
  v_result_lines   JSONB := '[]'::JSONB;
  v_reason_note    TEXT;
  v_type_tag       TEXT;
  v_closed_as      TEXT := NULL;  -- 全數退貨收尾結果（'cancelled' / 'completed' / NULL）
BEGIN
  -- P1: 驗 movement_type（只允許這兩種、皆在 stock_movements CHECK 內）
  IF p_movement_type IS NULL OR p_movement_type NOT IN ('customer_return','damage') THEN
    RAISE EXCEPTION 'invalid p_movement_type % (must be customer_return or damage)', p_movement_type;
  END IF;

  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','clerk','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create order return', v_role;
  END IF;

  SELECT * INTO v_order
    FROM customer_orders
   WHERE id = p_order_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order % not found in tenant', p_order_id;
  END IF;
  IF v_order.status NOT IN ('shipping','ready','partially_completed','completed','expired') THEN
    RAISE EXCEPTION 'order % status=% cannot be returned (must be shipping/ready/partially_completed/completed/expired)',
      p_order_id, v_order.status;
  END IF;

  SELECT location_id INTO v_store_loc
    FROM stores
   WHERE id = v_order.pickup_store_id AND tenant_id = v_tenant;
  IF v_store_loc IS NULL THEN
    RAISE EXCEPTION 'pickup store % has no location_id', v_order.pickup_store_id;
  END IF;

  SELECT id INTO v_hq_loc
    FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN
    RAISE EXCEPTION 'no active central_warehouse location for tenant';
  END IF;
  IF v_hq_loc = v_store_loc THEN
    RAISE EXCEPTION 'pickup store location is HQ; cannot return to self';
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  -- role 限制：店端只能退自家店訂單。store role 的「自己店」由 app_metadata.stores
  -- 店名經 _jwt_store_ids() 推導（本系統 JWT 無 store_id claim）。
  IF v_role IN ('store_manager','store_staff','clerk') THEN
    IF NOT (v_order.pickup_store_id = ANY (public._jwt_store_ids())) THEN
      RAISE EXCEPTION 'store role can only return orders for own store';
    END IF;
  END IF;

  v_transfer_no := public._next_transfer_no();
  -- 在 notes 加標記（HQ 收貨端 / 對帳 / 訂單退貨記錄看得出退貨情境）：
  --   破損 → |破損；客戶已取貨後退回 (restock_first) → |取貨後退回
  v_type_tag := '';
  IF p_movement_type = 'damage' THEN
    v_type_tag := v_type_tag || '|破損';
  END IF;
  IF p_restock_first THEN
    v_type_tag := v_type_tag || '|取貨後退回';
  END IF;
  v_reason_note := CASE
    WHEN NULLIF(TRIM(COALESCE(p_reason,'')),'') IS NOT NULL
    THEN '[order return' || v_type_tag || ': ' || TRIM(p_reason) || ']'
    ELSE '[order return' || v_type_tag || ']'
  END;

  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, customer_order_id,
    requested_by, shipped_by, shipped_at,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_transfer_no, v_store_loc, v_hq_loc,
    'shipped', 'return_to_hq', p_order_id,
    v_user, v_user, NOW(),
    v_reason_note, v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku_id := (v_line ->> 'sku_id')::BIGINT;
    v_qty    := (v_line ->> 'qty')::NUMERIC;

    IF v_sku_id IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'invalid line: sku_id=% qty=%', v_sku_id, v_qty;
    END IF;

    -- R：該 SKU 已收(訂單)量（含已取貨；single source of truth = customer_order_items）
    SELECT COALESCE(SUM(coi.qty), 0) INTO v_delivered
      FROM customer_order_items coi
     WHERE coi.order_id = p_order_id
       AND coi.sku_id = v_sku_id
       AND coi.status NOT IN ('cancelled','expired');

    IF v_delivered <= 0 THEN
      RAISE EXCEPTION 'sku % is not in order % (or is cancelled/expired)', v_sku_id, p_order_id;
    END IF;

    -- P：該 SKU 已取貨量（部分取貨會拆出獨立的 picked_up 行）
    SELECT COALESCE(SUM(coi.qty), 0) INTO v_picked
      FROM customer_order_items coi
     WHERE coi.order_id = p_order_id
       AND coi.sku_id = v_sku_id
       AND coi.status = 'picked_up';

    -- 已退量分兩池（依 notes 是否含 |取貨後退回 tag），本筆 transfer 還沒含進來
    SELECT
      COALESCE(SUM(ti.qty_shipped) FILTER (WHERE t.notes LIKE '%|取貨後退回%'), 0),
      COALESCE(SUM(ti.qty_shipped) FILTER (WHERE t.notes IS NULL OR t.notes NOT LIKE '%|取貨後退回%'), 0)
      INTO v_ret_picked, v_ret_unpicked
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.customer_order_id = p_order_id
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('shipped','received')
       AND t.source_location = v_store_loc
       AND t.id <> v_transfer_id
       AND ti.sku_id = v_sku_id;

    -- 退貨上限：依是否「已取貨後退回」分流
    IF p_restock_first THEN
      -- 客戶取走又拿回來：上限 = 已取貨量 − 已退(取貨後)量
      v_returnable := v_picked - v_ret_picked;
      IF v_qty > v_returnable THEN
        RAISE EXCEPTION 'sku %: 取貨後退回 qty % exceeds picked-up returnable % (picked=%, already_returned_after_pickup=%)',
          v_sku_id, v_qty, v_returnable, v_picked, v_ret_picked;
      END IF;
    ELSE
      -- 退店端「未取貨」的貨：上限 = (已收 − 已取) − 已退(一般)量
      v_returnable := (v_delivered - v_picked) - v_ret_unpicked;
      IF v_qty > v_returnable THEN
        RAISE EXCEPTION 'sku %: qty % exceeds returnable % (delivered=%, picked_up=%, already_returned=%)',
          v_sku_id, v_qty, v_returnable, v_delivered, v_picked, v_ret_unpicked;
      END IF;
    END IF;

    -- P2-A: 取貨後反悔 — 先把退回的貨入庫店端（customer_return inbound），
    -- 之後 outbound 才有庫存可扣。unit_cost=0 → 不動 avg_cost。
    IF p_restock_first THEN
      PERFORM rpc_inbound(
        p_tenant_id       => v_tenant,
        p_location_id     => v_store_loc,
        p_sku_id          => v_sku_id,
        p_quantity        => v_qty,
        p_unit_cost       => 0,
        p_movement_type   => 'customer_return',
        p_source_doc_type => 'customer_order',
        p_source_doc_id   => p_order_id,
        p_operator        => v_user
      );
    END IF;

    -- 出庫店端 → 在途回總倉。P1: movement_type 由參數決定。
    v_mov_id := rpc_outbound(
      p_tenant_id       => v_tenant,
      p_location_id     => v_store_loc,
      p_sku_id          => v_sku_id,
      p_quantity        => v_qty,
      p_movement_type   => p_movement_type,
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_transfer_id,
      p_operator        => v_user
    );

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped,
      out_movement_id, notes, created_by, updated_by
    ) VALUES (
      v_transfer_id, v_sku_id, v_qty, v_qty,
      v_mov_id, v_line ->> 'notes', v_user, v_user
    );

    v_result_lines := v_result_lines || jsonb_build_object(
      'sku_id', v_sku_id,
      'qty', v_qty,
      'out_movement_id', v_mov_id
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  -- ── 全數退貨收尾（2026-08-01）──
  -- 未取池 = 各 SKU active(pending/reserved/ready) 量；未取退貨（含本筆、
  -- notes header 不含 |取貨後退回）把未取池退光後，訂單不該繼續掛在取貨清單
  -- （回報案例：湖口 GRP-20260615-017-0013 全退後仍顯示「1 項可取」）。
  -- 品項行刻意不動：20260731000000 的應收扣減把退貨量分攤到非 cancelled/expired
  -- 行，改行狀態會讓扣減歸零、應收跳回全額。
  IF v_order.status IN ('shipping','ready','partially_completed') THEN
    IF NOT EXISTS (
      SELECT 1
        FROM (
          SELECT coi.sku_id, SUM(coi.qty) AS active_qty
            FROM customer_order_items coi
           WHERE coi.order_id = p_order_id
             AND coi.status IN ('pending','reserved','ready')
           GROUP BY coi.sku_id
        ) act
        LEFT JOIN (
          SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
            FROM transfers t
            JOIN transfer_items ti ON ti.transfer_id = t.id
           WHERE t.customer_order_id = p_order_id
             AND t.tenant_id     = v_tenant
             AND t.transfer_type = 'return_to_hq'
             AND t.status IN ('shipped','received')
             AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
                 NOT LIKE '%取貨後退回%'
           GROUP BY ti.sku_id
        ) r ON r.sku_id = act.sku_id
       WHERE act.active_qty - COALESCE(r.ret_qty, 0) > 0
    ) THEN
      IF EXISTS (
        SELECT 1 FROM customer_order_items
         WHERE order_id = p_order_id AND status = 'picked_up'
      ) THEN
        v_closed_as := 'completed';
        UPDATE customer_orders
           SET status       = 'completed',
               completed_at = NOW(),
               updated_by   = v_user,
               updated_at   = NOW()
         WHERE id = p_order_id;
      ELSE
        v_closed_as := 'cancelled';
        UPDATE customer_orders
           SET status       = 'cancelled',
               cancelled_at = NOW(),
               updated_by   = v_user,
               updated_at   = NOW()
         WHERE id = p_order_id;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'return_transfer_id', v_transfer_id,
    'transfer_no', v_transfer_no,
    'order_id', p_order_id,
    'source_location', v_store_loc,
    'dest_location', v_hq_loc,
    'movement_type', p_movement_type,
    'restocked_first', p_restock_first,
    'order_closed_as', v_closed_as,
    'lines', v_result_lines
  );
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_create_order_return(BIGINT, JSONB, TEXT, UUID, TEXT, BOOLEAN)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_order_return IS
  '分店發起退訂單回總倉。allowed status: shipping/ready/partially_completed/completed/expired。'
  'p_movement_type: customer_return(預設) / damage（破損、notes 加|破損標記）。'
  'p_restock_first=true: 取貨後反悔，先 customer_return inbound 再 outbound 回總倉；notes 加 |取貨後退回。'
  '退貨上限分流：restock_first=true → 已取貨量 − 已退(取貨後)；false → (已收 − 已取) − 已退(一般)。'
  '店端角色只能退自家店訂單，自己店由 app_metadata.stores 經 _jwt_store_ids() 判定。'
  '非 restock 路徑不夠店端庫存時由 rpc_outbound 擋 Insufficient stock。'
  '全數退貨收尾：未取池退光 → 無已取品項設 cancelled、有已取設 completed（品項行不動），result.order_closed_as 回報。';

-- ------------------------------------------------------------
-- 2. rpc_reject_transfer — return_to_hq 拒收改「復原訂單」，不再誤取消
-- ------------------------------------------------------------

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

  -- 3. 找 customer_order
  v_co_id := v_xfer.customer_order_id;
  IF v_co_id IS NULL AND v_next.id IS NOT NULL THEN
    v_co_id := v_next.customer_order_id;
  END IF;

  -- ── return_to_hq（訂單退貨單）拒收（2026-08-01）──
  -- 舊行為沿用互助單邏輯把原訂單設 cancelled，是 30709 事故根因
  -- （scripts/PROD-fix-order-30709-restore-after-return-reject.sql 手修過）。
  -- 退貨單拒收＝貨已由上面的 transfer_reject inbound 回到店端，原訂單應
  -- 「復原可取」而不是取消：
  --   - 曾因全數退貨收尾成 cancelled（有 active 品項、無已取）→ 回 ready
  --   - 曾因全數退貨收尾成 completed（仍有 active 品項）→ 回 partially_completed
  --   - 其他（正常 ready / partially_completed / expired…）→ 不動
  --     （被拒收的 transfer 已 cancelled，之後的可取量/應收扣減查詢自動不再計入）
  IF v_xfer.transfer_type = 'return_to_hq' THEN
    IF v_co_id IS NOT NULL THEN
      SELECT * INTO v_ret_co FROM customer_orders WHERE id = v_co_id FOR UPDATE;
      IF v_ret_co.status = 'cancelled'
         AND EXISTS (SELECT 1 FROM customer_order_items
                      WHERE order_id = v_co_id AND status IN ('pending','reserved','ready'))
         AND NOT EXISTS (SELECT 1 FROM customer_order_items
                          WHERE order_id = v_co_id AND status = 'picked_up') THEN
        v_restored_co_id  := v_co_id;
        v_restored_status := 'ready';
        UPDATE customer_orders
           SET status       = 'ready',
               ready_at     = COALESCE(ready_at, NOW()),
               cancelled_at = NULL,
               updated_by   = p_operator,
               updated_at   = NOW()
         WHERE id = v_co_id;
      ELSIF v_ret_co.status = 'completed'
         AND EXISTS (SELECT 1 FROM customer_order_items
                      WHERE order_id = v_co_id AND status IN ('pending','reserved','ready')) THEN
        v_restored_co_id  := v_co_id;
        v_restored_status := 'partially_completed';
        UPDATE customer_orders
           SET status       = 'partially_completed',
               completed_at = NULL,
               updated_by   = p_operator,
               updated_at   = NOW()
         WHERE id = v_co_id;
      END IF;
    END IF;
    v_co_id := NULL;  -- 不走互助單「取消訂單＋還原來源單」邏輯；JSON cancelled_co_id 維持 NULL
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
    'restored_co_id', v_restored_co_id,
    'restored_status', v_restored_status,
    'leg3_transfer_id', v_leg3_id,
    'source_order_reverted', v_co.transferred_from_order_id IS NOT NULL,
    'source_order_pickable', v_src_pickable
  );
END;
$$;

COMMENT ON FUNCTION rpc_reject_transfer IS
  'Transfer 拒收：反向 inbound、cancel 後續 chain。'
  '互助單（非 return_to_hq）：customer_order 取消、source order 回 confirmed。'
  'return_to_hq 退貨單：不取消原訂單（30709 事故防呆）；曾因全數退貨被收尾的訂單復原'
  '（cancelled→ready / completed→partially_completed），result 帶 restored_co_id / restored_status。'
  '波次派貨單分店不可拒收（20260731 守衛）。';

-- ------------------------------------------------------------
-- 3. rpc_record_pickup — active_remaining 扣掉未取退貨覆蓋量
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_record_pickup(
  p_order_id  bigint,
  p_item_ids  bigint[],
  p_operator  uuid,
  p_notes     text  DEFAULT NULL,
  p_item_qtys jsonb DEFAULT NULL   -- {"<item_id>": <取貨數量>}；缺項或 >=qty 視為整行取
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_pickup_loc       BIGINT;
  v_item             RECORD;
  v_ret_guard        RECORD;
  v_take             NUMERIC;
  v_picked_disc      NUMERIC;
  v_movement_id      BIGINT;
  v_new_item_id      BIGINT;
  v_picked_item_id   BIGINT;
  v_picked_count     INT := 0;
  v_event_item_ids   BIGINT[] := ARRAY[]::BIGINT[];
  v_active_remaining INT;
  v_new_status       TEXT;
  v_event_type       TEXT;
  v_event_id         BIGINT;
  v_sku_label        TEXT;
  v_now              TIMESTAMPTZ := NOW();
BEGIN
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_item_ids is empty';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_pickup:' || p_order_id::text));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 %', p_order_id;
  END IF;

  IF v_order.status IN ('completed','expired','cancelled','transferred_out') THEN
    RAISE EXCEPTION '訂單 % 目前狀態為「%」，無法取貨', p_order_id, v_order.status;
  END IF;

  SELECT location_id INTO v_pickup_loc
    FROM stores
   WHERE id = v_order.pickup_store_id;

  IF v_pickup_loc IS NULL THEN
    RAISE EXCEPTION '分店 % 未設定倉庫位置 (location_id)、無法寫 stock_movement', v_order.pickup_store_id;
  END IF;

  -- 退貨守門：同 SKU「本次取貨量」不得超過「active 品項量 − 未取退貨量」。
  -- 未取退貨（return_to_hq、notes header 不含 |取貨後退回）的貨已離店，
  -- 不能再被結帳；取貨後退回不計入（那批貨的錢在取貨時已收）。
  -- 前端 PickupDialog 有同款防線，但畫面 stale 時會失效，這裡是最後防線。
  FOR v_ret_guard IN
    SELECT r.sku_id, r.ret_qty,
           COALESCE(act.active_qty, 0) AS active_qty,
           COALESCE(req.take_qty, 0)   AS take_qty
      FROM (
        SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.customer_order_id = p_order_id
           AND t.tenant_id     = v_order.tenant_id
           AND t.transfer_type = 'return_to_hq'
           AND t.status IN ('shipped','received')
           AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
               NOT LIKE '%取貨後退回%'
         GROUP BY ti.sku_id
      ) r
      LEFT JOIN (
        SELECT coi.sku_id, SUM(coi.qty) AS active_qty
          FROM customer_order_items coi
         WHERE coi.order_id = p_order_id
           AND coi.status IN ('pending','reserved','ready')
         GROUP BY coi.sku_id
      ) act ON act.sku_id = r.sku_id
      LEFT JOIN (
        -- 本次各 SKU 取貨量（缺項＝整行取；clamp 到行量，超量交給主迴圈報錯）
        SELECT coi.sku_id,
               SUM(LEAST(COALESCE((p_item_qtys ->> coi.id::text)::numeric, coi.qty), coi.qty)) AS take_qty
          FROM customer_order_items coi
         WHERE coi.id = ANY(p_item_ids)
           AND coi.order_id = p_order_id
         GROUP BY coi.sku_id
      ) req ON req.sku_id = r.sku_id
     WHERE COALESCE(req.take_qty, 0) > COALESCE(act.active_qty, 0) - r.ret_qty
  LOOP
    SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
      INTO v_sku_label FROM skus s WHERE s.id = v_ret_guard.sku_id;
    RAISE EXCEPTION '品項「%」已退貨 % 件，本次最多可取 % 件（畫面資料可能過舊，請重新整理後再取）',
      COALESCE(v_sku_label, v_ret_guard.sku_id::text),
      v_ret_guard.ret_qty,
      GREATEST(v_ret_guard.active_qty - v_ret_guard.ret_qty, 0);
  END LOOP;

  -- 逐品項：判斷整行取 or 拆行部分取
  FOR v_item IN
    SELECT id, sku_id, qty, unit_price, status, source, campaign_item_id,
           tenant_id, notes, discount_amount, discount_percent, created_by
      FROM customer_order_items
     WHERE id = ANY(p_item_ids)
       AND order_id = p_order_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.status NOT IN ('pending','reserved','ready') THEN
      RAISE EXCEPTION '品項 % 狀態 % 不可取貨', v_item.id, v_item.status;
    END IF;

    -- 逐品項到貨擋板（取代舊的整單 is_order_pickup_ready 擋板）：
    -- 未到貨（該 SKU 分店實收 0）的品項個別擋，已到貨的品項放行先取
    IF NOT public.is_order_item_pickup_ready(v_item.id) THEN
      SELECT COALESCE(s.variant_name, s.product_name, s.sku_code)
        INTO v_sku_label FROM skus s WHERE s.id = v_item.sku_id;
      RAISE EXCEPTION '品項「%」分店尚未實收到貨，無法取貨（請取消勾選該品項，其餘已到貨品項可先取）',
        COALESCE(v_sku_label, v_item.sku_id::text);
    END IF;

    -- 本次取多少：p_item_qtys 指定則用之，否則整行取
    v_take := COALESCE((p_item_qtys ->> v_item.id::text)::numeric, v_item.qty);
    IF v_take IS NULL OR v_take <= 0 THEN
      RAISE EXCEPTION '品項 % 取貨數量 % 不合法（須 > 0）', v_item.id, v_take;
    END IF;
    IF v_take > v_item.qty THEN
      RAISE EXCEPTION '品項 % 取貨數量 % 超過待取數量 %', v_item.id, v_take, v_item.qty;
    END IF;

    IF v_take = v_item.qty THEN
      -- ── 整行取：沿用舊邏輯，直接標 picked_up ──
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
      ) VALUES (
        v_order.tenant_id, v_pickup_loc, v_item.sku_id, -v_take, 'sale',
        'customer_order', p_order_id, v_item.id,
        format('顧客取貨 order=%s item=%s', p_order_id, v_item.id), p_operator
      ) RETURNING id INTO v_movement_id;

      UPDATE customer_order_items
         SET status = 'picked_up',
             pickup_movement_id = v_movement_id,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v_item.id;

      v_picked_item_id := v_item.id;
    ELSE
      -- ── 部分取：拆行。新建 picked_up 行，原行扣量留待下次 ──
      -- line-level 折扣金額按取貨比例分攤，確保兩行小計加總 = 原行
      v_picked_disc := round(COALESCE(v_item.discount_amount, 0) * v_take / v_item.qty);

      -- 1) 先建 picked_up 行（暫不填 movement，先拿 id）
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, reserved_movement_id, pickup_movement_id, notes,
        discount_amount, discount_percent, created_by, updated_by, created_at, updated_at
      ) VALUES (
        v_item.tenant_id, p_order_id, v_item.campaign_item_id, v_item.sku_id, v_take, v_item.unit_price,
        'picked_up', v_item.source, NULL, NULL, v_item.notes,
        v_picked_disc, v_item.discount_percent, v_item.created_by, p_operator, v_now, v_now
      ) RETURNING id INTO v_new_item_id;

      -- 2) sale movement 指向新行
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reason, operator_id
      ) VALUES (
        v_order.tenant_id, v_pickup_loc, v_item.sku_id, -v_take, 'sale',
        'customer_order', p_order_id, v_new_item_id,
        format('顧客部分取貨 order=%s item=%s (split from %s)', p_order_id, v_new_item_id, v_item.id), p_operator
      ) RETURNING id INTO v_movement_id;

      -- 3) 回填新行 movement
      UPDATE customer_order_items
         SET pickup_movement_id = v_movement_id
       WHERE id = v_new_item_id;

      -- 4) 原行扣量、保持 active 狀態，剩餘留待下次取
      UPDATE customer_order_items
         SET qty = qty - v_take,
             discount_amount = COALESCE(discount_amount, 0) - v_picked_disc,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v_item.id;

      v_picked_item_id := v_new_item_id;
    END IF;

    -- event 記錄「被取走」那一行的 id（拆行時是新行）→ 收據查到正確的 qty
    v_event_item_ids := v_event_item_ids || v_picked_item_id;
    v_picked_count := v_picked_count + 1;
  END LOOP;

  IF v_picked_count = 0 THEN
    RAISE EXCEPTION 'no items picked (check p_item_ids belongs to order %)', p_order_id;
  END IF;

  -- 重算 order status（剩餘 active 行 → partially_completed；全取完 → completed）。
  -- 2026-08-01：剩餘 active 量要扣掉「未取退貨」覆蓋 — 已退回總倉的量不會再被
  -- 取走，若某 SKU 的 active 量全被退貨蓋掉，該 SKU 的殘行不算「待取」。
  -- 否則部分退貨後取走剩餘可取量（訂5退2取3）會讓訂單永遠卡在 partially_completed。
  SELECT COUNT(*) INTO v_active_remaining
    FROM customer_order_items coi
    JOIN (
      SELECT act.sku_id
        FROM (
          SELECT sku_id, SUM(qty) AS active_qty
            FROM customer_order_items
           WHERE order_id = p_order_id
             AND status IN ('pending','reserved','ready')
           GROUP BY sku_id
        ) act
        LEFT JOIN (
          SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
            FROM transfers t
            JOIN transfer_items ti ON ti.transfer_id = t.id
           WHERE t.customer_order_id = p_order_id
             AND t.tenant_id     = v_order.tenant_id
             AND t.transfer_type = 'return_to_hq'
             AND t.status IN ('shipped','received')
             AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
                 NOT LIKE '%取貨後退回%'
           GROUP BY ti.sku_id
        ) r ON r.sku_id = act.sku_id
       WHERE act.active_qty - COALESCE(r.ret_qty, 0) > 0
    ) open_sku ON open_sku.sku_id = coi.sku_id
   WHERE coi.order_id = p_order_id
     AND coi.status IN ('pending','reserved','ready');

  IF v_active_remaining = 0 THEN
    v_new_status := 'completed';
    v_event_type := 'picked_up';
  ELSE
    v_new_status := 'partially_completed';
    v_event_type := 'partial_pickup';
  END IF;

  UPDATE customer_orders
     SET status       = v_new_status,
         completed_at = CASE WHEN v_new_status = 'completed' THEN v_now ELSE NULL END,
         updated_by   = p_operator,
         updated_at   = v_now
   WHERE id = p_order_id;

  INSERT INTO order_pickup_events (
    tenant_id, order_id, pickup_store_id, event_type, item_ids, notes, created_by
  ) VALUES (
    v_order.tenant_id, p_order_id, v_order.pickup_store_id, v_event_type,
    to_jsonb(v_event_item_ids), p_notes, p_operator
  ) RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'event_id',        v_event_id,
    'event_type',      v_event_type,
    'picked_count',    v_picked_count,
    'active_remaining', v_active_remaining,
    'new_status',      v_new_status
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) IS
  '取貨記帳。p_item_qtys={"<item_id>":<取貨數量>} 可指定部分取貨（拆行）。'
  '到貨擋板為品項層級（is_order_item_pickup_ready）：未到貨品項個別擋、已到貨可先取。'
  '退貨守門：同 SKU 取貨量不得超過 active 量 − 未取退貨量（取貨後退回不計）。'
  'active_remaining 排除量已被未取退貨覆蓋的 SKU（退光的殘行不擋 completed）。';

GRANT EXECUTE ON FUNCTION public.rpc_record_pickup(bigint, bigint[], uuid, text, jsonb) TO authenticated;

-- ------------------------------------------------------------
-- 4. 資料治理（冪等）：既有「已全數退貨仍掛 active」的訂單收尾
-- ------------------------------------------------------------

DO $heal$
DECLARE
  v_o            RECORD;
  v_has_picked   BOOLEAN;
  v_cnt_cancel   INT := 0;
  v_cnt_complete INT := 0;
BEGIN
  FOR v_o IN
    SELECT co.id, co.order_no, co.status
      FROM customer_orders co
     WHERE co.status IN ('shipping','ready','partially_completed')
       -- 有至少一筆未取退貨 transfer
       AND EXISTS (
         SELECT 1 FROM transfers t
          WHERE t.customer_order_id = co.id
            AND t.tenant_id     = co.tenant_id
            AND t.transfer_type = 'return_to_hq'
            AND t.status IN ('shipped','received')
            AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
                NOT LIKE '%取貨後退回%'
       )
       -- 且所有 SKU 的 active 量都被未取退貨蓋掉（沒有任何可取殘量）
       AND NOT EXISTS (
         SELECT 1
           FROM (
             SELECT coi.sku_id, SUM(coi.qty) AS active_qty
               FROM customer_order_items coi
              WHERE coi.order_id = co.id
                AND coi.status IN ('pending','reserved','ready')
              GROUP BY coi.sku_id
           ) act
           LEFT JOIN (
             SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
               FROM transfers t
               JOIN transfer_items ti ON ti.transfer_id = t.id
              WHERE t.customer_order_id = co.id
                AND t.tenant_id     = co.tenant_id
                AND t.transfer_type = 'return_to_hq'
                AND t.status IN ('shipped','received')
                AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
                    NOT LIKE '%取貨後退回%'
              GROUP BY ti.sku_id
           ) r ON r.sku_id = act.sku_id
          WHERE act.active_qty - COALESCE(r.ret_qty, 0) > 0
       )
  LOOP
    SELECT EXISTS (
      SELECT 1 FROM customer_order_items
       WHERE order_id = v_o.id AND status = 'picked_up'
    ) INTO v_has_picked;

    IF v_has_picked THEN
      UPDATE customer_orders
         SET status       = 'completed',
             completed_at = COALESCE(completed_at, NOW()),
             updated_at   = NOW()
       WHERE id = v_o.id;
      v_cnt_complete := v_cnt_complete + 1;
      RAISE NOTICE '訂單 % (%) % → completed（已取部分照收、剩餘已全退）',
        v_o.id, v_o.order_no, v_o.status;
    ELSE
      UPDATE customer_orders
         SET status       = 'cancelled',
             cancelled_at = COALESCE(cancelled_at, NOW()),
             updated_at   = NOW()
       WHERE id = v_o.id;
      v_cnt_cancel := v_cnt_cancel + 1;
      RAISE NOTICE '訂單 % (%) % → cancelled（全數未取退貨）',
        v_o.id, v_o.order_no, v_o.status;
    END IF;
  END LOOP;

  RAISE NOTICE '資料治理完成：cancelled=% 張、completed=% 張', v_cnt_cancel, v_cnt_complete;
END;
$heal$;

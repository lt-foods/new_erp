-- ============================================================
-- 2026-08-11 (5)：現貨池收斂只能吃「已到貨」的池子 + 收拾同源的歷史殘留
--
-- 承 20260811000030。查 395 組「池子超額」舊帳時發現兩件事：
--
-- 【一】那 395 組 / 2,804 件**大部分不是壞帳**，是我算錯了。
--   當初的判準把「池子未取量 > on_hand − 已承諾」一律當成超額，但
--   RR- ride-along 單在補貨還沒到店時就已經存在（單頭 pending/confirmed），
--   它本來就會大於 on_hand —— 那是「還沒到貨」，不是「帳掛著沒收尾」。
--   例：平鎮店 SKU 2843 池子 13 件，其中 RR-94 的 3 件 7/24 到貨、
--   RR-280 / RR-346 的各 5 件根本還沒出貨，on_hand=3 完全正確。
--
--   換成用單頭狀態判「貨到了沒」（RR- 單要 restock 收貨後才被推 ready，
--   見 _settle_restock_ride_along）重算，真正的壞帳是 **26 組 / 68 件**。
--
--   附帶教訓：不要拿 is_order_item_pickup_ready() 當「這批貨到了沒」的判準。
--   它是 qty-blind 的閘門（Path C 只問「本店有沒有收過這個 SKU」），
--   同 SKU 只要到過一次，後面沒出貨的批次也會一起回 true —— 第一版就是
--   這樣把 79 組 / 221 件的「假壞帳」算進來的。CLAUDE.md 已有此警告，
--   這裡再踩一次，特此記錄。
--
-- 【二】那 26 組是**跟忠順同一個根因**的歷史殘留，不是隨機盤差。
--   例：中和店 RR-236 於 8/3 收 12 件芝麻燒餅，8/6～8/11 有 7 件被
--   GRP-20260717-014 的團購客人取走（stock_movements: sale →
--   customer_order 53893/55314/56188/56467，四張都 completed），
--   但 RR-236 的池子還掛著 12 —— 補貨供給了團購需求、池子沒被扣，
--   正是 20260811000020/30 修的那條路，只是這些取貨發生在修好之前。
--
-- 修法：
--   1. _trim_internal_pool 的池子來源收斂成**只吃已到貨的容器單**
--      （co.status IN ('ready','partially_completed')）。原本的
--      NOT IN ('cancelled',...) 會把還沒到貨的 pending/confirmed RR- 單
--      也當成可扣對象，等於拿「還在路上的貨」去沖銷已交付的量。
--   2. rpc_receive_transfer：把自動配單 + 池子收斂從邏輯 C 搬到邏輯 D/D2
--      **之後**（新的邏輯 E）。原本掛在 C 尾巴會在 ride-along 單被
--      _settle_restock_ride_along 推 ready 之前就執行 —— 配合第 1 點收緊
--      之後，那時候池子還是 pending、一件都扣不到，整支會靜默失效。
--      D/D2 先跑還有另一個好處：池子已經對齊實收量（短收拆行過），
--      收斂的基準才是真的。
--   3. 一次性清掉那 26 組 / 68 件歷史殘留（用同一支 helper，上限＝實測差額）。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   _trim_internal_pool               = 20260811000030（只改池子來源的 status 條件）
--   _advance_arrived_confirmed_orders = 20260811000030（不動，這裡不重貼）
--   rpc_receive_transfer              = 20260811000020（逐字保留，只搬呼叫位置）
--
-- Rollback：
--   兩支函式 CREATE OR REPLACE 回 20260811000030 / 20260811000020 的版本；
--   歷史清理的還原：
--     SELECT * FROM customer_order_items WHERE notes LIKE '%[已配給團購單%';
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _trim_internal_pool — 只吃已到貨的容器單
--    （基底 20260811000030，逐字保留；只改兩處 co.status 條件）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._trim_internal_pool(
  p_store_id BIGINT,
  p_sku_id   BIGINT,
  p_max_trim NUMERIC,
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_pool_qty NUMERIC;
  v_on_hand  NUMERIC := 0;
  v_promised NUMERIC := 0;
  v_trim     NUMERIC;
  v_done     NUMERIC := 0;
  v_new_disc NUMERIC;
  v_pool     RECORD;
  v_touched  BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  IF p_max_trim IS NULL OR p_max_trim <= 0 THEN
    RETURN 0;
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;
  END IF;

  -- 池子目前掛著的未取量。
  -- 20260811(5)：只算**已到貨**的容器單 —— RR- ride-along 單在補貨到店前
  -- 就存在（pending/confirmed），把它算進來等於拿還在路上的貨沖銷已交付量。
  SELECT COALESCE(SUM(coi.qty), 0) INTO v_pool_qty
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status IN ('ready','partially_completed')
     AND coi.sku_id = p_sku_id
     AND coi.qty > 0
     AND coi.status IN ('pending','reserved','ready');

  SELECT COALESCE(sb.on_hand, 0) INTO v_on_hand
    FROM stock_balances sb
   WHERE sb.tenant_id = v_tenant AND sb.location_id = v_loc AND sb.sku_id = p_sku_id;
  v_on_hand := COALESCE(v_on_hand, 0);

  -- 對客人的承諾（未取）；排除 store_internal 容器單與抵減單
  SELECT COALESCE(SUM(coi2.qty), 0) INTO v_promised
    FROM customer_orders co2
    JOIN customer_order_items coi2 ON coi2.order_id = co2.id
    LEFT JOIN members m2 ON m2.id = co2.member_id
   WHERE co2.tenant_id       = v_tenant
     AND co2.pickup_store_id = p_store_id
     AND co2.status IN ('ready','partially_completed','shipping')
     AND COALESCE(co2.order_kind, 'normal') <> 'offset'
     AND COALESCE(m2.member_type, '') <> 'store_internal'
     AND coi2.sku_id = p_sku_id
     AND coi2.qty > 0
     AND coi2.status IN ('pending','reserved','ready');

  v_trim := LEAST(p_max_trim, GREATEST(v_pool_qty - (v_on_hand - v_promised), 0));
  IF v_trim <= 0 THEN
    RETURN 0;
  END IF;

  FOR v_pool IN
    SELECT coi.*
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
      JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
     WHERE co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.status IN ('ready','partially_completed')
       AND coi.sku_id = p_sku_id
       AND coi.qty > 0
       AND coi.status IN ('pending','reserved','ready')
     ORDER BY co.created_at, coi.id
     FOR UPDATE OF coi
  LOOP
    EXIT WHEN v_trim <= 0;
    v_touched := v_touched || v_pool.order_id;

    IF v_pool.qty <= v_trim THEN
      -- 整行被配走
      UPDATE customer_order_items
         SET status     = 'cancelled',
             notes      = TRIM(BOTH E'\n' FROM COALESCE(notes || E'\n', '') || '[已配給團購單]'),
             updated_by = p_operator,
             updated_at = p_at
       WHERE id = v_pool.id;
      v_trim := v_trim - v_pool.qty;
      v_done := v_done + v_pool.qty;
    ELSE
      -- 只被配走一部分：拆行（折扣按數量比例分攤，同 20260805000100 / 20260810000000）
      v_new_disc := round(COALESCE(v_pool.discount_amount, 0) * v_trim / v_pool.qty);
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, notes, discount_amount, discount_percent,
        created_by, updated_by, created_at, updated_at
      ) VALUES (
        v_pool.tenant_id, v_pool.order_id, v_pool.campaign_item_id, v_pool.sku_id,
        v_trim, v_pool.unit_price,
        'cancelled', v_pool.source,
        TRIM(BOTH E'\n' FROM COALESCE(v_pool.notes || E'\n', '')
             || '[已配給團購單|拆分自#' || v_pool.id || ']'),
        v_new_disc, v_pool.discount_percent,
        p_operator, p_operator, p_at, p_at
      );
      UPDATE customer_order_items
         SET qty             = v_pool.qty - v_trim,
             discount_amount = COALESCE(v_pool.discount_amount, 0) - v_new_disc,
             updated_by      = p_operator,
             updated_at      = p_at
       WHERE id = v_pool.id;
      v_done := v_done + v_trim;
      v_trim := 0;
    END IF;
  END LOOP;

  -- CLAUDE.md：任何把品項改成 cancelled 的路徑，後面接單頭收尾
  IF array_length(v_touched, 1) > 0 THEN
    PERFORM public._close_orders_all_items_settled(v_touched, p_operator, p_at);
  END IF;

  RETURN v_done;
END;
$$;

COMMENT ON FUNCTION public._trim_internal_pool(BIGINT, BIGINT, NUMERIC, UUID, TIMESTAMPTZ) IS
  '把【內部】xx 店現貨池（member_type=store_internal、單頭已 ready/部分取貨的未取品項）'
  '收斂到 on_hand − 對客人的承諾，單次最多扣 p_max_trim 件。只吃已到貨的容器單 —— '
  'RR- 單在補貨到店前就存在，算進來會拿還在路上的貨沖銷已交付量。'
  '整行吃掉 → cancelled，部分 → 拆行留痕，一律標 [已配給團購單]。回傳實際扣掉的數量。';

-- ----------------------------------------------------------------
-- 2. rpc_receive_transfer — 自動配單搬到邏輯 D/D2 之後（新邏輯 E）
--    （基底 20260811000020，逐字保留；只把 C 尾巴那段搬到 D2 之後）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(
  p_transfer_id BIGINT,
  p_lines       JSONB,
  p_operator    UUID,
  p_notes       TEXT DEFAULT NULL::TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id            UUID;
  v_status               TEXT;
  v_transfer_type        TEXT;
  v_dest_location        BIGINT;
  v_existing_notes       TEXT;
  v_customer_order_id    BIGINT;
  v_next_transfer_id     BIGINT;
  v_item                 RECORD;
  v_qty_received         NUMERIC;
  v_unit_cost            NUMERIC;
  v_in_mov_id            BIGINT;
  v_total_qty            NUMERIC := 0;
  v_total_variance       NUMERIC := 0;
  v_items_received       INTEGER := 0;
  v_lines_consumed       INTEGER := 0;
  v_lines_count          INTEGER;
  v_orders_advanced      INTEGER := 0;
  v_next_shipped         BOOLEAN := FALSE;
  v_leg2                 transfers%ROWTYPE;
  v_leg2_item            RECORD;
  v_leg2_mov             BIGINT;
  v_dest_store_id        BIGINT;
  v_restock_received     INTEGER := 0;
  v_rr                   RECORD;
  v_prog                 RECORD;
  v_recv_skus            BIGINT[];   -- 20260811(3)：本次實收 > 0 的 SKU
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is in status %, expected shipped', p_transfer_id, v_status;
  END IF;

  IF p_lines IS NOT NULL THEN
    v_lines_count := jsonb_array_length(p_lines);
    IF EXISTS (
      SELECT 1
        FROM jsonb_array_elements(p_lines) AS l
        LEFT JOIN transfer_items ti
          ON ti.id = (l->>'transfer_item_id')::BIGINT
         AND ti.transfer_id = p_transfer_id
       WHERE ti.id IS NULL
    ) THEN
      RAISE EXCEPTION 'p_lines contains transfer_item_id not belonging to transfer %', p_transfer_id;
    END IF;
  END IF;

  -- ===== 原有邏輯：寫 qty_received + dest_location inbound =====
  FOR v_item IN
    SELECT ti.id, ti.sku_id, ti.qty_shipped, sm.unit_cost AS out_cost
      FROM transfer_items ti
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE ti.transfer_id = p_transfer_id
     ORDER BY ti.id
  LOOP
    v_qty_received := v_item.qty_shipped;

    IF p_lines IS NOT NULL THEN
      SELECT (l->>'qty_received')::NUMERIC
        INTO v_qty_received
        FROM jsonb_array_elements(p_lines) AS l
       WHERE (l->>'transfer_item_id')::BIGINT = v_item.id
       LIMIT 1;

      IF FOUND THEN
        v_lines_consumed := v_lines_consumed + 1;
      ELSE
        v_qty_received := v_item.qty_shipped;
      END IF;
    END IF;

    IF v_qty_received IS NULL OR v_qty_received < 0 THEN
      RAISE EXCEPTION 'transfer_item % qty_received must be >= 0, got %', v_item.id, v_qty_received;
    END IF;
    IF v_qty_received > v_item.qty_shipped THEN
      RAISE EXCEPTION 'transfer_item % over-receipt: qty_received=% > qty_shipped=%',
        v_item.id, v_qty_received, v_item.qty_shipped;
    END IF;

    IF v_qty_received > 0 THEN
      v_unit_cost := COALESCE(ABS(v_item.out_cost), 0);

      v_in_mov_id := rpc_inbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => v_dest_location,
        p_sku_id          => v_item.sku_id,
        p_quantity        => v_qty_received,
        p_unit_cost       => v_unit_cost,
        p_movement_type   => 'transfer_in',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => p_transfer_id,
        p_operator        => p_operator
      );

      UPDATE transfer_items
         SET qty_received   = v_qty_received,
             in_movement_id = v_in_mov_id,
             updated_by     = p_operator
       WHERE id = v_item.id;
    ELSE
      UPDATE transfer_items
         SET qty_received = 0,
             updated_by   = p_operator
       WHERE id = v_item.id;
    END IF;

    v_total_qty      := v_total_qty + v_qty_received;
    v_total_variance := v_total_variance + (v_qty_received - v_item.qty_shipped);
    v_items_received := v_items_received + 1;
  END LOOP;

  UPDATE transfers
     SET status      = 'received',
         received_by = p_operator,
         received_at = NOW(),
         notes       = CASE
                         WHEN p_notes IS NULL OR p_notes = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN p_notes
                         ELSE v_existing_notes || E'\n' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- ===== 邏輯 A：自動 ship 下一段（aid chain B 模型）=====
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_leg2 FROM transfers
     WHERE id = v_next_transfer_id FOR UPDATE;

    IF v_leg2.id IS NOT NULL AND v_leg2.status = 'draft' THEN
      FOR v_leg2_item IN
        SELECT ti.id AS leg2_item_id, ti.sku_id, ti2.qty_received
          FROM transfer_items ti
          JOIN transfer_items ti2
            ON ti2.transfer_id = p_transfer_id AND ti2.sku_id = ti.sku_id
         WHERE ti.transfer_id = v_leg2.id
      LOOP
        IF v_leg2_item.qty_received > 0 THEN
          v_leg2_mov := rpc_outbound(
            p_tenant_id       => v_leg2.tenant_id,
            p_location_id     => v_leg2.source_location,
            p_sku_id          => v_leg2_item.sku_id,
            p_quantity        => v_leg2_item.qty_received,
            p_movement_type   => 'transfer_out',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_leg2.id,
            p_operator        => p_operator
          );
          UPDATE transfer_items
             SET qty_shipped     = v_leg2_item.qty_received,
                 qty_requested   = v_leg2_item.qty_received,
                 out_movement_id = v_leg2_mov,
                 updated_by      = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        ELSE
          UPDATE transfer_items
             SET qty_shipped   = 0,
                 qty_requested = 0,
                 updated_by    = p_operator
           WHERE id = v_leg2_item.leg2_item_id;
        END IF;
      END LOOP;

      UPDATE transfers
         SET status      = 'shipped',
             shipped_by  = p_operator,
             shipped_at  = NOW(),
             updated_by  = p_operator
       WHERE id = v_leg2.id;
      v_next_shipped := TRUE;
    END IF;
  END IF;

  -- ===== 邏輯 B：aid 單 FK 直接推 customer_order → ready =====
  IF v_customer_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = NOW(),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_customer_order_id
       AND status = 'shipping';
    GET DIAGNOSTICS v_orders_advanced = ROW_COUNT;

  -- ===== 邏輯 C：hq_to_store wave transfer → 推該分店訂單 → ready =====
  -- 修：不再無條件推該店「所有」shipping 訂單；改成只推
  --     is_order_pickup_ready=true（依該訂單的團真的到齊、shortage-aware）的訂單，
  --     避免收到別團波次時把尚未出貨的團一起誤標為可取貨。
  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      WITH advanced AS (
        UPDATE customer_orders co
           SET status     = 'ready',
               ready_at   = NOW(),
               updated_by = p_operator,
               updated_at = NOW()
         WHERE co.tenant_id      = v_tenant_id
           AND co.pickup_store_id = v_dest_store_id
           AND co.status          = 'shipping'
           AND public.is_order_pickup_ready(co.id)
        RETURNING co.id
      )
      SELECT COUNT(*) INTO v_orders_advanced FROM advanced;
    END IF;
  END IF;

  -- ===== 邏輯 D：linked 補貨申請 → 已收貨；ride-along 單 → ready =====
  -- 店家收貨即補貨流程終點：把 linked_transfer_id 指向本單的補貨申請
  -- 推到 received。approved_transfer 為 legacy 防禦（現行直派皆直接 shipped）。
  FOR v_rr IN
    SELECT id FROM restock_requests
     WHERE linked_transfer_id = p_transfer_id
       AND status IN ('shipped', 'approved_transfer')
  LOOP
    UPDATE restock_requests
       SET status = 'received', updated_by = p_operator
     WHERE id = v_rr.id;
    v_restock_received := v_restock_received + 1;

    -- 20260810：ride-along 內部單改由 settle helper 收尾 —— 品項先對齊實收
    -- （短收 0 → cancelled、部分 → 拆行），再推 ready / 全未到自動取消。
    PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
  END LOOP;

  -- ===== 邏輯 D2（20260717）：wave 路徑補貨申請 → 已出貨/已收貨 =====
  -- 本調撥若為撿貨單產物（picking_wave_items.generated_transfer_id 指向本單），
  -- 歸屬的補貨申請（歸屬原則同 20260715000020）「全數出貨且全數到店」→ received、
  -- ride-along 單推 ready；已全數出貨但仍有他張在途 → 至少推 shipped。
  FOR v_rr IN
    SELECT DISTINCT rr.id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN restock_requests rr
        ON rr.tenant_id = v_tenant_id
       AND rr.requesting_store_id = pwi.store_id
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND rr.status IN ('approved_pr', 'approved_transfer', 'shipped')
       AND (pw.source_restock_request_id = rr.id
            OR (pwi.campaign_id IS NULL
                AND rr.linked_pr_id IS NOT NULL
                AND pw.source_po_id IN (
                  SELECT DISTINCT poi.po_id
                    FROM purchase_request_items pri
                    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
                   WHERE pri.pr_id = rr.linked_pr_id)))
       AND pwi.sku_id IN (SELECT sku_id FROM restock_request_lines
                           WHERE request_id = rr.id AND cancelled_at IS NULL)
  LOOP
    SELECT * INTO v_prog FROM public._restock_wave_progress(v_rr.id);
    IF v_prog.fully_dispatched AND v_prog.all_arrived THEN
      UPDATE restock_requests
         SET status = 'received', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer', 'shipped');
      v_restock_received := v_restock_received + 1;

      -- 20260810：ride-along 單交給 settle helper —— 短收品項對齊實收後
      -- 才推 ready；全未到則整單自動取消，不再掛在店身上。
      PERFORM public._settle_restock_ride_along(v_rr.id, p_operator, NOW());
    ELSIF v_prog.fully_dispatched THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = p_operator
       WHERE id = v_rr.id AND status IN ('approved_pr', 'approved_transfer');
    END IF;
  END LOOP;

  -- ===== 邏輯 E（20260811(3)，20260811(5) 從邏輯 C 搬到這裡）=====
  -- 補貨路線發的團沒有 campaign 對齊波次，客人單從來沒被推到 'shipping'，
  -- 邏輯 C 接不到。這裡把「對得上本次到貨 SKU」的 confirmed 單依訂單時間、
  -- 在可配量內推 ready，並把【內部】xx 店現貨池扣掉相應的量。
  --
  -- **必須排在 D/D2 之後**：ride-along 單要先被 _settle_restock_ride_along
  -- 推成 ready（並對齊實收量）， _trim_internal_pool 才吃得到它 ——
  -- 那支只認已到貨的容器單（20260811000040）。
  IF v_customer_order_id IS NULL AND v_transfer_type = 'hq_to_store' THEN
    IF v_dest_store_id IS NOT NULL THEN
      SELECT ARRAY_AGG(DISTINCT ti.sku_id)
        INTO v_recv_skus
        FROM transfer_items ti
       WHERE ti.transfer_id = p_transfer_id
         AND ti.qty_received > 0;

      IF v_recv_skus IS NOT NULL THEN
        v_orders_advanced := v_orders_advanced
          + public._advance_arrived_confirmed_orders(
              v_dest_store_id, v_recv_skus, p_operator, NOW());
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped,
    'restock_received',       v_restock_received
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 3. 一次性清理：跟忠順同根因的歷史殘留（補貨供了團購需求、池子沒被扣）
--    對象＝已到貨容器單的池子 > on_hand − 對客人的承諾；上限＝實測差額。
--    實測 26 組 / 68 件（詳見檔頭【一】的口徑說明）。
-- ----------------------------------------------------------------
DO $$
DECLARE
  r       RECORD;
  v_done  NUMERIC;
  v_total NUMERIC := 0;
  v_combo INT := 0;
BEGIN
  FOR r IN
    WITH pool AS (
      SELECT co.pickup_store_id AS sid, coi.sku_id, SUM(coi.qty) AS pool_qty
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id
                                     AND coi.status IN ('pending','reserved','ready')
        JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
       WHERE co.status IN ('ready','partially_completed') AND coi.qty > 0
       GROUP BY 1, 2
    ), promised AS (
      SELECT co.pickup_store_id AS sid, coi.sku_id, SUM(coi.qty) AS p
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id
                                     AND coi.status IN ('pending','reserved','ready')
        LEFT JOIN members m ON m.id = co.member_id
       WHERE co.status IN ('ready','partially_completed')
         AND COALESCE(co.order_kind,'normal') <> 'offset'
         AND COALESCE(m.member_type,'') <> 'store_internal'
         AND coi.qty > 0
       GROUP BY 1, 2
    )
    SELECT pool.sid AS store_id, pool.sku_id,
           pool.pool_qty - (COALESCE(sb.on_hand,0) - COALESCE(pr.p,0)) AS excess
      FROM pool
      JOIN stores s ON s.id = pool.sid
      LEFT JOIN stock_balances sb ON sb.location_id = s.location_id AND sb.sku_id = pool.sku_id
      LEFT JOIN promised pr ON pr.sid = pool.sid AND pr.sku_id = pool.sku_id
     WHERE pool.pool_qty > COALESCE(sb.on_hand,0) - COALESCE(pr.p,0)
     ORDER BY 1, 2
  LOOP
    v_done := public._trim_internal_pool(
                r.store_id, r.sku_id, r.excess,
                '00000000-0000-0000-0000-000000000000'::UUID, NOW());
    IF v_done > 0 THEN
      RAISE NOTICE '  store % / sku %: 池子扣掉 % 件（差額 %）',
        r.store_id, r.sku_id, v_done, r.excess;
      v_combo := v_combo + 1;
      v_total := v_total + v_done;
    END IF;
  END LOOP;

  RAISE NOTICE '歷史殘留清理完成：% 組 (店, SKU)、共 % 件', v_combo, v_total;
END $$;

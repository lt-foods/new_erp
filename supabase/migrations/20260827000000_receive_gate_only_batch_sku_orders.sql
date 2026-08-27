-- ============================================================================
-- 2026-08-27: 收貨邏輯 C 只對「有本批 SKU」的派貨中訂單跑取貨閘門
--
-- 症狀：批次收貨（rpc_receive_transfer_manual）一次 13~21 秒。8/27 下午總倉
--   收貨高峰 + Micro(1GB) → DB 兩度 OOM 當機（15:47、16:12），全站進不去。
--
-- 量測（松山 45 店、236 張 shipping 單、transfer 14361 共 8 SKU，rollback 實測）：
--   rpc_receive_transfer 單張 2,685ms，其中邏輯 C 的
--   「該店全部 shipping 單逐張 is_order_pickup_ready()」佔 1,962ms（閘門 ~8ms/張）。
--   批次收 8~14 張調撥單就是把同一批 236 張單掃 8~14 遍。
--   前濾「訂單有本批 SKU 的 active 品項」後母體 236 → 4 張。
--
-- 語意：收一張調撥單只會改變**本批 SKU** 的到貨/庫存/待補貨事實（A0 也只清
--   本批 SKU 的旗標），沒含這些 SKU 的訂單，閘門結果跟收貨前一模一樣 ——
--   之前推不動的現在也推不動，濾掉不改變任何單的最終狀態。
--   代價：歷史上「早該 ready 卻卡住」的單，以前任何一次收貨都會順手掃到，
--   現在要等到「含它 SKU 的那批」到貨（本來就是它的自然觸發點）或
--   手動 ⚖️ 配貨。此為刻意取捨。
--   active 集合沿用全站同一套 ('pending','reserved','ready')。
--
-- 基底版本：線上 pg_get_functiondef() 現況（2026-08-27 取出，與
--   20260824020000_receive_allocate_rework.sql 的版本逐字一致，已比對），
--   只改邏輯 C 那一段。
-- Rollback：把邏輯 C 的 IF 條件退回 `IF v_dest_store_id IS NOT NULL THEN`、
--   拿掉 `co.id IN (...)` 子查詢（即 20260824020000 的版本）。
--
-- 沒有對應的前端改動。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(p_transfer_id bigint, p_lines jsonb, p_operator uuid, p_notes text DEFAULT NULL::text, p_auto_allocate boolean DEFAULT true)
 RETURNS jsonb
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
  v_backorders_freed     INTEGER := 0;   -- 20260811(6)：本次到貨解除的待補貨列數
  v_sk                   RECORD;     -- 20260814(2)：逐 SKU 算本批多給
  v_grown                NUMERIC;
  v_surplus              JSONB := '[]'::jsonb;
  v_gate_candidates      BIGINT[];   -- 20260827：邏輯 C 的前濾母體
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
    -- 20260824020000：允許多收（實收 > 派出）。總倉實際多裝了就照實入庫，
    -- 差異走 v_hq_exceptions 的 transfer_over 分支回報總倉（同短少那套收件匣）。
    -- 上限守衛拿掉的是「帳跟不上實物」的錯：擋下來店家只能少報，貨照樣在店裡。

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

  -- ===== 邏輯 A0（20260811(6)）：本次到貨 → 解除待補貨 =====
  -- 少發配貨（rpc_allocate_shortage）把沒配到的品項標 backorder_at，取貨閘門
  -- 因此回 false。在這支之前，全 DB 沒有任何路徑會在「補的那批貨到店」時把它
  -- 清掉 —— 補出第二批、店家收了貨，品項還是掛「待補貨」，要有人記得回收貨頁
  -- 再點一次「⚖️ 配貨」才解得開。
  --
  -- **必須排在邏輯 A/B/C/E 之前**：邏輯 C 的 is_order_pickup_ready() 與
  -- 邏輯 E 的 _advance_arrived_confirmed_orders 都含 backorder_at IS NULL，
  -- 先解除才推得動單頭；順序反了這批單要等下一次收貨才會動。
  --
  -- 20260813：手動配單模式（p_auto_allocate = FALSE）**仍照跑** —— 這是
  -- 「先前⚖️配貨決定」的完成、有帳面+實體雙守衛，不是新的配單決策；
  -- 關掉會重演松山單卡 6 天災情。要重新決定配給誰請用 ⚖️ 配貨。
  IF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id
       AND location_id = v_dest_location
     LIMIT 1;

    SELECT ARRAY_AGG(DISTINCT ti.sku_id)
      INTO v_recv_skus
      FROM transfer_items ti
     WHERE ti.transfer_id = p_transfer_id
       AND ti.qty_received > 0;

    IF v_dest_store_id IS NOT NULL AND v_recv_skus IS NOT NULL THEN
      v_backorders_freed := public._settle_arrived_backorders(
        v_dest_store_id, v_recv_skus, p_operator, NOW());
    END IF;
  END IF;

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

    -- 20260827000000：只對「有本批 SKU active 品項」的派貨中訂單跑閘門。
    -- 閘門 ~8ms/張、原本逐張調撥單掃該店**全部** shipping 單（實測松山 236 張
    -- ＝每張調撥單 ~2 秒；批次收 8~14 張 = 16~27 秒，8/27 把 1GB 機器壓掛的主因）。
    -- 收貨只改變本批 SKU 的到貨／庫存事實，沒含這些 SKU 的訂單閘門結果與收貨前
    -- 相同，濾掉語意不變；歷史卡住的單改由「收到它的 SKU 那批」或手動 ⚖️ 配貨
    -- 觸發。v_recv_skus 為 NULL（本批零實收）整段跳過。
    -- **一定要兩步走**：前濾寫成同一句的 IN (子查詢) 時 planner 會把閘門函式
    -- 下推到 customer_orders 掃描層、先於 semi-join 執行（實測 2.4s，等於沒濾），
    -- 先收斂成陣列再 UPDATE 就沒有重排空間。
    IF v_dest_store_id IS NOT NULL AND v_recv_skus IS NOT NULL THEN
      SELECT COALESCE(ARRAY_AGG(DISTINCT coi.order_id), '{}'::BIGINT[])
        INTO v_gate_candidates
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id
       WHERE co.tenant_id       = v_tenant_id
         AND co.pickup_store_id = v_dest_store_id
         AND co.status          = 'shipping'
         AND coi.status IN ('pending','reserved','ready')
         AND coi.sku_id = ANY (v_recv_skus);

      IF cardinality(v_gate_candidates) > 0 THEN
        WITH advanced AS (
          UPDATE customer_orders co
             SET status     = 'ready',
                 ready_at   = NOW(),
                 updated_by = p_operator,
                 updated_at = NOW()
           WHERE co.id = ANY (v_gate_candidates)
             AND co.status = 'shipping'
             AND public.is_order_pickup_ready(co.id)
          RETURNING co.id
        )
        SELECT COUNT(*) INTO v_orders_advanced FROM advanced;
      END IF;
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
  --
  -- 20260813：p_auto_allocate = FALSE（手動配單模式）時跳過 —— 收貨只入庫，
  -- 配給哪些 confirmed 單由店家在收貨頁「手動配單」彈窗自己勾
  -- （rpc_manual_allocate_confirmed_orders，同一支 helper 推進）。
  IF p_auto_allocate AND v_customer_order_id IS NULL AND v_transfer_type = 'hq_to_store' THEN
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

  -- ===== 邏輯 F（20260814(2)）：多給的跳出【內部】店 =====
  -- 本批實收扣掉「本店對這個 SKU 還沒交出去的帳」之後仍有剩 → 沒有訂單主人，
  -- 掛進【內部】xx 店現貨池，店員才轉得出去（在這之前只進 on_hand，
  -- 池子看不到 → 帳上等於隱形，只能靠人工開內部單）。
  --
  -- **必須排在邏輯 B/C/E 之後**：那些是把貨配給客人的路徑，配掉的量會變成
  -- 「已承諾未取」，_grow_internal_pool 的自由量才扣得到；順序反了會把
  -- 客人的貨掛進池子，重演 20260811000030 忠順那種「團友撲空」。
  -- 手動配單模式（p_auto_allocate=FALSE）在這裡通常算不出剩餘（沒配的單
  -- 還是 confirmed，自由量已扣掉它們），真正的結算在
  -- rpc_receive_transfer_manual 配完單之後再跑一次 —— 同一支 helper，
  -- 依當下自由量重算，不會重複掛。
  IF v_customer_order_id IS NULL AND v_transfer_type = 'hq_to_store'
     AND v_dest_store_id IS NOT NULL THEN
    FOR v_sk IN
      SELECT ti.sku_id, SUM(ti.qty_received) AS received
        FROM transfer_items ti
       WHERE ti.transfer_id = p_transfer_id
         AND ti.qty_received > 0
       GROUP BY ti.sku_id
       ORDER BY ti.sku_id
    LOOP
      v_grown := public._grow_internal_pool(
        v_dest_store_id, v_sk.sku_id, v_sk.received, p_operator, NOW(),
        '[收貨多給|TF#' || p_transfer_id::TEXT || ']');
      IF v_grown > 0 THEN
        v_surplus := v_surplus
          || jsonb_build_object('sku_id', v_sk.sku_id, 'qty', v_grown);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped,
    'restock_received',       v_restock_received,
    'backorders_freed',       v_backorders_freed,
    'auto_allocate',          p_auto_allocate,
    'surplus',                v_surplus
  );
END;
$function$;

-- ============================================================
-- 2026-08-24 (2)：收貨/配貨頁重整（Alex 定案的三情境）
--
--   1. 到貨數量正確：配單視窗全選 → 確認 → 全部客人可取。
--   2. 數量多於訂單：畫面可直接調實收（含多收），沒有訂單主人的量
--      掛【內部】店現貨池（既有 _grow_internal_pool）。
--   3. 數量少於訂單：勾要配的人，沒配到的標待補貨、不能取
--      （20260824010000 已上）。
--   數量預設照 WV 派出量、可手動調整；短少/多收都回報總倉收件匣。
--
-- 本檔五件事：
--   A. rpc_receive_transfer：放行多收（實收 > 派出照實入庫）。
--      基底 20260814010000（該檔即最新版，已 grep 過後續 migration
--      無人再改），只移除 over-receipt RAISE。
--   B. rpc_get_transfer_allocation_preview：p_lines 支援跨多張調撥單
--      （transfer_item_id 全域唯一）。基底 20260814010000。
--   C. rpc_receive_transfer_manual：同上放寬 p_lines，收貨迴圈逐張切分。
--      基底 20260824010000（7 參數版）。
--   D. rpc_unreceive_transfer：反向邏輯 G —— 退回收貨同時還原配單決策
--      （清 backorder 標記、拉回的派貨中單還原 shipping，照 received_at
--      對時）＝「一鍵返回收貨＋配單」。基底 20260814010000。
--   E. v_hq_exceptions 加 transfer_over 分支（實收 > 派出回報總倉）＋
--      shortage_resolution 允許 'over_ack' ＋ rpc_ack_transfer_over
--      （HQ 按「知道了」收掉）。view 基底 20260811020010。
--
-- Rollback：各函式/視圖重跑上列基底檔對應區塊；constraint 改回
--   20260811020000 的六值版本；DROP FUNCTION rpc_ack_transfer_over。
-- ============================================================

-- ----------------------------------------------------------------
-- A. rpc_receive_transfer：放行多收
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(
  p_transfer_id   BIGINT,
  p_lines         JSONB,
  p_operator      UUID,
  p_notes         TEXT    DEFAULT NULL::TEXT,
  p_auto_allocate BOOLEAN DEFAULT TRUE
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
  v_backorders_freed     INTEGER := 0;   -- 20260811(6)：本次到貨解除的待補貨列數
  v_sk                   RECORD;     -- 20260814(2)：逐 SKU 算本批多給
  v_grown                NUMERIC;
  v_surplus              JSONB := '[]'::jsonb;
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

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT, BOOLEAN)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT, BOOLEAN) IS
  '調撥收貨：入庫 + 邏輯 A0(解除待補貨) / A(接力出貨) / B(aid 單) / C(波次推 ready) / '
  'D·D2(補貨申請 + ride-along) / E(自動配 confirmed 單，p_auto_allocate=TRUE 時) / '
  'F(20260814(2)：本批多給的量掛進【內部】店現貨池，_grow_internal_pool 以自由量夾住)。';

-- ----------------------------------------------------------------
-- B. rpc_get_transfer_allocation_preview：p_lines 跨多張
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_transfer_allocation_preview(
  p_transfer_ids BIGINT[],
  p_lines        JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '60000'
AS $$
DECLARE
  v_ids        BIGINT[];
  v_tenant     UUID;
  v_dest       BIGINT;
  v_store      BIGINT;
  v_store_name TEXT;
  v_cnt        INT;
  v_incoming   JSONB;
  v_budget     JSONB;
  v_orders     JSONB;
  v_cand_ids   BIGINT[];
  v_ship_ids   BIGINT[];
BEGIN
  IF p_transfer_ids IS NULL OR cardinality(p_transfer_ids) = 0 THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;
  v_ids := ARRAY(SELECT DISTINCT UNNEST(p_transfer_ids));

  SELECT COUNT(*) INTO v_cnt FROM transfers WHERE id = ANY (v_ids);
  IF v_cnt <> cardinality(v_ids) THEN
    RAISE EXCEPTION '有調撥單不存在';
  END IF;
  IF EXISTS (SELECT 1 FROM transfers WHERE id = ANY (v_ids) AND status <> 'shipped') THEN
    RAISE EXCEPTION '只有待收貨（已派出）的調撥單可以邊收邊配';
  END IF;
  SELECT COUNT(*) INTO v_cnt
    FROM (SELECT DISTINCT tenant_id, dest_location
            FROM transfers WHERE id = ANY (v_ids)) x;
  IF v_cnt > 1 THEN
    RAISE EXCEPTION '跨分店的調撥單請分開處理';
  END IF;
  -- 20260824020000：p_lines 以 transfer_item_id 定位（全域唯一），跨多張調撥單
  -- 也不會歧義 —— 只驗每一列都屬於這批單。
  IF p_lines IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lines) l
      LEFT JOIN transfer_items ti
        ON ti.id = (l->>'transfer_item_id')::BIGINT
       AND ti.transfer_id = ANY (v_ids)
     WHERE ti.id IS NULL) THEN
    RAISE EXCEPTION 'p_lines 含不屬於這批調撥單的品項';
  END IF;

  SELECT tenant_id, dest_location INTO v_tenant, v_dest
    FROM transfers WHERE id = v_ids[1];

  -- 跨租戶守衛（讀頂層 tenant_id claim；沒有 claim 的 service 情境放行）
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'transfer not in current tenant';
  END IF;

  SELECT id, name INTO v_store, v_store_name
    FROM stores WHERE tenant_id = v_tenant AND location_id = v_dest
    LIMIT 1;
  IF v_store IS NULL THEN
    -- 目的地不是分店（例如退回總倉）→ 沒有顧客訂單可配
    RETURN jsonb_build_object(
      'store_id', NULL, 'store_name', NULL,
      'incoming', '[]'::jsonb, 'budget', '[]'::jsonb, 'orders', '[]'::jsonb);
  END IF;

  -- 本次到貨量：p_lines 有值的品項以實收為準，其餘 = 派出量（同 rpc_receive_transfer）
  WITH li AS (
    SELECT (l->>'transfer_item_id')::BIGINT AS tid,
           (l->>'qty_received')::NUMERIC    AS q
      FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) l
  ),
  inc AS (
    SELECT ti.sku_id, SUM(GREATEST(COALESCE(li.q, ti.qty_shipped), 0)) AS qty
      FROM transfer_items ti
      LEFT JOIN li ON li.tid = ti.id
     WHERE ti.transfer_id = ANY (v_ids)
     GROUP BY ti.sku_id
    HAVING SUM(GREATEST(COALESCE(li.q, ti.qty_shipped), 0)) > 0
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',   inc.sku_id,
           'sku_code', s.sku_code,
           'name',     TRIM(COALESCE(s.product_name, '')
                         || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                 THEN ' / ' || s.variant_name ELSE '' END),
           'qty',      inc.qty
         ) ORDER BY inc.sku_id), '[]'::jsonb)
    INTO v_incoming
    FROM inc JOIN skus s ON s.id = inc.sku_id;

  -- 對到的訂單：該店還在等貨的一般單（排除內部容器單），至少一個未取品項的
  -- SKU 在本次到貨清單裡。
  -- 20260814：confirmed（等貨中，可配）＋ shipping（波次出貨時已配給他，
  -- 可保留或拉回）都列。先收 id 陣列 —— 之後的訂單 JSON、閘門呼叫、
  -- promised 排除都以同一個集合為準。
  SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[]),
         COALESCE(ARRAY_AGG(co.id) FILTER (WHERE co.status = 'shipping'), '{}'::BIGINT[])
    INTO v_cand_ids, v_ship_ids
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = v_store
     AND co.status          IN ('confirmed', 'shipping')
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal'
     AND EXISTS (
       SELECT 1
         FROM customer_order_items coi
         JOIN transfer_items ti
           ON ti.transfer_id = ANY (v_ids)
          AND ti.sku_id      = coi.sku_id
        WHERE coi.order_id = co.id
          AND coi.status IN ('pending','reserved','ready')
     );

  -- 訂單 JSON：多回 status（單頭）與 arrived（取貨閘門）。閘門只對候選
  -- 陣列跑（20260813020000 的教訓：別讓 planner 有機會把閘門提前對全店跑）。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id',      co.id,
           'order_no',      co.order_no,
           'member_id',     co.member_id,
           'customer',      COALESCE(m.name, co.nickname_snapshot),
           'campaign_name', CASE WHEN LEFT(COALESCE(gbc.campaign_no, ''), 2) = '__'
                                 THEN NULL ELSE gbc.name END,
           'created_at',    co.created_at,
           'status',        co.status,
           'arrived',       public.is_order_pickup_ready(co.id),
           'items', (
             SELECT jsonb_agg(jsonb_build_object('sku_id', i.sku_id, 'qty', i.need)
                              ORDER BY i.sku_id)
               FROM (
                 SELECT coi.sku_id, SUM(coi.qty) AS need
                   FROM customer_order_items coi
                  WHERE coi.order_id = co.id
                    AND coi.status IN ('pending','reserved','ready')
                  GROUP BY coi.sku_id
               ) i
           )
         ) ORDER BY co.created_at, co.order_no), '[]'::jsonb)
    INTO v_orders
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN group_buy_campaigns gbc ON gbc.id = co.campaign_id
   WHERE co.id = ANY (v_cand_ids);

  -- 既有可配量（收貨前）：on_hand − 已承諾未取；promised 一次 GROUP BY 後 JOIN。
  -- 種子 = 到貨 SKU ∪ 候選單的全部未取 SKU（多品項單要每一項都有數字）。
  -- 20260814：promised 排除畫面上列出的 shipping 單（v_ship_ids）——
  -- 它們的需求改成「勾了才佔額度」，前端把勾選需求逐 SKU 從上限扣；
  -- 沒勾（會被拉回 confirmed）就不佔。畫面外的 shipping 單照舊預扣。
  -- 20260814(2)：每列多回 'pool'（池子既有未取掛帳）—— 前端預估
  -- 「多給的會掛幾件進內部店」要扣掉它，跟 _grow_internal_pool 同一套帳。
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',    b.sku_id,
           'sku_code',  s.sku_code,
           'name',      TRIM(COALESCE(s.product_name, '')
                          || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                  THEN ' / ' || s.variant_name ELSE '' END),
           'available', b.avail,
           'pool',      b.pool_qty
         ) ORDER BY b.sku_id), '[]'::jsonb)
    INTO v_budget
    FROM (
      SELECT sk.sku_id,
             COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0) AS avail,
             COALESCE(pl.pool_qty, 0) AS pool_qty
        FROM (
          SELECT DISTINCT ti.sku_id
            FROM transfer_items ti
           WHERE ti.transfer_id = ANY (v_ids)
          UNION
          SELECT DISTINCT coi.sku_id
            FROM customer_order_items coi
           WHERE coi.order_id = ANY (v_cand_ids)
             AND coi.status IN ('pending','reserved','ready')
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_dest
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN (
          SELECT coi2.sku_id, SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = v_store
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.status IN ('pending','reserved','ready')
             AND NOT (co2.id = ANY (v_ship_ids))
           GROUP BY coi2.sku_id
        ) pr ON pr.sku_id = sk.sku_id
        LEFT JOIN (
          SELECT coi3.sku_id, SUM(coi3.qty) AS pool_qty
            FROM customer_orders co3
            JOIN customer_order_items coi3 ON coi3.order_id = co3.id
            JOIN members m3 ON m3.id = co3.member_id AND m3.member_type = 'store_internal'
           WHERE co3.tenant_id       = v_tenant
             AND co3.pickup_store_id = v_store
             AND co3.status NOT IN ('cancelled','expired','transferred_out','completed')
             AND coi3.status IN ('pending','reserved','ready')
           GROUP BY coi3.sku_id
        ) pl ON pl.sku_id = sk.sku_id
    ) b
    JOIN skus s ON s.id = b.sku_id;

  RETURN jsonb_build_object(
    'store_id',   v_store,
    'store_name', v_store_name,
    'incoming',   v_incoming,
    'budget',     v_budget,
    'orders',     v_orders
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB) IS
  '收貨前的手動配單預覽：這批（同店）調撥單的到貨品項，對到該店 confirmed（等貨中）'
  '與 shipping（波次已配給他）的一般單，各附單頭 status 與 arrived（取貨閘門）。'
  '可配上限 = 既有可配（on_hand − 已承諾未取，排除畫面上的 shipping 單）＋ 本次到貨量；'
  'budget 每列另回 pool（池子既有未取掛帳，前端預估多給量用）。'
  '確認收貨走 rpc_receive_transfer_manual：沒勾的 shipping 單拉回 confirmed、'
  '多給的量掛進【內部】店現貨池。';

GRANT EXECUTE ON FUNCTION public.rpc_get_transfer_allocation_preview(BIGINT[], JSONB)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- C. rpc_receive_transfer_manual：p_lines 跨多張、逐張切分
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[]);

CREATE OR REPLACE FUNCTION public.rpc_receive_transfer_manual(
  p_transfer_ids        BIGINT[],
  p_operator            UUID,
  p_order_ids           BIGINT[] DEFAULT NULL,
  p_notes               TEXT     DEFAULT NULL,
  p_lines               JSONB    DEFAULT NULL,
  p_pullback_order_ids  BIGINT[] DEFAULT NULL,
  p_backorder_order_ids BIGINT[] DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '180000'
AS $$
DECLARE
  v_ids          BIGINT[];
  v_tenant       UUID;
  v_dest         BIGINT;
  v_store        BIGINT;
  v_cnt          INT;
  v_id           BIGINT;
  v_recv         JSONB;
  v_results      JSONB := '[]'::jsonb;
  v_alloc        JSONB := NULL;
  v_now          TIMESTAMPTZ := NOW();
  v_pulled       BIGINT[] := '{}'::BIGINT[];
  v_pull_skipped JSONB := '[]'::jsonb;
  v_chk_ship     BIGINT[] := '{}'::BIGINT[];
  v_ship_adv     INT := 0;
  v_conf         BIGINT[];
  v_tag          TEXT;
  v_sk           RECORD;
  v_grown        NUMERIC;
  v_surplus      JSONB := '[]'::jsonb;
  v_batch_skus   BIGINT[];
  v_bo_orders    INT := 0;
BEGIN
  IF p_transfer_ids IS NULL OR cardinality(p_transfer_ids) = 0 THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;
  v_ids := ARRAY(SELECT DISTINCT UNNEST(p_transfer_ids));

  SELECT COUNT(*) INTO v_cnt FROM transfers WHERE id = ANY (v_ids);
  IF v_cnt <> cardinality(v_ids) THEN
    RAISE EXCEPTION '有調撥單不存在';
  END IF;
  SELECT COUNT(*) INTO v_cnt
    FROM (SELECT DISTINCT tenant_id, dest_location
            FROM transfers WHERE id = ANY (v_ids)) x;
  IF v_cnt > 1 THEN
    RAISE EXCEPTION '跨分店的調撥單請分開處理';
  END IF;
  -- 20260824020000：p_lines 以 transfer_item_id 定位（全域唯一），支援跨多張
  -- 調撥單 —— 只驗每一列都屬於這批單，收貨迴圈再逐張切分。
  IF p_lines IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lines) l
      LEFT JOIN transfer_items ti
        ON ti.id = (l->>'transfer_item_id')::BIGINT
       AND ti.transfer_id = ANY (v_ids)
     WHERE ti.id IS NULL) THEN
    RAISE EXCEPTION 'p_lines 含不屬於這批調撥單的品項';
  END IF;
  -- 同一張單不能又配又拉 —— 一定是前端組參數組錯了，直接擋
  IF p_order_ids IS NOT NULL AND p_pullback_order_ids IS NOT NULL
     AND EXISTS (SELECT 1 FROM UNNEST(p_order_ids) o
                  WHERE o = ANY (p_pullback_order_ids)) THEN
    RAISE EXCEPTION '同一張訂單不能同時勾選配單又拉回';
  END IF;
  -- 同一張單不能又勾又標待補貨（20260824）
  IF p_order_ids IS NOT NULL AND p_backorder_order_ids IS NOT NULL
     AND EXISTS (SELECT 1 FROM UNNEST(p_order_ids) o
                  WHERE o = ANY (p_backorder_order_ids)) THEN
    RAISE EXCEPTION '同一張訂單不能同時勾選配單又標待補貨';
  END IF;

  SELECT tenant_id, dest_location INTO v_tenant, v_dest
    FROM transfers WHERE id = v_ids[1];
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'transfer not in current tenant';
  END IF;

  SELECT id INTO v_store
    FROM stores WHERE tenant_id = v_tenant AND location_id = v_dest
    LIMIT 1;
  IF v_store IS NULL
     AND ((p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0)
       OR (p_pullback_order_ids IS NOT NULL AND cardinality(p_pullback_order_ids) > 0)
       OR (p_backorder_order_ids IS NOT NULL AND cardinality(p_backorder_order_ids) > 0)) THEN
    RAISE EXCEPTION '目的地不是分店，無法配單';
  END IF;

  -- 本批涵蓋的 SKU（派出清單）：清標/重標的範圍都以它為準 ——
  -- 配單視窗的候選本來就是「有品項對到本批 SKU」的單。
  v_batch_skus := ARRAY(
    SELECT DISTINCT ti.sku_id FROM transfer_items ti WHERE ti.transfer_id = ANY (v_ids));

  -- 拉回：沒勾的派貨中訂單退回 confirmed（這批貨不配給他，下批可再配）。
  -- **必須在收貨之前** —— 收貨邏輯 C 會把 shipping 單推 ready，先退回才攔得住。
  -- 拉不回的（狀態已變：已被收貨推進、已取貨…）記 pullback_skipped，不擋收貨。
  IF p_pullback_order_ids IS NOT NULL AND cardinality(p_pullback_order_ids) > 0 THEN
    WITH pulled AS (
      UPDATE customer_orders co
         SET status     = 'confirmed',
             updated_by = p_operator,
             updated_at = v_now
       WHERE co.id = ANY (p_pullback_order_ids)
         AND co.tenant_id       = v_tenant
         AND co.pickup_store_id = v_store
         AND co.status          = 'shipping'
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND NOT EXISTS (SELECT 1 FROM members m
                          WHERE m.id = co.member_id
                            AND m.member_type = 'store_internal')
      RETURNING co.id
    )
    SELECT COALESCE(ARRAY_AGG(id), '{}'::BIGINT[]) INTO v_pulled FROM pulled;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'order_id', u.oid,
             'order_no', co.order_no,
             'status',   COALESCE(co.status, 'not_found'))), '[]'::jsonb)
      INTO v_pull_skipped
      FROM (SELECT DISTINCT UNNEST(p_pullback_order_ids) AS oid) u
      LEFT JOIN customer_orders co ON co.id = u.oid
     WHERE NOT (u.oid = ANY (v_pulled));
  END IF;

  -- 勾選中的派貨中訂單快照（收貨前）：收完貨要推「可取貨」的集合
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[])
      INTO v_chk_ship
      FROM customer_orders co
      LEFT JOIN members m ON m.id = co.member_id
     WHERE co.id = ANY (p_order_ids)
       AND co.tenant_id       = v_tenant
       AND co.pickup_store_id = v_store
       AND co.status          = 'shipping'
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND COALESCE(m.member_type, '') <> 'store_internal';
  END IF;

  -- 逐張收貨（不自動配單）。**沒有 savepoint** —— 任何一張失敗整包回滾，
  -- 對應「按確認才完成收貨」：失敗＝什麼都沒發生，跟批次收貨的部分成功語意不同。
  FOREACH v_id IN ARRAY v_ids LOOP
    v_recv := public.rpc_receive_transfer(
      v_id,
      CASE WHEN p_lines IS NULL THEN NULL ELSE (
        SELECT jsonb_agg(l)
          FROM jsonb_array_elements(p_lines) l
          JOIN transfer_items ti ON ti.id = (l->>'transfer_item_id')::BIGINT
         WHERE ti.transfer_id = v_id) END,
      p_operator, p_notes, FALSE);
    v_results := v_results || jsonb_build_array(v_recv);
  END LOOP;

  -- 20260824：勾選的訂單先清掉本批 SKU 的待補貨旗標 —— 上一批配單被標過
  -- 的人這批被勾了，就是「這批給他」；不清的話下面的閘門重驗
  -- （rpc_manual_allocate_confirmed_orders / is_order_pickup_ready 都含
  -- backorder_at IS NULL）會把他跳過 not_arrived，勾了等於沒勾。
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = v_now
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND coi.order_id = ANY (p_order_ids)
       AND co.tenant_id       = v_tenant
       AND co.pickup_store_id = v_store
       AND coi.sku_id = ANY (v_batch_skus)
       AND coi.status IN ('pending','reserved','ready')
       AND coi.backorder_at IS NOT NULL;
  END IF;

  -- 勾選的派貨中訂單 → 可取貨。同波次到貨的多數已被收貨邏輯 C 推掉
  -- （閘門放行），這裡收尾跨批次到貨、閘門還沒開的 —— 店家勾了就是
  -- 「這批貨給他」，與邏輯 C 同樣 qty-blind、不做 _trim_internal_pool
  -- （波次貨不動現貨池；池子收斂只屬於 confirmed 配單路徑）。
  IF cardinality(v_chk_ship) > 0 THEN
    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = v_now,
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = ANY (v_chk_ship)
       AND status = 'shipping';

    SELECT COUNT(*) INTO v_ship_adv
      FROM customer_orders
     WHERE id = ANY (v_chk_ship) AND status = 'ready';
  END IF;

  -- 配單（confirmed 勾選單）：守衛全在 rpc_manual_allocate_confirmed_orders 裡
  -- （可配量、整單裝得下、閘門重驗、池子收斂；裝不下回報 skipped 不硬推）。
  -- 派貨中快照已在上面處理，剩下的照舊交給配單 RPC —— 狀態不符的它會
  -- 回報 not_eligible，跳過原因不遺失。
  IF p_order_ids IS NOT NULL AND cardinality(p_order_ids) > 0 THEN
    v_conf := ARRAY(SELECT DISTINCT UNNEST(p_order_ids)
                    EXCEPT SELECT UNNEST(v_chk_ship));
    IF cardinality(v_conf) > 0 THEN
      v_alloc := public.rpc_manual_allocate_confirmed_orders(v_store, v_conf, p_operator);
    END IF;
  END IF;

  -- 20260824：沒勾的候選訂單 → 本批 SKU 的 active 品項標「待補貨」。
  -- 取貨閘門含 backorder_at IS NULL → 一定關；會員端顯示「待到貨」。
  -- **必須在收貨迴圈之後** —— 收貨邏輯 A0 會解除舊旗標，先標會被它洗掉。
  -- 下一批貨到時 A0 自動重算解除（可配量夠才放）；那批又沒勾就再標回。
  IF p_backorder_order_ids IS NOT NULL AND cardinality(p_backorder_order_ids) > 0 THEN
    WITH marked AS (
      UPDATE customer_order_items coi
         SET backorder_at = v_now, backorder_by = p_operator,
             updated_by = p_operator, updated_at = v_now
        FROM customer_orders co
       WHERE co.id = coi.order_id
         AND coi.order_id = ANY (p_backorder_order_ids)
         AND co.tenant_id       = v_tenant
         AND co.pickup_store_id = v_store
         AND co.status          IN ('confirmed', 'shipping')
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND NOT EXISTS (SELECT 1 FROM members m
                          WHERE m.id = co.member_id
                            AND m.member_type = 'store_internal')
         AND coi.sku_id = ANY (v_batch_skus)
         AND coi.status IN ('pending','reserved','ready')
         AND coi.backorder_at IS NULL
      RETURNING coi.order_id
    )
    SELECT COUNT(DISTINCT order_id) INTO v_bo_orders FROM marked;
  END IF;

  -- 20260814(2)：多給的要跳出內部店 —— 收貨＋配單之後，本批沒有訂單主人的
  -- 剩餘量掛進【內部】xx 店現貨池。逐 SKU：
  --   本批剩餘 = 本批實收 − 本次配掉（保留勾選的派貨中單 ＋ 本次推 ready 的
  --   confirmed 單，只算各自在該 SKU 上的未取需求）。
  -- 實際掛帳交給 _grow_internal_pool 夾兩層上限（本批剩餘 × 帳上自由量 ——
  -- 自由量已扣掉沒勾/拉回而還在等貨的 confirmed 單，不吃他們下一批要領的貨）。
  IF v_store IS NOT NULL THEN
    v_tag := '[收貨多給|TF#' || array_to_string(v_ids, ',') || ']';
    FOR v_sk IN
      WITH got AS (
        SELECT ti.sku_id, SUM(ti.qty_received) AS received
          FROM transfer_items ti
         WHERE ti.transfer_id = ANY (v_ids)
           AND ti.qty_received > 0
         GROUP BY ti.sku_id
      ),
      alloc AS (
        SELECT coi.sku_id, SUM(coi.qty) AS used
          FROM customer_order_items coi
         WHERE coi.status IN ('pending','reserved','ready')
           AND (coi.order_id = ANY (v_chk_ship)
                OR (v_conf IS NOT NULL AND coi.order_id IN (
                      SELECT co.id FROM customer_orders co
                       WHERE co.id = ANY (v_conf)
                         AND co.status = 'ready'
                         AND co.ready_at = v_now)))
         GROUP BY coi.sku_id
      )
      SELECT g.sku_id, GREATEST(g.received - COALESCE(a.used, 0), 0) AS leftover
        FROM got g
        LEFT JOIN alloc a ON a.sku_id = g.sku_id
       WHERE GREATEST(g.received - COALESCE(a.used, 0), 0) > 0
    LOOP
      v_grown := public._grow_internal_pool(
        v_store, v_sk.sku_id, v_sk.leftover, p_operator, v_now, v_tag);
      IF v_grown > 0 THEN
        v_surplus := v_surplus
          || jsonb_build_object('sku_id', v_sk.sku_id, 'qty', v_grown);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'transfers_received', cardinality(v_ids),
    'received',           v_results,
    'pulled_back',        COALESCE(cardinality(v_pulled), 0),
    'pullback_skipped',   v_pull_skipped,
    'shipping_advanced',  v_ship_adv,
    'allocation',         v_alloc,
    'surplus',            v_surplus,
    'backordered',        v_bo_orders
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[], BIGINT[]) IS
  '手動配貨的一段式確認：單一交易內 拉回沒勾的派貨中訂單（shipping → confirmed，'
  '收貨前做，攔住邏輯 C）→ 逐張 rpc_receive_transfer(p_auto_allocate=FALSE) → '
  '清掉勾選單本批 SKU 的待補貨旗標 → 勾選的派貨中訂單推可取貨 → confirmed 勾選單走 '
  'rpc_manual_allocate_confirmed_orders → 沒勾的候選（p_backorder_order_ids）本批 SKU '
  '品項標待補貨（取貨閘門關、會員端顯示待到貨；下一批收貨 A0 自動重算解除）→ '
  '本批多給的剩餘量掛進【內部】店現貨池（_grow_internal_pool）。'
  '無 savepoint —— 任何一步失敗整包回滾（確認才完成收貨；取消/失敗＝什麼都沒發生）。';

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer_manual(BIGINT[], UUID, BIGINT[], TEXT, JSONB, BIGINT[], BIGINT[])
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- D. rpc_unreceive_transfer：反向邏輯 G（一鍵返回配單決策）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_unreceive_transfer(
  p_transfer_id bigint,
  p_operator    uuid,
  p_notes       text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
-- 邏輯 C 需重掃該店所有 ready 訂單並逐張跑 is_order_pickup_ready，覆寫 PostgREST
-- 預設 statement_timeout，避免大店退回時中途被砍。
SET statement_timeout TO '60000'
AS $function$
DECLARE
  v_tenant_id         UUID;
  v_status            TEXT;
  v_transfer_type     TEXT;
  v_dest_location     BIGINT;
  v_existing_notes    TEXT;
  v_customer_order_id BIGINT;
  v_next_transfer_id  BIGINT;
  v_leg2_status       TEXT;
  v_item              RECORD;
  v_orig              stock_movements%ROWTYPE;
  v_on_hand           NUMERIC;
  v_rev_id            BIGINT;
  v_items_reversed    INTEGER := 0;
  v_total_qty         NUMERIC := 0;
  v_dest_store_id     BIGINT;
  v_orders_reverted   INTEGER := 0;
  v_ord               RECORD;
  v_restock_reverted  INTEGER := 0;
  v_rr                RECORD;
  v_prog              RECORD;
  v_surplus_orders    BIGINT[] := '{}'::BIGINT[];
  v_received_at       TIMESTAMPTZ;
  v_backorder_cleared INTEGER := 0;
  v_pullback_restored INTEGER := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id, received_at
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id, v_received_at
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'received' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，僅「已收貨(received)」可退回取消收貨', p_transfer_id, v_status;
  END IF;

  -- 守衛：多段接力且後段已自動出貨（收貨時 ship 過），不允許直接退回本段
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT status INTO v_leg2_status FROM transfers WHERE id = v_next_transfer_id FOR UPDATE;
    IF v_leg2_status IS NOT NULL AND v_leg2_status <> 'draft' THEN
      RAISE EXCEPTION '此調撥為多段接力，後段調撥 %（狀態 %）已出貨，請先處理後段後再退回本段收貨',
        v_next_transfer_id, v_leg2_status;
    END IF;
  END IF;

  -- 逐項沖銷 transfer_in 入庫、並把 qty_received 歸零
  FOR v_item IN
    SELECT id, sku_id, qty_received, in_movement_id
      FROM transfer_items
     WHERE transfer_id = p_transfer_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.qty_received > 0 AND v_item.in_movement_id IS NOT NULL THEN
      SELECT * INTO v_orig FROM stock_movements WHERE id = v_item.in_movement_id;

      IF v_orig.id IS NULL
         OR v_orig.movement_type <> 'transfer_in'
         OR v_orig.source_doc_type <> 'transfer'
         OR v_orig.source_doc_id <> p_transfer_id THEN
        RAISE EXCEPTION 'transfer_item % 的 movement % 非本調撥入庫，無法退回收貨',
          v_item.id, v_item.in_movement_id;
      END IF;
      IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
        RAISE EXCEPTION 'movement % 已被沖銷過，不可重複退回收貨', v_orig.id;
      END IF;

      -- 物理守衛：入庫貨若已被取貨/售出使 on_hand 不足以沖銷 → 擋（避免庫存變負）
      SELECT on_hand INTO v_on_hand
        FROM stock_balances
       WHERE tenant_id   = v_orig.tenant_id
         AND location_id = v_orig.location_id
         AND sku_id      = v_orig.sku_id
       FOR UPDATE;
      IF COALESCE(v_on_hand, 0) < v_orig.quantity THEN
        RAISE EXCEPTION '分店庫存不足以退回收貨（SKU %：現有 %、需沖銷 %）：該批貨可能已被取貨/售出，無法退回',
          v_orig.sku_id, COALESCE(v_on_hand, 0), v_orig.quantity;
      END IF;

      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
      ) VALUES (
        v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
        -v_orig.quantity, v_orig.unit_cost, 'reversal',
        'transfer', p_transfer_id, v_item.id, v_orig.id,
        format('退回收貨 transfer=%s item=%s（沖銷 movement %s）%s',
               p_transfer_id, v_item.id, v_orig.id,
               COALESCE('：' || NULLIF(TRIM(p_notes), ''), '')),
        p_operator
      ) RETURNING id INTO v_rev_id;

      v_total_qty      := v_total_qty + v_orig.quantity;
      v_items_reversed := v_items_reversed + 1;
    END IF;

    UPDATE transfer_items
       SET qty_received   = 0,
           in_movement_id = NULL,
           updated_by     = p_operator,
           updated_at     = NOW()
     WHERE id = v_item.id;
  END LOOP;

  -- 調撥單退回 shipped
  UPDATE transfers
     SET status      = 'shipped',
         received_by = NULL,
         received_at = NULL,
         notes       = CASE
                         WHEN p_notes IS NULL OR TRIM(p_notes) = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN '退回收貨：' || p_notes
                         ELSE v_existing_notes || E'\n退回收貨：' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- 反向邏輯 B（aid 單 FK）/ 邏輯 C（hq_to_store）：
  -- 把因本次收貨被推到 ready、沖銷後已不再 pickup_ready 的訂單退回 shipping。
  -- 因其他已收波次而仍到貨的訂單維持 ready。已取貨(partially_completed/completed)不動。
  IF v_customer_order_id IS NOT NULL THEN
    FOR v_ord IN
      SELECT id FROM customer_orders
       WHERE id = v_customer_order_id AND status = 'ready'
       FOR UPDATE
    LOOP
      IF NOT public.is_order_pickup_ready(v_ord.id) THEN
        UPDATE customer_orders
           SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
         WHERE id = v_ord.id;
        PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
          format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
        v_orders_reverted := v_orders_reverted + 1;
      END IF;
    END LOOP;

  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      FOR v_ord IN
        SELECT id FROM customer_orders
         WHERE tenant_id       = v_tenant_id
           AND pickup_store_id = v_dest_store_id
           AND status          = 'ready'
         FOR UPDATE
      LOOP
        IF NOT public.is_order_pickup_ready(v_ord.id) THEN
          UPDATE customer_orders
             SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
           WHERE id = v_ord.id;
          PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
            format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
          v_orders_reverted := v_orders_reverted + 1;
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- ===== 反向邏輯 D：linked 補貨申請退回 shipped；ride-along 單退回 pending =====
  FOR v_rr IN
    SELECT id FROM restock_requests
     WHERE linked_transfer_id = p_transfer_id
       AND status = 'received'
  LOOP
    UPDATE restock_requests
       SET status = 'shipped', updated_by = p_operator
     WHERE id = v_rr.id;
    v_restock_reverted := v_restock_reverted + 1;

    -- 20260810：settle 的反向 —— 短收被取消/拆行的品項還原，整單短收取消的單重開
    PERFORM public._unsettle_restock_ride_along(v_rr.id, p_operator);
  END LOOP;

  UPDATE customer_orders co
     SET status     = 'pending',
         ready_at   = NULL,
         updated_by = p_operator,
         updated_at = NOW()
    FROM restock_requests rr
   WHERE rr.linked_transfer_id = p_transfer_id
     AND co.tenant_id  = rr.tenant_id
     AND co.order_no   = 'RR-' || rr.id::TEXT
     AND co.order_kind = 'restock'
     AND co.status = 'ready';

  -- ===== 反向邏輯 D2（20260717）：wave 路徑申請退回 shipped =====
  -- 本調撥退回在途後，歸屬的 received 申請若不再「全數出貨且全數到店」
  -- → 退回 shipped、ride-along 單 ready → pending。
  FOR v_rr IN
    SELECT DISTINCT rr.id
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
      JOIN restock_requests rr
        ON rr.tenant_id = v_tenant_id
       AND rr.requesting_store_id = pwi.store_id
     WHERE pwi.generated_transfer_id = p_transfer_id
       AND rr.status = 'received'
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
    IF NOT (v_prog.fully_dispatched AND v_prog.all_arrived) THEN
      UPDATE restock_requests
         SET status = 'shipped', updated_by = p_operator
       WHERE id = v_rr.id AND status = 'received';
      v_restock_reverted := v_restock_reverted + 1;

      -- 20260810：settle 的反向（同反向邏輯 D）
      PERFORM public._unsettle_restock_ride_along(v_rr.id, p_operator);

      UPDATE customer_orders co
         SET status     = 'pending',
             ready_at   = NULL,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE co.tenant_id  = v_tenant_id
         AND co.order_no   = 'RR-' || v_rr.id::TEXT
         AND co.order_kind = 'restock'
         AND co.status = 'ready';
    END IF;
  END LOOP;

  -- ===== 反向邏輯 F（20260814(2)）：收貨多給掛進現貨池的列跟著沖銷 =====
  -- 手動收貨會把本批沒有訂單主人的剩餘量掛進【內部】xx 店現貨池
  -- （notes 標 [收貨多給|TF#<ids>]）。退回收貨後這批貨已不在店裡，
  -- 池子繼續掛著＝店員會把不存在的貨轉出去（20260811000030 忠順同型）。
  -- 已被轉單吃掉的部分（qty 遞減 / 整列 cancelled）不再處理 ——
  -- 重新收貨時 _grow_internal_pool 依當下自由量重算，不會重複掛回。
  WITH hit AS (
    UPDATE customer_order_items coi
       SET status     = 'cancelled',
           notes      = TRIM(BOTH E'\n' FROM COALESCE(coi.notes || E'\n', '')
                        || '[退回收貨沖銷|TF#' || p_transfer_id || ']'),
           updated_by = p_operator,
           updated_at = NOW()
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND co.tenant_id = v_tenant_id
       AND coi.status IN ('pending','reserved','ready')
       AND coi.notes ~ ('\[收貨多給\|TF#([0-9]+,)*' || p_transfer_id::TEXT || '(,[0-9]+)*\]')
    RETURNING coi.order_id
  )
  SELECT COALESCE(ARRAY_AGG(DISTINCT order_id), '{}'::BIGINT[])
    INTO v_surplus_orders FROM hit;

  IF cardinality(v_surplus_orders) > 0 THEN
    -- CLAUDE.md：品項改 cancelled 後接單頭收尾；OV- 容器整張被沖光且
    -- 一件都沒取過 → 整單 cancelled（不留空殼佔 trio 唯一索引 slot）。
    PERFORM public._close_orders_all_items_settled(v_surplus_orders, p_operator, NOW());

    UPDATE customer_orders co
       SET status     = 'cancelled',
           updated_by = p_operator,
           updated_at = NOW()
     WHERE co.id = ANY (v_surplus_orders)
       AND co.status IN ('pending','confirmed','ready','shipping')
       AND NOT EXISTS (SELECT 1 FROM customer_order_items x
                        WHERE x.order_id = co.id
                          AND x.status NOT IN ('cancelled','expired'));
  END IF;

  -- ===== 反向邏輯 G（20260824020000）：一鍵返回配單決策 =====
  -- 手動配單在收貨同一交易做了兩類決策，退回收貨要一起還原：
  --   G1 沒勾的候選標了 backorder_at（值 = 本單 received_at —— 同交易 NOW()
  --      恆等）→ 清掉，否則退回重來後那些人仍被鎖住。
  --   G2 沒勾的派貨中單被拉回 confirmed（updated_at 同樣 = received_at，該
  --      交易裡唯一會把單寫成 confirmed 的就是拉回）→ 還原 shipping，
  --      下次配單才會再被預設勾選。
  -- 範圍限本店 ＋ 本單 SKU；照 received_at 精準對時（timestamptz 微秒級，
  -- 別次操作不可能撞到同一個值）。
  IF v_dest_store_id IS NULL THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id AND location_id = v_dest_location
     LIMIT 1;
  END IF;

  IF v_received_at IS NOT NULL AND v_dest_store_id IS NOT NULL THEN
    UPDATE customer_order_items coi
       SET backorder_at = NULL, backorder_by = NULL,
           updated_by = p_operator, updated_at = NOW()
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND co.tenant_id       = v_tenant_id
       AND co.pickup_store_id = v_dest_store_id
       AND coi.backorder_at   = v_received_at
       AND coi.sku_id IN (SELECT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id);
    GET DIAGNOSTICS v_backorder_cleared = ROW_COUNT;

    FOR v_ord IN
      SELECT co.id FROM customer_orders co
       WHERE co.tenant_id       = v_tenant_id
         AND co.pickup_store_id = v_dest_store_id
         AND co.status          = 'confirmed'
         AND co.updated_at      = v_received_at
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND EXISTS (SELECT 1 FROM customer_order_items coi
                      WHERE coi.order_id = co.id
                        AND coi.status IN ('pending','reserved','ready')
                        AND coi.sku_id IN (SELECT sku_id FROM transfer_items
                                            WHERE transfer_id = p_transfer_id))
       FOR UPDATE
    LOOP
      UPDATE customer_orders
         SET status = 'shipping', updated_by = p_operator, updated_at = NOW()
       WHERE id = v_ord.id;
      PERFORM rpc_log_order_status_change(v_ord.id, 'confirmed', 'shipping', p_operator,
        format('退回收貨（調撥 %s）：還原配單時拉回的派貨中狀態', p_transfer_id));
      v_pullback_restored := v_pullback_restored + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'transfer_id',        p_transfer_id,
    'items_reversed',     v_items_reversed,
    'total_qty_reversed', v_total_qty,
    'orders_reverted',    v_orders_reverted,
    'restock_reverted',   v_restock_reverted,
    'surplus_reversed',   COALESCE(cardinality(v_surplus_orders), 0),
    'backorder_cleared',  v_backorder_cleared,
    'pullback_restored',  v_pullback_restored
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) IS
  '退回收貨：rpc_receive_transfer 的反向。沖銷 transfer_in 入庫(reversal movement)、'
  'qty_received 歸零、調撥單 received→shipped；沖銷後不再 pickup_ready 的訂單退回 shipping；'
  'linked / wave 路徑補貨申請 received→shipped；20260810 起同時反向還原短收結算'
  '（_unsettle_restock_ride_along：拆行併回、[短收未到] 還原 pending、短收取消單重開）；'
  '20260814(2) 起連帶沖銷本單掛進現貨池的 [收貨多給|TF#] 列。'
  '20260824020000 起加反向邏輯 G：清掉配單標的待補貨旗標、拉回的派貨中單還原 shipping'
  '（照 received_at 對時）—— 一鍵返回整個收貨＋配單動作。'
  '守衛：非 received / 後段已出貨 / movement 已沖銷 / on_hand 不足(貨已取用) 皆擋下。';

-- ----------------------------------------------------------------
-- E. 多收回報總倉：constraint + view 分支 + 知道了 RPC
-- ----------------------------------------------------------------
DO $$
DECLARE v_conname TEXT;
BEGIN
  SELECT conname INTO v_conname
    FROM pg_constraint
   WHERE conrelid = 'transfer_items'::regclass
     AND pg_get_constraintdef(oid) LIKE '%shortage_resolution%';
  IF v_conname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE transfer_items DROP CONSTRAINT %I', v_conname);
  END IF;
END $$;

ALTER TABLE transfer_items
  ADD CONSTRAINT transfer_items_shortage_resolution_check
    CHECK (shortage_resolution IS NULL OR shortage_resolution IN
      ('replenish','cancel_orders','vendor_claim','accept','restock_hq','redispatch','over_ack'));

COMMENT ON COLUMN transfer_items.shortage_resolution IS
  '短收處理方式:replenish=補出貨/cancel_orders=取消客戶訂單/vendor_claim=供應商求償/'
  'accept=接受短收/restock_hq=沖回總倉庫存/redispatch=已重派/over_ack=多收已知悉(20260824020000)';

CREATE OR REPLACE VIEW public.v_hq_exceptions AS
-- 1+3. 進貨短少 / 過量進貨（同一次掃描，用 qty_shortage 決定 type）
SELECT
  CASE WHEN pd.qty_shortage > 0 THEN 'po_shortage' ELSE 'po_over' END::text AS type,
  (CASE WHEN pd.qty_shortage > 0 THEN 'po-short-' ELSE 'po-over-' END
    || pd.po_id::text || ':' || pd.sku_id::text)                            AS row_key,
  po.created_at                                                             AS ts,
  pd.po_no                                                                  AS doc_no,
  pd.sku_code,
  pd.sku_label,
  pd.qty_ordered::numeric                                                   AS expected,
  pd.gr_qty                                                                 AS actual,
  CASE WHEN pd.qty_shortage > 0 THEN pd.qty_shortage
       ELSE pd.gr_qty - pd.qty_ordered END                                  AS diff,
  NULL::text                                                                AS reason,
  CASE WHEN pd.qty_shortage > 0 THEN 'PO 已關單,差額不會到'
       ELSE '供應商多送或重複入庫' END::text                                 AS extra,
  NULL::bigint                                                              AS transfer_item_id,
  NULL::bigint                                                              AS transfer_id,
  NULL::text                                                                AS transfer_no,
  pd.sku_id,
  NULL::numeric                                                             AS qty_shipped,
  NULL::numeric                                                             AS qty_received,
  NULL::numeric                                                             AS shortage_qty,
  NULL::bigint                                                              AS dest_location,
  NULL::bigint                                                              AS dest_store_id,
  NULL::text                                                                AS dest_store_name,
  NULL::bigint                                                              AS customer_order_id,
  NULL::text                                                                AS shortage_resolution,
  pd.po_id                                                                  AS doc_id,
  (SELECT l.name FROM locations l WHERE l.id = po.dest_location_id)         AS warehouse_name
FROM (
  SELECT DISTINCT po_id, sku_id, po_no, sku_code, sku_label, qty_ordered, gr_qty, qty_shortage
  FROM public.v_picking_demand_by_po
  WHERE qty_shortage > 0 OR gr_qty > qty_ordered
) pd
LEFT JOIN public.purchase_orders po ON po.id = pd.po_id

UNION ALL

-- 2. 進貨破損
SELECT
  'po_damage'::text,
  'po-dmg-' || gri.id::text,
  gr.created_at,
  gr.gr_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || gri.sku_id::text),
  gri.qty_received::numeric,
  gri.qty_received - gri.qty_damaged,
  gri.qty_damaged::numeric,
  gri.variance_reason,
  '已收 ' || gri.qty_received::text || ' 含瑕疵 ' || gri.qty_damaged::text,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  gri.sku_id,
  NULL::numeric,
  NULL::numeric,
  NULL::numeric,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  NULL::bigint,
  NULL::text,
  gr.po_id,
  (SELECT l.name FROM locations l WHERE l.id = gr.dest_location_id)
FROM public.goods_receipt_items gri
JOIN public.goods_receipts gr ON gr.id = gri.gr_id
LEFT JOIN public.skus s ON s.id = gri.sku_id
WHERE gri.qty_damaged > 0
  AND gr.status = 'confirmed'

UNION ALL

-- 4. 收貨短少（轉貨 received 但實收 < 出貨；已標補出貨但還沒補到的也繼續列）
SELECT
  'transfer_short'::text,
  'tshort-' || ti.id::text,
  COALESCE(t.received_at, t.created_at),
  t.transfer_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || ti.sku_id::text),
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_shipped - ti.qty_received,
  CASE WHEN NULLIF(TRIM(COALESCE(t.notes,'')), '') IS NOT NULL
       THEN '店家收貨備註：' || TRIM(t.notes) ELSE NULL END,
  (CASE WHEN COALESCE(ti.damage_qty, 0) > 0 THEN '含破損 ' || ti.damage_qty::text
        ELSE '分店少收或運送中遺失' END)
  || (CASE WHEN ti.shortage_resolution = 'replenish' THEN ' · 已標補出貨,尚未補到' ELSE '' END),
  ti.id,
  ti.transfer_id,
  t.transfer_no,
  ti.sku_id,
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_shipped - ti.qty_received,
  t.dest_location,
  (SELECT ds.id FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  ),
  NULL::bigint,
  NULL::text,
  ti.transfer_id,
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  )
FROM public.transfer_items ti
JOIN public.transfers t ON t.id = ti.transfer_id
LEFT JOIN public.skus s ON s.id = ti.sku_id
WHERE t.status = 'received'
  AND ti.qty_received < ti.qty_shipped
  AND (
    ti.shortage_resolution IS NULL
    OR (
      ti.shortage_resolution = 'replenish'
      AND COALESCE((
        SELECT SUM(ti2.qty_received)
        FROM public.transfers t2
        JOIN public.transfer_items ti2 ON ti2.transfer_id = t2.id
        WHERE t2.dest_location = t.dest_location
          AND t2.tenant_id = t.tenant_id
          AND ti2.sku_id = ti.sku_id
          AND t2.status IN ('received', 'closed')
          AND COALESCE(t2.received_at, t2.updated_at) > ti.shortage_resolution_at
      ), 0) < (ti.qty_shipped - ti.qty_received)
    )
  )
UNION ALL

-- 5. 收貨多收（20260824020000：轉貨 received 且實收 > 出貨 —— 店家照實收，
--    差異回報總倉；HQ 按「知道了」(shortage_resolution='over_ack') 收掉）
SELECT
  'transfer_over'::text,
  'tover-' || ti.id::text,
  COALESCE(t.received_at, t.created_at),
  t.transfer_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || ti.sku_id::text),
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_received - ti.qty_shipped,
  CASE WHEN NULLIF(TRIM(COALESCE(t.notes,'')), '') IS NOT NULL
       THEN '店家收貨備註：' || TRIM(t.notes) ELSE NULL END,
  '分店實收多於派出（總倉多裝或撿貨誤差），貨已入分店帳'::text,
  ti.id,
  ti.transfer_id,
  t.transfer_no,
  ti.sku_id,
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_shipped - ti.qty_received,
  t.dest_location,
  (SELECT ds.id FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  ),
  NULL::bigint,
  ti.shortage_resolution,
  ti.transfer_id,
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  )
FROM public.transfer_items ti
JOIN public.transfers t ON t.id = ti.transfer_id
LEFT JOIN public.skus s ON s.id = ti.sku_id
WHERE t.status = 'received'
  AND ti.qty_received > ti.qty_shipped
  AND ti.shortage_resolution IS NULL;

GRANT SELECT ON public.v_hq_exceptions TO authenticated;

COMMENT ON VIEW public.v_hq_exceptions IS
  '總倉收件匣異常統一 view:union 進貨短少/破損/過量/收貨短少/收貨多收 5 來源為扁平列,'
  '供 rpc_hq_exceptions 做 server-side 分頁與計數。'
  'warehouse_name = 該筆異常的地點（PO/GR 收貨倉、收貨分店），前端畫成「地點」欄。'
  'transfer_over(20260824020000)=分店實收多於派出,HQ 按「知道了」(over_ack)收掉。';

-- HQ「知道了」：把多收列標 over_ack，從收件匣消失。
-- 角色守衛比照 rpc_resolve_transfer_item_shortage（20260811020000）：
-- app_metadata.role 不在管理員層級（owner/admin/hq_manager/''）才擋。
CREATE OR REPLACE FUNCTION public.rpc_ack_transfer_over(
  p_transfer_item_id BIGINT,
  p_operator         UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
  v_ti   RECORD;
BEGIN
  v_role := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  SELECT ti.id, ti.qty_shipped, ti.qty_received, ti.shortage_resolution, t.tenant_id
    INTO v_ti
    FROM transfer_items ti
    JOIN transfers t ON t.id = ti.transfer_id
   WHERE ti.id = p_transfer_item_id
   FOR UPDATE OF ti;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_item % not found', p_transfer_item_id;
  END IF;
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_ti.tenant_id THEN
    RAISE EXCEPTION 'transfer_item not in current tenant';
  END IF;
  IF v_ti.qty_received <= v_ti.qty_shipped THEN
    RAISE EXCEPTION '此列不是多收（實收 % ≤ 派出 %）', v_ti.qty_received, v_ti.qty_shipped;
  END IF;
  IF v_ti.shortage_resolution IS NOT NULL THEN
    RAISE EXCEPTION '此列已處理過（%）', v_ti.shortage_resolution;
  END IF;

  UPDATE transfer_items
     SET shortage_resolution    = 'over_ack',
         shortage_resolution_at = NOW(),
         shortage_resolution_by = p_operator,
         updated_by             = p_operator,
         updated_at             = NOW()
   WHERE id = p_transfer_item_id;

  RETURN jsonb_build_object('transfer_item_id', p_transfer_item_id, 'resolution', 'over_ack');
END;
$$;

COMMENT ON FUNCTION public.rpc_ack_transfer_over(BIGINT, UUID) IS
  '總倉收件匣「收貨多收」的知道了：標 shortage_resolution=over_ack，該列從 v_hq_exceptions 消失。';

GRANT EXECUTE ON FUNCTION public.rpc_ack_transfer_over(BIGINT, UUID) TO authenticated, service_role;

-- rpc_hq_exceptions 的 counts 補 transfer_over。
-- ⚠ 線上真身是 4 參數版（含 p_search，doc_no/sku/店名模糊搜尋）——
--   repo 只有 20260704000020 的 3 參數版，p_search 是「直接套上線沒回寫
--   migration」的 drift（同 SP- 前綴那課）。這裡收編 4 參數版為基底；
--   3 參數版一併 DROP —— 兩個 overload 並存時 PostgREST 用 3 個具名參數
--   呼叫會歧義（PGRST203），收件匣整頁會炸。
DROP FUNCTION IF EXISTS public.rpc_hq_exceptions(text, integer, integer);

CREATE OR REPLACE FUNCTION public.rpc_hq_exceptions(
  p_type      text DEFAULT NULL,
  p_page      int  DEFAULT 1,
  p_page_size int  DEFAULT 20,
  p_search    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ex AS MATERIALIZED (
    SELECT * FROM public.v_hq_exceptions
    WHERE (NULLIF(TRIM(p_search), '') IS NULL
           OR doc_no ILIKE '%' || TRIM(p_search) || '%'
           OR sku_code ILIKE '%' || TRIM(p_search) || '%'
           OR sku_label ILIKE '%' || TRIM(p_search) || '%'
           OR warehouse_name ILIKE '%' || TRIM(p_search) || '%')
  ),
  filtered AS (
    SELECT * FROM ex
    WHERE (p_type IS NULL OR p_type = 'all' OR ex.type = p_type)
  ),
  page AS (
    SELECT * FROM filtered
    ORDER BY ts DESC NULLS LAST, row_key
    LIMIT  GREATEST(1, p_page_size)
    OFFSET GREATEST(0, (p_page - 1) * p_page_size)
  )
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM filtered),
    'counts', (
      SELECT jsonb_build_object(
        'all',               COUNT(*),
        'po_shortage',       COUNT(*) FILTER (WHERE type = 'po_shortage'),
        'po_damage',         COUNT(*) FILTER (WHERE type = 'po_damage'),
        'po_over',           COUNT(*) FILTER (WHERE type = 'po_over'),
        'transfer_short',    COUNT(*) FILTER (WHERE type = 'transfer_short'),
        'transfer_over',     COUNT(*) FILTER (WHERE type = 'transfer_over'),
        'customer_shortage', COUNT(*) FILTER (WHERE type = 'customer_shortage')
      )
      FROM ex
    ),
    'rows', (
      SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY ts DESC NULLS LAST, row_key), '[]'::jsonb)
      FROM page
    )
  );
$$;

GRANT EXECUTE ON FUNCTION public.rpc_hq_exceptions(text, int, int, text) TO authenticated;

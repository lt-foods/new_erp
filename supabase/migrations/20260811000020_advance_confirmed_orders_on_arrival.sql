-- ============================================================
-- 2026-08-11 (3)：補貨路線發的團，收貨時要自動配單（confirmed → ready）
--
-- 災情（忠順店回報）：
--   進貨單 WV260811001364（＝補貨申請 RR-376）收貨後，內含的
--   「智利鮭魚頭剖半」10 包全部掛進【內部】忠順店的 RR-376，
--   而該店 3 張真的客人訂單（GRP-20260717-022，共 8 包）狀態
--   停在 'confirmed' 沒動 —— 店家看到「有加單卻沒自動配單」。
--
-- 根因（兩段都對不上，不是店家操作問題）：
--   這一團從頭到尾**沒有開過團購撿貨波次**，總倉是用「補貨申請」把貨
--   發到 14 間店的。補貨波次的 picking_wave_items.campaign_id 是 NULL，於是
--     1. 派貨：rpc_mark_orders_shipping_for_wave 要求
--        pwi.campaign_id = co.campaign_id 才推 → 客人單沒被推到 'shipping'。
--     2. 收貨：rpc_receive_transfer 邏輯 C 只推 status = 'shipping' 的單
--        → 客人單卡在 'confirmed'，永遠等不到人推。
--   取貨閘門 is_order_item_pickup_ready() 其實已經放行（走 Path C：該團該店
--   沒有對齊波次 → 退用「本店該 SKU 有實收」），但 /pickup 前端只讓
--   ready / partially_completed / shipping 的單勾品項，confirmed 一律不給勾，
--   所以店員實際上發不出貨，只剩「從 RR- 內部單轉單給客人」一條路 ——
--   而轉單會開一張**新單**、原本那張團購單永遠留在 confirmed，變成重複單
--   （未取貨金額重複計算，庫存上 RR- 10 包 + 團購單 8 包壓在 10 包實體貨上）。
--
-- 影響範圍（修這支之前的線上實測）：
--   * GRP-20260717-022 這一團：14 間店、105 張單、209 件，全部卡 confirmed。
--   * 全站同狀態（貨已到店、閘門放行、單頭仍 confirmed）：22 個團、265 張單。
--     其中 20 個團一個團購波次都沒開過，都是同一個模式（例：GRP-20260730-001
--     韓國米餅 41 張，08-04 也是走補貨申請發的）。
--
-- 修法：收貨時把「對得上這次到貨 SKU」的 confirmed 單一併推 ready，
--   但**必須帶數量守衛**。不能只看閘門就整批放行 —— 閘門是 qty-blind 的
--   （Path C 只問「本店有沒有實收過這個 SKU」），拿它當到貨通知的觸發條件
--   會出現「補貨 2 包、團購欠 8 包 → 8 位團友都收到到貨通知卻撲空」。
--   實例：經國店該 SKU 收 10 包，已經先用轉單賣掉 6 包、另 3 包轉出未取，
--   on_hand 只剩 4，欠 9 —— 無條件放行就會多通知 5 包出去。
--
--   所以配法比照既有的「依訂單時間自動配」（20260805000070 / ShortageAllocateModal）：
--     可配量 = stock_balances.on_hand − 已承諾未取量
--     依 created_at, order_no 由早到晚，**整單**裝得下才推 ready；
--     裝不下就跳過（維持 confirmed，等下一批貨再收時自然會被重算）。
--   刻意不寫 backorder_at：那一欄是「少發配貨沒配到」的語意，
--   會讓 is_order_item_pickup_ready 回 false，反而多一道要人工解除的關卡；
--   維持 confirmed 就是現況行為，只加不減。
--
--   「已承諾未取量」排除 members.member_type = 'store_internal' 的單
--   （RR- / 內部 xx 店是店內現貨池的容器，不是對客人的承諾；算進去會把
--   可配量歸零，等於這支完全不會生效）。
--
-- 只加不減：'shipping' → ready 那條原本的路徑逐字保留、行為與守衛完全不動
--   （維持 qty-blind），新增的數量守衛只作用在新的 'confirmed' 分支。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   rpc_receive_transfer = 20260810000000_short_receipt_settles_restock.sql
--   （＝線上現行版；邏輯 A/B/C/D/D2 全數逐字保留，只在邏輯 C 尾巴加一段呼叫）
--
-- Rollback：
--   CREATE OR REPLACE FUNCTION public.rpc_receive_transfer 回
--     20260810000000_short_receipt_settles_restock.sql 的版本；
--   DROP FUNCTION IF EXISTS public._advance_arrived_confirmed_orders(BIGINT,BIGINT[],UUID,TIMESTAMPTZ);
--   回填反轉（只還原本檔推上去的那批）：
--     UPDATE customer_orders SET status = 'confirmed', ready_at = NULL
--      WHERE status = 'ready'
--        AND updated_by = '00000000-0000-0000-0000-000000000000'::uuid;
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _advance_arrived_confirmed_orders — 到貨後把 confirmed 單依序推 ready
--
--    p_sku_ids = NULL → 該店所有 SKU（回填用）；否則只看這次到貨的 SKU。
--    回傳推進的訂單張數。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._advance_arrived_confirmed_orders(
  p_store_id BIGINT,
  p_sku_ids  BIGINT[],
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_budget   JSONB   := '{}'::JSONB;   -- sku_id(text) → 尚可配數量
  v_ord      RECORD;
  v_it       RECORD;
  v_fits     BOOLEAN;
  v_rem      NUMERIC;
  v_advanced INT := 0;
BEGIN
  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;

  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;   -- 沒設倉庫位置的店沒有 on_hand 可算，直接不動
  END IF;

  -- 可配量：本店現有庫存 − 已承諾未取量。
  -- 種子集合＝本店所有 confirmed 單的未取 SKU（不限 p_sku_ids）——
  -- 多品項的單要每一項都有預算才能推，所以預算表不能只放這次到貨的 SKU。
  SELECT COALESCE(jsonb_object_agg(b.sku_id::TEXT, b.avail), '{}'::JSONB)
    INTO v_budget
    FROM (
      SELECT sk.sku_id,
             COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0) AS avail
        FROM (
          SELECT DISTINCT coi.sku_id
            FROM customer_orders co
            JOIN customer_order_items coi ON coi.order_id = co.id
           WHERE co.tenant_id       = v_tenant
             AND co.pickup_store_id = p_store_id
             AND co.status          = 'confirmed'
             AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
             AND coi.status IN ('pending','reserved','ready')
        ) sk
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_loc
              AND sb.sku_id      = sk.sku_id
        LEFT JOIN LATERAL (
          -- 已經被承諾、貨還沒交出去的量。排除 store_internal 會員的單
          --（RR- / 【內部】xx 店是現貨池容器，不是對客人的承諾）。
          SELECT SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = p_store_id
             AND co2.status IN ('ready','partially_completed','shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.sku_id = sk.sku_id
             AND coi2.status IN ('pending','reserved','ready')
        ) pr ON TRUE
    ) b;

  IF v_budget = '{}'::JSONB THEN
    RETURN 0;
  END IF;

  -- 依下單時間由早到晚（同時間用單號決勝，與 20260805000070 同規則）
  FOR v_ord IN
    SELECT co.id
      FROM customer_orders co
     WHERE co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.status          = 'confirmed'
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       -- 便宜的前置篩：至少一項是這次到貨的 SKU、且店裡真的有帳上庫存。
       -- 先擋掉絕大多數候選，才輪到昂貴的 is_order_pickup_ready()。
       AND EXISTS (
         SELECT 1
           FROM customer_order_items coi
           JOIN stock_balances sb
             ON sb.tenant_id   = v_tenant
            AND sb.location_id = v_loc
            AND sb.sku_id      = coi.sku_id
            AND sb.on_hand     > 0
          WHERE coi.order_id = co.id
            AND coi.status IN ('pending','reserved','ready')
            AND (p_sku_ids IS NULL OR coi.sku_id = ANY (p_sku_ids))
       )
       -- 整單閘門：所有未取品項都到貨（Path A~D'、qty_received > 0、backorder_at）
       AND public.is_order_pickup_ready(co.id)
     ORDER BY co.created_at, co.order_no
  LOOP
    -- 裝得下才推：整單每一個 SKU 的需求都要在預算內（不拆行）
    v_fits := TRUE;
    FOR v_it IN
      SELECT coi.sku_id, SUM(coi.qty) AS need
        FROM customer_order_items coi
       WHERE coi.order_id = v_ord.id
         AND coi.status IN ('pending','reserved','ready')
       GROUP BY coi.sku_id
    LOOP
      IF COALESCE((v_budget ->> v_it.sku_id::TEXT)::NUMERIC, 0) < v_it.need THEN
        v_fits := FALSE;
        EXIT;
      END IF;
    END LOOP;

    IF NOT v_fits THEN
      CONTINUE;   -- 裝不下就跳過，繼續試後面的小單（維持 confirmed 等下批貨）
    END IF;

    FOR v_it IN
      SELECT coi.sku_id, SUM(coi.qty) AS need
        FROM customer_order_items coi
       WHERE coi.order_id = v_ord.id
         AND coi.status IN ('pending','reserved','ready')
       GROUP BY coi.sku_id
    LOOP
      v_rem := COALESCE((v_budget ->> v_it.sku_id::TEXT)::NUMERIC, 0) - v_it.need;
      v_budget := jsonb_set(v_budget, ARRAY[v_it.sku_id::TEXT], to_jsonb(v_rem));
    END LOOP;

    UPDATE customer_orders
       SET status     = 'ready',
           ready_at   = p_at,
           updated_by = p_operator,
           updated_at = p_at
     WHERE id = v_ord.id
       AND status = 'confirmed';

    v_advanced := v_advanced + 1;
  END LOOP;

  RETURN v_advanced;
END;
$$;

COMMENT ON FUNCTION public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ) IS
  '到貨後把該店 confirmed 的客人訂單依訂單時間推 ready（補貨路線發的團沒有 campaign 對齊波次，'
  '不會被 rpc_mark_orders_shipping_for_wave 推到 shipping，收貨端也就接不到）。'
  '守衛：整單過 is_order_pickup_ready + 可配量（on_hand − 已承諾未取，排除 store_internal 容器單）'
  '裝得下才推，裝不下維持 confirmed。p_sku_ids = NULL → 該店所有 SKU。';

GRANT EXECUTE ON FUNCTION public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 2. rpc_receive_transfer — 邏輯 C 尾巴接上 confirmed 單的自動配單
--    （基底 20260810000000，逐字保留；只新增 v_recv_skus 宣告 + 邏輯 C 末段）
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

      -- 20260811(3)：補貨路線發的團沒有 campaign 對齊波次，客人單從來沒被推到
      -- 'shipping'，上面那段接不到。這裡把「對得上本次到貨 SKU」的 confirmed 單
      -- 依訂單時間、在可配量內一併推 ready（詳見 _advance_arrived_confirmed_orders）。
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
-- 3. 一次性回填：既有「貨已到店、閘門放行、單頭仍 confirmed」的單
--    用跟上面同一套規則補推一次（含數量守衛，配不到的維持 confirmed）。
--    operator 記成全 0 uuid ＝ 系統回填，好跟人工操作區分／回滾。
-- ----------------------------------------------------------------
DO $$
DECLARE
  s        RECORD;
  v_n      INT;
  v_total  INT := 0;
  v_stores INT := 0;
BEGIN
  FOR s IN
    SELECT id, name FROM stores WHERE location_id IS NOT NULL ORDER BY id
  LOOP
    v_n := public._advance_arrived_confirmed_orders(
             s.id, NULL, '00000000-0000-0000-0000-000000000000'::UUID, NOW());
    IF v_n > 0 THEN
      RAISE NOTICE '  % (store %): % 張推到可取貨', s.name, s.id, v_n;
      v_stores := v_stores + 1;
      v_total  := v_total + v_n;
    END IF;
  END LOOP;

  RAISE NOTICE '回填完成：% 間店、共 % 張 confirmed → ready', v_stores, v_total;
END $$;

-- ============================================================
-- 2026-08-13：收貨可選「自動配單 / 手動配單」（定城店需求）
--
-- 需求（定城 2026-08-13）：補貨到店數量不夠分給所有團購訂單時，
--   自動配單（邏輯 E，依訂單時間由早到晚）會替店家決定誰先拿到貨；
--   店家想自己挑（熟客優先、急件優先…），但目前「無法選擇」——
--   唯一的替代路是從 RR- 內部單轉單給客人，而那會開新單、原團購單
--   永遠卡 confirmed 變重複單（20260811000020 檔頭記錄的忠順災情）。
--
-- 修法：收貨時讓店家選——
--   * 自動配單（預設，行為不變）：邏輯 E 依訂單時間在可配量內推 ready。
--   * 手動配單：收貨只入庫，不自動推任何 confirmed 單；店家在收貨頁
--     開「手動配單」彈窗勾選要配給哪幾張單，用**同一支**
--     _advance_arrived_confirmed_orders 推進（數量守衛、整單裝得下才推、
--     現貨池收斂全部沿用），只是候選集合換成店家勾的那幾張。
--
-- 內容：
--   1. _advance_arrived_confirmed_orders 加 p_order_ids BIGINT[] DEFAULT NULL
--      （NULL = 原自動行為；給值 = 只考慮這些單）。簽名變了要 DROP 重建。
--   2. rpc_receive_transfer 加 p_auto_allocate BOOLEAN DEFAULT TRUE
--      （FALSE = 跳過邏輯 E）。邏輯 A0（到貨自動解除待補貨）**兩種模式都保留**：
--      那是「先前⚖️配貨決定」的完成、有數量+實體庫存雙守衛，關掉會重演
--      松山單卡 6 天的災情（20260811000050）；要重新決定配給誰請走 ⚖️ 配貨。
--   3. rpc_receive_transfer_batch 同步加 p_auto_allocate 透傳。
--   4. rpc_get_members_to_notify_for_transfer 只通知**真的可取貨**的單
--      （status IN ready / partially_completed / shipping）。原本對「碰到
--      到貨 SKU 的所有未結單」都推播（qty-blind）——手動模式下沒配到的
--      confirmed 單也會收到「商品到貨」跑來撲空；自動模式下裝不下被跳過的
--      單同樣會被誤通知（CLAUDE.md「拿閘門當到貨通知要自己加數量守衛」，
--      這裡改成直接看單頭 status，與 /pickup 放行的集合一致）。
--      ⚠ 線上 drift：線上現行版是 20260516000005 的 jsonb 舊版
--      （20260605000011 的 RETURNS TABLE + no_notify_pickup 黑名單版
--      沒有部署，黑名單過濾一直沒生效）。本檔以 repo 最新
--      20260605000011 為基底一併收掉這個 drift。
--   5. 新 RPC rpc_get_manual_allocation_candidates(p_store_id)：
--      手動配單彈窗的候選清單（本店 confirmed 一般單、貨已到齊）
--      ＋各 SKU 可配量（on_hand − 已承諾未取，算法與邏輯 E 同一套）。
--   6. 新 RPC rpc_manual_allocate_confirmed_orders(p_store_id, p_order_ids,
--      p_operator)：把店家勾的單推 ready（走擴充後的
--      _advance_arrived_confirmed_orders），回傳成功/跳過清單與
--      到貨推播名單（已過 no_notify_pickup 黑名單）。
--
-- 基底版本（append-only，逐字保留所有 prior fix；已與線上
--   pg_get_functiondef 逐字比對確認一致，members_to_notify 除外見上）：
--   _advance_arrived_confirmed_orders      = 20260811000030
--   rpc_receive_transfer                   = 20260811000050
--   rpc_receive_transfer_batch             = 20260710000000
--   rpc_get_members_to_notify_for_transfer = 20260605000011
--
-- Rollback：
--   DROP FUNCTION public.rpc_manual_allocate_confirmed_orders(BIGINT, BIGINT[], UUID);
--   DROP FUNCTION public.rpc_get_manual_allocation_candidates(BIGINT);
--   DROP FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT, BOOLEAN);
--   DROP FUNCTION public.rpc_receive_transfer_batch(BIGINT[], UUID, TEXT, BOOLEAN);
--   DROP FUNCTION public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ, BIGINT[]);
--   然後重跑 20260811000030（helper）、20260811000050（receive）、
--   20260710000000（batch）、20260605000011（members_to_notify）。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _advance_arrived_confirmed_orders — 加 p_order_ids（手動配單用）
--    基底 20260811000030 逐字保留；只加參數 + 候選迴圈一行過濾。
--    加了 DEFAULT 參數會產生 overload 歧義，必須先 DROP 舊簽名。
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION public._advance_arrived_confirmed_orders(
  p_store_id  BIGINT,
  p_sku_ids   BIGINT[],
  p_operator  UUID,
  p_at        TIMESTAMPTZ DEFAULT NOW(),
  p_order_ids BIGINT[]    DEFAULT NULL
) RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_budget   JSONB   := '{}'::JSONB;   -- sku_id(text) → 尚可配數量
  v_alloc    JSONB   := '{}'::JSONB;   -- sku_id(text) → 本次實際配出去的量
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
  -- 20260813：p_order_ids 有值時只考慮這些單（手動配單 —— 店家勾誰就推誰，
  -- 其餘守衛與順序不變；勾的單彼此仍依訂單時間先後分預算）。
  FOR v_ord IN
    SELECT co.id
      FROM customer_orders co
     WHERE co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.status          = 'confirmed'
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND (p_order_ids IS NULL OR co.id = ANY (p_order_ids))
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
      -- 20260811(4)：記下本次配出量，稍後用來收斂現貨池
      v_alloc := jsonb_set(
        v_alloc, ARRAY[v_it.sku_id::TEXT],
        to_jsonb(COALESCE((v_alloc ->> v_it.sku_id::TEXT)::NUMERIC, 0) + v_it.need));
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

  -- 20260811(4)：配出去的貨已經是客人的了，【內部】xx 店的池子不能再掛著同一批
  FOR v_it IN
    SELECT k.key::BIGINT AS sku_id, k.value::NUMERIC AS allocated
      FROM jsonb_each_text(v_alloc) k
  LOOP
    PERFORM public._trim_internal_pool(
      p_store_id, v_it.sku_id, v_it.allocated, p_operator, p_at);
  END LOOP;

  RETURN v_advanced;
END;
$$;

COMMENT ON FUNCTION public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ, BIGINT[]) IS
  '到貨後把該店 confirmed 的客人訂單依訂單時間推 ready（補貨路線發的團沒有 campaign 對齊波次，'
  '不會被 rpc_mark_orders_shipping_for_wave 推到 shipping，收貨端也就接不到）。'
  '守衛：整單過 is_order_pickup_ready + 可配量（on_hand − 已承諾未取，排除 store_internal 容器單）'
  '裝得下才推，裝不下維持 confirmed。配完後呼叫 _trim_internal_pool 扣掉現貨池的超額掛帳，'
  '避免同一批貨被重複轉單給別人。p_sku_ids = NULL → 該店所有 SKU。'
  '20260813：p_order_ids 有值時只考慮這些單（手動配單），NULL = 原自動行為。';

GRANT EXECUTE ON FUNCTION public._advance_arrived_confirmed_orders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ, BIGINT[])
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 2. rpc_receive_transfer — 加 p_auto_allocate（FALSE = 跳過邏輯 E）
--    基底 20260811000050 逐字保留；只加參數、邏輯 E 的 IF、回傳一個欄位。
--    加了 DEFAULT 參數會產生 overload 歧義，必須先 DROP 舊簽名。
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT);

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

  RETURN jsonb_build_object(
    'transfer_id',            p_transfer_id,
    'items_received',         v_items_received,
    'total_qty_received',     v_total_qty,
    'total_variance',         v_total_variance,
    'orders_advanced',        v_orders_advanced,
    'next_transfer_shipped',  v_next_shipped,
    'restock_received',       v_restock_received,
    'backorders_freed',       v_backorders_freed,
    'auto_allocate',          p_auto_allocate
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT, BOOLEAN)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 3. rpc_receive_transfer_batch — p_auto_allocate 透傳
--    基底 20260710000000 逐字保留；只加參數 + 透傳。先 DROP 舊簽名。
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_receive_transfer_batch(BIGINT[], UUID, TEXT);

CREATE OR REPLACE FUNCTION public.rpc_receive_transfer_batch(
  p_transfer_ids  BIGINT[],
  p_operator      UUID,
  p_notes         TEXT    DEFAULT NULL,
  p_auto_allocate BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
-- 序列處理整批可能比單張久；覆寫 PostgREST 預設的 statement_timeout（8s），
-- 讓大批次（一個波次數十家分店）也不會中途被 timeout 砍斷。
SET statement_timeout TO '180000'
AS $$
DECLARE
  v_id        BIGINT;
  v_ok_count  INTEGER := 0;
  v_succeeded BIGINT[] := ARRAY[]::BIGINT[];
  v_failed    JSONB    := '[]'::jsonb;
  v_err       TEXT;
BEGIN
  IF p_transfer_ids IS NULL OR array_length(p_transfer_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;

  FOREACH v_id IN ARRAY p_transfer_ids LOOP
    BEGIN
      -- 序列呼叫現行單張收貨（全收：p_lines=NULL）。子區塊＝savepoint，
      -- 單張失敗只回滾該張、CONTINUE 處理下一張。
      PERFORM public.rpc_receive_transfer(v_id, NULL, p_operator, p_notes, p_auto_allocate);
      v_ok_count  := v_ok_count + 1;
      v_succeeded := v_succeeded || v_id;
    EXCEPTION WHEN OTHERS THEN
      v_err    := SQLERRM;
      v_failed := v_failed || jsonb_build_object('id', v_id, 'error', v_err);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', array_length(p_transfer_ids, 1),
    'ok_count',  v_ok_count,
    'succeeded', v_succeeded,
    'failed',    v_failed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer_batch(BIGINT[], UUID, TEXT, BOOLEAN) TO authenticated;

COMMENT ON FUNCTION public.rpc_receive_transfer_batch(BIGINT[], UUID, TEXT, BOOLEAN) IS
  '批次收貨：單一交易序列呼叫 rpc_receive_transfer（全收），取代前端並行打 N 次'
  '造成的 row-lock 互卡 / statement timeout。單張失敗以 savepoint 隔離，回傳 succeeded / failed。'
  '20260813：p_auto_allocate 透傳（FALSE = 手動配單模式，收貨不自動配 confirmed 單）。';

-- ----------------------------------------------------------------
-- 4. rpc_get_members_to_notify_for_transfer — 只通知真的可取貨的單
--    基底 20260605000011（RETURNS TABLE + no_notify_pickup 黑名單）。
--    線上現行是 20260516000005 的 jsonb 舊版（drift，黑名單一直沒生效），
--    回傳型別不同必須 DROP 重建，順便把 drift 收掉。
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_get_members_to_notify_for_transfer(BIGINT);

CREATE OR REPLACE FUNCTION public.rpc_get_members_to_notify_for_transfer(
  p_transfer_id BIGINT
) RETURNS TABLE(
  member_id              BIGINT,
  order_id               BIGINT,
  order_no               TEXT,
  last_notify_pickup_at  TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH dest AS (
    SELECT t.dest_location, t.tenant_id, s.id AS store_id
      FROM transfers t
      LEFT JOIN stores s ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
     WHERE t.id = p_transfer_id
  ),
  skus AS (
    SELECT DISTINCT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id
  )
  SELECT DISTINCT co.member_id, co.id, co.order_no, co.last_notify_pickup_at
    FROM customer_orders co
    JOIN dest d
      ON d.store_id = co.pickup_store_id
     AND d.tenant_id = co.tenant_id
    JOIN customer_order_items coi
      ON coi.order_id = co.id
    JOIN members m
      ON m.id = co.member_id
   WHERE coi.sku_id IN (SELECT sku_id FROM skus)
     AND co.member_id IS NOT NULL
     -- 20260813：只通知**真的能來領**的單（與 /pickup 放行的集合一致）。
     -- 原本是 NOT IN (cancelled/expired/transferred_out/completed)，等於把
     -- confirmed / pending 也通知 —— 但那些單取貨閘門根本沒開：
     --   * 手動配單模式：收貨後 confirmed 單全數未配，通知了客人來就是撲空；
     --   * 自動配單模式：可配量裝不下被跳過的單一樣還不能領。
     -- （CLAUDE.md：拿閘門/收貨當「到貨通知」觸發條件要自己加數量守衛 ——
     --   這裡直接看單頭 status，配到才通知。）
     AND co.status IN ('ready', 'partially_completed', 'shipping')
     AND COALESCE(co.order_kind, 'normal') = 'normal'
     AND COALESCE(m.no_notify_pickup, FALSE) = FALSE  -- 黑名單跳過
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_members_to_notify_for_transfer(BIGINT) TO authenticated;

-- ----------------------------------------------------------------
-- 5. rpc_get_manual_allocation_candidates — 手動配單彈窗的候選清單
--    候選 = 本店 confirmed 一般單（排除內部容器單）、貨已到齊
--    （is_order_pickup_ready，前置篩同 _advance_arrived_confirmed_orders）。
--    budget = 各 SKU 可配量（on_hand − 已承諾未取），種子集合與算法
--    逐字對齊 _advance_arrived_confirmed_orders —— 前端據此即時算
--    「勾了這幾張還裝不裝得下」，兩邊必須同一套帳。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_manual_allocation_candidates(
  p_store_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_cand_ids BIGINT[];
  v_total    INT := 0;
  v_budget   JSONB;
  v_orders   JSONB;
BEGIN
  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;
  -- 跨租戶守衛。直接讀頂層 tenant_id claim（hook 有拉，見 CLAUDE.md）；
  -- 不用 _current_tenant_id() —— 它在沒有 claim 時會 RAISE，service_role 會炸。
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'store % not in current tenant', p_store_id;
  END IF;
  IF v_loc IS NULL THEN
    -- 沒設倉庫位置的店算不出可配量（同 helper 直接不動）
    RETURN jsonb_build_object(
      'store_id', p_store_id, 'budget', '[]'::jsonb,
      'orders', '[]'::jsonb, 'waiting_count', 0);
  END IF;

  -- 候選單：confirmed 一般單、非內部容器、貨已到齊。
  -- 前置篩（至少一項未取 SKU 店裡有帳上庫存）同
  -- _advance_arrived_confirmed_orders，先擋掉大多數才跑昂貴的閘門。
  SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[])
    INTO v_cand_ids
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status          = 'confirmed'
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal'
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
     )
     AND public.is_order_pickup_ready(co.id);

  -- 分母：本店全部 confirmed 一般單（排除內部容器）——
  -- 差額 = 貨還沒到齊 / 店裡沒庫存、目前配不了的張數，前端當註腳顯示。
  SELECT COUNT(*)
    INTO v_total
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status          = 'confirmed'
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal';

  -- 各 SKU 可配量（種子與算法逐字同 _advance_arrived_confirmed_orders；
  -- available 回原始值可能為負，前端顯示時自行夾 0、計算時用原始值）
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'sku_id',    b.sku_id,
           'sku_code',  s.sku_code,
           'name',      TRIM(COALESCE(s.product_name, '')
                          || CASE WHEN COALESCE(s.variant_name, '') <> ''
                                  THEN ' / ' || s.variant_name ELSE '' END),
           'available', b.avail
         ) ORDER BY b.sku_id), '[]'::jsonb)
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
    ) b
    JOIN skus s ON s.id = b.sku_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id',      co.id,
           'order_no',      co.order_no,
           'member_id',     co.member_id,
           'customer',      COALESCE(m.name, co.nickname_snapshot),
           'campaign_name', CASE WHEN LEFT(COALESCE(gbc.campaign_no, ''), 2) = '__'
                                 THEN NULL ELSE gbc.name END,
           'created_at',    co.created_at,
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

  RETURN jsonb_build_object(
    'store_id',      p_store_id,
    'budget',        v_budget,
    'orders',        v_orders,
    'waiting_count', GREATEST(v_total - COALESCE(cardinality(v_cand_ids), 0), 0)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_get_manual_allocation_candidates(BIGINT) IS
  '手動配單彈窗的候選清單：本店 confirmed 一般單（排除 store_internal 容器單）且'
  '貨已到齊（is_order_pickup_ready）者，附各 SKU 可配量（on_hand − 已承諾未取，'
  '算法逐字對齊 _advance_arrived_confirmed_orders）。waiting_count = 其餘配不了的'
  'confirmed 張數（貨未到齊 / 沒庫存）。';

GRANT EXECUTE ON FUNCTION public.rpc_get_manual_allocation_candidates(BIGINT)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 6. rpc_manual_allocate_confirmed_orders — 把店家勾的單推 ready
--    走同一支 _advance_arrived_confirmed_orders（p_order_ids = 勾選集合），
--    數量守衛 / 整單裝得下才推 / 現貨池收斂全部沿用 —— 店家勾了但
--    伺服端算下來裝不下的單會被跳過並回報原因，不會硬推。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_manual_allocate_confirmed_orders(
  p_store_id  BIGINT,
  p_order_ids BIGINT[],
  p_operator  UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  v_now      TIMESTAMPTZ := NOW();
  v_eligible BIGINT[] := '{}'::BIGINT[];
  v_advanced INT := 0;
  v_orders   JSONB;
  v_skipped  JSONB;
  v_notify   JSONB;
BEGIN
  IF p_order_ids IS NULL OR cardinality(p_order_ids) = 0 THEN
    RAISE EXCEPTION '未選擇任何訂單';
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc
    FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;
  -- 跨租戶守衛（同 rpc_get_manual_allocation_candidates，讀頂層 claim）
  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'store % not in current tenant', p_store_id;
  END IF;

  -- 兩個店員同時配單時序列化，避免同一批可配量被算兩次
  PERFORM pg_advisory_xact_lock(hashtext('manual_alloc:' || p_store_id::TEXT));

  -- 只吃本店的 confirmed 一般單（排除內部容器單）；其餘進 skipped
  SELECT COALESCE(ARRAY_AGG(co.id), '{}'::BIGINT[])
    INTO v_eligible
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.id = ANY (p_order_ids)
     AND co.tenant_id       = v_tenant
     AND co.pickup_store_id = p_store_id
     AND co.status          = 'confirmed'
     AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
     AND COALESCE(m.member_type, '') <> 'store_internal';

  IF cardinality(v_eligible) > 0 THEN
    v_advanced := public._advance_arrived_confirmed_orders(
      p_store_id, NULL, p_operator, v_now, v_eligible);
  END IF;

  -- 這一次真的被推 ready 的單（ready_at = v_now 是本次呼叫的印記）
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id', co.id,
           'order_no', co.order_no,
           'customer', COALESCE(m.name, co.nickname_snapshot)
         ) ORDER BY co.order_no), '[]'::jsonb)
    INTO v_orders
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.id = ANY (v_eligible)
     AND co.status = 'ready'
     AND co.ready_at = v_now;

  -- 沒推成的單附原因：not_eligible（不是本店可配的 confirmed 一般單）/
  -- not_arrived（貨未到齊，閘門沒過）/ insufficient_stock（可配量裝不下整單）
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id', u.oid,
           'order_no', co.order_no,
           'reason',   CASE
                         WHEN co.id IS NULL                       THEN 'not_found'
                         WHEN NOT (u.oid = ANY (v_eligible))      THEN 'not_eligible'
                         WHEN NOT public.is_order_pickup_ready(co.id)
                                                                  THEN 'not_arrived'
                         ELSE 'insufficient_stock'
                       END)), '[]'::jsonb)
    INTO v_skipped
    FROM (SELECT DISTINCT UNNEST(p_order_ids) AS oid) u
    LEFT JOIN customer_orders co ON co.id = u.oid
   WHERE co.id IS NULL
      OR NOT (co.status = 'ready' AND co.ready_at = v_now AND u.oid = ANY (v_eligible));

  -- 到貨推播名單（同 rpc_get_members_to_notify_for_transfer 的黑名單規則；
  -- 推不推由前端依「收貨後通知會員」開關決定）
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'member_id',             co.member_id,
           'order_id',              co.id,
           'order_no',              co.order_no,
           'last_notify_pickup_at', co.last_notify_pickup_at
         )), '[]'::jsonb)
    INTO v_notify
    FROM customer_orders co
    JOIN members m ON m.id = co.member_id
   WHERE co.id = ANY (v_eligible)
     AND co.status = 'ready'
     AND co.ready_at = v_now
     AND COALESCE(m.no_notify_pickup, FALSE) = FALSE;

  RETURN jsonb_build_object(
    'advanced', v_advanced,
    'orders',   v_orders,
    'skipped',  v_skipped,
    'notify',   v_notify
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_manual_allocate_confirmed_orders(BIGINT, BIGINT[], UUID) IS
  '手動配單：把店家勾選的 confirmed 一般單推 ready（走 _advance_arrived_confirmed_orders，'
  '可配量守衛 / 整單裝得下才推 / _trim_internal_pool 現貨池收斂全部沿用）。'
  '裝不下或閘門沒過的單跳過並回報原因，不硬推。回傳 notify = 已過黑名單的到貨推播名單。';

GRANT EXECUTE ON FUNCTION public.rpc_manual_allocate_confirmed_orders(BIGINT, BIGINT[], UUID)
  TO authenticated, service_role;

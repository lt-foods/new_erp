-- ============================================================
-- 2026-08-11 (6)：補的那批貨到店時，自動解除「待補貨」
--
-- 災情（松山店，GRP-20260730-016-0008 阿猴鮮奶）：
--   撿貨單 WV260805001104 派 10 給松山，但松山當時的訂單需求是 11
--   （總倉少撿 1，不是短收 —— WAVE-959-S2 出 10 收 10 全收）。店家在收貨頁
--   跑「⚖️ 配貨」把 10 件配掉，一位客人原本 qty 2 的那列被拆成
--   1（可取）+ 1（backorder_at）。那第二列從 08-05 卡到現在：
--     * 取貨頁只顯示「⏳ 待補貨」，店員發不出去 → 單頭永遠停 partially_completed
--     * 總倉端沒有任何東西告訴他們「有客人在等這 1 件」
--
-- 根因：backorder_at **沒有任何自動解除的路徑**。全 DB 只有
--   rpc_allocate_shortage / rpc_create_inventory_deduction /
--   rpc_create_offset_sale / rpc_cancel_backorder_items 會清掉它，全部要人手動點。
--   rpc_receive_transfer 完全不碰這一欄，_advance_arrived_confirmed_orders
--   甚至因為 is_order_pickup_ready() 內含 backorder_at IS NULL 而**主動跳過**
--   這種單。所以總倉就算補派第二批、店家也收了貨，品項還是掛待補貨 ——
--   要有人記得回收貨頁再點一次「⚖️ 配貨」才解得開，沒人記得就永遠卡著。
--
-- 修法：收貨時（rpc_receive_transfer 新增邏輯 A0）對「本次實收 > 0 的 SKU」
--   逐個 (團, 店, SKU) 重算可交付量，把裝得下的待補貨列解除。
--
--   可交付量的算法**逐字比照 rpc_get_allocation_candidates**（配貨彈窗）：
--     ledger = 該組全部已收實收(supplied) + 店內現貨吸收(covered) − 已領走(picked)
--   —— 兩邊同一套算法，自動解除的結果才會跟店員手動點「⚖️ 配貨」一致。
--
--   但**只信這本帳會誤放行**。店裡的貨會跨團／跨批流用（轉單、POS、減抵…），
--   線上實測有 5 列的組合是「supplied 4、picked 0、on_hand 0」—— 貨早就從別的
--   路徑出去了，照帳放行等於通知客人來撲空（同 20260811000020 的教訓：
--   閘門是 qty-blind 的，拿它當到貨通知一定要自己加數量守衛）。所以再夾一層
--   實體可配量，算法與 _advance_arrived_confirmed_orders 同一套：
--     headroom = stock_balances.on_hand − 已承諾未取量
--   「已承諾」排除 store_internal 容器單與 offset，**另外排除掛著 backorder_at
--   的列** —— 那些正是「還沒配到貨」的，算進去等於自己擋自己，整支會永遠
--   解不開任何一列。headroom 跨團共用且逐列遞減，同一批實體貨不會被兩個團
--   各認領一次。最終 available = LEAST(ledger, headroom)。
--
--   配法兩段，**只清旗標、永不新標**（新標是少發配貨的職責，這支不越權）：
--     Pass 1：已配到（沒掛 backorder_at）的未取品項先把額度扣掉 ——
--             那些貨已經是他們的了，不能被待補貨的列搶走。
--     Pass 2：剩下的額度依 created_at, order_no 由早到晚配給待補貨的列，
--             **整列裝得下才解除**（不拆行），裝不下跳過繼續試後面的小列。
--   排序與「裝得下才配」的規則跟 20260805000070 回頭配貨、
--   ShortageAllocateModal 的「依訂單時間自動配」、_advance_arrived_confirmed_orders
--   同一套，三邊結果才會一致。
--
--   刻意不動單頭 status：解除後 partially_completed 的單就能在取貨頁勾選了
--   （/pickup 放行 ready / partially_completed / shipping）；confirmed / shipping
--   的單交給後面的邏輯 C / E 推 —— 所以 A0 一定要排在它們前面。
--
-- 影響範圍（線上實測）：目前 backorder_at 未解、單子還活著的品項 94 筆／150 件，
--   其中 88 筆來自 20260805000070 那支一次性回頭配貨的 backfill（歷史死帳，
--   總倉多半 on_hand = 0），真正由線上少發配貨產生的只有 6 筆。這支只在
--   「補的貨真的到店」時才動手，額度不足一律不碰，所以死帳不會被誤放行。
--
-- 基底版本：rpc_receive_transfer = 20260811000040_pool_trim_ordering_and_legacy_cleanup
--   （線上 pg_get_functiondef 逐字取出，只新增 v_backorders_freed 宣告、
--     邏輯 A0 區塊、回傳多一個 backorders_freed 欄位；其餘一字未動）
-- rollback:
--   DROP FUNCTION IF EXISTS public._settle_arrived_backorders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ);
--   並重跑 20260811000040 的 rpc_receive_transfer。
--   （本檔不做回填 —— 解除待補貨等於對客人承諾交貨，要有實體到貨事件當依據，
--     不能靠 migration 憑空放行。既有的 6 筆等下一批貨收進來時自然會被重算。）
-- ============================================================

-- ----------------------------------------------------------------
-- 1. _settle_arrived_backorders — 到貨後解除裝得下的待補貨列
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._settle_arrived_backorders(
  p_store_id BIGINT,
  p_sku_ids  BIGINT[],
  p_operator UUID,
  p_at       TIMESTAMPTZ DEFAULT NOW()
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_tenant   UUID;
  v_loc      BIGINT;
  c          RECORD;
  r          RECORD;
  v_avail    NUMERIC;
  v_budget   JSONB := '{}'::JSONB;   -- sku_id(text) → 該店該 SKU 實體可配量（跨團共用）
  v_head     NUMERIC;
  v_freed    INT := 0;
BEGIN
  IF p_sku_ids IS NULL OR array_length(p_sku_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  SELECT tenant_id, location_id INTO v_tenant, v_loc FROM stores WHERE id = p_store_id;
  IF v_tenant IS NULL OR v_loc IS NULL THEN
    RETURN 0;   -- 沒設倉庫位置的店算不出實體可配量，一律不動
  END IF;

  -- 只看「這次到貨的 SKU、且該店真的有待補貨掛著」的 (團, SKU)
  FOR c IN
    SELECT DISTINCT co.campaign_id, coi.sku_id
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.tenant_id       = v_tenant
       AND co.pickup_store_id = p_store_id
       AND co.campaign_id IS NOT NULL
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND (co.transferred_from_order_id IS NULL OR EXISTS (
             SELECT 1 FROM customer_orders src
              WHERE src.id = co.transferred_from_order_id
                AND src.pickup_store_id = co.pickup_store_id))
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND coi.sku_id = ANY (p_sku_ids)
       AND coi.status IN ('pending', 'reserved', 'ready')
       AND coi.backorder_at IS NOT NULL
  LOOP
    -- available = supplied + covered − picked（與 rpc_get_allocation_candidates 同算法）
    SELECT
        COALESCE((
          -- supplied：同一組可能分好幾批到，全部已收的實收量都算
          SELECT SUM(ti.qty_received)
            FROM picking_wave_items pwi
            JOIN transfers t       ON t.id = pwi.generated_transfer_id
                                  AND t.status IN ('received', 'closed')
            JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = c.sku_id
           WHERE pwi.tenant_id   = v_tenant
             AND pwi.campaign_id = c.campaign_id
             AND pwi.store_id    = p_store_id
             AND pwi.sku_id      = c.sku_id
        ), 0)
      + COALESCE((
          -- covered：庫存減抵單（店內現貨先交）
          SELECT SUM(n.qty)
            FROM inventory_deduction_notes n
           WHERE n.tenant_id   = v_tenant
             AND n.campaign_id = c.campaign_id
             AND n.store_id    = p_store_id
             AND n.sku_id      = c.sku_id
             AND n.cancelled_at IS NULL
        ), 0)
      + COALESCE((
          -- covered：抵減單（order_kind='offset' 負數訂單）
          SELECT SUM(-oi.qty)
            FROM customer_orders oo
            JOIN customer_order_items oi
              ON oi.order_id = oo.id
             AND oi.sku_id   = c.sku_id
             AND oi.qty < 0
             AND oi.status NOT IN ('cancelled', 'expired')
           WHERE oo.tenant_id       = v_tenant
             AND oo.campaign_id     = c.campaign_id
             AND oo.pickup_store_id = p_store_id
             AND oo.order_kind      = 'offset'
             AND oo.status NOT IN ('cancelled', 'expired', 'transferred_out')
        ), 0)
      - COALESCE((
          -- picked：已經領走的量
          SELECT SUM(coi.qty)
            FROM customer_orders co
            JOIN customer_order_items coi
              ON coi.order_id = co.id
             AND coi.sku_id   = c.sku_id
             AND coi.status IN ('picked_up', 'partially_picked_up')
           WHERE co.tenant_id       = v_tenant
             AND co.campaign_id     = c.campaign_id
             AND co.pickup_store_id = p_store_id
             AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
             AND (co.transferred_from_order_id IS NULL OR EXISTS (
                   SELECT 1 FROM customer_orders src
                    WHERE src.id = co.transferred_from_order_id
                      AND src.pickup_store_id = co.pickup_store_id))
             AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
        ), 0)
      INTO v_avail;

    -- Pass 1：已配到（沒掛待補貨）的未取品項先扣掉 —— 那批貨已經是他們的了
    v_avail := v_avail - COALESCE((
      SELECT SUM(coi.qty)
        FROM customer_orders co
        JOIN customer_order_items coi
          ON coi.order_id = co.id
         AND coi.sku_id   = c.sku_id
         AND coi.status IN ('pending', 'reserved', 'ready')
         AND coi.backorder_at IS NULL
       WHERE co.tenant_id       = v_tenant
         AND co.campaign_id     = c.campaign_id
         AND co.pickup_store_id = p_store_id
         AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
         AND (co.transferred_from_order_id IS NULL OR EXISTS (
               SELECT 1 FROM customer_orders src
                WHERE src.id = co.transferred_from_order_id
                  AND src.pickup_store_id = co.pickup_store_id))
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
    ), 0);

    IF v_avail <= 0 THEN
      CONTINUE;   -- 這一組沒有多的貨，待補貨維持原狀
    END IF;

    -- 實體庫存守衛：帳上算得出來 ≠ 貨真的在架上。
    -- 上面那套是「該團該店該 SKU」的帳（supplied/covered/picked），但店裡的貨會
    -- 跨團／跨批流用（轉單、POS、減抵…），只信帳會出現「supplied 4、picked 0、
    -- on_hand 0」這種組合 —— 線上實測有 5 列會被這樣誤放行，等於通知客人來撲空。
    -- 所以再夾一層實體可配量，算法與 _advance_arrived_confirmed_orders 同一套：
    --   可配量 = stock_balances.on_hand − 已承諾未取量
    -- 「已承諾」排除 members.member_type='store_internal'（RR- /【內部】xx 店是
    -- 現貨池容器，不是對客人的承諾）與 order_kind='offset'，另外**排除掛著
    -- backorder_at 的列** —— 那些正是「還沒配到貨」的，把它們算進已承諾等於
    -- 自己擋自己，整支會永遠解不開任何一列。
    -- budget 跨團共用且逐列遞減：同一批實體貨不會被兩個團各認領一次。
    IF NOT (v_budget ? c.sku_id::TEXT) THEN
      SELECT COALESCE(sb.on_hand, 0) - COALESCE(pr.promised, 0)
        INTO v_head
        FROM (SELECT 1) _
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = v_tenant
              AND sb.location_id = v_loc
              AND sb.sku_id      = c.sku_id
        LEFT JOIN LATERAL (
          SELECT SUM(coi2.qty) AS promised
            FROM customer_orders co2
            JOIN customer_order_items coi2 ON coi2.order_id = co2.id
            LEFT JOIN members m2 ON m2.id = co2.member_id
           WHERE co2.tenant_id       = v_tenant
             AND co2.pickup_store_id = p_store_id
             AND co2.status IN ('ready', 'partially_completed', 'shipping')
             AND COALESCE(co2.order_kind, 'normal') <> 'offset'
             AND COALESCE(m2.member_type, '') <> 'store_internal'
             AND coi2.sku_id = c.sku_id
             AND coi2.status IN ('pending', 'reserved', 'ready')
             AND coi2.backorder_at IS NULL
        ) pr ON TRUE;
      v_budget := jsonb_set(v_budget, ARRAY[c.sku_id::TEXT], to_jsonb(COALESCE(v_head, 0)));
    END IF;

    v_avail := LEAST(v_avail, COALESCE((v_budget ->> c.sku_id::TEXT)::NUMERIC, 0));
    IF v_avail <= 0 THEN
      CONTINUE;   -- 帳上有、架上沒有 → 不放行，等貨真的到再說
    END IF;

    -- Pass 2：依訂單時間解除，整列裝得下才放（不拆行）
    FOR r IN
      SELECT coi.id, coi.qty
        FROM customer_orders co
        JOIN customer_order_items coi
          ON coi.order_id = co.id
         AND coi.sku_id   = c.sku_id
         AND coi.status IN ('pending', 'reserved', 'ready')
         AND coi.backorder_at IS NOT NULL
       WHERE co.tenant_id       = v_tenant
         AND co.campaign_id     = c.campaign_id
         AND co.pickup_store_id = p_store_id
         AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
         AND (co.transferred_from_order_id IS NULL OR EXISTS (
               SELECT 1 FROM customer_orders src
                WHERE src.id = co.transferred_from_order_id
                  AND src.pickup_store_id = co.pickup_store_id))
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       ORDER BY co.created_at, co.order_no, coi.id
       FOR UPDATE OF coi
    LOOP
      IF r.qty <= v_avail THEN
        UPDATE customer_order_items
           SET backorder_at = NULL,
               backorder_by = NULL,
               updated_by   = p_operator,
               updated_at   = p_at
         WHERE id = r.id;
        v_avail := v_avail - r.qty;
        v_budget := jsonb_set(
          v_budget, ARRAY[c.sku_id::TEXT],
          to_jsonb(COALESCE((v_budget ->> c.sku_id::TEXT)::NUMERIC, 0) - r.qty));
        v_freed := v_freed + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN v_freed;
END;
$$;

COMMENT ON FUNCTION public._settle_arrived_backorders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ) IS
  '到貨後解除「少發配貨沒配到」的待補貨列（backorder_at）。'
  '可交付量 = LEAST(supplied + covered − picked − 已配到未取, on_hand − 已承諾未取)：'
  '前者與 rpc_get_allocation_candidates 同算法，後者與 _advance_arrived_confirmed_orders 同算法，'
  '帳上有、架上沒有的一律不放行。剩下的依 created_at, order_no 整列裝得下才解除（不拆行）。'
  '只清旗標、永不新標 —— 新標是 rpc_allocate_shortage 的職責。';

GRANT EXECUTE ON FUNCTION public._settle_arrived_backorders(BIGINT, BIGINT[], UUID, TIMESTAMPTZ)
  TO authenticated, service_role;

-- ----------------------------------------------------------------
-- 2. rpc_receive_transfer — 新增邏輯 A0（排在 A/B/C/E 之前）
--    基底 20260811000040，逐字保留；只加 v_backorders_freed 宣告、
--    邏輯 A0 區塊、回傳多一個 backorders_freed 欄位。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_transfer(p_transfer_id bigint, p_lines jsonb, p_operator uuid, p_notes text DEFAULT NULL::text)
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
    'restock_received',       v_restock_received,
    'backorders_freed',       v_backorders_freed
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer(BIGINT, JSONB, UUID, TEXT)
  TO authenticated, service_role;

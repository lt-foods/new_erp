-- ============================================================
-- 補貨重複派貨守衛：三個出貨入口都改成「只派剩餘量、派完就擋」
--
-- 背景：20260715000010 修了派貨工作台「需求派完仍一直顯示」後，
--   工作台不再邀請使用者重複派貨；但 RPC 層仍有三個入口對同一筆補貨
--   放行重複出貨（實際案例：RR-51/53 每 SKU 申請 1 件，龍潭店被派了
--   7 張 wave ＋ 1 張直派，共出貨 8–9 次）：
--
--   1) rpc_ship_restock_pr_received（收件匣「派貨」→ 直派 transfer）：
--      照 restock lines 全量出貨，不知道已透過工作台 wave 派出的量。
--   2) rpc_create_wave_from_po（工作台矩陣建單）：
--      補貨來源的分配只驗「有沒有需求」（EXISTS），不驗「剩多少沒派」，
--      同一筆 1 件補貨可以無限次各派 1 件。
--   3) rpc_create_wave_from_restock（工作台補貨 amber 區塊建單）：
--      守衛只驗「單次分配 ≤ 申請量」，跨多次呼叫不累計 — 連按兩次
--      各派全量也放行。
--
-- 修法（歸屬原則）：
--   「已派給此補貨」= 撿貨單裡 campaign_id IS NULL 的 wave items
--   （rpc_create_wave_from_po 只在該 (store,sku) 無開團需求、僅補貨
--   justification 時才掛 NULL）＋ 補貨直派 transfer（linked_transfer_id）。
--   campaign_id 非 NULL 的 wave 屬客戶訂單需求，不能拿來抵補貨 —
--   寧可保守多派、不可誤扣訂單的貨。
--
--   1) rpc_ship_restock_pr_received：逐 line 只出「申請量 − 已派量」，
--      全部為 0 時 RAISE（已全數透過撿貨單派出）。
--   2) rpc_create_wave_from_po：補貨 justification 的分配（campaign NULL）
--      加上限 = 該 (store,sku) 剩餘補貨需求（申請 − wave(campaign NULL) − 直派）。
--      刻意要多推庫存給分店 → 引導走內部調撥（wms/transfers）。
--   3) rpc_create_wave_from_restock：守衛改「累計」— 單次分配 ≤
--      申請量 − 該申請已 wave 量。
--
-- 基於（各函式最新版本）：
--   rpc_ship_restock_pr_received — 20260705000000_dispatch_price_guard.sql Part 3
--   rpc_create_wave_from_po      — 20260715000010（守衛含直派版）
--   rpc_create_wave_from_restock — 20260612000040_approve_restock_via_picking_workstation.sql
-- Rollback：CREATE OR REPLACE 各函式回上列基底版本
-- TEST: docs/TEST-picking-dispatched-demand-left.md（追加 §D）
-- ============================================================

-- ----------------------------------------------------------------------------
-- Part 1: rpc_ship_restock_pr_received — 只直派「申請量 − 已 wave 量」
-- 基底：20260705000000 逐字保留（role/狀態機/價格守衛/outbound + shipped）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_ship_restock_pr_received(
  p_request_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_user        UUID := auth.uid();
  v_role        TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req         RECORD;
  v_hq_loc      BIGINT;
  v_dest_loc    BIGINT;
  v_transfer_id BIGINT;
  v_no          TEXT;
  v_line        RECORD;
  v_out_mov_id  BIGINT;
  v_missing     TEXT;
  v_fallback    NUMERIC;
  v_waved       NUMERIC;
  v_ship_qty    NUMERIC;
  v_shipped_any BOOLEAN := FALSE;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot ship restock', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;
  IF v_req.status <> 'approved_pr' THEN
    RAISE EXCEPTION 'request % must be in approved_pr (current: %)', p_request_id, v_req.status;
  END IF;
  IF v_req.linked_pr_id IS NULL THEN
    RAISE EXCEPTION 'request % missing linked_pr_id', p_request_id;
  END IF;
  IF v_req.linked_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'request % already shipped (transfer #%)', p_request_id, v_req.linked_transfer_id;
  END IF;

  SELECT id INTO v_hq_loc FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN RAISE EXCEPTION 'no active central_warehouse'; END IF;

  SELECT location_id INTO v_dest_loc FROM stores
   WHERE id = v_req.requesting_store_id AND tenant_id = v_tenant;
  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'requesting store % has no location_id', v_req.requesting_store_id;
  END IF;

  -- 出貨價格防呆（同 generate_transfer_from_wave）
  SELECT public._missing_dispatch_prices(
           v_tenant,
           (SELECT array_agg(DISTINCT sku_id)
              FROM restock_request_lines
             WHERE request_id = p_request_id AND tenant_id = v_tenant))
    INTO v_missing;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '無法派貨：以下品項尚未設定成本價／分店價，請先補價再出貨（商品頁 SKU 區塊或派貨工作台可直接補）→ %', v_missing;
  END IF;

  v_no := public._next_transfer_no();

  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type,
    requested_by, shipped_by, shipped_at,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_no, v_hq_loc, v_dest_loc,
    'shipped', 'hq_to_store',
    v_user, v_user, NOW(),
    'restock #' || p_request_id::TEXT || ' / PR #' || v_req.linked_pr_id::TEXT,
    v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  FOR v_line IN
    SELECT sku_id, qty, notes FROM restock_request_lines
     WHERE request_id = p_request_id AND tenant_id = v_tenant
  LOOP
    -- 已透過撿貨單派給此補貨的量：
    --   a) amber 區塊建的 wave（source_restock_request_id = 本申請）
    --   b) 工作台矩陣建的 wave（source_po_id ∈ 本申請 PR 拆出的 PO、
    --      派給申請分店、campaign_id IS NULL = 補貨 justification）
    -- campaign_id 非 NULL 的 wave 屬客戶訂單需求，不抵補貨。
    SELECT COALESCE(SUM(pwi.qty), 0) INTO v_waved
      FROM picking_wave_items pwi
      JOIN picking_waves pw ON pw.id = pwi.wave_id
     WHERE pw.status <> 'cancelled'
       AND pwi.sku_id = v_line.sku_id
       AND pwi.store_id = v_req.requesting_store_id
       AND (
         pw.source_restock_request_id = p_request_id
         OR (
           pwi.campaign_id IS NULL
           AND pw.source_po_id IN (
             SELECT DISTINCT poi.po_id
               FROM purchase_request_items pri
               JOIN purchase_order_items poi ON poi.id = pri.po_item_id
              WHERE pri.pr_id = v_req.linked_pr_id
           )
         )
       );

    v_ship_qty := GREATEST(0, v_line.qty - v_waved);
    IF v_ship_qty = 0 THEN
      CONTINUE;  -- 這條 line 已透過撿貨單派完，跳過
    END IF;
    v_shipped_any := TRUE;

    v_fallback := public._current_cost_price(v_tenant, v_line.sku_id);

    v_out_mov_id := public.rpc_outbound(
      p_tenant_id          => v_tenant,
      p_location_id        => v_hq_loc,
      p_sku_id             => v_line.sku_id,
      p_quantity           => v_ship_qty,
      p_movement_type      => 'transfer_out',
      p_source_doc_type    => 'transfer',
      p_source_doc_id      => v_transfer_id,
      p_operator           => v_user,
      p_allow_negative     => FALSE,
      p_fallback_unit_cost => v_fallback
    );

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped,
      out_movement_id, notes, created_by, updated_by
    ) VALUES (
      v_transfer_id, v_line.sku_id, v_ship_qty, v_ship_qty,
      v_out_mov_id, v_line.notes, v_user, v_user
    );
  END LOOP;

  IF NOT v_shipped_any THEN
    -- 整張申請都已透過撿貨單派完 → 不留空 transfer、直接擋下
    RAISE EXCEPTION '補貨申請 #% 的品項已全數透過撿貨單派出，無需再直派（若要補送額外庫存請走內部調撥）',
      p_request_id;
  END IF;

  UPDATE restock_requests
     SET status = 'shipped',
         linked_transfer_id = v_transfer_id,
         updated_by = v_user
   WHERE id = p_request_id;

  RETURN v_transfer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_ship_restock_pr_received(BIGINT) TO authenticated;
COMMENT ON FUNCTION public.rpc_ship_restock_pr_received(BIGINT) IS
  'restock approved_pr → 收貨後派貨：建 shipped transfer + outbound HQ 庫存；'
  '20260705 起：出貨前守衛缺成本價/分店價，avg_cost=0 時出庫以現行成本價計價；'
  '20260715 起：只直派「申請量 − 已 wave 量」，全數已派時 RAISE（防重複派貨）。';

-- ----------------------------------------------------------------------------
-- Part 2: rpc_create_wave_from_po — 補貨 justification 的分配加「剩餘補貨需求」上限
-- 基底：20260715000010 逐字保留，只在 campaign NULL 分支追加數量上限守衛。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_wave_from_po(
  p_po_id        BIGINT,
  p_wave_date    DATE,
  p_allocations  JSONB,
  p_operator     UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_po                purchase_orders%ROWTYPE;
  v_tenant            UUID;
  v_wave_id           BIGINT;
  v_wave_code         TEXT;
  v_alloc             JSONB;
  v_sku_id            BIGINT;
  v_store_id          BIGINT;
  v_qty               NUMERIC(18,3);
  v_line_campaign_id  BIGINT;
  v_total_qty         NUMERIC(18,3) := 0;
  v_item_count        INTEGER := 0;
  v_store_count       INTEGER := 0;
  v_over              RECORD;
  v_restock_demand    NUMERIC;
  v_restock_dispatched NUMERIC;
  v_restock_left      NUMERIC;
BEGIN
  -- 1. PO 守衛
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;
  IF v_po.status NOT IN ('sent','partially_received','fully_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可建撿貨單（需為「已發送」/「部分進貨」/「全部進貨」）', v_po.po_no, v_po.status;
  END IF;
  v_tenant := v_po.tenant_id;

  -- 2. allocations 守衛
  IF p_allocations IS NULL OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION '請先填寫各分店分配量、不可全為空';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('wave:po:' || p_po_id::text));

  -- 3. 守衛：每個分配 qty > 0
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_qty := (v_alloc->>'qty')::NUMERIC;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '分配數量必須 > 0';
    END IF;
  END LOOP;

  -- 4. 守衛：每 sku 的總分配量 ≤ (GR 量 − 已派量)
  --    已派量 = picking_wave_items ＋ 補貨直派 transfer（linked_transfer_id 路徑），
  --    與 v_picking_demand_by_po.po_sku_already_wave 對齊。
  WITH alloc_agg AS (
    SELECT
      (a->>'sku_id')::BIGINT  AS sku_id,
      SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  po_sku_state AS (
    SELECT
      poi.sku_id,
      COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status = 'confirmed'), 0) AS gr_qty,
      COALESCE((
        SELECT SUM(pwi.qty)
          FROM picking_wave_items pwi
          JOIN picking_waves pw ON pw.id = pwi.wave_id
         WHERE pw.source_po_id = p_po_id
           AND pwi.sku_id = poi.sku_id
           AND pw.status <> 'cancelled'
      ), 0)
      + COALESCE((
        SELECT SUM(ti.qty_requested)
          FROM restock_requests rr
          JOIN transfers t ON t.id = rr.linked_transfer_id
          JOIN transfer_items ti ON ti.transfer_id = t.id
          JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
          JOIN purchase_order_items poi2 ON poi2.id = pri.po_item_id AND poi2.sku_id = ti.sku_id
         WHERE poi2.po_id = p_po_id
           AND poi2.sku_id = poi.sku_id
           AND t.transfer_type = 'hq_to_store'
           AND t.status <> 'cancelled'
      ), 0) AS already_wave
    FROM purchase_order_items poi
    LEFT JOIN goods_receipt_items gri ON gri.po_item_id = poi.id
    LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id
    WHERE poi.po_id = p_po_id
    GROUP BY poi.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
    aa.total_alloc, ps.gr_qty, ps.already_wave,
    (ps.gr_qty - ps.already_wave) AS available
  INTO v_over
  FROM alloc_agg aa
  JOIN po_sku_state ps ON ps.sku_id = aa.sku_id
  JOIN skus s ON s.id = aa.sku_id
  WHERE aa.total_alloc > (ps.gr_qty - ps.already_wave)
  LIMIT 1;

  IF v_over.sku_code IS NOT NULL THEN
    RAISE EXCEPTION 'SKU「% %」分配 % 超過可分配量 %（進貨 %、已派 %，含撿貨單與補貨直派）',
      v_over.sku_code, v_over.sku_label,
      v_over.total_alloc, v_over.available, v_over.gr_qty, v_over.already_wave;
  END IF;

  -- 5. wave header — 用 sequence 產 code,避免同秒撞單
  v_wave_code := 'WV'
              || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYMMDD')
              || LPAD(nextval('public.picking_wave_code_seq')::TEXT, 6, '0');

  INSERT INTO picking_waves (
    tenant_id, wave_code, wave_date, status, source_po_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_wave_code, p_wave_date, 'draft', p_po_id,
    p_operator, p_operator
  ) RETURNING id INTO v_wave_id;

  -- 6 + 7. 逐 (sku, store) 解析「實際有需求的那一團」當 campaign_id，並擋跨團誤撿
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_sku_id   := (v_alloc->>'sku_id')::BIGINT;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    v_qty      := (v_alloc->>'qty')::NUMERIC;

    -- 在「此 PO 對應的開團」裡，挑對該 (store, sku) 確實有訂單需求的一團。
    -- 涵蓋兩條 PO→campaign 路徑（purchase_request_campaigns 與 source_campaign_id），
    -- 與 v_picking_demand_by_po 的 po_campaigns 對齊。
    SELECT cand.campaign_id
      INTO v_line_campaign_id
      FROM (
        SELECT prc.campaign_id
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
         WHERE poi.po_id = p_po_id
        UNION
        SELECT pri.source_campaign_id AS campaign_id
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
         WHERE poi.po_id = p_po_id
           AND pri.source_campaign_id IS NOT NULL
      ) cand
     WHERE EXISTS (
       SELECT 1
         FROM customer_orders co
         JOIN customer_order_items coi ON coi.order_id = co.id
        WHERE co.campaign_id = cand.campaign_id
          AND co.pickup_store_id = v_store_id
          AND co.status NOT IN ('cancelled','expired','transferred_out')
          AND co.transferred_from_order_id IS NULL
          AND coi.sku_id = v_sku_id
          AND coi.status NOT IN ('cancelled','expired')
     )
     ORDER BY cand.campaign_id
     LIMIT 1;

    IF v_line_campaign_id IS NULL THEN
      -- 此 (store, sku) 在這張 PO 的開團都沒有需求。
      -- 只有「補貨 (restock) 來源」才允許（campaign_id 掛 NULL，沿用既有行為）。
      IF NOT EXISTS (
        SELECT 1
          FROM purchase_order_items poi
          JOIN purchase_request_items pri ON pri.po_item_id = poi.id
          JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                  AND rr.requesting_store_id = v_store_id
                                  AND rr.status NOT IN ('cancelled','rejected')
          JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                        AND rrl.sku_id = v_sku_id
         WHERE poi.po_id = p_po_id
           AND poi.sku_id = v_sku_id
      ) THEN
        RAISE EXCEPTION
          '分店「%」在採購單「%」對應的開團沒有 SKU「%」的訂單需求，不能撿到這批貨（這批屬於別團，請改用該店所屬開團的採購單撿貨）',
          COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
          v_po.po_no,
          COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id);
      END IF;

      -- 20260715 新增：補貨分配不可超過「剩餘補貨需求」= 申請量 − 已派量。
      -- 申請量：此 PO 對應補貨申請對該 (store, sku) 的 lines 加總。
      SELECT COALESCE(SUM(rrl.qty), 0) INTO v_restock_demand
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                                AND rr.requesting_store_id = v_store_id
                                AND rr.status NOT IN ('cancelled','rejected')
        JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                      AND rrl.sku_id = v_sku_id
       WHERE poi.po_id = p_po_id
         AND poi.sku_id = v_sku_id;

      -- 已派量：此 PO 的 campaign NULL wave items（含本 wave 前面 loop 已插入的列，
      -- 同批重複 (sku,store) 會累計）＋ 補貨直派 transfer。
      SELECT
        COALESCE((
          SELECT SUM(pwi.qty)
            FROM picking_wave_items pwi
            JOIN picking_waves pw ON pw.id = pwi.wave_id
           WHERE pw.source_po_id = p_po_id
             AND pw.status <> 'cancelled'
             AND pwi.sku_id = v_sku_id
             AND pwi.store_id = v_store_id
             AND pwi.campaign_id IS NULL
        ), 0)
        + COALESCE((
          SELECT SUM(ti.qty_requested)
            FROM restock_requests rr
            JOIN transfers t ON t.id = rr.linked_transfer_id
            JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = v_sku_id
            JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
            JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = v_sku_id
           WHERE poi.po_id = p_po_id
             AND rr.requesting_store_id = v_store_id
             AND t.transfer_type = 'hq_to_store'
             AND t.status <> 'cancelled'
        ), 0)
      INTO v_restock_dispatched;

      v_restock_left := GREATEST(0, v_restock_demand - v_restock_dispatched);
      IF v_qty > v_restock_left THEN
        RAISE EXCEPTION
          '分店「%」SKU「%」的補貨需求只剩 % 件未派（申請 %、已派 %，含撿貨單與直派），本次分配 % 超過。若要額外補庫存給分店，請走內部調撥。',
          COALESCE((SELECT name FROM stores WHERE id = v_store_id), '#' || v_store_id),
          COALESCE((SELECT sku_code FROM skus WHERE id = v_sku_id), '#' || v_sku_id),
          v_restock_left, v_restock_demand, v_restock_dispatched, v_qty;
      END IF;
    END IF;

    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, campaign_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_wave_id, v_sku_id, v_store_id, v_qty, v_line_campaign_id,
      p_operator, p_operator
    )
    ON CONFLICT (wave_id, sku_id, store_id) DO UPDATE
      SET qty = picking_wave_items.qty + EXCLUDED.qty,
          updated_by = p_operator,
          updated_at = NOW();
  END LOOP;

  -- 8. 統計 wave header
  SELECT COUNT(*), COUNT(DISTINCT store_id), COALESCE(SUM(qty), 0)
    INTO v_item_count, v_store_count, v_total_qty
    FROM picking_wave_items WHERE wave_id = v_wave_id;

  UPDATE picking_waves
     SET item_count = v_item_count,
         store_count = v_store_count,
         total_qty = v_total_qty,
         updated_at = NOW()
   WHERE id = v_wave_id;

  RETURN jsonb_build_object(
    'wave_id', v_wave_id,
    'wave_code', v_wave_code,
    'item_count', v_item_count,
    'store_count', v_store_count,
    'total_qty', v_total_qty
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_create_wave_from_po IS
  '按 PO 建撿貨單；wave item 的 campaign_id 逐 (sku,store) 取「此 PO 對應開團裡確實有該店該 SKU 需求」的那一團；'
  '若無開團需求且非補貨來源則 RAISE（擋跨團誤撿）。可分配守衛 = GR − (wave ＋ 補貨直派 transfer)，'
  '與 v_picking_demand_by_po.po_sku_already_wave 對齊。'
  '補貨 justification 的分配另有上限 = 剩餘補貨需求（申請 − 已派），防重複派貨。'
  'wave_code 用 sequence 避免同秒撞單。';

-- ----------------------------------------------------------------------------
-- Part 3: rpc_create_wave_from_restock — 守衛改累計（申請量 − 已 wave 量）
-- 基底：20260612000040 逐字保留，只把 line_agg 上限改成扣掉既有 wave。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_wave_from_restock(
  p_restock_request_id BIGINT,
  p_wave_date          DATE,
  p_allocations        JSONB,
  p_operator           UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request      restock_requests%ROWTYPE;
  v_tenant       UUID;
  v_wave_id      BIGINT;
  v_wave_code    TEXT;
  v_alloc        JSONB;
  v_sku_id       BIGINT;
  v_store_id     BIGINT;
  v_qty          NUMERIC(18,3);
  v_total_qty    NUMERIC(18,3) := 0;
  v_item_count   INTEGER := 0;
  v_store_count  INTEGER := 0;
  v_hq_location  BIGINT;
  v_short        RECORD;
BEGIN
  SELECT * INTO v_request FROM restock_requests
    WHERE id = p_restock_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到補貨申請 #%', p_restock_request_id;
  END IF;
  -- 收緊:只接受 approved_transfer(必經 inbox 審核)
  IF v_request.status <> 'approved_transfer' THEN
    RAISE EXCEPTION '補貨申請狀態為「%」、不可建撿貨單(需先在總倉收件匣點「派貨」)',
      v_request.status;
  END IF;
  IF v_request.linked_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION '補貨申請 #% 已有直派 transfer(legacy),不可重複建單',
      p_restock_request_id;
  END IF;
  v_tenant := v_request.tenant_id;

  IF p_allocations IS NULL OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION '請先填寫各分店分配量、不可全為空';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('wave:restock:' || p_restock_request_id::TEXT));

  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_qty := (v_alloc->>'qty')::NUMERIC;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '分配數量必須 > 0';
    END IF;
    IF v_store_id <> v_request.requesting_store_id THEN
      RAISE EXCEPTION '補貨申請只能派給申請分店 #%、不可派往其他店',
        v_request.requesting_store_id;
    END IF;
  END LOOP;

  SELECT id INTO v_hq_location FROM locations
    WHERE tenant_id = v_tenant AND type = 'central_warehouse'
    ORDER BY id LIMIT 1;
  IF v_hq_location IS NULL THEN
    RAISE EXCEPTION '找不到總倉 location(type=central_warehouse)';
  END IF;

  -- 20260715 改：上限從「申請量」改成「申請量 − 該申請已 wave 量」（累計守衛）。
  -- 原版只驗單次分配 ≤ 申請量，連按兩次各派全量也放行 → 重複派貨。
  WITH alloc_agg AS (
    SELECT (a->>'sku_id')::BIGINT AS sku_id,
           SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  line_agg AS (
    SELECT sku_id, SUM(qty) AS line_qty
    FROM restock_request_lines
    WHERE request_id = p_restock_request_id
    GROUP BY sku_id
  ),
  waved_agg AS (
    SELECT pwi.sku_id, SUM(pwi.qty) AS waved_qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
    WHERE pw.source_restock_request_id = p_restock_request_id
      AND pw.status <> 'cancelled'
    GROUP BY pwi.sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name,'') || COALESCE(' ' || NULLIF(s.variant_name,''),'') AS sku_label,
    aa.total_alloc,
    COALESCE(la.line_qty, 0) AS line_qty,
    COALESCE(wa.waved_qty, 0) AS waved_qty,
    GREATEST(0, COALESCE(la.line_qty, 0) - COALESCE(wa.waved_qty, 0)) AS line_left,
    COALESCE(sb.on_hand, 0) AS on_hand
  INTO v_short
  FROM alloc_agg aa
  JOIN skus s ON s.id = aa.sku_id
  LEFT JOIN line_agg la ON la.sku_id = aa.sku_id
  LEFT JOIN waved_agg wa ON wa.sku_id = aa.sku_id
  LEFT JOIN stock_balances sb
    ON sb.tenant_id = v_tenant
   AND sb.location_id = v_hq_location
   AND sb.sku_id = aa.sku_id
  WHERE
    aa.total_alloc > GREATEST(0, COALESCE(la.line_qty, 0) - COALESCE(wa.waved_qty, 0))
    OR aa.total_alloc > COALESCE(sb.on_hand, 0)
  LIMIT 1;

  IF v_short.sku_code IS NOT NULL THEN
    IF v_short.total_alloc > v_short.line_left THEN
      RAISE EXCEPTION 'SKU「% %」分配 % 超過剩餘申請量 %（申請 %、已撿 %）',
        v_short.sku_code, v_short.sku_label, v_short.total_alloc,
        v_short.line_left, v_short.line_qty, v_short.waved_qty;
    ELSE
      RAISE EXCEPTION 'SKU「% %」分配 % 超過總倉庫存 %',
        v_short.sku_code, v_short.sku_label, v_short.total_alloc, v_short.on_hand;
    END IF;
  END IF;

  v_wave_code := 'WV'
              || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYMMDD')
              || LPAD(nextval('public.picking_wave_code_seq')::TEXT, 6, '0');

  INSERT INTO picking_waves (
    tenant_id, wave_code, wave_date, status, source_restock_request_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_wave_code, p_wave_date, 'draft', p_restock_request_id,
    p_operator, p_operator
  ) RETURNING id INTO v_wave_id;

  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_sku_id   := (v_alloc->>'sku_id')::BIGINT;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    v_qty      := (v_alloc->>'qty')::NUMERIC;

    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, campaign_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_wave_id, v_sku_id, v_store_id, v_qty, NULL,
      p_operator, p_operator
    )
    ON CONFLICT (wave_id, sku_id, store_id) DO UPDATE
      SET qty = picking_wave_items.qty + EXCLUDED.qty,
          updated_by = p_operator,
          updated_at = NOW();
  END LOOP;

  SELECT COUNT(*), COUNT(DISTINCT store_id), COALESCE(SUM(qty), 0)
    INTO v_item_count, v_store_count, v_total_qty
    FROM picking_wave_items WHERE wave_id = v_wave_id;

  UPDATE picking_waves
    SET item_count = v_item_count,
        store_count = v_store_count,
        total_qty = v_total_qty,
        updated_at = NOW()
   WHERE id = v_wave_id;

  RETURN jsonb_build_object(
    'wave_id', v_wave_id,
    'wave_code', v_wave_code,
    'item_count', v_item_count,
    'store_count', v_store_count,
    'total_qty', v_total_qty
  );
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_create_wave_from_restock(BIGINT, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_wave_from_restock(BIGINT, DATE, JSONB, UUID) IS
  '補貨申請（無 PO 來源）建撿貨單；只接受 approved_transfer、只可派給申請分店；'
  '20260715 起：分配上限 = 申請量 − 該申請已 wave 量（累計守衛，防重複派貨）。';

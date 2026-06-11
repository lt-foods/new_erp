-- ============================================================================
-- 2026-07-05: 出貨價格防呆 — 成本價/分店價未設定的品項不能出倉（HQ→店）
-- ----------------------------------------------------------------------------
-- 背景（楊小胖 2026-06-11 回報）：
--   採購單可以 0 成本 / 0 分店價建單（先建後補價的工作流），但若沒人補價：
--   收貨以 0 成本入庫 → HQ avg_cost = 0 → 派貨出庫 movement.unit_cost = 0
--   → 月結 rpc_generate_hq_to_store_settlement 計 qty × 0 = 0 元，
--   「一鍵派貨」過程完全沒有金額欄位，沒人會發現。
--
-- 變更：
--   Part 0  helper：
--     _missing_dispatch_prices(tenant, sku_ids[]) — 列出缺「現行成本價/分店價」
--       (prices scope='cost'/'branch'、scope_id IS NULL、effective_to IS NULL、
--        price > 0) 的非虛擬 SKU，全齊回 NULL。
--     _current_cost_price(tenant, sku_id) — 現行成本價（無則 NULL）。
--   Part 1  rpc_outbound 9 → 10 參數：加 p_fallback_unit_cost DEFAULT NULL。
--     avg_cost 缺值(≤0)且呼叫端有給後備成本時，出庫 movement.unit_cost 改用
--     後備值 — 已經以 0 成本入庫的存貨，補完成本價後派貨，月結才收得到錢。
--     ※ 必須 DROP 舊 9 參數版再建：若留兩個 overload，既有 9 參數呼叫
--       會撞 PostgreSQL「function is not unique」。其餘呼叫端（銷售/退貨/
--       互助/取貨 leg）不傳新參數 → default NULL → 行為與舊版完全相同。
--   Part 2  generate_transfer_from_wave：建 transfer 前守衛缺價（一鍵派貨主路徑）。
--   Part 3  rpc_ship_restock_pr_received：補貨 PR 到貨直派，同守衛。
--   Part 4  rpc_transfer_distribute_batch：僅 transfer_type='hq_to_store' 守衛；
--     店↔店自由轉貨不受影響。缺價 transfer 進 failed[]、其他張照常。
--
-- 基底版本（依 CLAUDE.md 規則 grep 全歷史、以時間最新版擴寫）：
--   rpc_outbound                 ← 20260510000001_rpc_outbound_sku_in_error.sql
--   generate_transfer_from_wave  ← 20260511000002_generate_transfer_zh_errors.sql
--   rpc_ship_restock_pr_received ← 20260515000004_restock_transfer_ship_immediate.sql
--   rpc_transfer_distribute_batch← 20260515000006_skip_inventory_for_virtual_sku.sql
-- Rollback：
--   DROP FUNCTION public._missing_dispatch_prices(UUID, BIGINT[]);
--   DROP FUNCTION public._current_cost_price(UUID, BIGINT);
--   rpc_outbound：DROP 10 參數版、重跑 20260510000001。
--   其餘三支：重跑各自基底 migration 的定義與 GRANT。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Part 0a: helper — 列出缺現行成本價/分店價的（非虛擬）SKU
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._missing_dispatch_prices(
  p_tenant  UUID,
  p_sku_ids BIGINT[]
) RETURNS TEXT
LANGUAGE sql STABLE
AS $$
  SELECT string_agg(
           x.label || '【' || array_to_string(x.missing, '、') || '】',
           '；' ORDER BY x.sku_code NULLS LAST)
    FROM (
      SELECT
        s.sku_code,
        COALESCE(NULLIF(s.sku_code, ''), '#' || s.id::TEXT)
          || COALESCE(' ' || NULLIF(s.product_name, ''), '')
          || COALESCE('（' || NULLIF(btrim(s.variant_name), '') || '）', '') AS label,
        ARRAY_REMOVE(ARRAY[
          CASE WHEN NOT EXISTS (
            SELECT 1 FROM public.prices pr
             WHERE pr.tenant_id    = p_tenant
               AND pr.sku_id       = s.id
               AND pr.scope        = 'cost'
               AND pr.scope_id     IS NULL
               AND pr.effective_to IS NULL
               AND pr.price        > 0
          ) THEN '缺成本價' END,
          CASE WHEN NOT EXISTS (
            SELECT 1 FROM public.prices pr
             WHERE pr.tenant_id    = p_tenant
               AND pr.sku_id       = s.id
               AND pr.scope        = 'branch'
               AND pr.scope_id     IS NULL
               AND pr.effective_to IS NULL
               AND pr.price        > 0
          ) THEN '缺分店價' END
        ], NULL) AS missing
      FROM public.skus s
      JOIN public.products p ON p.id = s.product_id
     WHERE s.id = ANY(p_sku_ids)
       AND s.tenant_id = p_tenant
       AND COALESCE(p.is_virtual, FALSE) = FALSE
    ) x
   WHERE COALESCE(array_length(x.missing, 1), 0) > 0
$$;

COMMENT ON FUNCTION public._missing_dispatch_prices(UUID, BIGINT[]) IS
  '出貨價格防呆 helper：回傳缺「現行成本價/分店價」(price>0, effective_to IS NULL) '
  '的非虛擬 SKU 清單文字；全部齊全回 NULL。供 HQ→店出倉 RPC 守衛用。';

-- ----------------------------------------------------------------------------
-- Part 0b: helper — 現行成本價（無則 NULL）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._current_cost_price(
  p_tenant UUID,
  p_sku_id BIGINT
) RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
  SELECT pr.price
    FROM public.prices pr
   WHERE pr.tenant_id    = p_tenant
     AND pr.sku_id       = p_sku_id
     AND pr.scope        = 'cost'
     AND pr.scope_id     IS NULL
     AND pr.effective_to IS NULL
     AND pr.price        > 0
   ORDER BY pr.effective_from DESC
   LIMIT 1
$$;

COMMENT ON FUNCTION public._current_cost_price(UUID, BIGINT) IS
  '現行成本價（prices scope=cost, effective_to IS NULL, price>0）；無則 NULL。';

-- ----------------------------------------------------------------------------
-- Part 1: rpc_outbound — 加 p_fallback_unit_cost（10 參數）
-- 基底：20260510000001（Insufficient stock 帶 SKU 識別）逐字保留。
-- 先 DROP 舊 9 參數版，避免 default 參數造成 overload 歧義。
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS rpc_outbound(UUID, BIGINT, BIGINT, NUMERIC, TEXT, TEXT, BIGINT, UUID, BOOLEAN);

CREATE OR REPLACE FUNCTION rpc_outbound(
  p_tenant_id          UUID,
  p_location_id        BIGINT,
  p_sku_id             BIGINT,
  p_quantity           NUMERIC,
  p_movement_type      TEXT,
  p_source_doc_type    TEXT,
  p_source_doc_id      BIGINT,
  p_operator           UUID,
  p_allow_negative     BOOLEAN DEFAULT FALSE,
  p_fallback_unit_cost NUMERIC DEFAULT NULL
) RETURNS BIGINT AS $$
DECLARE
  v_available NUMERIC;
  v_cost      NUMERIC;
  v_id        BIGINT;
  v_sku_code  TEXT;
  v_sku_name  TEXT;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Outbound quantity must be positive';
  END IF;

  SELECT on_hand - reserved, avg_cost
    INTO v_available, v_cost
    FROM stock_balances
   WHERE tenant_id = p_tenant_id
     AND location_id = p_location_id
     AND sku_id = p_sku_id
   FOR UPDATE;

  IF NOT FOUND THEN
    v_available := 0;
    v_cost := 0;
  END IF;

  IF v_available < p_quantity AND NOT p_allow_negative THEN
    SELECT s.sku_code, COALESCE(s.product_name, '')
      INTO v_sku_code, v_sku_name
      FROM skus s
     WHERE s.id = p_sku_id;

    RAISE EXCEPTION 'Insufficient stock for SKU % (%): available=%, required=%',
      COALESCE(v_sku_code, p_sku_id::TEXT),
      COALESCE(v_sku_name, ''),
      v_available,
      p_quantity;
  END IF;

  -- avg_cost 缺值（0 成本入庫的存貨）且呼叫端提供後備成本 → 以後備成本計價，
  -- 讓下游（店月結等）拿得到非 0 金額。未提供後備值時行為與舊版完全相同。
  IF (v_cost IS NULL OR v_cost <= 0)
     AND COALESCE(p_fallback_unit_cost, 0) > 0 THEN
    v_cost := p_fallback_unit_cost;
  END IF;

  INSERT INTO stock_movements
    (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
     source_doc_type, source_doc_id, operator_id)
  VALUES
    (p_tenant_id, p_location_id, p_sku_id, -p_quantity, v_cost, p_movement_type,
     p_source_doc_type, p_source_doc_id, p_operator)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rpc_outbound(UUID, BIGINT, BIGINT, NUMERIC, TEXT, TEXT, BIGINT, UUID, BOOLEAN, NUMERIC) IS
  '出庫（含可用庫存檢查）。p_fallback_unit_cost：avg_cost ≤ 0 時的後備計價成本'
  '（HQ→店出貨用現行成本價，避免月結 0 元）；NULL = 行為同舊版。';

-- ----------------------------------------------------------------------------
-- Part 2: generate_transfer_from_wave — 出倉前守衛缺價 + 出庫帶後備成本
-- 基底：20260511000002 逐字保留（picked_qty 修補 / 中文錯誤 / advisory lock /
--       store location 檢查 / so_generated audit / 張數核對 / 訂單狀態更新）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_transfer_from_wave(
  p_wave_id        BIGINT,
  p_hq_location_id BIGINT,
  p_operator       UUID
) RETURNS JSONB AS $$
DECLARE
  v_tenant_id            UUID;
  v_wave_status          TEXT;
  v_expected_store_count INTEGER;
  v_expected_item_count  INTEGER;
  v_actual_xfer_count    INTEGER;
  v_store_rec            RECORD;
  v_dest_location_id     BIGINT;
  v_new_xfer_id          BIGINT;
  v_inserted_items       INTEGER;
  v_xfer_ids             BIGINT[] := ARRAY[]::BIGINT[];
  v_pwi                  RECORD;
  v_out_mov_id           BIGINT;
  v_missing              TEXT;
  v_fallback_cost        NUMERIC;
BEGIN
  PERFORM pg_advisory_xact_lock(p_wave_id);

  SELECT tenant_id, status INTO v_tenant_id, v_wave_status
    FROM picking_waves WHERE id = p_wave_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到撿貨單 %', p_wave_id;
  END IF;

  IF v_wave_status <> 'picked' THEN
    RAISE EXCEPTION '撿貨單 % 目前狀態為「%」，需先確認撿貨完成（picked）才能派貨', p_wave_id, v_wave_status;
  END IF;

  -- 防禦性修補：若有 picked_qty IS NULL（未手動填），補成 qty
  UPDATE picking_wave_items
     SET picked_qty = qty,
         updated_by = p_operator
   WHERE wave_id   = p_wave_id
     AND picked_qty IS NULL;

  -- 檢查是否有任何品項有撿貨量
  SELECT COUNT(DISTINCT store_id), COUNT(*)
    INTO v_expected_store_count, v_expected_item_count
    FROM picking_wave_items
   WHERE wave_id = p_wave_id AND picked_qty > 0;

  IF v_expected_item_count = 0 THEN
    -- 區分「根本沒有品項」vs「全部撿貨量為 0」
    PERFORM 1 FROM picking_wave_items WHERE wave_id = p_wave_id LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION '撿貨單 % 沒有任何品項，無法產生出倉單', p_wave_id;
    ELSE
      RAISE EXCEPTION '撿貨單 % 所有品項撿貨數量均為 0，無法產生出倉單。請先在「修正數量」輸入實際撿貨量再派貨。', p_wave_id;
    END IF;
  END IF;

  -- 出貨價格防呆：要出的每個（非虛擬）SKU 必須已設定現行成本價 + 分店價，
  -- 否則整張擋下 — 0 成本/0 分店價出貨會讓店月結算出 0 元、無人發現。
  SELECT public._missing_dispatch_prices(
           v_tenant_id,
           (SELECT array_agg(DISTINCT sku_id)
              FROM picking_wave_items
             WHERE wave_id = p_wave_id AND picked_qty > 0))
    INTO v_missing;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '無法派貨：以下品項尚未設定成本價／分店價，請先補價再出貨（商品頁 SKU 區塊或派貨工作台可直接補）→ %', v_missing;
  END IF;

  FOR v_store_rec IN
    SELECT DISTINCT pwi.store_id, s.location_id
      FROM picking_wave_items pwi
      JOIN stores s ON s.id = pwi.store_id
     WHERE pwi.wave_id = p_wave_id AND pwi.picked_qty > 0
  LOOP
    v_dest_location_id := v_store_rec.location_id;
    IF v_dest_location_id IS NULL THEN
      RAISE EXCEPTION '分店 % 未設定倉庫位置（location_id）', v_store_rec.store_id;
    END IF;

    INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                           status, transfer_type, requested_by, shipped_by, shipped_at,
                           created_by, updated_by)
    VALUES (v_tenant_id,
            'WAVE-' || p_wave_id || '-S' || v_store_rec.store_id,
            p_hq_location_id, v_dest_location_id,
            'shipped', 'hq_to_store', p_operator, p_operator, NOW(),
            p_operator, p_operator)
    RETURNING id INTO v_new_xfer_id;

    FOR v_pwi IN
      SELECT id, sku_id, picked_qty
        FROM picking_wave_items
       WHERE wave_id  = p_wave_id
         AND store_id = v_store_rec.store_id
         AND picked_qty > 0
    LOOP
      -- avg_cost = 0（0 成本入庫）時，出庫以現行成本價計價，月結才不會 0 元
      v_fallback_cost := public._current_cost_price(v_tenant_id, v_pwi.sku_id);

      v_out_mov_id := rpc_outbound(
        p_tenant_id          => v_tenant_id,
        p_location_id        => p_hq_location_id,
        p_sku_id             => v_pwi.sku_id,
        p_quantity           => v_pwi.picked_qty,
        p_movement_type      => 'transfer_out',
        p_source_doc_type    => 'transfer',
        p_source_doc_id      => v_new_xfer_id,
        p_operator           => p_operator,
        p_allow_negative     => FALSE,
        p_fallback_unit_cost => v_fallback_cost
      );

      INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped,
                                  out_movement_id, created_by, updated_by)
      VALUES (v_new_xfer_id, v_pwi.sku_id, v_pwi.picked_qty, v_pwi.picked_qty,
              v_out_mov_id, p_operator, p_operator);
    END LOOP;

    GET DIAGNOSTICS v_inserted_items = ROW_COUNT;

    UPDATE picking_wave_items
       SET generated_transfer_id = v_new_xfer_id, updated_by = p_operator
     WHERE wave_id  = p_wave_id
       AND store_id = v_store_rec.store_id
       AND picked_qty > 0;

    INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, created_by)
    VALUES (v_tenant_id, p_wave_id, 'so_generated',
            jsonb_build_object('transfer_id', v_new_xfer_id,
                               'store_id', v_store_rec.store_id,
                               'items_count', v_inserted_items),
            p_operator);

    v_xfer_ids := v_xfer_ids || v_new_xfer_id;
  END LOOP;

  UPDATE picking_waves SET status = 'shipped', updated_by = p_operator WHERE id = p_wave_id;

  -- 呼叫訂單狀態更新（若 function 存在）
  BEGIN
    PERFORM rpc_mark_orders_shipping_for_wave(p_wave_id, p_operator);
  EXCEPTION WHEN undefined_function THEN NULL;
  END;

  SELECT COUNT(DISTINCT generated_transfer_id)
    INTO v_actual_xfer_count
    FROM picking_wave_items
   WHERE wave_id = p_wave_id AND picked_qty > 0 AND generated_transfer_id IS NOT NULL;

  IF v_actual_xfer_count <> v_expected_store_count THEN
    RAISE EXCEPTION '出倉單數量不符：預期 % 張，實際建立 % 張', v_expected_store_count, v_actual_xfer_count;
  END IF;

  RETURN jsonb_build_object(
    'wave_id',      p_wave_id,
    'transfer_ids', to_jsonb(v_xfer_ids),
    'store_count',  v_expected_store_count,
    'item_count',   v_expected_item_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION generate_transfer_from_wave(BIGINT, BIGINT, UUID) TO authenticated;
COMMENT ON FUNCTION generate_transfer_from_wave IS
  '根據撿貨單產生分店出倉 transfer；需 status=picked 且至少一項 picked_qty > 0；'
  '20260705 起：出貨前守衛缺成本價/分店價（非虛擬 SKU），avg_cost=0 時出庫以現行成本價計價。';

-- ----------------------------------------------------------------------------
-- Part 3: rpc_ship_restock_pr_received — 同守衛 + 後備成本
-- 基底：20260515000004 逐字保留（role 檢查 / 狀態機 / 直接 shipped + outbound）。
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
    v_fallback := public._current_cost_price(v_tenant, v_line.sku_id);

    v_out_mov_id := public.rpc_outbound(
      p_tenant_id          => v_tenant,
      p_location_id        => v_hq_loc,
      p_sku_id             => v_line.sku_id,
      p_quantity           => v_line.qty,
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
      v_transfer_id, v_line.sku_id, v_line.qty, v_line.qty,
      v_out_mov_id, v_line.notes, v_user, v_user
    );
  END LOOP;

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
  '20260705 起：出貨前守衛缺成本價/分店價，avg_cost=0 時出庫以現行成本價計價。';

-- ----------------------------------------------------------------------------
-- Part 4: rpc_transfer_distribute_batch — 僅 hq_to_store 守衛缺價 + 後備成本
-- 基底：20260515000006 逐字保留（任意 source / 虛擬 SKU 跳過 / 逐張 try-catch）。
-- 店↔店自由轉貨（transfer_type ≠ hq_to_store）完全不受影響。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_transfer_distribute_batch(
  p_transfer_ids   BIGINT[],
  p_hq_location_id BIGINT,
  p_operator       UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id          BIGINT;
  v_t           transfers%ROWTYPE;
  v_ti          RECORD;
  v_is_virtual  BOOLEAN;
  v_out_id      BIGINT;
  v_succeeded   BIGINT[] := ARRAY[]::BIGINT[];
  v_failed      JSONB    := '[]'::jsonb;
  v_err         TEXT;
  v_missing     TEXT;
  v_fallback    NUMERIC;
BEGIN
  IF p_transfer_ids IS NULL OR array_length(p_transfer_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;

  FOREACH v_id IN ARRAY p_transfer_ids LOOP
    BEGIN
      SELECT * INTO v_t FROM transfers WHERE id = v_id FOR UPDATE;

      IF v_t.id IS NULL THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason', 'not found');
        CONTINUE;
      END IF;
      IF v_t.status NOT IN ('draft','confirmed') THEN
        v_failed := v_failed || jsonb_build_object('id', v_id, 'reason',
          'status=' || v_t.status || ', expected draft/confirmed');
        CONTINUE;
      END IF;

      -- 出貨價格防呆：僅 HQ→店（賣斷計費）守衛；店↔店自由轉貨不檢查
      IF v_t.transfer_type = 'hq_to_store' THEN
        SELECT public._missing_dispatch_prices(
                 v_t.tenant_id,
                 (SELECT array_agg(DISTINCT sku_id)
                    FROM transfer_items WHERE transfer_id = v_id))
          INTO v_missing;

        IF v_missing IS NOT NULL THEN
          RAISE EXCEPTION '無法派貨：以下品項尚未設定成本價／分店價，請先補價再出貨 → %', v_missing;
        END IF;
      END IF;

      FOR v_ti IN
        SELECT id AS ti_id, sku_id, qty_requested
          FROM transfer_items
         WHERE transfer_id = v_id
      LOOP
        SELECT p.is_virtual INTO v_is_virtual
          FROM skus s JOIN products p ON p.id = s.product_id
         WHERE s.id = v_ti.sku_id;

        IF v_is_virtual THEN
          -- 虛擬 SKU：不動庫存、out_movement_id 留 NULL
          UPDATE transfer_items
             SET qty_shipped = qty_requested,
                 updated_by  = p_operator
           WHERE id = v_ti.ti_id;
        ELSE
          -- 後備成本僅用於 HQ→店出貨（月結計費路徑）
          v_fallback := CASE WHEN v_t.transfer_type = 'hq_to_store'
                             THEN public._current_cost_price(v_t.tenant_id, v_ti.sku_id)
                             ELSE NULL END;

          v_out_id := rpc_outbound(
            p_tenant_id          => v_t.tenant_id,
            p_location_id        => v_t.source_location,
            p_sku_id             => v_ti.sku_id,
            p_quantity           => v_ti.qty_requested,
            p_movement_type      => 'transfer_out',
            p_source_doc_type    => 'transfer',
            p_source_doc_id      => v_id,
            p_operator           => p_operator,
            p_allow_negative     => FALSE,
            p_fallback_unit_cost => v_fallback
          );
          UPDATE transfer_items
             SET qty_shipped     = qty_requested,
                 out_movement_id = v_out_id,
                 updated_by      = p_operator
           WHERE id = v_ti.ti_id;
        END IF;
      END LOOP;

      UPDATE transfers
         SET status     = 'shipped',
             shipped_by = p_operator,
             shipped_at = NOW(),
             updated_by = p_operator
       WHERE id = v_id;

      v_succeeded := v_succeeded || v_id;
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
      v_failed := v_failed || jsonb_build_object('id', v_id, 'reason', v_err);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', array_length(p_transfer_ids, 1),
    'succeeded', v_succeeded,
    'failed', v_failed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_transfer_distribute_batch(BIGINT[], BIGINT, UUID) TO authenticated;
COMMENT ON FUNCTION rpc_transfer_distribute_batch(BIGINT[], BIGINT, UUID) IS
  '批次派發 transfers（任意 source、虛擬 SKU 跳過庫存）；'
  '20260705 起：hq_to_store 出貨前守衛缺成本價/分店價，avg_cost=0 時以現行成本價計價。';

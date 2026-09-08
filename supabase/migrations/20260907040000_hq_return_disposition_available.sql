-- ============================================================
-- 總倉退回貨處理 — F 後端可派量
--
-- 只重建三個現有物件：
--   1. 通用店家退貨不再接受「少收」
--   2. 無 PO 補貨需求的 HQ 供給量改為 on_hand - reserved
--   3. 建補貨撿貨單前鎖 balance，並用同一可派量後端守門
--
-- 不改公開 signature，不回填歷史資料。
-- ============================================================

-- 1. 店家通用退貨：少收必須回原派貨單更正實收。
CREATE OR REPLACE FUNCTION public.rpc_create_store_return(
  p_store_id  BIGINT,
  p_lines     JSONB,
  p_reason    TEXT,
  p_operator  UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := COALESCE(p_operator, auth.uid());
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_store_loc    BIGINT;
  v_store_name   TEXT;
  v_hq_loc       BIGINT;
  v_transfer_id  BIGINT;
  v_transfer_no  TEXT;
  v_line         JSONB;
  v_sku_id       BIGINT;
  v_qty          NUMERIC;
  v_qty_text     TEXT;
  v_sku_label    TEXT;
  v_on_hand      NUMERIC;
  v_pending      NUMERIC;
  v_pending_nos  TEXT;
  v_lock         RECORD;
  v_need         RECORD;
  v_notes        TEXT;
  v_count        INT := 0;
  v_total_qty    NUMERIC := 0;
  v_result_lines JSONB := '[]'::JSONB;
BEGIN
  IF p_reason = '少收' THEN
    RAISE EXCEPTION '「少收」不能用一般退貨建單。請到 /wms/inbound 找到原派貨單，用「修改實收」更正實收數量。';
  END IF;

  IF p_reason IS NULL OR p_reason NOT IN ('破損','過期','客人退') THEN
    RAISE EXCEPTION '退貨原因必須是「破損／過期／客人退」其中一個，收到的是「%」',
      COALESCE(p_reason, '(空白)');
  END IF;

  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','clerk','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create store return', v_role;
  END IF;

  SELECT location_id, name INTO v_store_loc, v_store_name
    FROM stores
   WHERE id = p_store_id AND tenant_id = v_tenant;
  IF v_store_loc IS NULL THEN
    RAISE EXCEPTION '門市 % 沒有設定倉庫位置（location_id），無法建退貨單', p_store_id;
  END IF;

  IF v_role NOT IN ('owner','admin','hq_manager') THEN
    IF NOT (p_store_id = ANY (public._jwt_store_ids())) THEN
      RAISE EXCEPTION '這個帳號不能幫「%」建退貨單 —— 只有這家店自己的帳號、或總部帳號（owner／admin／hq_manager）可以。如果你就是這家店的人卻被擋，請總部確認你的帳號有掛到這家店。',
        v_store_name;
    END IF;
  END IF;

  SELECT id INTO v_hq_loc
    FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN
    RAISE EXCEPTION '找不到啟用中的總倉，無法建退貨單';
  END IF;
  IF v_hq_loc = v_store_loc THEN
    RAISE EXCEPTION '這個帳號的位置就是總倉，不能退貨給自己';
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '請至少選一項商品';
  END IF;

  -- 第 1 趟：只驗輸入，先不建單。
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku_id := (v_line ->> 'sku_id')::BIGINT;
    v_qty_text := v_line ->> 'qty';

    -- 先驗原始文字，不能讓後段 NUMERIC(18,3) 靜默四捨五入。
    IF COALESCE(v_qty_text, '') !~ '^[0-9]+([.][0-9]{1,3})?$' THEN
      RAISE EXCEPTION '退貨數量必須是有限正數，且最多 3 位小數';
    END IF;

    v_qty := v_qty_text::NUMERIC;

    IF v_sku_id IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '品項資料不完整（商品 %、數量 %），請重新選一次', v_sku_id, v_qty;
    END IF;

    SELECT COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'')
             || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), s.sku_code)
      INTO v_sku_label
      FROM skus s
     WHERE s.id = v_sku_id AND s.tenant_id = v_tenant;
    IF v_sku_label IS NULL THEN
      RAISE EXCEPTION '找不到商品 %（或不屬於本公司）', v_sku_id;
    END IF;

    IF EXISTS (
      SELECT 1 FROM skus s JOIN products p ON p.id = s.product_id
       WHERE s.id = v_sku_id AND p.is_virtual
    ) THEN
      RAISE EXCEPTION '「%」是系統用的虛擬商品（沒有實體），不能用退貨頁退回總倉', v_sku_label;
    END IF;

    v_result_lines := v_result_lines || jsonb_build_object(
      'sku_id', v_sku_id,
      'sku_label', v_sku_label,
      'qty', v_qty
    );
    v_count     := v_count + 1;
    v_total_qty := v_total_qty + v_qty;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION '請至少選一項商品';
  END IF;

  -- 第 2 趟：依固定順序鎖住店倉 balance，再重讀可退量。
  FOR v_lock IN
    SELECT DISTINCT v_store_loc AS location_id, (l ->> 'sku_id')::BIGINT AS sku_id
      FROM jsonb_array_elements(p_lines) AS l
     ORDER BY 1, 2
  LOOP
    PERFORM 1
       FROM stock_balances
      WHERE tenant_id   = v_tenant
        AND location_id = v_lock.location_id
        AND sku_id      = v_lock.sku_id
      FOR UPDATE;
  END LOOP;

  FOR v_need IN
    SELECT g.sku_id,
           g.need,
           COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'')
             || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''),
             s.sku_code, '品項#' || g.sku_id::TEXT) AS sku_label
      FROM (
        SELECT (l ->> 'sku_id')::BIGINT AS sku_id,
               SUM((l ->> 'qty')::NUMERIC) AS need
          FROM jsonb_array_elements(p_lines) AS l
         GROUP BY 1
      ) g
      LEFT JOIN skus s ON s.id = g.sku_id AND s.tenant_id = v_tenant
     ORDER BY g.sku_id
  LOOP
    SELECT COALESCE(on_hand, 0) INTO v_on_hand
      FROM stock_balances
     WHERE tenant_id = v_tenant AND location_id = v_store_loc AND sku_id = v_need.sku_id;
    v_on_hand := COALESCE(v_on_hand, 0);

    SELECT COALESCE(pending_qty, 0), doc_nos
      INTO v_pending, v_pending_nos
      FROM v_store_pending_returns
     WHERE tenant_id = v_tenant AND location_id = v_store_loc AND sku_id = v_need.sku_id;
    v_pending := COALESCE(v_pending, 0);

    IF v_on_hand < v_pending + v_need.need THEN
      RAISE EXCEPTION '「%」退不了：店裡帳上 % 件，其中 % 件已經在等總倉回覆（單號 %），這次要退 % 件 —— 最多只能再退 % 件。',
        v_need.sku_label,
        trim_scale(v_on_hand),
        trim_scale(v_pending),
        COALESCE(v_pending_nos, '無'),
        trim_scale(v_need.need),
        trim_scale(GREATEST(v_on_hand - v_pending, 0));
    END IF;
  END LOOP;

  -- 第 3 趟：驗證全過才建單；這裡不動庫存。
  v_notes := CASE WHEN p_reason = '破損'
                  THEN '[order return|破損]'
                  ELSE '[order return: ' || p_reason || ']'
             END;

  v_transfer_no := public._next_transfer_no();

  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, customer_order_id,
    requested_by, shipped_by, shipped_at,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_transfer_no, v_store_loc, v_hq_loc,
    'shipped', 'return_to_hq', NULL,
    v_user, v_user, NOW(),
    v_notes, v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(v_result_lines)
  LOOP
    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped,
      out_movement_id, created_by, updated_by
    ) VALUES (
      v_transfer_id,
      (v_line ->> 'sku_id')::BIGINT,
      (v_line ->> 'qty')::NUMERIC,
      (v_line ->> 'qty')::NUMERIC,
      NULL, v_user, v_user
    );
  END LOOP;

  RETURN jsonb_build_object(
    'transfer_id',  v_transfer_id,
    'transfer_no',  v_transfer_no,
    'store_id',     p_store_id,
    'store_name',   v_store_name,
    'reason',       p_reason,
    'lines',        v_count,
    'total_qty',    v_total_qty,
    'stock_moved',  FALSE,
    'items',        v_result_lines
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_store_return(BIGINT, JSONB, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_store_return(BIGINT, JSONB, TEXT, UUID) IS
  '店家退貨頁：從商品下手建 return_to_hq 退貨單，送出時不動庫存。'
  '通用原因只收破損／過期／客人退；少收必須回 /wms/inbound 的原派貨單修改實收。'
  '退貨量只收有限正數且最多 3 位小數；店別、tenant、庫存預鎖與待退量守門沿用 20260904020000；原回傳結構不變。';

-- 2. 補貨需求中的 HQ 供給量改為「帳上 - 已保留」。
--    欄位、排序、需求/已建 wave 篩選及權限不變。
CREATE OR REPLACE VIEW public.v_picking_demand_no_po AS
WITH hq_loc AS (
  SELECT DISTINCT ON (tenant_id) tenant_id, id AS location_id
    FROM locations
   WHERE type = 'central_warehouse'
   ORDER BY tenant_id, id
),
rr_lines AS (
  SELECT
    rr.id AS restock_request_id,
    rr.tenant_id,
    rr.status AS restock_status,
    rr.requesting_store_id AS store_id,
    rrl.sku_id,
    rrl.qty AS demand_qty
  FROM restock_requests rr
  JOIN restock_request_lines rrl ON rrl.request_id = rr.id
  WHERE rr.status = 'approved_transfer'
    AND rr.linked_transfer_id IS NULL
),
hq_supply AS (
  SELECT
    sb.tenant_id,
    sb.sku_id,
    GREATEST(COALESCE(sb.on_hand, 0) - COALESCE(sb.reserved, 0), 0) AS on_hand
  FROM stock_balances sb
  JOIN hq_loc h ON h.tenant_id = sb.tenant_id AND h.location_id = sb.location_id
),
wave_qty AS (
  SELECT pw.source_restock_request_id AS restock_request_id,
         pwi.sku_id, pwi.store_id,
         SUM(pwi.qty) AS wave_qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
   WHERE pw.status <> 'cancelled'
     AND pw.source_restock_request_id IS NOT NULL
   GROUP BY pw.source_restock_request_id, pwi.sku_id, pwi.store_id
)
SELECT
  l.tenant_id,
  NULL::BIGINT AS po_id,
  'RR-' || l.restock_request_id::TEXT AS po_no,
  'restock'::TEXT AS po_status,
  NULL::BIGINT AS supplier_id,
  NULL::BIGINT AS po_item_id,
  l.sku_id,
  s.sku_code,
  COALESCE(s.product_name,'') || COALESCE(' ' || NULLIF(s.variant_name,''),'') AS sku_label,
  l.demand_qty AS qty_ordered,
  COALESCE(hs.on_hand, 0)::NUMERIC AS gr_qty,
  0::NUMERIC AS qty_in_transit,
  0::NUMERIC AS qty_shortage,
  l.store_id,
  st.code AS store_code,
  st.name AS store_name,
  l.demand_qty,
  COALESCE(wq.wave_qty, 0)::NUMERIC AS wave_qty,
  0::NUMERIC AS shipped_qty,
  TRUE AS is_restock_sourced,
  l.restock_request_id,
  l.restock_status
FROM rr_lines l
JOIN skus s ON s.id = l.sku_id
LEFT JOIN hq_supply hs ON hs.tenant_id = l.tenant_id AND hs.sku_id = l.sku_id
LEFT JOIN stores st ON st.id = l.store_id
LEFT JOIN wave_qty wq ON wq.restock_request_id = l.restock_request_id
                     AND wq.sku_id = l.sku_id
                     AND wq.store_id = l.store_id
WHERE COALESCE(wq.wave_qty, 0) < l.demand_qty;

GRANT SELECT ON public.v_picking_demand_no_po TO authenticated;

COMMENT ON VIEW public.v_picking_demand_no_po IS
  '已核准直派的補貨需求；gr_qty 是 HQ 可派量 GREATEST(on_hand-reserved,0)，未確認退回貨不算供給。';

-- 3. 補貨建 wave：先驗每筆原始數量與 tenant/SKU，再固定順序鎖 HQ balance。
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
  v_qty_text     TEXT;
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
  IF v_request.status <> 'approved_transfer' THEN
    RAISE EXCEPTION '補貨申請狀態為「%」、不可建撿貨單(需先在總倉收件匣點「派貨」)',
      v_request.status;
  END IF;
  IF v_request.linked_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION '補貨申請 #% 已有直派 transfer(legacy),不可重複建單',
      p_restock_request_id;
  END IF;
  v_tenant := v_request.tenant_id;

  IF p_allocations IS NULL
  OR jsonb_typeof(p_allocations) IS DISTINCT FROM 'array'
  OR jsonb_array_length(p_allocations) = 0
  THEN
    RAISE EXCEPTION '請先填寫各分店分配量、不可全為空';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('wave:restock:' || p_restock_request_id::TEXT));

  -- 先驗原始值，不讓 numeric(18,3) 自動四捨五入超過 3 位小數。
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
  LOOP
    IF jsonb_typeof(v_alloc) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION '每筆分配必須是包含 sku_id、store_id、qty 的資料';
    END IF;

    IF COALESCE(v_alloc->>'sku_id', '') !~ '^[0-9]+$'
    OR COALESCE(v_alloc->>'store_id', '') !~ '^[0-9]+$'
    THEN
      RAISE EXCEPTION '分配的 sku_id 與 store_id 必須是正整數';
    END IF;

    v_sku_id   := (v_alloc->>'sku_id')::BIGINT;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    v_qty_text := v_alloc->>'qty';

    IF v_sku_id <= 0 OR v_store_id <= 0 THEN
      RAISE EXCEPTION '分配的 sku_id 與 store_id 必須是正整數';
    END IF;

    IF COALESCE(v_qty_text, '') !~ '^[0-9]+([.][0-9]{1,3})?$' THEN
      RAISE EXCEPTION '分配數量必須是有限正數，且最多 3 位小數';
    END IF;

    v_qty := v_qty_text::NUMERIC;
    IF v_qty <= 0 THEN
      RAISE EXCEPTION '分配數量必須 > 0';
    END IF;

    IF v_store_id <> v_request.requesting_store_id THEN
      RAISE EXCEPTION '補貨申請只能派給申請分店 #%、不可派往其他店',
        v_request.requesting_store_id;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM skus s
       WHERE s.id = v_sku_id AND s.tenant_id = v_tenant
    ) THEN
      RAISE EXCEPTION '找不到 SKU #%（或不屬於這家公司）', v_sku_id;
    END IF;
  END LOOP;

  SELECT id INTO v_hq_location FROM locations
    WHERE tenant_id = v_tenant AND type = 'central_warehouse'
    ORDER BY id LIMIT 1;
  IF v_hq_location IS NULL THEN
    RAISE EXCEPTION '找不到總倉 location(type=central_warehouse)';
  END IF;

  -- 與 _hq_hold_return 更新 reserved 共用同一 balance 鎖；SKU 升冪避免死鎖。
  FOR v_sku_id IN
    SELECT DISTINCT (a->>'sku_id')::BIGINT
      FROM jsonb_array_elements(p_allocations) AS a
     ORDER BY 1
  LOOP
    PERFORM 1
      FROM stock_balances
     WHERE tenant_id = v_tenant
       AND location_id = v_hq_location
       AND sku_id = v_sku_id
     FOR UPDATE;
  END LOOP;

  -- 單次分配不可超過「申請量 - 已建 wave」，也不可超過 HQ 可派量。
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
    GREATEST(COALESCE(sb.on_hand, 0) - COALESCE(sb.reserved, 0), 0) AS available_qty
  INTO v_short
  FROM alloc_agg aa
  JOIN skus s ON s.id = aa.sku_id AND s.tenant_id = v_tenant
  LEFT JOIN line_agg la ON la.sku_id = aa.sku_id
  LEFT JOIN waved_agg wa ON wa.sku_id = aa.sku_id
  LEFT JOIN stock_balances sb
    ON sb.tenant_id = v_tenant
   AND sb.location_id = v_hq_location
   AND sb.sku_id = aa.sku_id
  WHERE aa.total_alloc > GREATEST(0, COALESCE(la.line_qty, 0) - COALESCE(wa.waved_qty, 0))
     OR aa.total_alloc > GREATEST(COALESCE(sb.on_hand, 0) - COALESCE(sb.reserved, 0), 0)
  LIMIT 1;

  IF v_short.sku_code IS NOT NULL THEN
    IF v_short.total_alloc > v_short.line_left THEN
      RAISE EXCEPTION 'SKU「% %」分配 % 超過剩餘申請量 %（申請 %、已撿 %）',
        v_short.sku_code, v_short.sku_label, v_short.total_alloc,
        v_short.line_left, v_short.line_qty, v_short.waved_qty;
    ELSE
      RAISE EXCEPTION 'SKU「% %」分配 % 超過總倉可派量 %（帳上庫存已扣掉待確認保留量）',
        v_short.sku_code, v_short.sku_label, v_short.total_alloc, v_short.available_qty;
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

  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
  LOOP
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
  '補貨申請（無 PO 來源）建撿貨單；保留 approved_transfer、申請剩餘量、已 wave 去重與申請分店守門。'
  '分配只收有限正數且最多 3 位小數；先排序鎖 HQ balance，再以 GREATEST(on_hand-reserved,0) 驗後端可派量。';

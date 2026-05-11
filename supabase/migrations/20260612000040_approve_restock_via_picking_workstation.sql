-- ============================================================
-- 改寫 rpc_approve_restock_to_transfer:
--   原本「點派貨」直接建 hq_to_store transfer + status=shipped
--   改為:只把 restock_requests.status 設成 'approved_transfer'(不建 transfer)
--   然後 restock 會出現在派貨工作台 amber section,實際 transfer 由 wave 流產出
--
-- 同步收緊 v_picking_demand_no_po:
--   status='approved_transfer' 且 linked_transfer_id IS NULL
--   → 不影響舊資料(已直派的、linked_transfer_id 非 NULL,不會再列在派貨工作台)
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_approve_restock_to_transfer(p_request_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req    RECORD;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot approve restock', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'request % already processed (status=%)', p_request_id, v_req.status;
  END IF;

  -- 只更新狀態:後續由派貨工作台 rpc_create_wave_from_restock 接手
  UPDATE restock_requests
     SET status = 'approved_transfer',
         linked_transfer_id = NULL,
         approved_by = v_user,
         approved_at = NOW(),
         updated_by  = v_user,
         updated_at  = NOW()
   WHERE id = p_request_id;

  RETURN p_request_id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_approve_restock_to_transfer(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_approve_restock_to_transfer(BIGINT) IS
  '審核通過補貨申請、轉派貨工作台處理(不直接建 transfer)。實際 transfer 由 wave 流產出。';

-- 同步更新 view filter
CREATE OR REPLACE VIEW public.v_picking_demand_no_po AS
WITH hq_loc AS (
  SELECT DISTINCT ON (tenant_id) tenant_id, id AS location_id
    FROM locations
   WHERE type = 'central_warehouse'
   ORDER BY tenant_id, id
),
rr_lines AS (
  SELECT
    rr.id              AS restock_request_id,
    rr.tenant_id,
    rr.status          AS restock_status,
    rr.requesting_store_id AS store_id,
    rrl.sku_id,
    rrl.qty            AS demand_qty
  FROM restock_requests rr
  JOIN restock_request_lines rrl ON rrl.request_id = rr.id
  WHERE rr.status = 'approved_transfer'
    AND rr.linked_transfer_id IS NULL  -- 排除舊資料的直派 transfer
),
hq_supply AS (
  SELECT
    sb.tenant_id, sb.sku_id, sb.on_hand
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
  NULL::BIGINT                AS po_id,
  'RR-' || l.restock_request_id::TEXT AS po_no,
  'restock'::TEXT             AS po_status,
  NULL::BIGINT                AS supplier_id,
  NULL::BIGINT                AS po_item_id,
  l.sku_id,
  s.sku_code,
  COALESCE(s.product_name,'') || COALESCE(' ' || NULLIF(s.variant_name,''),'') AS sku_label,
  l.demand_qty                AS qty_ordered,
  COALESCE(hs.on_hand, 0)::NUMERIC AS gr_qty,
  0::NUMERIC                  AS qty_in_transit,
  0::NUMERIC                  AS qty_shortage,
  l.store_id,
  st.code                     AS store_code,
  st.name                     AS store_name,
  l.demand_qty,
  COALESCE(wq.wave_qty, 0)::NUMERIC AS wave_qty,
  0::NUMERIC                  AS shipped_qty,
  TRUE                        AS is_restock_sourced,
  l.restock_request_id,
  l.restock_status
FROM rr_lines l
JOIN skus s ON s.id = l.sku_id
LEFT JOIN hq_supply hs ON hs.tenant_id = l.tenant_id AND hs.sku_id = l.sku_id
LEFT JOIN stores st ON st.id = l.store_id
LEFT JOIN wave_qty wq ON wq.restock_request_id = l.restock_request_id
                     AND wq.sku_id = l.sku_id
                     AND wq.store_id = l.store_id
WHERE
  COALESCE(wq.wave_qty, 0) < l.demand_qty;

GRANT SELECT ON public.v_picking_demand_no_po TO authenticated;

-- 同步:rpc_create_wave_from_restock 守衛也只接受 approved_transfer
-- (原本接 pending 是因為 view 也 show pending,但現在 inbox 必經 gate)
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
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name,'') || COALESCE(' ' || NULLIF(s.variant_name,''),'') AS sku_label,
    aa.total_alloc,
    COALESCE(la.line_qty, 0) AS line_qty,
    COALESCE(sb.on_hand, 0) AS on_hand
  INTO v_short
  FROM alloc_agg aa
  JOIN skus s ON s.id = aa.sku_id
  LEFT JOIN line_agg la ON la.sku_id = aa.sku_id
  LEFT JOIN stock_balances sb
    ON sb.tenant_id = v_tenant
   AND sb.location_id = v_hq_location
   AND sb.sku_id = aa.sku_id
  WHERE
    aa.total_alloc > COALESCE(la.line_qty, 0)
    OR aa.total_alloc > COALESCE(sb.on_hand, 0)
  LIMIT 1;

  IF v_short.sku_code IS NOT NULL THEN
    IF v_short.total_alloc > v_short.line_qty THEN
      RAISE EXCEPTION 'SKU「% %」分配 % 超過申請量 %',
        v_short.sku_code, v_short.sku_label, v_short.total_alloc, v_short.line_qty;
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

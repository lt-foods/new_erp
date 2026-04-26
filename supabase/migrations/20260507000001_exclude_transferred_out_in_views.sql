-- ============================================================
-- Phase 5a-1 follow-up: 把 'transferred_out' 加進所有抓未完訂單的 view / RPC 的排除清單
--
-- 受影響的查詢：
--   1. v_picking_demand_by_close_date  (撿貨工作站需求矩陣)
--   2. v_open_group_matrix             (開團總表)
--   3. v_stalled_items                 (積壓未到貨)
--   4. rpc_upsert_member               (改 home_store 守衛)
--   5. rpc_create_pr_from_close_date   (該日商品彙總建 PR)
--
-- 不修：
--   - 任何 picking_wave_*  /  goods_receipt_*  /  transfers RPC
--     這些走 customer_order_items 的 status，items.status 仍是 'pending'，
--     但因實際撿貨流由 customer_orders.status 驅動，view/RPC 加 co.status filter 已足夠
-- ============================================================

-- ============================================================
-- 1. v_picking_demand_by_close_date
-- ============================================================
DROP VIEW IF EXISTS public.v_picking_demand_by_close_date CASCADE;

CREATE OR REPLACE VIEW public.v_picking_demand_by_close_date AS
SELECT
  gbc.tenant_id,
  DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') AS close_date,
  coi.sku_id,
  COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
  s.sku_code,
  co.pickup_store_id AS store_id,
  st.code AS store_code,
  st.name AS store_name,
  SUM(coi.qty) AS demand_qty,
  COUNT(DISTINCT co.id) AS order_count,
  array_agg(DISTINCT gbc.id) AS campaign_ids,
  COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status = 'confirmed'), 0)::NUMERIC AS received_qty,
  array_agg(DISTINCT po.po_no) FILTER (WHERE po.po_no IS NOT NULL) AS po_numbers,
  array_agg(DISTINCT co.order_no) FILTER (WHERE co.order_no IS NOT NULL) AS order_numbers
FROM group_buy_campaigns gbc
JOIN customer_orders co ON co.campaign_id = gbc.id
                       AND co.status NOT IN ('cancelled','expired','transferred_out')
JOIN customer_order_items coi ON coi.order_id = co.id
                             AND coi.status NOT IN ('cancelled','expired')
JOIN skus s ON s.id = coi.sku_id
JOIN stores st ON st.id = co.pickup_store_id
LEFT JOIN goods_receipt_items gri ON gri.sku_id = coi.sku_id
LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id AND gr.tenant_id = gbc.tenant_id AND gr.status = 'confirmed'
LEFT JOIN purchase_orders po ON po.id = gr.po_id
WHERE gbc.status NOT IN ('cancelled')
GROUP BY
  gbc.tenant_id,
  DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei'),
  coi.sku_id, s.product_name, s.variant_name, s.sku_code,
  co.pickup_store_id, st.code, st.name;

GRANT SELECT ON public.v_picking_demand_by_close_date TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_close_date IS
  '撿貨工作站需求矩陣（含進庫量、PO/訂單號、排除 transferred_out 訂單）';

-- ============================================================
-- 2. v_open_group_matrix
-- ============================================================
DROP VIEW IF EXISTS v_open_group_matrix CASCADE;

CREATE OR REPLACE VIEW v_open_group_matrix AS
SELECT
  gbc.id                AS campaign_id,
  gbc.tenant_id,
  gbc.cutoff_date,
  gbc.matrix_row_order,
  ci.sku_id,
  s.id                  AS store_id,
  s.name                AS store_name,
  COALESCE(SUM(coi.qty), 0)        AS total_qty,
  COUNT(DISTINCT co.member_id)     AS customer_count,
  COUNT(DISTINCT co.id)            AS order_count
FROM group_buy_campaigns gbc
JOIN campaign_items ci ON ci.campaign_id = gbc.id
LEFT JOIN customer_order_items coi ON coi.campaign_item_id = ci.id
                                  AND coi.status NOT IN ('cancelled','expired')
LEFT JOIN customer_orders co ON co.id = coi.order_id
                            AND co.status NOT IN ('cancelled','expired','transferred_out')
LEFT JOIN stores s ON s.id = co.pickup_store_id
WHERE gbc.status IN ('open','closed')
GROUP BY gbc.id, gbc.tenant_id, gbc.cutoff_date, gbc.matrix_row_order,
         ci.sku_id, s.id, s.name;

-- ============================================================
-- 3. v_stalled_items
-- ============================================================
DROP VIEW IF EXISTS v_stalled_items CASCADE;

CREATE OR REPLACE VIEW v_stalled_items AS
SELECT
  coi.id                AS order_item_id,
  coi.tenant_id,
  gbc.id                AS campaign_id,
  gbc.cutoff_date,
  gbc.expected_arrival_date,
  coi.sku_id,
  coi.qty,
  co.channel_id,
  co.member_id,
  co.pickup_store_id,
  EXTRACT(DAY FROM NOW() - gbc.expected_arrival_date)::INT AS days_overdue
FROM customer_order_items coi
JOIN customer_orders co ON co.id = coi.order_id
                       AND co.status NOT IN ('transferred_out','cancelled','expired')
JOIN campaign_items ci ON ci.id = coi.campaign_item_id
JOIN group_buy_campaigns gbc ON gbc.id = ci.campaign_id
WHERE coi.status IN ('pending','reserved')
  AND gbc.expected_arrival_date IS NOT NULL
  AND gbc.expected_arrival_date < CURRENT_DATE;

-- ============================================================
-- 4. rpc_upsert_member — 改 home_store 守衛加 'transferred_out'
-- ============================================================
-- transferred_out 視同已處理（轉走了），允許改 home_store

CREATE OR REPLACE FUNCTION public.rpc_upsert_member(
  p_id            BIGINT,
  p_member_no     TEXT,
  p_phone         TEXT,
  p_name          TEXT,
  p_gender        TEXT DEFAULT NULL,
  p_birthday      DATE DEFAULT NULL,
  p_email         TEXT DEFAULT NULL,
  p_tier_id       BIGINT DEFAULT NULL,
  p_home_store_id BIGINT DEFAULT NULL,
  p_status        TEXT DEFAULT 'active',
  p_notes         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_id          BIGINT;
  v_phone_hash  TEXT;
  v_email_hash  TEXT;
  v_birth_md    TEXT;
  v_old_store   BIGINT;
  v_open_orders INT;
BEGIN
  IF p_phone IS NULL OR p_phone = '' THEN
    RAISE EXCEPTION 'phone is required';
  END IF;
  IF p_name IS NULL OR p_name = '' THEN
    RAISE EXCEPTION 'name is required';
  END IF;

  v_phone_hash := encode(digest(p_phone, 'sha256'), 'hex');
  v_email_hash := CASE WHEN p_email IS NOT NULL AND p_email <> ''
                       THEN encode(digest(lower(p_email), 'sha256'), 'hex')
                  END;
  v_birth_md   := CASE WHEN p_birthday IS NOT NULL
                       THEN to_char(p_birthday, 'MM-DD')
                  END;

  IF p_tier_id IS NOT NULL THEN
    PERFORM 1 FROM member_tiers WHERE id = p_tier_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'tier % not in tenant', p_tier_id; END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO members (
      tenant_id, member_no, phone_hash, phone, email_hash, email,
      name, birthday, birth_md, gender, tier_id, home_store_id,
      status, notes, created_by, updated_by
    ) VALUES (
      v_tenant, p_member_no, v_phone_hash, p_phone, v_email_hash, p_email,
      p_name, p_birthday, v_birth_md, p_gender, p_tier_id, p_home_store_id,
      COALESCE(p_status, 'active'), p_notes, auth.uid(), auth.uid()
    ) RETURNING id INTO v_id;
  ELSE
    SELECT home_store_id INTO v_old_store FROM members
     WHERE id = p_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_id; END IF;

    IF v_old_store IS DISTINCT FROM p_home_store_id THEN
      SELECT COUNT(*) INTO v_open_orders FROM customer_orders
       WHERE tenant_id = v_tenant
         AND member_id = p_id
         AND status NOT IN ('completed','cancelled','expired','transferred_out');
      IF v_open_orders > 0 THEN
        RAISE EXCEPTION '會員仍有 % 筆未取貨訂單，請先處理完才能改取貨店', v_open_orders;
      END IF;
    END IF;

    UPDATE members SET
      member_no     = COALESCE(p_member_no, member_no),
      phone_hash    = v_phone_hash,
      phone         = p_phone,
      email_hash    = v_email_hash,
      email         = p_email,
      name          = COALESCE(p_name, name),
      birthday      = p_birthday,
      birth_md      = v_birth_md,
      gender        = p_gender,
      tier_id       = p_tier_id,
      home_store_id = p_home_store_id,
      status        = COALESCE(p_status, status),
      notes         = p_notes,
      updated_by    = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'member % not in tenant', p_id; END IF;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_member TO authenticated;

-- ============================================================
-- 5. rpc_create_pr_from_close_date — 加 'transferred_out' 排除
-- ============================================================
-- 兩個 query 點：守衛 demand_count + items 彙總

CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_close_date(
  p_close_date DATE,
  p_operator   UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_pr_id       BIGINT;
  v_pr_no       TEXT;
  v_dest_loc    BIGINT;
  v_campaign_count INTEGER;
  v_demand_count   INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_campaign_count
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status = 'closed'
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = p_close_date;

  IF v_campaign_count = 0 THEN
    RAISE EXCEPTION 'no closed campaigns on date %', p_close_date;
  END IF;

  SELECT COUNT(*) INTO v_demand_count
    FROM group_buy_campaigns gbc
    JOIN customer_orders co ON co.campaign_id = gbc.id
    JOIN customer_order_items coi ON coi.order_id = co.id
   WHERE gbc.tenant_id = v_tenant
     AND gbc.status = 'closed'
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
     AND co.status NOT IN ('cancelled','expired','transferred_out')
     AND coi.status NOT IN ('cancelled','expired');

  IF v_demand_count = 0 THEN
    RAISE EXCEPTION 'no orders to aggregate for close_date %', p_close_date;
  END IF;

  SELECT id INTO v_dest_loc FROM locations
   WHERE tenant_id = v_tenant
   ORDER BY id LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined for tenant %', v_tenant;
  END IF;

  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date,
    source_location_id, status, total_amount,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'close_date', p_close_date,
    v_dest_loc, 'draft', 0,
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested,
    suggested_supplier_id, unit_cost, source_campaign_id,
    created_by, updated_by
  )
  SELECT
    v_pr_id,
    agg.sku_id,
    agg.qty_total,
    ss.supplier_id,
    COALESCE(ss.default_unit_cost, 0),
    agg.first_campaign_id,
    p_operator,
    p_operator
  FROM (
    SELECT
      coi.sku_id,
      SUM(coi.qty) AS qty_total,
      MIN(gbc.id)  AS first_campaign_id
      FROM group_buy_campaigns gbc
      JOIN customer_orders co ON co.campaign_id = gbc.id
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE gbc.tenant_id = v_tenant
       AND gbc.status = 'closed'
       AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id
  ) agg
  LEFT JOIN LATERAL (
    SELECT supplier_id, default_unit_cost
      FROM supplier_skus
     WHERE tenant_id = v_tenant
       AND sku_id = agg.sku_id
       AND is_preferred = TRUE
     LIMIT 1
  ) ss ON TRUE;

  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  RETURN v_pr_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_pr_from_close_date TO authenticated;

-- Quick mobile controls for food-train / flash / limited campaigns.
-- Keeps the phone UI on narrow RPCs instead of the generic campaign editor.

CREATE OR REPLACE FUNCTION public.rpc_quick_update_campaign_control(
  p_campaign_id BIGINT,
  p_status TEXT DEFAULT NULL,
  p_end_at TIMESTAMPTZ DEFAULT NULL,
  p_total_cap_qty_delta NUMERIC DEFAULT NULL
) RETURNS TABLE (
  id BIGINT,
  status TEXT,
  end_at TIMESTAMPTZ,
  total_cap_qty NUMERIC,
  sold_qty NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user UUID := auth.uid();
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_campaign group_buy_campaigns%ROWTYPE;
  v_sold_qty NUMERIC := 0;
  v_next_status TEXT;
  v_next_end_at TIMESTAMPTZ;
  v_next_total_cap_qty NUMERIC;
BEGIN
  IF v_role NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  SELECT * INTO v_campaign
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
     AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id;
  END IF;

  IF v_campaign.status NOT IN ('draft', 'open', 'closed') THEN
    RAISE EXCEPTION 'campaign % is %, cannot quick-control', p_campaign_id, v_campaign.status;
  END IF;

  IF NOT (
       v_campaign.close_type IN ('food_train', 'fast', 'limited')
    OR COALESCE(v_campaign.total_cap_qty, 0) > 0
    OR EXISTS (
      SELECT 1
        FROM campaign_items ci
       WHERE ci.tenant_id = v_tenant
         AND ci.campaign_id = p_campaign_id
         AND COALESCE(ci.cap_qty, 0) > 0
    )
  ) THEN
    RAISE EXCEPTION 'campaign % is not a quick-control campaign', p_campaign_id;
  END IF;

  SELECT COALESCE(SUM(coi.qty), 0)
    INTO v_sold_qty
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE co.tenant_id = v_tenant
     AND co.campaign_id = p_campaign_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND coi.status NOT IN ('cancelled', 'expired')
     AND COALESCE(co.order_kind, 'normal') = 'normal';

  v_next_status := COALESCE(p_status, v_campaign.status);
  v_next_end_at := COALESCE(p_end_at, v_campaign.end_at);
  v_next_total_cap_qty := v_campaign.total_cap_qty;

  IF p_status IS NOT NULL THEN
    IF p_status <> 'open' THEN
      RAISE EXCEPTION 'invalid quick target status: %', p_status;
    END IF;

    IF p_status = 'open' THEN
      IF v_campaign.status NOT IN ('draft', 'closed', 'open') THEN
        RAISE EXCEPTION 'campaign % is %, cannot open', p_campaign_id, v_campaign.status;
      END IF;

      PERFORM 1 FROM campaign_items WHERE campaign_id = p_campaign_id LIMIT 1;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'campaign % has no items', p_campaign_id;
      END IF;

      IF v_campaign.status = 'closed' AND EXISTS (
        SELECT 1
          FROM purchase_request_campaigns prc
          JOIN purchase_requests pr ON pr.id = prc.pr_id
         WHERE prc.tenant_id = v_tenant
           AND prc.campaign_id = p_campaign_id
           AND pr.status <> 'cancelled'
      ) THEN
        RAISE EXCEPTION 'campaign % already has purchase request linkage; cannot reopen', p_campaign_id;
      END IF;

      IF v_next_end_at IS NULL OR v_next_end_at <= NOW() THEN
        RAISE EXCEPTION 'future end_at is required when opening/reopening';
      END IF;
    END IF;
  END IF;

  IF p_end_at IS NOT NULL THEN
    IF p_end_at <= NOW() THEN
      RAISE EXCEPTION 'end_at must be in the future';
    END IF;
    IF v_campaign.status = 'closed' AND v_next_status <> 'open' THEN
      RAISE EXCEPTION 'closed campaigns must be reopened, not only extended';
    END IF;
  END IF;

  IF p_total_cap_qty_delta IS NOT NULL THEN
    IF p_total_cap_qty_delta <= 0 THEN
      RAISE EXCEPTION 'cap delta must be > 0';
    END IF;
    v_next_total_cap_qty := COALESCE(v_campaign.total_cap_qty, v_sold_qty) + p_total_cap_qty_delta;
  END IF;

  UPDATE group_buy_campaigns gbc
     SET status = v_next_status,
         end_at = v_next_end_at,
         total_cap_qty = v_next_total_cap_qty,
         updated_by = v_user,
         updated_at = NOW()
   WHERE gbc.id = p_campaign_id
     AND gbc.tenant_id = v_tenant;

  IF p_status IS NOT NULL AND v_next_status IS DISTINCT FROM v_campaign.status THEN
    INSERT INTO campaign_audit_log (
      tenant_id, campaign_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_tenant, p_campaign_id, 'campaign', p_campaign_id, 'status',
      to_jsonb(v_campaign.status), to_jsonb(v_next_status),
      'quick_control', v_user
    );
  END IF;

  IF p_end_at IS NOT NULL AND v_next_end_at IS DISTINCT FROM v_campaign.end_at THEN
    INSERT INTO campaign_audit_log (
      tenant_id, campaign_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_tenant, p_campaign_id, 'campaign', p_campaign_id, 'end_at',
      to_jsonb(v_campaign.end_at), to_jsonb(v_next_end_at),
      'quick_control', v_user
    );
  END IF;

  IF p_total_cap_qty_delta IS NOT NULL AND v_next_total_cap_qty IS DISTINCT FROM v_campaign.total_cap_qty THEN
    INSERT INTO campaign_audit_log (
      tenant_id, campaign_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_tenant, p_campaign_id, 'campaign', p_campaign_id, 'total_cap_qty',
      to_jsonb(v_campaign.total_cap_qty), to_jsonb(v_next_total_cap_qty),
      'quick_control', v_user
    );
  END IF;

  RETURN QUERY
  SELECT p_campaign_id, v_next_status, v_next_end_at, v_next_total_cap_qty, v_sold_qty;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) TO authenticated;

COMMENT ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) IS
  'Mobile quick control for food_train/fast/limited campaigns: open/reopen, future end_at, positive total cap delta. Closing must use rpc_close_campaign.';

CREATE OR REPLACE FUNCTION public.rpc_place_member_order_guarded(
  p_tenant UUID,
  p_campaign_id BIGINT,
  p_channel_id BIGINT,
  p_member_id BIGINT,
  p_pickup_store_id BIGINT,
  p_items JSONB,
  p_notes TEXT DEFAULT NULL,
  p_source TEXT DEFAULT 'liff'
) RETURNS TABLE (
  order_id BIGINT,
  order_no TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign group_buy_campaigns%ROWTYPE;
  v_member members%ROWTYPE;
  v_source TEXT := CASE WHEN p_source = 'pwa' THEN 'pwa' ELSE 'liff' END;
  v_requested_count INT := 0;
  v_requested_total NUMERIC := 0;
  v_total_sold NUMERIC := 0;
  v_order_id BIGINT;
  v_order_no TEXT;
  v_seq INT;
  v_req RECORD;
  v_ci RECORD;
  v_item_sold NUMERIC;
  v_existing_qty NUMERIC;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant required';
  END IF;
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'campaign_id required';
  END IF;
  IF p_channel_id IS NULL THEN
    RAISE EXCEPTION 'channel_id required';
  END IF;
  IF p_member_id IS NULL THEN
    RAISE EXCEPTION 'member_id required';
  END IF;
  IF p_pickup_store_id IS NULL THEN
    RAISE EXCEPTION 'pickup_store_id required';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items required';
  END IF;

  SELECT * INTO v_campaign
    FROM group_buy_campaigns
   WHERE tenant_id = p_tenant
     AND id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found';
  END IF;
  IF v_campaign.status <> 'open' THEN
    RAISE EXCEPTION 'campaign not open';
  END IF;
  IF COALESCE(v_campaign.is_for_shop, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'campaign not available';
  END IF;
  IF v_campaign.end_at IS NOT NULL AND v_campaign.end_at <= NOW() THEN
    RAISE EXCEPTION 'campaign already ended';
  END IF;

  SELECT * INTO v_member
    FROM members
   WHERE tenant_id = p_tenant
     AND id = p_member_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member not found';
  END IF;
  IF COALESCE(v_member.no_new_order, false) THEN
    RAISE EXCEPTION 'member blocked';
  END IF;

  PERFORM 1 FROM stores WHERE tenant_id = p_tenant AND id = p_pickup_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_store_id required';
  END IF;

  PERFORM 1 FROM line_channels WHERE tenant_id = p_tenant AND id = p_channel_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no active channel for tenant';
  END IF;

  FOR v_req IN
    SELECT
      (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
      (x ->> 'qty')::NUMERIC AS qty
    FROM jsonb_array_elements(p_items) AS x
  LOOP
    IF v_req.campaign_item_id IS NULL OR v_req.qty IS NULL OR v_req.qty <= 0 THEN
      RAISE EXCEPTION 'qty must be > 0';
    END IF;
  END LOOP;

  SELECT COUNT(*), COALESCE(SUM(qty), 0)
    INTO v_requested_count, v_requested_total
    FROM (
      SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
             SUM((x ->> 'qty')::NUMERIC) AS qty
        FROM jsonb_array_elements(p_items) AS x
       GROUP BY (x ->> 'campaign_item_id')::BIGINT
    ) req;

  IF v_requested_count = 0 OR v_requested_total <= 0 THEN
    RAISE EXCEPTION 'items required';
  END IF;

  SELECT COALESCE(SUM(coi.qty), 0)
    INTO v_total_sold
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE co.tenant_id = p_tenant
     AND co.campaign_id = p_campaign_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND coi.status NOT IN ('cancelled', 'expired')
     AND COALESCE(co.order_kind, 'normal') = 'normal';

  IF COALESCE(v_campaign.total_cap_qty, 0) > 0
     AND v_total_sold + v_requested_total > v_campaign.total_cap_qty THEN
    RAISE EXCEPTION 'sold out';
  END IF;

  FOR v_req IN
    SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
           SUM((x ->> 'qty')::NUMERIC) AS qty
      FROM jsonb_array_elements(p_items) AS x
     GROUP BY (x ->> 'campaign_item_id')::BIGINT
  LOOP
    SELECT id, sku_id, unit_price, cap_qty
      INTO v_ci
      FROM campaign_items
     WHERE tenant_id = p_tenant
       AND campaign_id = p_campaign_id
       AND id = v_req.campaign_item_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'campaign item not found';
    END IF;

    SELECT COALESCE(SUM(coi.qty), 0)
      INTO v_item_sold
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE co.tenant_id = p_tenant
       AND co.campaign_id = p_campaign_id
       AND coi.campaign_item_id = v_req.campaign_item_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND coi.status NOT IN ('cancelled', 'expired')
       AND COALESCE(co.order_kind, 'normal') = 'normal';

    IF COALESCE(v_ci.cap_qty, 0) > 0 AND v_item_sold + v_req.qty > v_ci.cap_qty THEN
      RAISE EXCEPTION 'item sold out';
    END IF;
  END LOOP;

  SELECT id, order_no
    INTO v_order_id, v_order_no
    FROM customer_orders
   WHERE tenant_id = p_tenant
     AND campaign_id = p_campaign_id
     AND channel_id = p_channel_id
     AND member_id = p_member_id
     AND COALESCE(order_kind, 'normal') = 'normal'
     AND status NOT IN ('cancelled', 'expired', 'transferred_out')
   FOR UPDATE;

  IF v_order_id IS NULL THEN
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = p_tenant
       AND campaign_id = p_campaign_id;
    v_order_no := v_campaign.campaign_no || '-' || lpad(v_seq::TEXT, 4, '0');

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      nickname_snapshot, pickup_store_id, status, order_kind, notes
    ) VALUES (
      p_tenant, v_order_no, p_campaign_id, p_channel_id, p_member_id,
      v_member.name, p_pickup_store_id, 'pending', 'normal', NULLIF(p_notes, '')
    )
    RETURNING id INTO v_order_id;
  ELSE
    UPDATE customer_orders
       SET nickname_snapshot = COALESCE(v_member.name, nickname_snapshot),
           pickup_store_id = p_pickup_store_id,
           notes = NULLIF(p_notes, ''),
           updated_at = NOW()
     WHERE id = v_order_id;
  END IF;

  FOR v_req IN
    SELECT (x ->> 'campaign_item_id')::BIGINT AS campaign_item_id,
           SUM((x ->> 'qty')::NUMERIC) AS qty
      FROM jsonb_array_elements(p_items) AS x
     GROUP BY (x ->> 'campaign_item_id')::BIGINT
  LOOP
    SELECT sku_id, unit_price
      INTO v_ci
      FROM campaign_items
     WHERE tenant_id = p_tenant
       AND campaign_id = p_campaign_id
       AND id = v_req.campaign_item_id;

    SELECT qty INTO v_existing_qty
      FROM customer_order_items
     WHERE order_id = v_order_id
       AND campaign_item_id = v_req.campaign_item_id
     FOR UPDATE;

    IF v_existing_qty IS NULL THEN
      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status, source
      ) VALUES (
        p_tenant, v_order_id, v_req.campaign_item_id, v_ci.sku_id, v_req.qty, v_ci.unit_price, 'pending', v_source
      );
    ELSE
      UPDATE customer_order_items
         SET qty = v_existing_qty + v_req.qty,
             source = v_source,
             updated_at = NOW()
       WHERE order_id = v_order_id
         AND campaign_item_id = v_req.campaign_item_id;
    END IF;
  END LOOP;

  order_id := v_order_id;
  order_no := v_order_no;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_place_member_order_guarded(UUID, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_place_member_order_guarded(UUID, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, TEXT, TEXT) TO service_role;

COMMENT ON FUNCTION public.rpc_place_member_order_guarded(UUID, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, TEXT, TEXT) IS
  'Service-role member order writer for LIFF/PWA. Locks campaign, checks total/item caps, and writes order/items atomically.';

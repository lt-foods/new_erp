-- Allow mobile quick-control to reopen a closed campaign even when it already
-- has purchase-request linkage. Later PR creation already creates deltas only.

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
      PERFORM 1 FROM campaign_items WHERE campaign_id = p_campaign_id LIMIT 1;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'campaign % has no items', p_campaign_id;
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

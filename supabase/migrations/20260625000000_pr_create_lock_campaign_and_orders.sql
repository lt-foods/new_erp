-- ============================================================
-- Stage 4 — 請購單建立時自動鎖團 + auto-confirm 訂單
--
-- 設計:
--   PR 建立的瞬間,把所屬 closed campaigns 推進到 locked,
--   並把那些 campaigns 下的所有 pending 訂單自動推進到 confirmed,
--   寫 audit log 記錄 "auto-confirmed by PR #N"。
--
--   觸發點(兩條 PR 建立路徑):
--     1. rpc_create_pr_from_close_date — 結單日批次建 PR
--     2. rpc_append_campaign_to_pr — 後追加 campaign 到既有 PR
--
--   故意排除:
--     - rpc_approve_restock_to_pr (補貨單 PR,訂單不在 pending)
--     - 任何直接 INSERT INTO purchase_requests 的 ad-hoc script
--
-- 本 migration 內容:
--   1. 擴充 customer_order_audit_log CHECK 加 'qty' (Stage 3 依賴) 與 'status' (本 stage)
--   2. 新 helper _lock_orders_after_pr_aggregation
--   3. CREATE OR REPLACE rpc_create_pr_from_close_date (尾巴加 lock 邏輯)
--   4. CREATE OR REPLACE rpc_append_campaign_to_pr (尾巴加 lock 邏輯)
-- ============================================================

-- ----------------------------------------------------------------
-- 1. 擴充 customer_order_audit_log_field_check
--    Stage 3 的 rpc_update_order_item_qty 寫 field='qty'
--    本 stage 的 _lock_orders_after_pr_aggregation 寫 field='status'
--    現有 CHECK 不含這兩個值,需擴充
-- ----------------------------------------------------------------
ALTER TABLE customer_order_audit_log DROP CONSTRAINT customer_order_audit_log_field_check;
ALTER TABLE customer_order_audit_log
  ADD CONSTRAINT customer_order_audit_log_field_check
    CHECK (field IN (
      'unit_price','item_notes','item_discount_amount','item_discount_percent',
      'discount_amount','discount_percent','order_notes',
      'qty',     -- Stage 3 (店家改 qty)
      'status'   -- Stage 4 (PR auto-confirm)
    ));

-- ----------------------------------------------------------------
-- 2. helper:_lock_orders_after_pr_aggregation
--    把指定 campaigns 下的所有 pending 訂單推進到 confirmed,寫稽核
--    不開放 GRANT,只給內部 RPC 用
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._lock_orders_after_pr_aggregation(
  p_campaign_ids BIGINT[],
  p_operator     UUID,
  p_pr_id        BIGINT
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_count  INTEGER := 0;
  r        RECORD;
BEGIN
  IF p_campaign_ids IS NULL OR array_length(p_campaign_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT id FROM customer_orders
     WHERE tenant_id   = v_tenant
       AND campaign_id = ANY(p_campaign_ids)
       AND status      = 'pending'
     FOR UPDATE
  LOOP
    UPDATE customer_orders
       SET status       = 'confirmed',
           confirmed_at = NOW(),
           updated_by   = p_operator,
           updated_at   = NOW()
     WHERE id = r.id;

    INSERT INTO customer_order_audit_log
      (tenant_id, order_id, entity_type, entity_id, field,
       before_value, after_value, edit_reason, operator_id)
    VALUES
      (v_tenant, r.id, 'order', NULL, 'status',
       to_jsonb('pending'::text), to_jsonb('confirmed'::text),
       format('auto-confirmed by PR #%s', p_pr_id),
       p_operator);

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public._lock_orders_after_pr_aggregation IS
  'PR 建立時自動把 campaigns 下的 pending 訂單推進到 confirmed,寫 audit log。'
  '內部 helper,不開 GRANT;由 rpc_create_pr_from_close_date / rpc_append_campaign_to_pr 呼叫';

-- ----------------------------------------------------------------
-- 3. rpc_create_pr_from_close_date:尾巴加鎖團 + 鎖訂單
--    完整 replace(20260614000010 版本之上加 step 5/6)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_close_date(p_close_date date, p_operator uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_pr_id          BIGINT;
  v_pr_no          TEXT;
  v_dest_loc       BIGINT;
  v_campaign_count INTEGER;
  v_demand_count   INTEGER;
  v_campaign_ids   BIGINT[];
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

  -- sync purchase_request_campaigns join 表
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_pr_id, gbc.id, v_tenant
    FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = v_tenant
     AND gbc.status = 'closed'
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  -- *** Stage 4 新增:鎖團 + auto-confirm 訂單 ***
  WITH locked_campaigns AS (
    UPDATE group_buy_campaigns
       SET status     = 'locked',
           updated_by = p_operator,
           updated_at = NOW()
     WHERE tenant_id = v_tenant
       AND status = 'closed'
       AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
    RETURNING id
  )
  SELECT array_agg(id) INTO v_campaign_ids FROM locked_campaigns;

  PERFORM public._lock_orders_after_pr_aggregation(v_campaign_ids, p_operator, v_pr_id);

  RETURN v_pr_id;
END;
$function$;

COMMENT ON FUNCTION public.rpc_create_pr_from_close_date IS
  '從結單日彙總所有 closed campaigns 建立 PR;'
  '尾巴自動把這些 campaigns 推進到 locked、把 pending 訂單推進到 confirmed(寫稽核)';

-- ----------------------------------------------------------------
-- 4. rpc_append_campaign_to_pr:尾巴加鎖團 + 鎖訂單
--    完整 replace(20260614000010 版本之上加最後一段)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_append_campaign_to_pr(p_pr_id bigint, p_campaign_id bigint, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant      UUID;
  v_pr_status   TEXT;
  v_pr_close_date DATE;
  v_camp_status TEXT;
  v_camp_close_date DATE;
  v_camp_tenant UUID;
  v_inserted    INTEGER := 0;
  v_updated     INTEGER := 0;
  v_demand RECORD;
BEGIN
  SELECT tenant_id, status, source_close_date
    INTO v_tenant, v_pr_status, v_pr_close_date
    FROM purchase_requests
   WHERE id = p_pr_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PR % not found', p_pr_id;
  END IF;

  IF v_pr_status <> 'draft' THEN
    RAISE EXCEPTION 'PR % is not in draft status (current: %); cannot append',
      p_pr_id, v_pr_status;
  END IF;

  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei')
    INTO v_camp_tenant, v_camp_status, v_camp_close_date
    FROM group_buy_campaigns
   WHERE id = p_campaign_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_camp_tenant <> v_tenant THEN
    RAISE EXCEPTION 'tenant mismatch';
  END IF;

  IF v_camp_status <> 'closed' THEN
    RAISE EXCEPTION 'campaign % not in closed status (current: %)',
      p_campaign_id, v_camp_status;
  END IF;

  IF v_pr_close_date IS NOT NULL AND v_camp_close_date <> v_pr_close_date THEN
    RAISE EXCEPTION 'close_date mismatch: PR=%, campaign=%',
      v_pr_close_date, v_camp_close_date;
  END IF;

  FOR v_demand IN
    SELECT
      coi.sku_id,
      SUM(coi.qty) AS qty_total
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.campaign_id = p_campaign_id
       AND co.tenant_id = v_tenant
       AND co.status NOT IN ('cancelled','expired')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id
  LOOP
    UPDATE purchase_request_items
       SET qty_requested = qty_requested + v_demand.qty_total,
           updated_by = p_operator
     WHERE pr_id = p_pr_id AND sku_id = v_demand.sku_id;

    IF FOUND THEN
      v_updated := v_updated + 1;
    ELSE
      INSERT INTO purchase_request_items (
        pr_id, sku_id, qty_requested,
        suggested_supplier_id, unit_cost,
        retail_price, franchise_price,
        source_campaign_id,
        created_by, updated_by
      )
      SELECT
        p_pr_id, v_demand.sku_id, v_demand.qty_total,
        ss.supplier_id, COALESCE(ss.default_unit_cost, 0),
        pr_retail.price, pr_franchise.price,
        p_campaign_id, p_operator, p_operator
      FROM (SELECT 1) dummy
      LEFT JOIN LATERAL (
        SELECT supplier_id, default_unit_cost
          FROM supplier_skus
         WHERE tenant_id = v_tenant
           AND sku_id = v_demand.sku_id
           AND is_preferred = TRUE
         LIMIT 1
      ) ss ON TRUE
      LEFT JOIN LATERAL (
        SELECT price FROM prices
         WHERE sku_id = v_demand.sku_id AND scope = 'retail'
         ORDER BY effective_from DESC NULLS LAST
         LIMIT 1
      ) pr_retail ON TRUE
      LEFT JOIN LATERAL (
        SELECT price FROM prices
         WHERE sku_id = v_demand.sku_id AND scope = 'franchise'
         ORDER BY effective_from DESC NULLS LAST
         LIMIT 1
      ) pr_franchise ON TRUE;

      v_inserted := v_inserted + 1;
    END IF;
  END LOOP;

  -- sync purchase_request_campaigns join 表
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (p_pr_id, p_campaign_id, v_tenant)
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = p_pr_id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id = p_pr_id;

  -- *** Stage 4 新增:鎖該 campaign + auto-confirm 訂單 ***
  UPDATE group_buy_campaigns
     SET status     = 'locked',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_campaign_id AND status = 'closed';

  PERFORM public._lock_orders_after_pr_aggregation(
    ARRAY[p_campaign_id], p_operator, p_pr_id
  );

  RETURN jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
END;
$function$;

COMMENT ON FUNCTION public.rpc_append_campaign_to_pr IS
  '把指定 closed campaign 併入既有 draft PR;'
  '尾巴自動把該 campaign 推進到 locked、把 pending 訂單推進到 confirmed(寫稽核)';

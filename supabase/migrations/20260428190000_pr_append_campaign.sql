-- ============================================================
-- 補上同日結單但晚於 PR 建立的 campaign：
-- A. 新 RPC rpc_append_campaign_to_pr — 把指定 campaign 的需求 append 進指定 PR
-- B. rpc_close_campaign 升級：PR 已存在且還在 draft → 自動 append；
--    否則保留原行為（記錄 reason）
-- ============================================================

-- ============================================================
-- A. rpc_append_campaign_to_pr
--    - 守衛：PR 必須屬同 tenant；campaign 必須 status='closed' 且同 tenant
--    - 同 SKU 已存在 → qty_requested 累加
--    - 新 SKU → INSERT 含 supplier / cost / 售價分店價 snapshot
--    - 重算 PR.total_amount
--    - 回傳 (inserted, updated) 數
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_append_campaign_to_pr(
  p_pr_id       BIGINT,
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
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
  -- 載入 PR
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

  -- 載入 campaign
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

  -- 對每個 sku：合併 or 新增
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
    -- 嘗試累加既有 row
    UPDATE purchase_request_items
       SET qty_requested = qty_requested + v_demand.qty_total,
           updated_by = p_operator
     WHERE pr_id = p_pr_id AND sku_id = v_demand.sku_id;

    IF FOUND THEN
      v_updated := v_updated + 1;
    ELSE
      -- 新 SKU：抓 preferred supplier / cost + 售價/分店價 snapshot 後 INSERT
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

  -- 重算 total_amount
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = p_pr_id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id = p_pr_id;

  RETURN jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_append_campaign_to_pr TO authenticated;

COMMENT ON FUNCTION public.rpc_append_campaign_to_pr IS
  '把指定 campaign 的需求 append 進指定 PR（PR 必須 draft、同 close_date）';

-- ============================================================
-- B. rpc_close_campaign 升級
--    PR 已存在 + draft → 自動 append；非 draft → 保留 skip 行為
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_close_campaign(BIGINT, UUID);

CREATE OR REPLACE FUNCTION public.rpc_close_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant         UUID;
  v_status         TEXT;
  v_close_date     DATE;
  v_other_open_count INTEGER;
  v_existing_pr_id BIGINT;
  v_existing_pr_status TEXT;
  v_new_pr_id      BIGINT;
  v_new_pr_no      TEXT;
  v_append_result  JSONB;
BEGIN
  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei')
    INTO v_tenant, v_status, v_close_date
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'campaign % not in open status (current: %)', p_campaign_id, v_status;
  END IF;

  -- 1. 切 status
  UPDATE group_buy_campaigns
     SET status = 'closed',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_campaign_id;

  -- 2. 找該 close_date 是否已有 PR
  SELECT id, status INTO v_existing_pr_id, v_existing_pr_status
    FROM purchase_requests
   WHERE tenant_id = v_tenant
     AND source_type = 'close_date'
     AND source_close_date = v_close_date
     AND status <> 'cancelled'
   LIMIT 1;

  IF v_existing_pr_id IS NOT NULL THEN
    -- PR 在 draft → 自動 append 此 campaign 商品
    IF v_existing_pr_status = 'draft' THEN
      BEGIN
        v_append_result := public.rpc_append_campaign_to_pr(
          v_existing_pr_id, p_campaign_id, p_operator
        );
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', v_existing_pr_id,
          'action', 'appended',
          'append', v_append_result
        );
      EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object(
          'closed', true,
          'pr_id', v_existing_pr_id,
          'action', 'append_failed',
          'reason', SQLERRM
        );
      END;
    ELSE
      -- 已送審 / 已轉單 → 不動，提示前端讓人工處理
      RETURN jsonb_build_object(
        'closed', true,
        'pr_id', v_existing_pr_id,
        'action', 'skipped_pr_locked',
        'pr_status', v_existing_pr_status,
        'reason', 'PR exists but already submitted; manual append required'
      );
    END IF;
  END IF;

  -- 3. 還有其他 open campaign 在同 close_date → 先不建 PR
  SELECT COUNT(*) INTO v_other_open_count
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status = 'open'
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = v_close_date
     AND id <> p_campaign_id;

  IF v_other_open_count > 0 OR v_close_date IS NULL THEN
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', NULL, 'action', 'deferred',
      'reason', 'other open campaigns exist on close_date'
    );
  END IF;

  -- 4. auto-create PR
  BEGIN
    v_new_pr_id := public.rpc_create_pr_from_close_date(v_close_date, p_operator);
    SELECT pr_no INTO v_new_pr_no FROM purchase_requests WHERE id = v_new_pr_id;
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', v_new_pr_id, 'pr_no', v_new_pr_no, 'action', 'created'
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'closed', true, 'pr_id', NULL, 'action', 'create_failed', 'reason', SQLERRM
    );
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_close_campaign TO authenticated;

COMMENT ON FUNCTION public.rpc_close_campaign IS
  '結單：切 closed；同日已有 PR 且 draft → 自動 append；無 PR + 該日全結 → 自動建 PR';

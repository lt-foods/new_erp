-- ============================================================
-- Workflow 收尾：3 個關鍵阻斷補上
-- A1. rpc_close_campaign — 該日最後一個 campaign 關閉時自動建 PR
-- A2. rpc_finalize_campaign — 所有顧客訂單結案後 campaign 轉 completed
-- A3. v_pickup_reconcile view — 揀貨數 vs 取貨數對帳
-- ============================================================

-- ============================================================
-- A1. rpc_close_campaign 升級
--   - 切 status open → closed
--   - 若該 close_date 沒有其他 open campaign + 無 active PR → auto-create PR
--   - 回傳 jsonb { closed: true, pr_id: NULL|BIGINT, pr_no: NULL|text }
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_close_campaign(BIGINT, UUID);

CREATE OR REPLACE FUNCTION public.rpc_close_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant       UUID;
  v_status       TEXT;
  v_close_date   DATE;
  v_other_open_count INTEGER;
  v_existing_pr_id   BIGINT;
  v_new_pr_id    BIGINT;
  v_new_pr_no    TEXT;
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

  -- 2. 若該 close_date 還有別的 open campaign，先不產 PR
  SELECT COUNT(*) INTO v_other_open_count
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status = 'open'
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = v_close_date
     AND id <> p_campaign_id;

  IF v_other_open_count > 0 OR v_close_date IS NULL THEN
    RETURN jsonb_build_object('closed', true, 'pr_id', NULL, 'pr_no', NULL,
                              'reason', 'other open campaigns exist on close_date');
  END IF;

  -- 3. 已有 active PR → 不重建
  SELECT id INTO v_existing_pr_id
    FROM purchase_requests
   WHERE tenant_id = v_tenant
     AND source_type = 'close_date'
     AND source_close_date = v_close_date
     AND status <> 'cancelled'
   LIMIT 1;

  IF v_existing_pr_id IS NOT NULL THEN
    RETURN jsonb_build_object('closed', true, 'pr_id', v_existing_pr_id,
                              'reason', 'PR already exists');
  END IF;

  -- 4. auto-create PR（reuse rpc_create_pr_from_close_date）
  --    若無 customer_orders 會 RAISE，這時退回 closed=true / pr_id=NULL（捕捉異常）
  BEGIN
    v_new_pr_id := public.rpc_create_pr_from_close_date(v_close_date, p_operator);
    SELECT pr_no INTO v_new_pr_no FROM purchase_requests WHERE id = v_new_pr_id;
    RETURN jsonb_build_object('closed', true, 'pr_id', v_new_pr_id, 'pr_no', v_new_pr_no);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('closed', true, 'pr_id', NULL, 'pr_no', NULL,
                              'reason', SQLERRM);
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_close_campaign TO authenticated;

COMMENT ON FUNCTION public.rpc_close_campaign IS
  '結單：campaign open→closed；若該日最後一個 open campaign 結束 → 自動建 PR';

-- ============================================================
-- A2. rpc_finalize_campaign — 整單結算
--   - 守衛：所有 customer_orders 必須是 completed / expired / cancelled
--   - 切 campaign.status = 'completed'
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_finalize_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_status      TEXT;
  v_open_orders INTEGER;
BEGIN
  SELECT status INTO v_status
    FROM group_buy_campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_status NOT IN ('closed','ordered','receiving','ready') THEN
    RAISE EXCEPTION 'campaign % not in finalizable status (current: %)', p_campaign_id, v_status;
  END IF;

  -- 守衛：仍有未結案的顧客訂單
  SELECT COUNT(*) INTO v_open_orders
    FROM customer_orders
   WHERE campaign_id = p_campaign_id
     AND status NOT IN ('completed','expired','cancelled');

  IF v_open_orders > 0 THEN
    RAISE EXCEPTION 'campaign % has % unfinished customer orders', p_campaign_id, v_open_orders;
  END IF;

  UPDATE group_buy_campaigns
     SET status = 'completed',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_campaign_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_finalize_campaign TO authenticated;

COMMENT ON FUNCTION public.rpc_finalize_campaign IS
  '整單結算：所有顧客訂單結案後 campaign 轉 completed';

-- ============================================================
-- A3. v_pickup_reconcile — 揀貨 vs 取貨對帳 view
--   - per (campaign, sku, store)：picked_qty vs picked_up_qty
--   - 顯示差異（短少 / 超過 / 一致）
-- ============================================================

CREATE OR REPLACE VIEW public.v_pickup_reconcile AS
WITH wave_picked AS (
  SELECT
    pwi.campaign_id,
    pwi.sku_id,
    pwi.store_id,
    SUM(COALESCE(pwi.picked_qty, 0)) AS picked_qty
  FROM picking_wave_items pwi
  WHERE pwi.campaign_id IS NOT NULL
  GROUP BY pwi.campaign_id, pwi.sku_id, pwi.store_id
),
customer_received AS (
  SELECT
    co.campaign_id,
    coi.sku_id,
    co.pickup_store_id AS store_id,
    SUM(CASE WHEN coi.status IN ('picked_up','partially_picked_up') THEN coi.qty ELSE 0 END) AS received_qty,
    co.tenant_id
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  GROUP BY co.campaign_id, coi.sku_id, co.pickup_store_id, co.tenant_id
)
SELECT
  COALESCE(wp.campaign_id, cr.campaign_id) AS campaign_id,
  COALESCE(wp.sku_id, cr.sku_id)           AS sku_id,
  COALESCE(wp.store_id, cr.store_id)       AS store_id,
  cr.tenant_id,
  COALESCE(wp.picked_qty, 0)   AS picked_qty,
  COALESCE(cr.received_qty, 0) AS received_qty,
  COALESCE(wp.picked_qty, 0) - COALESCE(cr.received_qty, 0) AS diff,
  CASE
    WHEN COALESCE(wp.picked_qty, 0) = COALESCE(cr.received_qty, 0) THEN 'match'
    WHEN COALESCE(wp.picked_qty, 0) > COALESCE(cr.received_qty, 0) THEN 'short_pickup'
    ELSE 'over_pickup'
  END AS reconcile_status
FROM wave_picked wp
FULL OUTER JOIN customer_received cr
  ON cr.campaign_id = wp.campaign_id
 AND cr.sku_id = wp.sku_id
 AND cr.store_id = wp.store_id;

COMMENT ON VIEW public.v_pickup_reconcile IS
  '揀貨 vs 取貨對帳：per (campaign, sku, store) 比 picking_wave_items.picked_qty vs customer 已取貨數';

GRANT SELECT ON public.v_pickup_reconcile TO authenticated;

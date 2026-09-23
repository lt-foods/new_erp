-- ============================================================================
-- 2026-09-23: 結單日待開單也走同團 + SKU 差額邏輯
-- ----------------------------------------------------------------------------
-- #982 已修「補單」與「針對團購建單」，但「結單日待開單」仍呼叫
-- rpc_create_pr_from_close_date。原團延長結單日後，舊 PR 還是草稿時，
-- 舊函式會把同一團全量重開第二張 PR。
--
-- 本刀只重建舊入口本身：
--   * 用 _pr_campaign_sku_remaining_rows 算同團 + SKU 剩餘未請購量。
--   * 找得到可改的舊草稿品項時，直接把差額加回舊草稿。
--   * 找不到可改草稿時，才新增差額 PR。
--   * 仍保留結單日建單原本的鎖團、鎖訂單行為。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_close_date(
  p_close_date DATE,
  p_operator   UUID
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_pr_id          BIGINT;
  v_pr_no          TEXT;
  v_dest_loc       BIGINT;
  v_campaign_count INTEGER;
  v_delta_count    INTEGER;
  v_campaign_ids   BIGINT[];
  v_all_campaign_ids BIGINT[];
  v_touched_pr_id  BIGINT;
BEGIN
  SELECT array_agg(id ORDER BY id), COUNT(*)
    INTO v_campaign_ids, v_campaign_count
    FROM public.group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status IN ('closed','locked')
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = p_close_date;

  IF v_campaign_count = 0 THEN
    RAISE EXCEPTION 'no closed/locked campaigns on date %', p_close_date;
  END IF;

  v_all_campaign_ids := v_campaign_ids;

  SELECT id INTO v_dest_loc
    FROM public.locations
   WHERE tenant_id = v_tenant
   ORDER BY id
   LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined for tenant %', v_tenant;
  END IF;

  PERFORM 1
    FROM public.group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND id = ANY(v_campaign_ids)
   ORDER BY id
   FOR UPDATE;

  DROP TABLE IF EXISTS _close_pr_delta;
  CREATE TEMP TABLE _close_pr_delta ON COMMIT DROP AS
  SELECT *
    FROM public._pr_campaign_sku_remaining_rows(v_campaign_ids)
   WHERE delta_qty > 0;

  SELECT COUNT(*) INTO v_delta_count FROM _close_pr_delta;

  IF v_delta_count = 0 THEN
    RAISE EXCEPTION 'no remaining demand to create PR for close_date % (前次請購已涵蓋全部需求)', p_close_date;
  END IF;

  -- 草稿可改就改舊草稿，避免延長結單日後同一團同商品被拆成兩張 PR。
  DROP TABLE IF EXISTS _close_pr_target;
  CREATE TEMP TABLE _close_pr_target ON COMMIT DROP AS
  WITH candidates AS (
    SELECT
      d.campaign_id,
      d.sku_id,
      d.delta_qty,
      pri.id AS pr_item_id,
      pri.pr_id,
      pric.qty_requested AS current_campaign_qty,
      0 AS priority,
      pr.updated_at
    FROM _close_pr_delta d
    JOIN public.purchase_request_item_campaigns pric
      ON pric.campaign_id = d.campaign_id
    JOIN public.purchase_request_items pri
      ON pri.id = pric.pr_item_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    WHERE pr.tenant_id = v_tenant
      AND pric.tenant_id = v_tenant
      AND pr.status = 'draft'

    UNION ALL

    SELECT
      d.campaign_id,
      d.sku_id,
      d.delta_qty,
      pri.id AS pr_item_id,
      pri.pr_id,
      pri.qty_requested AS current_campaign_qty,
      1 AS priority,
      pr.updated_at
    FROM _close_pr_delta d
    JOIN public.purchase_request_items pri
      ON pri.source_campaign_id = d.campaign_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    WHERE pr.tenant_id = v_tenant
      AND pr.status = 'draft'
      AND NOT EXISTS (
        SELECT 1
          FROM public.purchase_request_item_campaigns pric
         WHERE pric.pr_item_id = pri.id
           AND pric.campaign_id = d.campaign_id
      )
  ),
  target AS (
    SELECT DISTINCT ON (c.campaign_id, c.sku_id)
      c.campaign_id,
      c.sku_id,
      c.delta_qty,
      c.pr_item_id,
      c.pr_id,
      c.current_campaign_qty
    FROM candidates c
    ORDER BY c.campaign_id, c.sku_id, c.priority, c.updated_at DESC, c.pr_item_id DESC
  )
  SELECT
    campaign_id,
    sku_id,
    delta_qty,
    pr_item_id,
    pr_id,
    current_campaign_qty
  FROM target;

  INSERT INTO public.purchase_request_item_campaigns (
    pr_item_id, campaign_id, tenant_id, qty_requested
  )
  SELECT
    pr_item_id,
    campaign_id,
    v_tenant,
    current_campaign_qty + delta_qty
    FROM _close_pr_target
  ON CONFLICT (pr_item_id, campaign_id) DO UPDATE
     SET qty_requested = EXCLUDED.qty_requested;

  WITH item_delta AS (
    SELECT pr_item_id, pr_id, SUM(delta_qty) AS delta_qty
      FROM _close_pr_target
     GROUP BY pr_item_id, pr_id
  )
  UPDATE public.purchase_request_items pri
     SET qty_requested = pri.qty_requested + item_delta.delta_qty,
         updated_by = p_operator,
         updated_at = NOW()
    FROM item_delta
   WHERE pri.id = item_delta.pr_item_id;

  DROP TABLE IF EXISTS _close_pr_applied;
  CREATE TEMP TABLE _close_pr_applied ON COMMIT DROP AS
  SELECT
    campaign_id,
    sku_id,
    pr_item_id,
    pr_id,
    current_campaign_qty + delta_qty AS qty_requested
  FROM _close_pr_target;

  INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT pr_id, campaign_id, v_tenant
    FROM _close_pr_applied
   GROUP BY pr_id, campaign_id
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM public.purchase_request_items WHERE pr_id = pr.id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id IN (SELECT pr_id FROM _close_pr_applied);

  DELETE FROM _close_pr_delta d
    USING _close_pr_applied a
   WHERE a.campaign_id = d.campaign_id
     AND a.sku_id = d.sku_id;

  SELECT MIN(pr_id)
    INTO v_touched_pr_id
    FROM _close_pr_applied;

  SELECT COUNT(*) INTO v_delta_count FROM _close_pr_delta;

  IF v_delta_count = 0 THEN
    UPDATE public.group_buy_campaigns
       SET status = 'locked',
           updated_by = p_operator,
           updated_at = NOW()
     WHERE tenant_id = v_tenant
       AND status = 'closed'
       AND id = ANY(v_all_campaign_ids);

    PERFORM public._lock_orders_after_pr_aggregation(v_all_campaign_ids, p_operator, v_touched_pr_id);

    RETURN v_touched_pr_id;
  END IF;

  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO public.purchase_requests (
    tenant_id, pr_no, source_type, source_close_date,
    source_location_id, status, total_amount, notes,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'close_date', p_close_date,
    v_dest_loc, 'draft', 0,
    format('結單日 %s（同團+SKU 只帶尚未請購差額）', p_close_date),
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  WITH inserted AS (
    INSERT INTO public.purchase_request_items (
      pr_id, sku_id, qty_requested,
      suggested_supplier_id, unit_cost, source_campaign_id,
      created_by, updated_by
    )
    SELECT
      v_pr_id,
      d.sku_id,
      SUM(d.delta_qty) AS qty_requested,
      ss.supplier_id,
      COALESCE(ss.default_unit_cost, 0),
      CASE WHEN COUNT(DISTINCT d.campaign_id) = 1 THEN MIN(d.campaign_id) ELSE NULL::BIGINT END,
      p_operator,
      p_operator
    FROM _close_pr_delta d
    LEFT JOIN LATERAL (
      SELECT supplier_id, default_unit_cost
        FROM public.supplier_skus
       WHERE tenant_id = v_tenant
         AND sku_id = d.sku_id
         AND is_preferred = TRUE
       LIMIT 1
    ) ss ON TRUE
    GROUP BY d.sku_id, ss.supplier_id, ss.default_unit_cost
    RETURNING id, sku_id
  )
  INSERT INTO public.purchase_request_item_campaigns (
    pr_item_id, campaign_id, tenant_id, qty_requested
  )
  SELECT
    i.id,
    d.campaign_id,
    v_tenant,
    d.delta_qty
  FROM inserted i
  JOIN _close_pr_delta d
    ON d.sku_id = i.sku_id;

  INSERT INTO public.purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_pr_id, d.campaign_id, v_tenant
    FROM _close_pr_delta d
   GROUP BY d.campaign_id
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM public.purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  UPDATE public.group_buy_campaigns
     SET status = 'locked',
         updated_by = p_operator,
         updated_at = NOW()
     WHERE tenant_id = v_tenant
     AND status = 'closed'
     AND id = ANY(v_all_campaign_ids);

  PERFORM public._lock_orders_after_pr_aggregation(v_all_campaign_ids, p_operator, v_pr_id);

  RETURN v_pr_id;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_pr_from_close_date(DATE, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_pr_from_close_date(DATE, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_pr_from_close_date(DATE, UUID) IS
  '結單日建請購：以同團+SKU 扣掉未取消 PR 已請購量；舊品項仍是草稿且未拆 PO 時先更新舊草稿，否則新增差額 PR；保留鎖團與鎖訂單。';

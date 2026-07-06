-- ============================================================================
-- 2026-07-06: 結單日「補單」— 保留原請購單，另開一張只含新增未請購量的 PR
-- ----------------------------------------------------------------------------
-- 背景（使用者 2026-07-06 決策，選項 B）：
--   對某結單日建了請購單後，該日開團 closed→locked（20260625000000 鎖團），
--   所有建 PR 路徑（結單日待開單卡 / 針對團購建單 modal / rpc_create_pr_from_campaigns
--   守衛）都只吃 'closed'，導致「7/4 不能再建單」。實務上結單後仍需補單
--   （漏的品相 / 分張開單後的剩餘 / 解鎖後新加的訂單）。
--
--   要的行為：**保留原單，另開一張補單，只彙總「前次尚未請購的新增量」**：
--     delta(sku) = 該結單日目前訂單需求(sku)
--                − 該結單日所有『未取消 close_date PR』已請購量(sku)
--     只列 delta > 0 的 SKU。原單、已拆 PO 一律不動；已涵蓋的 SKU 自動歸零剔除，
--     避免重複下單。
--
-- 本 migration 內容：
--   1. rpc_create_supplementary_pr_from_close_date(p_close_date, p_operator) → 建補單
--   2. rpc_list_supplementable_close_dates() → 列「已建單但仍有 delta>0」的結單日
--      （前端「🔁 結單日補單」卡片資料源；delta 邏輯只留在 SQL，單一真相）
--
-- 基底 / 對齊：
--   - 建單彙總、鎖團尾巴 mirror rpc_create_pr_from_close_date 最新版（20260625000000）。
--   - 供應商帶入交給 trg_pri_fill_default_supplier（20260709000030）+ supplier_skus。
--   - join 表由 trg_pri_sync_campaigns（20260614000020）自動同步，另顯式補全日全部團。
--
-- 故意不動：rpc_create_pr_from_close_date / rpc_create_pr_from_campaigns /
--   rpc_append_campaign_to_pr / 鎖團語意 — 本檔只『新增』兩支函式，零 CREATE OR REPLACE 既有邏輯。
--
-- Rollback：
--   DROP FUNCTION public.rpc_create_supplementary_pr_from_close_date(DATE, UUID);
--   DROP FUNCTION public.rpc_list_supplementable_close_dates();
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 建補單：只含 delta>0 的品項
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_supplementary_pr_from_close_date(
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
BEGIN
  -- 守衛 1：該結單日要有 closed/locked 開團
  SELECT COUNT(*) INTO v_campaign_count
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status IN ('closed','locked')
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = p_close_date;

  IF v_campaign_count = 0 THEN
    RAISE EXCEPTION 'no closed/locked campaigns on date %', p_close_date;
  END IF;

  -- 守衛 2：必須已有一張未取消的 close_date PR（否則走正常建單，不是補單）
  IF NOT EXISTS (
    SELECT 1 FROM purchase_requests
     WHERE tenant_id = v_tenant
       AND source_type = 'close_date'
       AND source_close_date = p_close_date
       AND status <> 'cancelled'
  ) THEN
    RAISE EXCEPTION 'no existing PR for close_date % — use rpc_create_pr_from_close_date instead', p_close_date;
  END IF;

  SELECT id INTO v_dest_loc FROM locations
   WHERE tenant_id = v_tenant
   ORDER BY id LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined for tenant %', v_tenant;
  END IF;

  -- delta > 0 的品項（目前需求 − 該結單日所有未取消 PR 已請購量）先算進 temp，
  -- 空的話直接 RAISE，不浪費 pr_no 序號、也不留殘 header。
  CREATE TEMP TABLE _supp_delta ON COMMIT DROP AS
  WITH demand AS (
    SELECT
      coi.sku_id,
      SUM(coi.qty) AS qty,
      MIN(gbc.id)  AS first_campaign_id
      FROM group_buy_campaigns gbc
      JOIN customer_orders co ON co.campaign_id = gbc.id
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE gbc.tenant_id = v_tenant
       AND gbc.status IN ('closed','locked')
       AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
       AND co.status  NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id
  ),
  already AS (
    SELECT pri.sku_id, SUM(pri.qty_requested) AS qty
      FROM purchase_requests pr
      JOIN purchase_request_items pri ON pri.pr_id = pr.id
     WHERE pr.tenant_id = v_tenant
       AND pr.source_type = 'close_date'
       AND pr.source_close_date = p_close_date
       AND pr.status <> 'cancelled'
     GROUP BY pri.sku_id
  )
  SELECT
    d.sku_id,
    d.first_campaign_id,
    (d.qty - COALESCE(a.qty, 0)) AS delta_qty
    FROM demand d
    LEFT JOIN already a ON a.sku_id = d.sku_id
   WHERE (d.qty - COALESCE(a.qty, 0)) > 0;

  SELECT COUNT(*) INTO v_delta_count FROM _supp_delta;

  IF v_delta_count = 0 THEN
    -- 前次請購已涵蓋全部需求 → 無可補
    RAISE EXCEPTION 'no remaining demand to supplement for close_date % (前次請購已涵蓋全部需求)', p_close_date;
  END IF;

  -- PR header
  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date,
    source_location_id, status, total_amount, notes,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'close_date', p_close_date,
    v_dest_loc, 'draft', 0,
    format('補單：結單日 %s（僅新增未請購量，不含前次已請購）', p_close_date),
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested,
    suggested_supplier_id, unit_cost, source_campaign_id,
    created_by, updated_by
  )
  SELECT
    v_pr_id,
    dq.sku_id,
    dq.delta_qty,
    ss.supplier_id,
    COALESCE(ss.default_unit_cost, 0),
    dq.first_campaign_id,
    p_operator,
    p_operator
  FROM _supp_delta dq
  LEFT JOIN LATERAL (
    SELECT supplier_id, default_unit_cost
      FROM supplier_skus
     WHERE tenant_id = v_tenant
       AND sku_id = dq.sku_id
       AND is_preferred = TRUE
     LIMIT 1
  ) ss ON TRUE;

  -- join 表：補全該結單日所有 closed/locked 團（trigger 只補 first_campaign_id 那個）
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_pr_id, gbc.id, v_tenant
    FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = v_tenant
     AND gbc.status IN ('closed','locked')
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  -- total snapshot
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  -- 鎖團尾巴：把該結單日『尚 closed』的團（例：解鎖補單後）重新 lock + auto-confirm 其 pending 訂單。
  -- 已 locked 的團 WHERE status='closed' 不命中、不受影響。
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
$$;

REVOKE ALL ON FUNCTION public.rpc_create_supplementary_pr_from_close_date(DATE, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_supplementary_pr_from_close_date(DATE, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_supplementary_pr_from_close_date(DATE, UUID) IS
  '結單日補單：保留原請購單，另開一張只含 delta>0（目前需求 − 該結單日所有未取消 PR 已請購量）的 PR；'
  '守衛 = 該日已有未取消 close_date PR；尾巴把尚 closed 的團 lock + auto-confirm；'
  '前次已涵蓋全部需求則 RAISE、不留空單。';

-- ----------------------------------------------------------------------------
-- 2. 列出可補單的結單日（前端卡片資料源；delta 邏輯單一真相留 SQL）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_list_supplementable_close_dates()
RETURNS TABLE(
  close_date     DATE,
  campaign_count INTEGER,
  remaining_skus INTEGER,
  remaining_qty  NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH t AS (SELECT public._current_tenant_id() AS tid),
  demand AS (
    SELECT
      DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') AS d,
      coi.sku_id,
      SUM(coi.qty) AS qty
      FROM group_buy_campaigns gbc
      JOIN customer_orders co ON co.campaign_id = gbc.id
      JOIN customer_order_items coi ON coi.order_id = co.id
      CROSS JOIN t
     WHERE gbc.tenant_id = t.tid
       AND gbc.status IN ('closed','locked')
       AND gbc.end_at >= NOW() - INTERVAL '60 days'
       AND co.status  NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY 1, 2
  ),
  already AS (
    SELECT pr.source_close_date AS d, pri.sku_id, SUM(pri.qty_requested) AS qty
      FROM purchase_requests pr
      JOIN purchase_request_items pri ON pri.pr_id = pr.id
      CROSS JOIN t
     WHERE pr.tenant_id = t.tid
       AND pr.source_type = 'close_date'
       AND pr.source_close_date IS NOT NULL
       AND pr.status <> 'cancelled'
     GROUP BY 1, 2
  ),
  -- 只保留「已有未取消 close_date PR」的結單日
  dates_with_pr AS (
    SELECT DISTINCT pr.source_close_date AS d
      FROM purchase_requests pr
      CROSS JOIN t
     WHERE pr.tenant_id = t.tid
       AND pr.source_type = 'close_date'
       AND pr.source_close_date IS NOT NULL
       AND pr.status <> 'cancelled'
  ),
  delta AS (
    SELECT
      d.d,
      d.sku_id,
      (d.qty - COALESCE(a.qty, 0)) AS remaining
      FROM demand d
      JOIN dates_with_pr dwp ON dwp.d = d.d
      LEFT JOIN already a ON a.d = d.d AND a.sku_id = d.sku_id
  )
  SELECT
    del.d AS close_date,
    (SELECT COUNT(*)::INTEGER
       FROM group_buy_campaigns g CROSS JOIN t
      WHERE g.tenant_id = t.tid
        AND g.status IN ('closed','locked')
        AND DATE(g.end_at AT TIME ZONE 'Asia/Taipei') = del.d) AS campaign_count,
    COUNT(*) FILTER (WHERE del.remaining > 0)::INTEGER AS remaining_skus,
    COALESCE(SUM(del.remaining) FILTER (WHERE del.remaining > 0), 0) AS remaining_qty
  FROM delta del
  GROUP BY del.d
  HAVING COUNT(*) FILTER (WHERE del.remaining > 0) > 0
  ORDER BY del.d DESC;
$$;

REVOKE ALL ON FUNCTION public.rpc_list_supplementable_close_dates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_list_supplementable_close_dates() TO authenticated;

COMMENT ON FUNCTION public.rpc_list_supplementable_close_dates() IS
  '列近 60 天「已建 close_date PR 但仍有未請購量(delta>0)」的結單日；'
  '供前端「結單日補單」卡片；remaining_qty = Σ delta>0。';

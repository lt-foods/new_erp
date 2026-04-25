-- ============================================================================
-- v_pr_progress：給 PR 列表 / PO 列表 PR header 用的進度摘要
-- 一次查就有：每張 PR 的 PO 總數 / 已發送 / 已全收，以及對應 close_date 的 campaign 是否全部 finalized
-- ============================================================================

CREATE OR REPLACE VIEW public.v_pr_progress AS
SELECT
  pr.id   AS pr_id,
  pr.tenant_id,
  pr.source_close_date,
  COALESCE(po_agg.po_total, 0)          AS po_total,
  COALESCE(po_agg.po_sent, 0)           AS po_sent,
  COALESCE(po_agg.po_received_fully, 0) AS po_received_fully,
  CASE
    WHEN pr.source_close_date IS NULL THEN FALSE
    WHEN cmp.total_campaigns = 0 THEN FALSE
    ELSE cmp.completed_campaigns = cmp.total_campaigns
  END AS all_campaigns_finalized
FROM purchase_requests pr
LEFT JOIN LATERAL (
  SELECT
    COUNT(DISTINCT po.id)                                                         AS po_total,
    COUNT(DISTINCT po.id) FILTER (WHERE po.status IN ('sent','partially_received','fully_received','closed')) AS po_sent,
    COUNT(DISTINCT po.id) FILTER (WHERE po.status IN ('fully_received','closed')) AS po_received_fully
    FROM purchase_request_items pri
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
    JOIN purchase_orders po       ON po.id  = poi.po_id
   WHERE pri.pr_id = pr.id
) po_agg ON TRUE
LEFT JOIN LATERAL (
  SELECT
    COUNT(*)                                                AS total_campaigns,
    COUNT(*) FILTER (WHERE gbc.status = 'completed')        AS completed_campaigns
    FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = pr.tenant_id
     AND pr.source_close_date IS NOT NULL
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = pr.source_close_date
     AND gbc.status NOT IN ('cancelled')
) cmp ON TRUE;

GRANT SELECT ON public.v_pr_progress TO authenticated;

COMMENT ON VIEW public.v_pr_progress IS
  'PR 進度摘要：PO 收貨進度 + close_date 對應 campaigns 是否全部 finalized（給 stepper 用）';

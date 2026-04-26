-- v_pr_progress 補上 item_count + unassigned_supplier_count
-- 解決 PR 列表草稿 PR 顯示 $0 看起來像空單、實際裡面有內容、admin 不知道要進去填的問題。
--
-- 用 DROP + CREATE 是因為新欄位插在中間、CREATE OR REPLACE 不允許改欄位順序。

DROP VIEW IF EXISTS public.v_pr_progress;

CREATE VIEW public.v_pr_progress AS
SELECT
  pr.id   AS pr_id,
  pr.tenant_id,
  pr.source_close_date,
  COALESCE(po_agg.po_total, 0)          AS po_total,
  COALESCE(po_agg.po_sent, 0)           AS po_sent,
  COALESCE(po_agg.po_received_fully, 0) AS po_received_fully,
  COALESCE(xfer_agg.transfer_total, 0)     AS transfer_total,
  COALESCE(xfer_agg.transfer_shipped, 0)   AS transfer_shipped,
  COALESCE(xfer_agg.transfer_delivered, 0) AS transfer_delivered,
  COALESCE(item_agg.item_count, 0)               AS item_count,
  COALESCE(item_agg.unassigned_supplier_count, 0) AS unassigned_supplier_count,
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
    COUNT(DISTINCT t.id)                                                                  AS transfer_total,
    COUNT(DISTINCT t.id) FILTER (WHERE t.status IN ('shipped','received','closed'))       AS transfer_shipped,
    COUNT(DISTINCT t.id) FILTER (WHERE t.status IN ('received','closed'))                 AS transfer_delivered
    FROM group_buy_campaigns gbc
    JOIN picking_wave_items pwi ON pwi.campaign_id = gbc.id
    JOIN transfers t
      ON t.tenant_id      = gbc.tenant_id
     AND t.transfer_type  = 'hq_to_store'
     AND t.transfer_no LIKE 'WAVE-' || pwi.wave_id || '-S%'
   WHERE gbc.tenant_id = pr.tenant_id
     AND pr.source_close_date IS NOT NULL
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = pr.source_close_date
     AND gbc.status NOT IN ('cancelled')
) xfer_agg ON TRUE
LEFT JOIN LATERAL (
  SELECT
    COUNT(*)                                                       AS item_count,
    COUNT(*) FILTER (WHERE pri.suggested_supplier_id IS NULL)      AS unassigned_supplier_count
    FROM purchase_request_items pri
   WHERE pri.pr_id = pr.id
) item_agg ON TRUE
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
  'PR 進度摘要：PO / transfer / 品項數 / 未指派 supplier 數 / campaigns finalized';

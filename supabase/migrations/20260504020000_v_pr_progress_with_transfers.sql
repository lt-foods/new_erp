-- v_pr_progress 補上 transfer 統計：
--   transfer_total      該 PR 的 close_date 對應的 hq_to_store transfer 總數
--   transfer_shipped    其中 status >= shipped 的張數
--   transfer_delivered  其中 status = received 的張數
--
-- 路徑：PR.source_close_date = picking_waves.wave_date → 抓 wave.id
--       → transfers WHERE transfer_no LIKE 'WAVE-{wave.id}-S%' AND transfer_type='hq_to_store'
--
-- 為什麼 PR list 的 step 8 / step 9 一直是 pending：前端讀
-- p.transfer_total / transfer_shipped / transfer_delivered，但 v_pr_progress 沒這些欄位。
-- 補上後 timeline 才會跟著 wave 派貨 / 分店收貨更新。

CREATE OR REPLACE VIEW public.v_pr_progress AS
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
    COUNT(DISTINCT t.id)                                                                         AS transfer_total,
    COUNT(DISTINCT t.id) FILTER (WHERE t.status IN ('shipped','received','closed'))              AS transfer_shipped,
    COUNT(DISTINCT t.id) FILTER (WHERE t.status IN ('received','closed'))                        AS transfer_delivered
    FROM picking_waves pw
    JOIN transfers t
      ON t.tenant_id      = pw.tenant_id
     AND t.transfer_type  = 'hq_to_store'
     AND t.transfer_no LIKE 'WAVE-' || pw.id || '-S%'
   WHERE pw.tenant_id = pr.tenant_id
     AND pr.source_close_date IS NOT NULL
     AND pw.wave_date = pr.source_close_date
) xfer_agg ON TRUE
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
  'PR 進度摘要：PO 收貨進度 + 配送 transfer 進度 + close_date 對應 campaigns 是否全部 finalized（給 stepper 用）';

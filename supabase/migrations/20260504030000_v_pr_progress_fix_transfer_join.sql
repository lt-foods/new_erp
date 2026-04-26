-- v_pr_progress 的 transfer 統計用 wave_date == source_close_date join 是錯的，
-- 因為累積式撿貨單會把多個結單日的商品合到同一張 wave（wave_date 是配送日，
-- 不一定等於某張 PR 的 close_date）。
--
-- 正確路徑：
--   PR.source_close_date → group_buy_campaigns（DATE(end_at AT 'Asia/Taipei') = source_close_date）
--   → picking_wave_items.campaign_id IN (那些 campaign)
--   → picking_wave_items.wave_id
--   → transfers WHERE transfer_no LIKE 'WAVE-{wave_id}-S%' AND transfer_type='hq_to_store'
--
-- 改用 campaign_id 鏈路後，多 close_date 共用一張 wave 也能正確攤算：
-- 同一張 transfer 可能會被多個 PR 算到（各自結單日商品都在那張 wave 裡），
-- 這對 step 8/9 是合理的（兩個 PR 的「派貨」確實由同一張 transfer 處理）。

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
  -- 透過 PR close_date → campaign → picking_wave_items.campaign_id → wave → transfer
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
  'PR 進度摘要：PO 收貨進度 + 配送 transfer 進度（透過 campaign_id 鏈路，支援累積式 wave）';

-- ============================================================================
-- v_pr_progress: 修正 xfer_agg 跨 PR 串水
--
-- 問題：
--   原本 xfer_agg 用 `pr.source_close_date IS NOT NULL` 過濾，再算同日所有
--   campaigns 的 transfers。同日多張 PR（一張 close_date PR + 多張 campaign PR）
--   都會看到同一份 transfer 計數，導致 draft campaign PR 的「已派貨」步驟被誤亮。
--
-- 修正：
--   - campaign-type PR：只算 pwi.campaign_id = pr.source_campaign_id 的 wave。
--   - close_date PR：只算同日「未被其他 campaign PR 蓋掉」的 campaigns 的 wave
--     （避免重複計算）。
--   - manual / 其他：transfer_* = 0（沒 source_close_date / source_campaign_id 走得到）。
--
-- 行為一致性：
--   - PR.draft 沒有自己的 campaign 對應 wave → transfer_total=0 → 步驟回 pending（灰）。
--   - 既有 close_date PR 跟其同日 campaign PR 的計數互不重疊。
-- ============================================================================

DROP VIEW IF EXISTS public.v_pr_progress CASCADE;

CREATE OR REPLACE VIEW public.v_pr_progress AS
SELECT
  pr.id AS pr_id,
  pr.tenant_id,
  pr.source_close_date,
  COALESCE(po_agg.po_total, 0::bigint) AS po_total,
  COALESCE(po_agg.po_sent, 0::bigint) AS po_sent,
  COALESCE(po_agg.po_received_fully, 0::bigint) AS po_received_fully,
  COALESCE(xfer_agg.transfer_total, 0::bigint) AS transfer_total,
  COALESCE(xfer_agg.transfer_shipped, 0::bigint) AS transfer_shipped,
  COALESCE(xfer_agg.transfer_delivered, 0::bigint) AS transfer_delivered,
  COALESCE(item_agg.item_count, 0::bigint) AS item_count,
  COALESCE(item_agg.unassigned_supplier_count, 0::bigint) AS unassigned_supplier_count,
  CASE
    WHEN pr.source_close_date IS NULL THEN false
    WHEN cmp.total_campaigns = 0 THEN false
    ELSE cmp.completed_campaigns = cmp.total_campaigns
  END AS all_campaigns_finalized
FROM purchase_requests pr
LEFT JOIN LATERAL (
  SELECT
    count(DISTINCT po.id) AS po_total,
    count(DISTINCT po.id) FILTER (
      WHERE po.status = ANY (ARRAY['sent','partially_received','fully_received','closed'])
    ) AS po_sent,
    count(DISTINCT po.id) FILTER (
      WHERE po.status = ANY (ARRAY['fully_received','closed'])
    ) AS po_received_fully
  FROM purchase_request_items pri
  JOIN purchase_order_items poi ON poi.id = pri.po_item_id
  JOIN purchase_orders po ON po.id = poi.po_id
  WHERE pri.pr_id = pr.id
) po_agg ON true
LEFT JOIN LATERAL (
  -- 算 transfers：限縮到屬於這張 PR 的 campaigns
  SELECT
    count(DISTINCT t.id) AS transfer_total,
    count(DISTINCT t.id) FILTER (
      WHERE t.status = ANY (ARRAY['shipped','received','closed'])
    ) AS transfer_shipped,
    count(DISTINCT t.id) FILTER (
      WHERE t.status = ANY (ARRAY['received','closed'])
    ) AS transfer_delivered
  FROM picking_wave_items pwi
  JOIN transfers t
    ON t.tenant_id = pr.tenant_id
   AND t.transfer_type = 'hq_to_store'
   AND t.transfer_no LIKE 'WAVE-' || pwi.wave_id || '-S%'
  WHERE pwi.tenant_id = pr.tenant_id
    AND (
      -- campaign-type PR：只算自己 campaign 的
      (pr.source_type = 'campaign' AND pwi.campaign_id = pr.source_campaign_id)
      OR
      -- close_date PR：算同日 campaigns，但排除「已被 campaign PR 蓋掉的」避免重複
      (pr.source_type = 'close_date'
       AND pr.source_close_date IS NOT NULL
       AND EXISTS (
         SELECT 1
         FROM group_buy_campaigns gbc
         WHERE gbc.id = pwi.campaign_id
           AND gbc.tenant_id = pr.tenant_id
           AND date(gbc.end_at AT TIME ZONE 'Asia/Taipei') = pr.source_close_date
           AND gbc.status <> 'cancelled'
           AND NOT EXISTS (
             SELECT 1 FROM purchase_requests pr2
             WHERE pr2.tenant_id = pr.tenant_id
               AND pr2.source_type = 'campaign'
               AND pr2.source_campaign_id = gbc.id
               AND pr2.status <> 'cancelled'
           )
       ))
    )
) xfer_agg ON true
LEFT JOIN LATERAL (
  SELECT
    count(*) AS item_count,
    count(*) FILTER (WHERE pri.suggested_supplier_id IS NULL) AS unassigned_supplier_count
  FROM purchase_request_items pri
  WHERE pri.pr_id = pr.id
) item_agg ON true
LEFT JOIN LATERAL (
  SELECT
    count(*) AS total_campaigns,
    count(*) FILTER (WHERE gbc.status = 'completed') AS completed_campaigns
  FROM group_buy_campaigns gbc
  WHERE gbc.tenant_id = pr.tenant_id
    AND pr.source_close_date IS NOT NULL
    AND date(gbc.end_at AT TIME ZONE 'Asia/Taipei') = pr.source_close_date
    AND gbc.status <> 'cancelled'
) cmp ON true;

GRANT SELECT ON public.v_pr_progress TO authenticated;

COMMENT ON VIEW public.v_pr_progress IS
  'PR 進度（含 PO/Transfer 聚合）。xfer_agg 限縮至屬於該 PR 的 campaigns：'
  'campaign-PR 看自己 source_campaign_id；close_date PR 看同日且未被 campaign-PR 蓋掉的 campaigns。';

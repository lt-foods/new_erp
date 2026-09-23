-- Make PR delta preview labels easier for operators to understand.
-- Logic is unchanged; only action_label text is updated.

CREATE OR REPLACE FUNCTION public.rpc_preview_pr_campaign_sku_delta(
  p_close_date   DATE DEFAULT NULL,
  p_campaign_ids BIGINT[] DEFAULT NULL
) RETURNS TABLE(
  campaign_id      BIGINT,
  campaign_name    TEXT,
  sku_id           BIGINT,
  sku_label        TEXT,
  demand_qty       NUMERIC,
  already_qty      NUMERIC,
  delta_qty        NUMERIC,
  draft_pr_id      BIGINT,
  draft_pr_no      TEXT,
  action_code      TEXT,
  action_label     TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH t AS (
    SELECT public._current_tenant_id() AS tid
  ),
  selected AS (
    SELECT DISTINCT gbc.id AS campaign_id
      FROM public.group_buy_campaigns gbc
      CROSS JOIN t
     WHERE gbc.tenant_id = t.tid
       AND (
         (p_close_date IS NOT NULL
          AND gbc.status IN ('closed','locked')
          AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date)
         OR
         (p_campaign_ids IS NOT NULL
          AND gbc.id = ANY(p_campaign_ids))
       )
  ),
  delta AS (
    SELECT r.*
      FROM public._pr_campaign_sku_remaining_rows(
             ARRAY(SELECT campaign_id FROM selected ORDER BY campaign_id)
           ) r
     WHERE r.delta_qty > 0
  ),
  candidates AS (
    SELECT
      d.campaign_id,
      d.sku_id,
      pri.pr_id,
      pr.pr_no,
      0 AS priority,
      pr.updated_at,
      pri.id AS pr_item_id
    FROM delta d
    JOIN public.purchase_request_item_campaigns pric
      ON pric.campaign_id = d.campaign_id
    JOIN public.purchase_request_items pri
      ON pri.id = pric.pr_item_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    CROSS JOIN t
    WHERE pr.tenant_id = t.tid
      AND pric.tenant_id = t.tid
      AND pr.status = 'draft'

    UNION ALL

    SELECT
      d.campaign_id,
      d.sku_id,
      pri.pr_id,
      pr.pr_no,
      1 AS priority,
      pr.updated_at,
      pri.id AS pr_item_id
    FROM delta d
    JOIN public.purchase_request_items pri
      ON pri.source_campaign_id = d.campaign_id
     AND pri.sku_id = d.sku_id
     AND pri.po_item_id IS NULL
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    CROSS JOIN t
    WHERE pr.tenant_id = t.tid
      AND pr.status = 'draft'
      AND NOT EXISTS (
        SELECT 1
          FROM public.purchase_request_item_campaigns pric
         WHERE pric.pr_item_id = pri.id
           AND pric.campaign_id = d.campaign_id
      )
  ),
  target AS (
    SELECT DISTINCT ON (campaign_id, sku_id)
      campaign_id,
      sku_id,
      pr_id,
      pr_no
    FROM candidates
    ORDER BY campaign_id, sku_id, priority, updated_at DESC, pr_item_id DESC
  )
  SELECT
    d.campaign_id,
    gbc.name AS campaign_name,
    d.sku_id,
    COALESCE(
      NULLIF(TRIM(COALESCE(s.product_name, '')
        || COALESCE(' / ' || NULLIF(s.variant_name, ''), '')), ''),
      s.sku_code,
      '品項#' || d.sku_id::TEXT
    ) AS sku_label,
    d.demand_qty,
    d.already_qty,
    d.delta_qty,
    target.pr_id AS draft_pr_id,
    target.pr_no AS draft_pr_no,
    CASE WHEN target.pr_id IS NULL THEN 'create_delta' ELSE 'update_draft' END AS action_code,
    CASE
      WHEN target.pr_id IS NOT NULL THEN '會更新原本那張草稿請購單，不會多開新單'
      WHEN d.already_qty <= 0 THEN '目前還沒有請購單，會另外開一張補買單'
      ELSE '原本那張已經變採購單，不能改，會另外開一張補買單'
    END AS action_label
  FROM delta d
  JOIN public.group_buy_campaigns gbc
    ON gbc.id = d.campaign_id
  LEFT JOIN public.skus s
    ON s.id = d.sku_id
  LEFT JOIN target
    ON target.campaign_id = d.campaign_id
   AND target.sku_id = d.sku_id
  ORDER BY gbc.end_at DESC NULLS LAST, gbc.id, sku_label;
$$;

REVOKE ALL ON FUNCTION public.rpc_preview_pr_campaign_sku_delta(DATE, BIGINT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_preview_pr_campaign_sku_delta(DATE, BIGINT[]) TO authenticated;

COMMENT ON FUNCTION public.rpc_preview_pr_campaign_sku_delta(DATE, BIGINT[]) IS
  '請購補差額預覽：列出同團+SKU 目前需求、已請購、差額，以及會更新草稿或開補買單。';

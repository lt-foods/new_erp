-- 2026-08-13: Production hotfix plan for PR list item search.
--
-- Root cause:
--   The live rpc_pr_list only searches purchase_requests.pr_no / notes.
--   Searching an item name such as "一次性" therefore returns no PR rows even
--   when PR2608120686 contains the item.
--
-- Scope:
--   Replace rpc_pr_list only. No data writes, no status changes, no order/PR
--   mutation RPCs. This adds item search through purchase_request_items -> skus
--   -> products / suppliers, and includes skus.product_name as a defensive
--   fallback because older views in this codebase use that display field.
--
-- Verification after applying on staging/prod:
--   SELECT public.rpc_pr_list(NULL,NULL,NULL,'一次性',NULL,NULL,'updated_at','desc',1,20);
--   Expected: rows includes PR2608120686, with matched_items non-empty.
--
-- Rollback:
--   Re-apply the previous live definition captured by:
--   SELECT pg_get_functiondef(
--     'public.rpc_pr_list(text,text,text,text,date,date,text,text,int,int)'::regprocedure
--   );

CREATE OR REPLACE FUNCTION public.rpc_pr_list(
  p_status    text DEFAULT NULL,
  p_review    text DEFAULT NULL,
  p_source    text DEFAULT NULL,
  p_search    text DEFAULT NULL,
  p_date_from date DEFAULT NULL,
  p_date_to   date DEFAULT NULL,
  p_sort      text DEFAULT 'updated_at',
  p_dir       text DEFAULT 'desc',
  p_page      int  DEFAULT 1,
  p_page_size int  DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_tenant uuid := public._current_tenant_id();
  v_sort   text;
  v_dir    text;
  v_size   int  := GREATEST(1, LEAST(COALESCE(p_page_size, 20), 200));
  v_offset int;
  v_rows   jsonb;
  v_total  bigint;
BEGIN
  v_sort := CASE lower(COALESCE(p_sort, 'updated_at'))
              WHEN 'pr_no'             THEN 'b.pr_no'
              WHEN 'total_amount'      THEN 'b.total_amount'
              WHEN 'source_close_date' THEN 'b.source_close_date'
              ELSE                          'b.updated_at'
            END;
  v_dir    := CASE WHEN lower(COALESCE(p_dir, 'desc')) = 'asc' THEN 'ASC' ELSE 'DESC' END;
  v_offset := GREATEST(0, (GREATEST(1, COALESCE(p_page, 1)) - 1) * v_size);

  EXECUTE format($q$
    WITH base AS (
      SELECT pr.id, pr.pr_no, pr.total_amount, pr.source_close_date, pr.updated_at
      FROM purchase_requests pr
      WHERE pr.tenant_id = $1
        AND ($2 IS NULL OR $2 = 'all' OR pr.status = $2)
        AND ($3 IS NULL OR pr.review_status = $3)
        AND ($4 IS NULL OR pr.source_type = $4)
        AND ($5 IS NULL OR (pr.source_close_date IS NOT NULL AND pr.source_close_date >= $5))
        AND ($6 IS NULL OR (pr.source_close_date IS NOT NULL AND pr.source_close_date <= $6))
        AND ($7 IS NULL OR (
              pr.pr_no ILIKE '%%' || $7 || '%%'
           OR COALESCE(pr.notes, '') ILIKE '%%' || $7 || '%%'
           OR EXISTS (
                SELECT 1
                FROM purchase_request_items pri
                LEFT JOIN skus sk       ON sk.id  = pri.sku_id
                LEFT JOIN products pd   ON pd.id  = sk.product_id
                LEFT JOIN suppliers sup ON sup.id = pri.suggested_supplier_id
                WHERE pri.pr_id = pr.id
                  AND (
                       COALESCE(pd.name, '')          ILIKE '%%' || $7 || '%%'
                    OR COALESCE(pd.product_code, '')  ILIKE '%%' || $7 || '%%'
                    OR COALESCE(sk.product_name, '')  ILIKE '%%' || $7 || '%%'
                    OR COALESCE(sk.sku_code, '')      ILIKE '%%' || $7 || '%%'
                    OR COALESCE(sk.variant_name, '')  ILIKE '%%' || $7 || '%%'
                    OR COALESCE(sup.name, '')         ILIKE '%%' || $7 || '%%'
                  ))
        ))
    ),
    picked AS (
      SELECT b.id, row_number() OVER (ORDER BY %s %s NULLS LAST, b.id DESC) AS rn
      FROM base b
      ORDER BY %s %s NULLS LAST, b.id DESC
      LIMIT $8 OFFSET $9
    ),
    page AS (
      SELECT
        pr.id, pr.pr_no, pr.source_type, pr.source_close_date, pr.status,
        pr.review_status, pr.total_amount, pr.notes, pr.updated_at,
        COALESCE(vp.po_total, 0)                    AS po_total,
        COALESCE(vp.po_sent, 0)                     AS po_sent,
        COALESCE(vp.po_received_fully, 0)           AS po_received_fully,
        COALESCE(vp.transfer_total, 0)              AS transfer_total,
        COALESCE(vp.transfer_shipped, 0)            AS transfer_shipped,
        COALESCE(vp.transfer_delivered, 0)          AS transfer_delivered,
        COALESCE(vp.item_count, 0)                  AS item_count,
        COALESCE(vp.unassigned_supplier_count, 0)   AS unassigned_supplier_count,
        COALESCE(vp.all_campaigns_finalized, false) AS all_campaigns_finalized,
        COALESCE(mi.n, 0)                           AS matched_item_count,
        mi.labels                                   AS matched_items,
        pk.rn
      FROM picked pk
      JOIN purchase_requests pr ON pr.id = pk.id
      LEFT JOIN v_pr_progress vp ON vp.pr_id = pr.id
      LEFT JOIN LATERAL (
        SELECT count(*)::int AS n,
               (array_agg(m.label ORDER BY m.label))[1:5] AS labels
        FROM (
          SELECT DISTINCT COALESCE(
                   NULLIF(TRIM(COALESCE(pd.name, sk.product_name, sk.sku_code, '') ||
                               COALESCE(' / ' || NULLIF(sk.variant_name, ''), '')), ''),
                   'sku#' || pri.sku_id::text
                 ) AS label
          FROM purchase_request_items pri
          LEFT JOIN skus sk       ON sk.id  = pri.sku_id
          LEFT JOIN products pd   ON pd.id  = sk.product_id
          LEFT JOIN suppliers sup ON sup.id = pri.suggested_supplier_id
          WHERE $7 IS NOT NULL
            AND pri.pr_id = pr.id
            AND (
                 COALESCE(pd.name, '')          ILIKE '%%' || $7 || '%%'
              OR COALESCE(pd.product_code, '')  ILIKE '%%' || $7 || '%%'
              OR COALESCE(sk.product_name, '')  ILIKE '%%' || $7 || '%%'
              OR COALESCE(sk.sku_code, '')      ILIKE '%%' || $7 || '%%'
              OR COALESCE(sk.variant_name, '')  ILIKE '%%' || $7 || '%%'
              OR COALESCE(sup.name, '')         ILIKE '%%' || $7 || '%%'
            )
        ) m
      ) mi ON true
    )
    SELECT
      (SELECT count(*) FROM base),
      COALESCE((SELECT jsonb_agg(to_jsonb(page) - 'rn' ORDER BY page.rn) FROM page), '[]'::jsonb)
  $q$, v_sort, v_dir, v_sort, v_dir)
  INTO v_total, v_rows
  USING v_tenant, p_status, p_review, p_source, p_date_from, p_date_to,
        NULLIF(btrim(COALESCE(p_search, '')), ''), v_size, v_offset;

  RETURN jsonb_build_object(
    'total', v_total,
    'counts', (
      SELECT jsonb_build_object(
        'all',               count(*),
        'draft',             count(*) FILTER (WHERE status = 'draft'),
        'submitted',         count(*) FILTER (WHERE status = 'submitted'),
        'partially_ordered', count(*) FILTER (WHERE status = 'partially_ordered'),
        'fully_ordered',     count(*) FILTER (WHERE status = 'fully_ordered'),
        'cancelled',         count(*) FILTER (WHERE status = 'cancelled')
      )
      FROM purchase_requests WHERE tenant_id = v_tenant
    ),
    'kpi', jsonb_build_object(
      'pending_review', (
        SELECT count(*) FROM purchase_requests
        WHERE tenant_id = v_tenant AND review_status = 'pending_review'),
      'to_split', (
        SELECT count(*) FROM purchase_requests
        WHERE tenant_id = v_tenant AND review_status = 'approved'
          AND status NOT IN ('fully_ordered','cancelled')),
      'amount_in_flight', (
        SELECT COALESCE(sum(total_amount), 0) FROM purchase_requests
        WHERE tenant_id = v_tenant AND review_status = 'approved'
          AND status NOT IN ('fully_ordered','cancelled')),
      'unassigned', (
        SELECT count(*)
        FROM purchase_request_items pri
        JOIN purchase_requests pr ON pr.id = pri.pr_id
        WHERE pr.tenant_id = v_tenant AND pri.suggested_supplier_id IS NULL)
    ),
    'rows', v_rows
  );
END;
$fn$;

COMMENT ON FUNCTION public.rpc_pr_list(text,text,text,text,date,date,text,text,int,int) IS
  'PR list server-side filters/sort/pagination. Search matches PR no/notes and items (product/product_code/sku product name/sku/variant/supplier), returns rows with matched_items.';

GRANT EXECUTE ON FUNCTION public.rpc_pr_list(text,text,text,text,date,date,text,text,int,int) TO authenticated;

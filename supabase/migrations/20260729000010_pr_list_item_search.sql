-- ============================================================
-- 請購單列表：搜尋框支援「品項」（商品名 / 商品編號 / SKU 編號 / 規格 / 廠商）
--
-- 背景：
--   #551 把請購單列表改成 server-side 之後，rpc_pr_list 的搜尋只比對
--   pr_no 與 notes，但同一個搜尋框餵給的 rpc_pr_supplier_pivot 卻已經
--   比對到商品名 / SKU 編號 / 廠商名。結果是同一個關鍵字：
--     樞紐檢視 → 有資料；清單檢視 → 整頁空白。
--   使用者的實際需求是「我要知道哪幾張請購單裡有這個品項」，清單檢視反而
--   是主要入口，卻搜不到。
--
-- 解法：
--   1. rpc_pr_list 的搜尋條件加一個 EXISTS，往 purchase_request_items
--      → skus → products / suppliers 比對品項欄位。
--   2. 每列多回傳 matched_items / matched_item_count，讓前端能直接顯示
--      「這張單是因為哪個品項被搜出來的」，不必點進去才知道。
--      只有帶關鍵字時才算（$7 IS NULL 時 lateral 會被 one-time filter 擋掉）。
--   3. rpc_pr_supplier_pivot 的搜尋欄位補齊 product_code / variant_name，
--      讓清單 / 樞紐兩個檢視吃同一組關鍵字時命中範圍一致。
--   4. 補索引：purchase_request_items 只有 partial index (pr_id) WHERE
--      po_item_id IS NULL，sku_id 完全沒索引；再對 products.name /
--      skus.sku_code 建 pg_trgm GIN（同 20260704000000 members 的作法），
--      讓 ILIKE '%kw%' 兩種可能的 plan（逐 PR nested loop、整表 semi join）
--      都有索引可用。
--
-- 基於：20260729000000_po_pr_list_server_side.sql
--   （rpc_pr_list / rpc_pr_supplier_pivot 的唯一前身版本；rpc_po_list 未動，
--     它本來就已經搜商品名）。本檔只擴充搜尋與回傳欄位，
--     篩選 / 排序 / 分頁 / counts / kpi 的行為完全不變。
--
-- Rollback:
--   重跑 20260729000000_po_pr_list_server_side.sql 裡的
--     rpc_pr_list(text,text,text,text,date,date,text,text,int,int)
--     rpc_pr_supplier_pivot(text,text,text,text,date,date,boolean)
--   兩段 CREATE OR REPLACE 即可（簽章未變，不需 DROP）。
--   索引：
--     DROP INDEX IF EXISTS public.idx_pri_pr_id;
--     DROP INDEX IF EXISTS public.idx_pri_sku_id;
--     DROP INDEX IF EXISTS public.idx_products_name_trgm;
--     DROP INDEX IF EXISTS public.idx_skus_sku_code_trgm;
-- ============================================================


-- ----------------------------------------------------------------
-- 0. 索引
-- ----------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 既有的 idx_pri_pending 是 partial（WHERE po_item_id IS NULL），
-- 品項搜尋要看「全部」品項，用不到它。
CREATE INDEX IF NOT EXISTS idx_pri_pr_id
  ON public.purchase_request_items (pr_id);

CREATE INDEX IF NOT EXISTS idx_pri_sku_id
  ON public.purchase_request_items (sku_id);

CREATE INDEX IF NOT EXISTS idx_products_name_trgm
  ON public.products USING gin (name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_skus_sku_code_trgm
  ON public.skus USING gin (sku_code gin_trgm_ops);


-- ----------------------------------------------------------------
-- 1. rpc_pr_list — 加品項搜尋 + 回傳命中的品項名稱
-- ----------------------------------------------------------------
-- 回傳形狀同前，rows 每列多兩個欄位：
--   matched_items      text[]  命中關鍵字的品項標籤（去重、最多 5 個）
--   matched_item_count int     命中的品項總數（前端用來顯示「…等 N 項」）
-- 未帶關鍵字時 matched_items = NULL / matched_item_count = 0。
-- ----------------------------------------------------------------
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
           -- 品項搜尋：商品名 / 商品編號 / SKU 編號 / 規格 / 建議廠商
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
        COALESCE(vp.po_total, 0)                  AS po_total,
        COALESCE(vp.po_sent, 0)                   AS po_sent,
        COALESCE(vp.po_received_fully, 0)         AS po_received_fully,
        COALESCE(vp.transfer_total, 0)            AS transfer_total,
        COALESCE(vp.transfer_shipped, 0)          AS transfer_shipped,
        COALESCE(vp.transfer_delivered, 0)        AS transfer_delivered,
        COALESCE(vp.item_count, 0)                AS item_count,
        COALESCE(vp.unassigned_supplier_count, 0) AS unassigned_supplier_count,
        COALESCE(vp.all_campaigns_finalized, false) AS all_campaigns_finalized,
        COALESCE(mi.n, 0)                         AS matched_item_count,
        mi.labels                                 AS matched_items,
        pk.rn
      FROM picked pk
      JOIN purchase_requests pr ON pr.id = pk.id
      LEFT JOIN v_pr_progress vp ON vp.pr_id = pr.id
      -- 命中品項（只有當頁的 20 列會算，且沒帶關鍵字時整段被 one-time filter 擋掉）
      LEFT JOIN LATERAL (
        SELECT count(*)::int                            AS n,
               (array_agg(m.label ORDER BY m.label))[1:5] AS labels
        FROM (
          SELECT DISTINCT COALESCE(
                   NULLIF(TRIM(COALESCE(pd.name, sk.sku_code, '') ||
                               COALESCE(' / ' || NULLIF(sk.variant_name, ''), '')), ''),
                   '品項#' || pri.sku_id::text
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
      -- 待指派供應商＝所有 PR 品項中 suggested_supplier_id 為空的列數（同原前端加總）
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
  '請購單列表 server-side 篩選/排序/分頁：搜尋比對 單號/備註/品項(商品名·編號·SKU·規格·廠商)，回傳 { total, counts, kpi, rows(含進度與 matched_items) }。';

GRANT EXECUTE ON FUNCTION public.rpc_pr_list(text,text,text,text,date,date,text,text,int,int) TO authenticated;


-- ----------------------------------------------------------------
-- 2. rpc_pr_supplier_pivot — 搜尋欄位對齊 rpc_pr_list
-- ----------------------------------------------------------------
-- 只動 WHERE 裡的關鍵字比對（補 product_code / variant_name），
-- 聚合邏輯與回傳形狀完全不變。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_pr_supplier_pivot(
  p_status         text    DEFAULT NULL,
  p_review         text    DEFAULT NULL,
  p_source         text    DEFAULT NULL,
  p_search         text    DEFAULT NULL,
  p_date_from      date    DEFAULT NULL,
  p_date_to        date    DEFAULT NULL,
  p_only_unordered boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  WITH q AS (
    SELECT NULLIF(btrim(COALESCE(p_search, '')), '') AS kw,
           public._current_tenant_id()               AS tenant
  ),
  items AS (
    SELECT
      pri.pr_id,
      pr.pr_no,
      pri.suggested_supplier_id                       AS supplier_id,
      s.name                                          AS supplier_name,
      pri.sku_id,
      COALESCE(
        NULLIF(TRIM(COALESCE(pd.name, sk.sku_code, '') ||
                    COALESCE(' / ' || NULLIF(sk.variant_name, ''), '')), ''),
        '品項#' || pri.sku_id::text
      )                                               AS sku_label,
      COALESCE(pri.qty_requested, 0)                  AS qty,
      COALESCE(pri.qty_requested, 0) * COALESCE(pri.unit_cost, 0) AS amount,
      (pri.po_item_id IS NOT NULL)                    AS ordered
    FROM purchase_request_items pri
    JOIN purchase_requests pr ON pr.id = pri.pr_id
    CROSS JOIN q
    LEFT JOIN suppliers s  ON s.id  = pri.suggested_supplier_id
    LEFT JOIN skus sk      ON sk.id = pri.sku_id
    LEFT JOIN products pd  ON pd.id = sk.product_id
    WHERE pr.tenant_id = q.tenant
      AND pr.status <> 'cancelled'
      AND (p_status    IS NULL OR p_status = 'all' OR pr.status = p_status)
      AND (p_review    IS NULL OR pr.review_status = p_review)
      AND (p_source    IS NULL OR pr.source_type = p_source)
      AND (p_date_from IS NULL OR (pr.source_close_date IS NOT NULL AND pr.source_close_date >= p_date_from))
      AND (p_date_to   IS NULL OR (pr.source_close_date IS NOT NULL AND pr.source_close_date <= p_date_to))
      AND (NOT p_only_unordered OR pri.po_item_id IS NULL)
      AND (q.kw IS NULL OR (
            pr.pr_no ILIKE '%' || q.kw || '%'
         OR COALESCE(pr.notes, '')        ILIKE '%' || q.kw || '%'
         OR COALESCE(s.name, '')          ILIKE '%' || q.kw || '%'
         OR COALESCE(pd.name, '')         ILIKE '%' || q.kw || '%'
         OR COALESCE(pd.product_code, '') ILIKE '%' || q.kw || '%'
         OR COALESCE(sk.sku_code, '')     ILIKE '%' || q.kw || '%'
         OR COALESCE(sk.variant_name, '') ILIKE '%' || q.kw || '%'
      ))
  ),
  by_sku AS (
    SELECT
      supplier_id,
      MAX(supplier_name)                          AS supplier_name,
      sku_id,
      MAX(sku_label)                              AS label,
      SUM(qty)                                    AS qty,
      SUM(qty) FILTER (WHERE ordered)             AS ordered_qty,
      SUM(amount)                                 AS amount,
      jsonb_agg(DISTINCT jsonb_build_object('id', pr_id, 'pr_no', pr_no)) AS prs
    FROM items
    GROUP BY supplier_id, sku_id
  ),
  by_supplier AS (
    SELECT
      k.supplier_id,
      COALESCE(MAX(k.supplier_name), '未指派供應商') AS supplier_name,
      SUM(k.qty)                                     AS qty,
      COALESCE(SUM(k.ordered_qty), 0)                AS ordered_qty,
      SUM(k.amount)                                  AS amount,
      (SELECT count(DISTINCT i.pr_id) FROM items i
        WHERE i.supplier_id IS NOT DISTINCT FROM k.supplier_id) AS pr_count,
      jsonb_agg(
        jsonb_build_object(
          'sku_id',      k.sku_id,
          'label',       k.label,
          'qty',         k.qty,
          'ordered_qty', COALESCE(k.ordered_qty, 0),
          'amount',      k.amount,
          'prs',         k.prs
        ) ORDER BY k.label
      ) AS skus
    FROM by_sku k
    GROUP BY k.supplier_id
  )
  SELECT jsonb_build_object(
    'groups',
    COALESCE(
      (SELECT jsonb_agg(
         jsonb_build_object(
           'supplier_id',   supplier_id,
           'supplier_name', supplier_name,
           'qty',           qty,
           'ordered_qty',   ordered_qty,
           'amount',        amount,
           'pr_count',      pr_count,
           'skus',          skus
         )
         -- 未指派供應商排最前面（最需要處理）
         ORDER BY (supplier_id IS NOT NULL), supplier_name
       )
       FROM by_supplier),
      '[]'::jsonb)
  );
$fn$;

COMMENT ON FUNCTION public.rpc_pr_supplier_pivot(text,text,text,text,date,date,boolean) IS
  '請購單樞紐：依廠商 → SKU 聚合請購量 / 已轉單量 / 金額 / 來源請購單，全部在 DB 算完（搜尋欄位同 rpc_pr_list）。';

GRANT EXECUTE ON FUNCTION public.rpc_pr_supplier_pivot(text,text,text,text,date,date,boolean) TO authenticated;

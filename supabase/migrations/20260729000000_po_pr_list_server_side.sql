-- ============================================================
-- 採購單 / 請購單列表：server-side 篩選 + 分頁 + 計數
--
-- 背景：
--   兩張列表頁原本都是「前端全撈再自己篩」。採購單頁寫死 .limit(500)
--   取最近更新的 500 張 —— 線上已 778 張 PO，搜 PO2606180538（依
--   updated_at desc 排第 714 名）根本搜不到，狀態頁籤與 KPI 也少算。
--   把 limit 拿掉只是把問題延後：單數再長下去首屏傳輸量會失控。
--
-- 解法：比照 rpc_hq_exceptions 的慣例，改成 server-side RPC，
--   一次回傳 { total, counts, kpi, rows(當前頁) }，前端只收當頁資料。
--   搜尋在 DB 用 ILIKE 比對，跨表條件（來源請購單單號、商品名）走 EXISTS，
--   不再受「前端載了多少筆」限制。
--
--   1. rpc_po_list           採購單列表
--   2. rpc_pr_list           請購單列表
--   3. rpc_pr_supplier_pivot 請購單樞紐（依廠商彙整品項，直接在 DB 聚合）
--
-- 慣例對齊：
--   - SECURITY DEFINER + 自行用 public._current_tenant_id() 綁租戶
--     （同 rpc_hq_exceptions：admin JWT 的 role claim 可能為 NULL，
--      走 RLS 會讀不到；因此改由函式內明確過濾 tenant_id）
--   - 回傳 jsonb { total, counts, ... }，GRANT EXECUTE TO authenticated
--   - 排序欄位以白名單映射後才進 format()，不接受任意字串
--
-- 基於：無前身（這三支都是新函式，未動任何既有 view / function）。
-- Rollback:
--   DROP FUNCTION public.rpc_po_list(text,bigint,text,date,date,text,text,int,int);
--   DROP FUNCTION public.rpc_pr_list(text,text,text,text,date,date,text,text,int,int);
--   DROP FUNCTION public.rpc_pr_supplier_pivot(text,text,text,text,date,date,boolean);
-- ============================================================


-- ----------------------------------------------------------------
-- 1. rpc_po_list — 採購單列表
-- ----------------------------------------------------------------
-- 回傳：
--   {
--     "total":     <套用篩選後的張數>,
--     "counts":    { "all": N, "draft": N, ... },   -- 狀態頁籤；只綁租戶，不受其他篩選影響（同原前端行為）
--     "kpi":       { "draft", "pending_arrival", "overdue", "pending_amount" },
--     "suppliers": [ { "id", "name" } ],            -- 廠商下拉選項（全租戶，不受分頁影響）
--     "rows":      [ { ...含 supplier_name / pr_no / item_count / product_names... } ]
--   }
-- p_status = NULL / 'all' → 不分狀態。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_po_list(
  p_status      text   DEFAULT NULL,
  p_supplier_id bigint DEFAULT NULL,
  p_search      text   DEFAULT NULL,
  p_date_from   date   DEFAULT NULL,
  p_date_to     date   DEFAULT NULL,
  p_sort        text   DEFAULT 'updated_at',
  p_dir         text   DEFAULT 'desc',
  p_page        int    DEFAULT 1,
  p_page_size   int    DEFAULT 30
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
  v_size   int  := GREATEST(1, LEAST(COALESCE(p_page_size, 30), 200));
  v_offset int;
  v_rows   jsonb;
  v_total  bigint;
BEGIN
  -- 排序欄位白名單（絕不把 p_sort 原字串塞進 SQL）
  v_sort := CASE lower(COALESCE(p_sort, 'updated_at'))
              WHEN 'po_no'         THEN 'b.po_no'
              WHEN 'total'         THEN 'b.total'
              WHEN 'expected_date' THEN 'b.expected_date'
              WHEN 'supplier'      THEN 'b.supplier_name'
              ELSE                      'b.updated_at'
            END;
  v_dir    := CASE WHEN lower(COALESCE(p_dir, 'desc')) = 'asc' THEN 'ASC' ELSE 'DESC' END;
  v_offset := GREATEST(0, (GREATEST(1, COALESCE(p_page, 1)) - 1) * v_size);

  EXECUTE format($q$
    WITH base AS (
      -- 篩選條件只寫一次；只取 id + 排序鍵，撐不大
      SELECT po.id, po.po_no, po.total, po.expected_date, po.updated_at,
             s.name AS supplier_name
      FROM purchase_orders po
      LEFT JOIN suppliers s ON s.id = po.supplier_id
      WHERE po.tenant_id = $1
        AND ($2 IS NULL OR $2 = 'all' OR po.status = $2)
        AND ($3 IS NULL OR po.supplier_id = $3)
        AND ($4 IS NULL OR po.created_at >= $4::timestamptz)
        AND ($5 IS NULL OR po.created_at < ($5::date + 1)::timestamptz)
        AND ($6 IS NULL OR (
              po.po_no ILIKE '%%' || $6 || '%%'
           OR s.name   ILIKE '%%' || $6 || '%%'
           OR EXISTS (
                SELECT 1 FROM purchase_order_items poi
                JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                JOIN purchase_requests pr       ON pr.id = pri.pr_id
                WHERE poi.po_id = po.id AND pr.pr_no ILIKE '%%' || $6 || '%%')
           OR EXISTS (
                SELECT 1 FROM purchase_order_items poi
                JOIN skus sk     ON sk.id = poi.sku_id
                JOIN products pd ON pd.id = sk.product_id
                WHERE poi.po_id = po.id AND pd.name ILIKE '%%' || $6 || '%%')
        ))
    ),
    picked AS (
      SELECT b.id, row_number() OVER (ORDER BY %s %s NULLS LAST, b.id DESC) AS rn
      FROM base b
      ORDER BY %s %s NULLS LAST, b.id DESC
      LIMIT $7 OFFSET $8
    ),
    -- 只對「當前頁」做昂貴的 lateral 補值（品項數 / 商品名 / 來源 PR）
    page AS (
      SELECT
        po.id, po.po_no, po.supplier_id, s.name AS supplier_name, po.status,
        po.total, po.expected_date, po.sent_at, po.sent_channel, po.stockout_at,
        po.created_at, po.updated_at,
        src.pr_id, src.pr_no,
        COALESCE(it.item_count, 0)                  AS item_count,
        COALESCE(it.product_names, ARRAY[]::text[]) AS product_names,
        pk.rn
      FROM picked pk
      JOIN purchase_orders po ON po.id = pk.id
      LEFT JOIN suppliers s   ON s.id = po.supplier_id
      LEFT JOIN LATERAL (
        SELECT count(*) AS item_count,
               array_agg(DISTINCT pd.name) FILTER (WHERE pd.name IS NOT NULL) AS product_names
        FROM purchase_order_items poi
        LEFT JOIN skus sk     ON sk.id = poi.sku_id
        LEFT JOIN products pd ON pd.id = sk.product_id
        WHERE poi.po_id = po.id
      ) it ON true
      LEFT JOIN LATERAL (
        SELECT pr.id AS pr_id, pr.pr_no
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN purchase_requests pr       ON pr.id = pri.pr_id
        WHERE poi.po_id = po.id
        LIMIT 1
      ) src ON true
    )
    SELECT
      (SELECT count(*) FROM base),
      COALESCE((SELECT jsonb_agg(to_jsonb(page) - 'rn' ORDER BY page.rn) FROM page), '[]'::jsonb)
  $q$, v_sort, v_dir, v_sort, v_dir)
  INTO v_total, v_rows
  USING v_tenant, p_status, p_supplier_id, p_date_from, p_date_to,
        NULLIF(btrim(COALESCE(p_search, '')), ''), v_size, v_offset;

  RETURN jsonb_build_object(
    'total', v_total,
    'counts', (
      SELECT jsonb_build_object(
        'all',                count(*),
        'draft',              count(*) FILTER (WHERE status = 'draft'),
        'sent',               count(*) FILTER (WHERE status = 'sent'),
        'partially_received', count(*) FILTER (WHERE status = 'partially_received'),
        'fully_received',     count(*) FILTER (WHERE status = 'fully_received'),
        'closed',             count(*) FILTER (WHERE status = 'closed'),
        'cancelled',          count(*) FILTER (WHERE status = 'cancelled')
      )
      FROM purchase_orders WHERE tenant_id = v_tenant
    ),
    'kpi', (
      SELECT jsonb_build_object(
        'draft',           count(*) FILTER (WHERE status = 'draft'),
        'pending_arrival', count(*) FILTER (WHERE status IN ('sent','partially_received')),
        -- 逾期＝已發送/部分到貨且預計到貨日已過（對齊原前端：只看在途單）
        'overdue',         count(*) FILTER (
                             WHERE status IN ('sent','partially_received')
                               AND expected_date IS NOT NULL
                               AND expected_date < current_date),
        'pending_amount',  COALESCE(sum(total) FILTER (
                             WHERE status IN ('sent','partially_received')), 0)
      )
      FROM purchase_orders WHERE tenant_id = v_tenant
    ),
    'suppliers', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name) ORDER BY d.name), '[]'::jsonb)
      FROM (
        SELECT DISTINCT s.id, s.name
        FROM purchase_orders po
        JOIN suppliers s ON s.id = po.supplier_id
        WHERE po.tenant_id = v_tenant
      ) d
    ),
    'rows', v_rows
  );
END;
$fn$;

COMMENT ON FUNCTION public.rpc_po_list(text,bigint,text,date,date,text,text,int,int) IS
  '採購單列表 server-side 篩選/排序/分頁：回傳 { total, counts, kpi, suppliers, rows(當前頁) }。搜尋以 ILIKE 比對單號/廠商/來源請購單單號/商品名。';

GRANT EXECUTE ON FUNCTION public.rpc_po_list(text,bigint,text,date,date,text,text,int,int) TO authenticated;


-- ----------------------------------------------------------------
-- 2. rpc_pr_list — 請購單列表
-- ----------------------------------------------------------------
-- 回傳：
--   {
--     "total":  <套用篩選後的張數>,
--     "counts": { "all", "draft", "submitted", "partially_ordered", "fully_ordered", "cancelled" },
--     "kpi":    { "pending_review", "to_split", "amount_in_flight", "unassigned" },
--     "rows":   [ { ...PR 欄位 + v_pr_progress 進度欄位... } ]
--   }
-- 搜尋比對：單號 / 備註（同原前端）。
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
        pk.rn
      FROM picked pk
      JOIN purchase_requests pr ON pr.id = pk.id
      LEFT JOIN v_pr_progress vp ON vp.pr_id = pr.id
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
  '請購單列表 server-side 篩選/排序/分頁：回傳 { total, counts, kpi, rows(當前頁，含 v_pr_progress 進度) }。';

GRANT EXECUTE ON FUNCTION public.rpc_pr_list(text,text,text,text,date,date,text,text,int,int) TO authenticated;


-- ----------------------------------------------------------------
-- 3. rpc_pr_supplier_pivot — 請購單樞紐（依廠商彙整品項）
-- ----------------------------------------------------------------
-- 與 rpc_pr_list 吃同一組篩選（狀態 / 審核 / 來源 / 結單日），
-- 差別在搜尋：樞紐是品項視角，所以搜尋同時比對
-- 單號 / 備註 / 廠商名 / 商品名，避免「搜商品名卻整個樞紐空掉」。
-- 已作廢的 PR 一律不納入。
--
-- 回傳：
--   { "groups": [ { supplier_id, supplier_name, qty, ordered_qty, amount, pr_count,
--                   skus: [ { sku_id, label, qty, ordered_qty, amount,
--                             prs: [ { id, pr_no } ] } ] } ] }
-- p_only_unordered = true → 只算尚未轉成 PO 品項的列。
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
         OR COALESCE(pr.notes, '') ILIKE '%' || q.kw || '%'
         OR COALESCE(s.name, '')   ILIKE '%' || q.kw || '%'
         OR COALESCE(pd.name, '')  ILIKE '%' || q.kw || '%'
         OR COALESCE(sk.sku_code, '') ILIKE '%' || q.kw || '%'
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
  '請購單樞紐：依廠商 → SKU 聚合請購量 / 已轉單量 / 金額 / 來源請購單，全部在 DB 算完。';

GRANT EXECUTE ON FUNCTION public.rpc_pr_supplier_pivot(text,text,text,text,date,date,boolean) TO authenticated;

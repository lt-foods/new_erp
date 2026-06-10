-- ============================================================
-- 總倉收件匣「異常」清單:伺服器端分頁
--
-- 背景:
--   ExceptionsContent 原本把 5 種異常來源在「前端」各自全撈
--   (其中 customer_shortage 走 v_order_shortage .limit(20000)),
--   合併後一次塞進單一表格 — 線上已 857 筆,難捲動、傳輸量大,
--   且非真正分頁(只是前端切片)。
--
-- 解法:把 5 來源 union 成單一 flat view v_hq_exceptions,
--   再用 rpc_hq_exceptions(type, page, page_size) 做 server-side
--   分頁 + 一次回傳各 tab 計數,前端只收當頁 20 筆。
--
-- 5 種異常來源(與舊前端邏輯逐欄對齊):
--   1. po_shortage       進貨短少  v_picking_demand_by_po qty_shortage>0(去重 po×sku)
--   2. po_damage         進貨破損  goods_receipt_items qty_damaged>0 + gr.confirmed
--   3. po_over           過量進貨  v_picking_demand_by_po gr_qty>qty_ordered(去重 po×sku)
--   4. transfer_short    收貨短少  transfer_items(transfer received / 未解決 / 收<出)
--   5. customer_shortage 訂單短少  v_order_shortage 聚合到 order 維度
--
-- 慣例對齊:
--   - 純 view + GRANT SELECT TO authenticated(同 v_order_shortage / v_hq_inbox)
--   - 計數 / 分頁走 SECURITY DEFINER RPC(admin JWT role 可能 NULL,同 rpc_hq_inbox_keys)
--
-- 基於:無前身(此清單原為純前端計算),依賴最新
--   v_picking_demand_by_po(20260701000010)、v_order_shortage(20260607000020)。
-- Rollback:DROP FUNCTION public.rpc_hq_exceptions(text,int,int);
--           DROP VIEW public.v_hq_exceptions;
-- ============================================================

-- ----------------------------------------------------------------
-- 1. v_hq_exceptions — 5 來源 union 的扁平異常 view
-- ----------------------------------------------------------------
DROP VIEW IF EXISTS public.v_hq_exceptions CASCADE;

CREATE VIEW public.v_hq_exceptions AS
-- 1. 進貨短少
SELECT
  'po_shortage'::text                                        AS type,
  'po-short-' || pd.po_id::text || ':' || pd.sku_id::text    AS row_key,
  po.created_at                                              AS ts,
  pd.po_no                                                   AS doc_no,
  pd.sku_code                                                AS sku_code,
  pd.sku_label                                               AS sku_label,
  pd.qty_ordered::numeric                                    AS expected,
  pd.gr_qty::numeric                                         AS actual,
  pd.qty_shortage::numeric                                   AS diff,
  NULL::text                                                 AS reason,
  'PO 已關單,差額不會到'::text                                AS extra,
  NULL::bigint                                               AS transfer_item_id,
  NULL::bigint                                               AS transfer_id,
  NULL::text                                                 AS transfer_no,
  pd.sku_id::bigint                                          AS sku_id,
  NULL::numeric                                              AS qty_shipped,
  NULL::numeric                                              AS qty_received,
  NULL::numeric                                              AS shortage_qty,
  NULL::bigint                                               AS dest_location,
  NULL::bigint                                               AS dest_store_id,
  NULL::text                                                 AS dest_store_name,
  NULL::bigint                                               AS customer_order_id,
  NULL::text                                                 AS shortage_resolution
FROM (
  SELECT DISTINCT po_id, sku_id, po_no, sku_code, sku_label, qty_ordered, gr_qty, qty_shortage
  FROM public.v_picking_demand_by_po
  WHERE qty_shortage > 0
) pd
LEFT JOIN public.purchase_orders po ON po.id = pd.po_id

UNION ALL

-- 2. 進貨破損
SELECT
  'po_damage'::text,
  'po-dmg-' || gri.id::text,
  gr.created_at,
  gr.gr_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || gri.sku_id::text),
  gri.qty_received::numeric,
  (gri.qty_received - gri.qty_damaged)::numeric,
  gri.qty_damaged::numeric,
  gri.variance_reason,
  '已收 ' || gri.qty_received::text || ' 含瑕疵 ' || gri.qty_damaged::text,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  gri.sku_id::bigint,
  NULL::numeric,
  NULL::numeric,
  NULL::numeric,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  NULL::bigint,
  NULL::text
FROM public.goods_receipt_items gri
JOIN public.goods_receipts gr ON gr.id = gri.gr_id
LEFT JOIN public.skus s ON s.id = gri.sku_id
WHERE gri.qty_damaged > 0
  AND gr.status = 'confirmed'

UNION ALL

-- 3. 過量進貨
SELECT
  'po_over'::text,
  'po-over-' || pd.po_id::text || ':' || pd.sku_id::text,
  po.created_at,
  pd.po_no,
  pd.sku_code,
  pd.sku_label,
  pd.qty_ordered::numeric,
  pd.gr_qty::numeric,
  (pd.gr_qty - pd.qty_ordered)::numeric,
  NULL::text,
  '供應商多送或重複入庫'::text,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  pd.sku_id::bigint,
  NULL::numeric,
  NULL::numeric,
  NULL::numeric,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  NULL::bigint,
  NULL::text
FROM (
  SELECT DISTINCT po_id, sku_id, po_no, sku_code, sku_label, qty_ordered, gr_qty
  FROM public.v_picking_demand_by_po
  WHERE gr_qty > qty_ordered
) pd
LEFT JOIN public.purchase_orders po ON po.id = pd.po_id

UNION ALL

-- 4. 收貨短少(轉貨 received 但實收 < 出貨,且尚未解決)
SELECT
  'transfer_short'::text,
  'tshort-' || ti.id::text,
  COALESCE(t.received_at, t.created_at),
  t.transfer_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || ti.sku_id::text),
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  (ti.qty_shipped - ti.qty_received)::numeric,
  NULL::text,
  CASE WHEN COALESCE(ti.damage_qty, 0) > 0 THEN '含破損 ' || ti.damage_qty::text ELSE '分店少收或運送中遺失' END,
  ti.id::bigint,
  ti.transfer_id::bigint,
  t.transfer_no,
  ti.sku_id::bigint,
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  (ti.qty_shipped - ti.qty_received)::numeric,
  t.dest_location::bigint,
  (SELECT ds.id FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1)::bigint,
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  ),
  NULL::bigint,
  NULL::text
FROM public.transfer_items ti
JOIN public.transfers t ON t.id = ti.transfer_id
LEFT JOIN public.skus s ON s.id = ti.sku_id
WHERE t.status = 'received'
  AND ti.shortage_resolution IS NULL
  AND ti.qty_received < ti.qty_shipped

UNION ALL

-- 5. 訂單短少(v_order_shortage order×sku → 聚合到 order)
SELECT
  'customer_shortage'::text,
  'custshort-' || agg.order_id::text,
  agg.ts,
  agg.order_no,
  NULL::text,
  agg.sku_label,
  agg.expected::numeric,
  GREATEST(0, agg.expected - agg.total_unfulfillable)::numeric,
  agg.total_unfulfillable::numeric,
  CASE agg.shortage_resolution
    WHEN 'notified'        THEN '✓ 已通知客戶'
    WHEN 'cancelled'       THEN '✓ 已取消退款'
    WHEN 'reallocated'     THEN '✓ 已改派'
    WHEN 'waiting_next_po' THEN '⏳ 等下批 PO'
    ELSE NULL
  END,
  COALESCE(agg.store_name, '—') || ' · 會員 #' || COALESCE(agg.member_id::text, '—') || ' · ' || agg.short_item_count::text || ' 樣品項短少',
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  NULL::bigint,
  NULL::numeric,
  NULL::numeric,
  NULL::numeric,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  agg.order_id::bigint,
  agg.shortage_resolution
FROM (
  SELECT
    vos.order_id,
    MAX(vos.order_no)            AS order_no,
    MAX(vos.member_id)           AS member_id,
    MAX(vos.store_name)          AS store_name,
    MAX(vos.shortage_resolution) AS shortage_resolution,
    MAX(vos.order_updated_at)    AS ts,
    SUM(vos.order_qty)           AS expected,
    SUM(vos.demand_unfulfillable) AS total_unfulfillable,
    COUNT(*)                     AS short_item_count,
    string_agg(
      CASE
        WHEN vos.sku_code IS NOT NULL AND vos.sku_code <> ''
          THEN vos.sku_code || ' ' || COALESCE(NULLIF(TRIM(COALESCE(vos.product_name,'') || COALESCE(' / ' || NULLIF(vos.variant_name,''), '')), ''), '品項#' || vos.sku_id::text)
        ELSE COALESCE(NULLIF(TRIM(COALESCE(vos.product_name,'') || COALESCE(' / ' || NULLIF(vos.variant_name,''), '')), ''), '品項#' || vos.sku_id::text)
      END,
      '、' ORDER BY vos.sku_id
    )                            AS sku_label
  FROM public.v_order_shortage vos
  GROUP BY vos.order_id
) agg;

GRANT SELECT ON public.v_hq_exceptions TO authenticated;

COMMENT ON VIEW public.v_hq_exceptions IS
  '總倉收件匣異常統一 view:union 進貨短少/破損/過量/收貨短少/訂單短少 5 來源為扁平列,'
  '供 rpc_hq_exceptions 做 server-side 分頁與計數。';

-- ----------------------------------------------------------------
-- 2. rpc_hq_exceptions — server-side 分頁 + 各 tab 計數(一次回傳)
-- ----------------------------------------------------------------
-- 回傳:
--   {
--     "total":  <當前 type 篩選後的總筆數>,
--     "counts": { "all": N, "po_shortage": N, ..., "customer_shortage": N },
--     "rows":   [ { ...v_hq_exceptions 整列... }, ... ]  -- 僅當前頁
--   }
-- p_type = NULL / 'all' → 不分類型;否則只回該 type。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_hq_exceptions(
  p_type      text DEFAULT NULL,
  p_page      int  DEFAULT 1,
  p_page_size int  DEFAULT 20
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ex AS MATERIALIZED (
    SELECT * FROM public.v_hq_exceptions
  ),
  filtered AS (
    SELECT * FROM ex
    WHERE (p_type IS NULL OR p_type = 'all' OR ex.type = p_type)
  ),
  page AS (
    SELECT * FROM filtered
    ORDER BY ts DESC NULLS LAST, row_key
    LIMIT  GREATEST(1, p_page_size)
    OFFSET GREATEST(0, (p_page - 1) * p_page_size)
  )
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM filtered),
    'counts', (
      SELECT jsonb_build_object(
        'all',               COUNT(*),
        'po_shortage',       COUNT(*) FILTER (WHERE type = 'po_shortage'),
        'po_damage',         COUNT(*) FILTER (WHERE type = 'po_damage'),
        'po_over',           COUNT(*) FILTER (WHERE type = 'po_over'),
        'transfer_short',    COUNT(*) FILTER (WHERE type = 'transfer_short'),
        'customer_shortage', COUNT(*) FILTER (WHERE type = 'customer_shortage')
      )
      FROM ex
    ),
    'rows', (
      SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY ts DESC NULLS LAST, row_key), '[]'::jsonb)
      FROM page
    )
  );
$$;

COMMENT ON FUNCTION public.rpc_hq_exceptions(text, int, int) IS
  '總倉收件匣異常 server-side 分頁:回傳 { total, counts(各 tab), rows(當前頁) }。';

GRANT EXECUTE ON FUNCTION public.rpc_hq_exceptions(text, int, int) TO authenticated;

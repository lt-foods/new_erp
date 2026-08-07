-- ============================================================
-- v_hq_exceptions 效能:po_shortage / po_over 合併為單次掃描
--
-- 背景:rpc_hq_exceptions 整體 ~8s,已貼著 authenticated 角色的
--   statement_timeout(8s),anon(3s)直接逾時。實測分解:
--     v_picking_demand_by_po 單次掃描 ~4.5s ← 佔比最大
--     transfer_short ~1.8s / customer_shortage agg ~2.2s
--   而 view 裡 po_shortage 與 po_over 兩個 UNION 分支「各掃一次」
--   v_picking_demand_by_po(Postgres 不會跨 UNION 分支共用掃描),
--   等於白付一次 4.5s。
--
-- 解法:兩分支合併成一個子查詢單次掃描
--   (WHERE qty_shortage > 0 OR gr_qty > qty_ordered),
--   type / row_key / diff / extra 用 CASE 區分。兩條件互斥
--   (短少 = 訂>收、過量 = 收>訂),行為與舊版逐列一致。
--
-- 基於:20260807000050(doc_id / warehouse_name 版)。其餘分支、
--   欄位順序、rpc_hq_exceptions(20260807000060 的 p_search 版)不變。
-- Rollback:重跑 20260807000050 的 CREATE VIEW 段落。
-- ============================================================

DROP VIEW IF EXISTS public.v_hq_exceptions;

CREATE VIEW public.v_hq_exceptions AS
-- 1+3. 進貨短少 / 過量進貨(單次掃描 v_picking_demand_by_po,CASE 區分)
SELECT
  CASE WHEN pd.qty_shortage > 0 THEN 'po_shortage' ELSE 'po_over' END::text AS type,
  CASE WHEN pd.qty_shortage > 0 THEN 'po-short-' ELSE 'po-over-' END
    || pd.po_id::text || ':' || pd.sku_id::text                             AS row_key,
  po.created_at                                              AS ts,
  pd.po_no                                                   AS doc_no,
  pd.sku_code                                                AS sku_code,
  pd.sku_label                                               AS sku_label,
  pd.qty_ordered::numeric                                    AS expected,
  pd.gr_qty::numeric                                         AS actual,
  CASE WHEN pd.qty_shortage > 0 THEN pd.qty_shortage
       ELSE pd.gr_qty - pd.qty_ordered END::numeric          AS diff,
  NULL::text                                                 AS reason,
  CASE WHEN pd.qty_shortage > 0 THEN 'PO 已關單,差額不會到'
       ELSE '供應商多送或重複入庫' END::text                  AS extra,
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
  NULL::text                                                 AS shortage_resolution,
  pd.po_id::bigint                                           AS doc_id,
  (SELECT l.name FROM public.locations l WHERE l.id = po.dest_location_id) AS warehouse_name
FROM (
  SELECT DISTINCT po_id, sku_id, po_no, sku_code, sku_label, qty_ordered, gr_qty, qty_shortage
  FROM public.v_picking_demand_by_po
  WHERE qty_shortage > 0 OR gr_qty > qty_ordered
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
  NULL::text,
  gr.po_id::bigint,
  (SELECT l.name FROM public.locations l WHERE l.id = gr.dest_location_id)
FROM public.goods_receipt_items gri
JOIN public.goods_receipts gr ON gr.id = gri.gr_id
LEFT JOIN public.skus s ON s.id = gri.sku_id
WHERE gri.qty_damaged > 0
  AND gr.status = 'confirmed'

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
  NULL::text,
  ti.transfer_id::bigint,
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  )
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
  agg.shortage_resolution,
  agg.order_id::bigint,
  agg.store_name
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
  '供 rpc_hq_exceptions 做 server-side 分頁與計數。'
  '20260807000050 起含 doc_id / warehouse_name;20260807000070 起 po 兩類合併單次掃描。';

NOTIFY pgrst, 'reload schema';

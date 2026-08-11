-- ============================================================
-- v_hq_exceptions：收編線上 drift + 「地點」改由 warehouse_name 統一供應
--
-- 動機：
--   /wms/exceptions 的「收貨短少」「過量進貨」看不出是哪一間店 / 哪個倉收的，
--   只有「訂單短少」把店名塞在 extra 開頭（`四號店 · 會員 #68599 · …`）。
--   線上其實**每一種異常都已經有 warehouse_name 欄位**（見下方 drift），
--   只是前端沒有畫出來。這一檔把 extra 裡重複的店名拿掉，改由前端統一用
--   warehouse_name 畫成獨立的「地點」欄，五種異常一致。
--     po_shortage / po_damage / po_over → PO / GR 的收貨地點（多為「經總倉」）
--     transfer_short                    → 收貨分店（永和店 / 忠順店 …）
--     customer_shortage                 → 取貨店
--
-- 線上 drift（repo 從 20260704000020 之後就沒再記錄過，本檔一併收編，
--   下次誰要改這支 view 請以本檔為基底，不要回去抄 20260704000020）：
--   1. 多了 doc_id、warehouse_name 兩欄。
--   2. po_shortage / po_over 合併成同一個 UNION 分支（同一個 DISTINCT
--      子查詢用 qty_shortage > 0 決定 type），不再掃 v_picking_demand_by_po 兩次。
--   3. transfer_short 的 reason 改成帶出店家收貨備註
--      （`店家收貨備註：<t.notes>`）。
--   4. transfer_short 的 WHERE 放寬：shortage_resolution='replenish'
--      （已標補出貨）的列**繼續列出**，直到之後同店同 SKU 的收貨量補滿
--      缺口為止；extra 會加註「· 已標補出貨,尚未補到」。
--
-- 本檔唯一的行為變更：customer_shortage 的 extra 去掉開頭的
--   `<店名> · `，只留 `會員 #<id> · <N> 樣品項短少`（店名改走 warehouse_name）。
--   其餘一律與線上現行定義逐字相同。
--
-- 基於：2026-08-11 線上 pg_get_viewdef('public.v_hq_exceptions') 逐字取回。
-- Rollback：CREATE OR REPLACE VIEW 回本檔內文，把 customer_shortage 的
--   extra 還原成 `COALESCE(agg.store_name,'—') || ' · 會員 #' || …`。
-- ============================================================

CREATE OR REPLACE VIEW public.v_hq_exceptions AS
-- 1+3. 進貨短少 / 過量進貨（同一次掃描，用 qty_shortage 決定 type）
SELECT
  CASE WHEN pd.qty_shortage > 0 THEN 'po_shortage' ELSE 'po_over' END::text AS type,
  (CASE WHEN pd.qty_shortage > 0 THEN 'po-short-' ELSE 'po-over-' END
    || pd.po_id::text || ':' || pd.sku_id::text)                            AS row_key,
  po.created_at                                                             AS ts,
  pd.po_no                                                                  AS doc_no,
  pd.sku_code,
  pd.sku_label,
  pd.qty_ordered::numeric                                                   AS expected,
  pd.gr_qty                                                                 AS actual,
  CASE WHEN pd.qty_shortage > 0 THEN pd.qty_shortage
       ELSE pd.gr_qty - pd.qty_ordered END                                  AS diff,
  NULL::text                                                                AS reason,
  CASE WHEN pd.qty_shortage > 0 THEN 'PO 已關單,差額不會到'
       ELSE '供應商多送或重複入庫' END::text                                 AS extra,
  NULL::bigint                                                              AS transfer_item_id,
  NULL::bigint                                                              AS transfer_id,
  NULL::text                                                                AS transfer_no,
  pd.sku_id,
  NULL::numeric                                                             AS qty_shipped,
  NULL::numeric                                                             AS qty_received,
  NULL::numeric                                                             AS shortage_qty,
  NULL::bigint                                                              AS dest_location,
  NULL::bigint                                                              AS dest_store_id,
  NULL::text                                                                AS dest_store_name,
  NULL::bigint                                                              AS customer_order_id,
  NULL::text                                                                AS shortage_resolution,
  pd.po_id                                                                  AS doc_id,
  (SELECT l.name FROM locations l WHERE l.id = po.dest_location_id)         AS warehouse_name
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
  gri.qty_received - gri.qty_damaged,
  gri.qty_damaged::numeric,
  gri.variance_reason,
  '已收 ' || gri.qty_received::text || ' 含瑕疵 ' || gri.qty_damaged::text,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  gri.sku_id,
  NULL::numeric,
  NULL::numeric,
  NULL::numeric,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  NULL::bigint,
  NULL::text,
  gr.po_id,
  (SELECT l.name FROM locations l WHERE l.id = gr.dest_location_id)
FROM public.goods_receipt_items gri
JOIN public.goods_receipts gr ON gr.id = gri.gr_id
LEFT JOIN public.skus s ON s.id = gri.sku_id
WHERE gri.qty_damaged > 0
  AND gr.status = 'confirmed'

UNION ALL

-- 4. 收貨短少（轉貨 received 但實收 < 出貨；已標補出貨但還沒補到的也繼續列）
SELECT
  'transfer_short'::text,
  'tshort-' || ti.id::text,
  COALESCE(t.received_at, t.created_at),
  t.transfer_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || ti.sku_id::text),
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_shipped - ti.qty_received,
  CASE WHEN NULLIF(TRIM(COALESCE(t.notes,'')), '') IS NOT NULL
       THEN '店家收貨備註：' || TRIM(t.notes) ELSE NULL END,
  (CASE WHEN COALESCE(ti.damage_qty, 0) > 0 THEN '含破損 ' || ti.damage_qty::text
        ELSE '分店少收或運送中遺失' END)
  || (CASE WHEN ti.shortage_resolution = 'replenish' THEN ' · 已標補出貨,尚未補到' ELSE '' END),
  ti.id,
  ti.transfer_id,
  t.transfer_no,
  ti.sku_id,
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_shipped - ti.qty_received,
  t.dest_location,
  (SELECT ds.id FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  ),
  NULL::bigint,
  NULL::text,
  ti.transfer_id,
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  )
FROM public.transfer_items ti
JOIN public.transfers t ON t.id = ti.transfer_id
LEFT JOIN public.skus s ON s.id = ti.sku_id
WHERE t.status = 'received'
  AND ti.qty_received < ti.qty_shipped
  AND (
    ti.shortage_resolution IS NULL
    OR (
      ti.shortage_resolution = 'replenish'
      AND COALESCE((
        SELECT SUM(ti2.qty_received)
        FROM public.transfers t2
        JOIN public.transfer_items ti2 ON ti2.transfer_id = t2.id
        WHERE t2.dest_location = t.dest_location
          AND t2.tenant_id = t.tenant_id
          AND ti2.sku_id = ti.sku_id
          AND t2.status IN ('received', 'closed')
          AND COALESCE(t2.received_at, t2.updated_at) > ti.shortage_resolution_at
      ), 0) < (ti.qty_shipped - ti.qty_received)
    )
  )

UNION ALL

-- 5. 訂單短少（v_order_shortage order×sku → 聚合到 order）
--    extra 不再帶店名 —— 店名走 warehouse_name，前端畫成獨立的「地點」欄
SELECT
  'customer_shortage'::text,
  'custshort-' || agg.order_id::text,
  agg.ts,
  agg.order_no,
  NULL::text,
  agg.sku_label,
  agg.expected,
  GREATEST(0, agg.expected - agg.total_unfulfillable),
  agg.total_unfulfillable,
  CASE agg.shortage_resolution
    WHEN 'notified'        THEN '✓ 已通知客戶'
    WHEN 'cancelled'       THEN '✓ 已取消退款'
    WHEN 'reallocated'     THEN '✓ 已改派'
    WHEN 'waiting_next_po' THEN '⏳ 等下批 PO'
    ELSE NULL
  END,
  '會員 #' || COALESCE(agg.member_id::text, '—') || ' · ' || agg.short_item_count::text || ' 樣品項短少',
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
  agg.order_id,
  agg.shortage_resolution,
  agg.order_id,
  agg.store_name
FROM (
  SELECT
    vos.order_id,
    MAX(vos.order_no)             AS order_no,
    MAX(vos.member_id)            AS member_id,
    MAX(vos.store_name)           AS store_name,
    MAX(vos.shortage_resolution)  AS shortage_resolution,
    MAX(vos.order_updated_at)     AS ts,
    SUM(vos.order_qty)            AS expected,
    SUM(vos.demand_unfulfillable) AS total_unfulfillable,
    COUNT(*)                      AS short_item_count,
    string_agg(
      CASE
        WHEN vos.sku_code IS NOT NULL AND vos.sku_code <> ''
          THEN vos.sku_code || ' ' || COALESCE(NULLIF(TRIM(COALESCE(vos.product_name,'') || COALESCE(' / ' || NULLIF(vos.variant_name,''), '')), ''), '品項#' || vos.sku_id::text)
        ELSE COALESCE(NULLIF(TRIM(COALESCE(vos.product_name,'') || COALESCE(' / ' || NULLIF(vos.variant_name,''), '')), ''), '品項#' || vos.sku_id::text)
      END,
      '、' ORDER BY vos.sku_id
    )                             AS sku_label
  FROM public.v_order_shortage vos
  GROUP BY vos.order_id
) agg;

GRANT SELECT ON public.v_hq_exceptions TO authenticated;

COMMENT ON VIEW public.v_hq_exceptions IS
  '總倉收件匣異常統一 view:union 進貨短少/破損/過量/收貨短少/訂單短少 5 來源為扁平列,'
  '供 rpc_hq_exceptions 做 server-side 分頁與計數。'
  'warehouse_name = 該筆異常的地點（PO/GR 收貨倉、收貨分店、取貨店），前端畫成「地點」欄。';

-- ============================================================
-- 2026-08-11: 總倉收件匣「異常」移除「訂單短少」(customer_shortage) 來源
--
-- 決策（使用者 2026-08-11）：訂單短少是前瞻推算（v_order_shortage：
-- 未到貨需求 vs 現在拿得出的貨），供應商短交後必然大量出現；總倉已經從
-- 「進貨短少」「收貨短少」兩個實績分頁知道哪些貨少了，這個分頁 290 筆
-- 只是噪音 → 收件匣不再顯示。
--
-- 修法：v_hq_exceptions 拿掉第 5 來源（customer_shortage），
--   其餘來源逐字保留。欄位形狀不變（25 欄同名同序同型別，
--   customer_order_id / shortage_resolution 對其餘來源本來就是 NULL）→
--   rpc_hq_exceptions 免改（counts.customer_shortage 自然歸 0），
--   收件匣「⚠️ 異常」徽章（= counts.all）同步少掉這批。
--   線上實測：531 → 242（290 筆訂單短少歸零）。
--
-- 保留不動：
--   - v_order_shortage 本身（收件匣 URL 直達的「短少訂單」legacy 來源、
--     rpc_hq_shortage_orders、rpc_handle_shortage_order 仍在用）。
--   - 前端 ExceptionsContent 的訂單短少分頁與批次處理 UI 同步移除（同 PR）。
--
-- 基於：20260811010010_hq_exceptions_capture_drift.sql（最新版；
--   該檔已收編線上 drift：po_shortage/po_over 合併掃描、doc_id /
--   warehouse_name 欄、replenish 未補到重新浮上來、店家收貨備註進 reason）。
-- Rollback：CREATE OR REPLACE VIEW 回 20260811010010 版本
--   （補回 customer_shortage 分支）。
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
  );

GRANT SELECT ON public.v_hq_exceptions TO authenticated;

COMMENT ON VIEW public.v_hq_exceptions IS
  '總倉收件匣異常統一 view:union 進貨短少/破損/過量/收貨短少 4 來源為扁平列,'
  '供 rpc_hq_exceptions 做 server-side 分頁與計數。'
  'warehouse_name = 該筆異常的地點（PO/GR 收貨倉、收貨分店），前端畫成「地點」欄。'
  '訂單短少(customer_shortage)於 2026-08-11 移除 — 前瞻推算噪音大,'
  '實際短交已由進貨短少/收貨短少覆蓋;v_order_shortage 本身保留。';

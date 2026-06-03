-- ============================================================
-- v_picking_wave_campaign_mismatch：撿貨單「跨開團誤撿 / 無需求超撿」偵測視圖（唯讀防呆）
--
-- 背景：
--   同一賣場每週重開一團（product_id 相同、SKU 相同）是正常營運模式，不能硬擋。
--   真正的風險是「某店某 SKU 被撿到一張『其開團對該店該 SKU 根本沒有訂單需求』的
--   PO 上」——也就是把 A 團的貨撿去服務 B 團的訂單（GRP-20260531-002-0005 即此類）。
--   rpc_create_wave_from_po 已在「建撿貨單」時擋掉這種跨團誤撿；本視圖負責把
--   「已經發生」的存量撈出來給人複核 / 清理。
--
-- 判定（與 rpc_create_wave_from_po 守衛同一條不變式）：
--   一筆 picking_wave_item（wave 非 cancelled、有 source_po_id），若
--     (a) 其來源 PO 對應的「任何開團」都沒有該 (store, sku) 的活訂單需求，且
--     (b) 也沒有對應的補貨 (restock) 需求
--   → 列為 mismatch。
--
-- demand_actually_in：該 (store, sku) 實際有活訂單、但不在此 PO 開團清單內的開團編號。
--   - 有值 → 跨團誤撿，這批貨其實屬於該開團的訂單（victim）。
--   - NULL → 該店該 SKU 任何開團都沒需求 → 純超撿 / 訂單已取消，需人工確認。
--
-- 用途：純診斷，不阻擋任何流程。Rollback：DROP VIEW。
-- ============================================================

CREATE OR REPLACE VIEW public.v_picking_wave_campaign_mismatch AS
SELECT
  p.tenant_id,
  p.wave_id,
  pw.wave_code,
  pw.status        AS wave_status,
  pw.source_po_id  AS po_id,
  po.po_no,
  p.store_id,
  st.name          AS store_name,
  p.sku_id,
  s.sku_code,
  COALESCE(s.product_name,'') || COALESCE(' ' || NULLIF(s.variant_name,''),'') AS sku_label,
  p.qty,
  p.campaign_id    AS tagged_campaign_id,
  ( SELECT string_agg(DISTINCT c2.campaign_no, ', ' ORDER BY c2.campaign_no)
      FROM customer_orders co2
      JOIN customer_order_items coi2 ON coi2.order_id = co2.id
      JOIN group_buy_campaigns c2 ON c2.id = co2.campaign_id
     WHERE co2.pickup_store_id = p.store_id
       AND coi2.sku_id = p.sku_id
       AND co2.status NOT IN ('cancelled','expired','transferred_out')
       AND co2.transferred_from_order_id IS NULL
       AND coi2.status NOT IN ('cancelled','expired')
  ) AS demand_actually_in
FROM picking_wave_items p
JOIN picking_waves pw ON pw.id = p.wave_id
JOIN purchase_orders po ON po.id = pw.source_po_id
JOIN skus s ON s.id = p.sku_id
LEFT JOIN stores st ON st.id = p.store_id
WHERE pw.status <> 'cancelled'
  AND pw.source_po_id IS NOT NULL
  -- (a) 此 PO 的開團都沒有該 (store, sku) 的活訂單需求
  AND NOT EXISTS (
    SELECT 1
    FROM (
      SELECT prc.campaign_id
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
        JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
       WHERE poi.po_id = pw.source_po_id
      UNION
      SELECT pri.source_campaign_id
        FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id = poi.id
       WHERE poi.po_id = pw.source_po_id
         AND pri.source_campaign_id IS NOT NULL
    ) cand
    JOIN customer_orders co ON co.campaign_id = cand.campaign_id
                           AND co.pickup_store_id = p.store_id
                           AND co.status NOT IN ('cancelled','expired','transferred_out')
                           AND co.transferred_from_order_id IS NULL
    JOIN customer_order_items coi ON coi.order_id = co.id
                                 AND coi.sku_id = p.sku_id
                                 AND coi.status NOT IN ('cancelled','expired')
  )
  -- (b) 也不是補貨來源
  AND NOT EXISTS (
    SELECT 1
      FROM purchase_order_items poi
      JOIN purchase_request_items pri ON pri.po_item_id = poi.id
      JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                              AND rr.requesting_store_id = p.store_id
                              AND rr.status NOT IN ('cancelled','rejected')
      JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                    AND rrl.sku_id = p.sku_id
     WHERE poi.po_id = pw.source_po_id
       AND poi.sku_id = p.sku_id
  );

GRANT SELECT ON public.v_picking_wave_campaign_mismatch TO authenticated;

COMMENT ON VIEW public.v_picking_wave_campaign_mismatch IS
  '撿貨單跨開團誤撿 / 無需求超撿偵測（唯讀）。某 (store,sku) 被撿到一張其開團對該店該 '
  'SKU 沒有訂單需求、也非補貨來源的 PO 上即列出；demand_actually_in 指出這批貨實際該屬於哪些開團'
  '（NULL=任何開團都無需求，純超撿/訂單已取消）。與 rpc_create_wave_from_po 的跨團守衛同一不變式。';

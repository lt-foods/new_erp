-- ============================================================
-- rpc_receiving_workbench — admin /wms/receiving 進貨待辦清單聚合
--
-- 動機：進貨待辦頁讀取很慢。根因與 /orders 同源 — mount 時瀏覽器端跨
--   6 張表做 client join、4 個 sequential round-trip 波次，其中
--   restock_requests 是「無任何篩選撈整張表」(只為算 is_restock)，隨
--   營運累積越來越慢。
--
-- 修法：照 rpc_orders_pivot / rpc_order_overview 的 RETURNS jsonb 範本，
--   把整個聚合搬到伺服端、一次 round-trip 回傳 ready-to-render 列。
--   jsonb 單一 row 不受 PostgREST max_rows=1000 截斷。
--
-- 與既有 client 邏輯對齊（輸出不變）：
--   * 取 status IN (sent, partially_received, fully_received)，sent_at desc，上限 200
--   * total_qty_received = 來自 status='confirmed' 的 goods_receipt_items 加總
--     （沿用頁面的 authoritative 算法，不直接讀 poi.qty_received 避免漂移）
--   * is_restock = PO 任一 po_item 經 purchase_request_items 連到某 pr，
--     且該 pr 是 restock_requests.linked_pr_id
--   * 期間 / 狀態 filter 仍由前端對回傳列做（資料量小、即時切換）
--
-- 不下 SECURITY DEFINER：沿用 invoker RLS（與既有 client 查詢同一條
--   tenant 隔離路徑，與 rpc_orders_pivot 一致）。
--
-- 基底版本：無（全新 function）
-- rollback：DROP FUNCTION rpc_receiving_workbench();
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_receiving_workbench()
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH po AS (
    SELECT p.id, p.po_no, p.status, p.sent_at, p.supplier_id
    FROM purchase_orders p
    WHERE p.status IN ('sent','partially_received','fully_received')
    ORDER BY p.sent_at DESC NULLS LAST
    LIMIT 200
  ),
  poi AS (
    SELECT i.id, i.po_id, i.qty_ordered
    FROM purchase_order_items i
    JOIN po ON po.id = i.po_id
  ),
  received AS (
    -- 已到 = 已確認進貨單的明細加總（po_item 為單位）
    SELECT gi.po_item_id, SUM(gi.qty_received)::numeric AS qty
    FROM goods_receipt_items gi
    JOIN goods_receipts g ON g.id = gi.gr_id
    JOIN poi ON poi.id = gi.po_item_id
    WHERE g.status = 'confirmed'
    GROUP BY gi.po_item_id
  ),
  restock_poi AS (
    -- 來自補貨申請的 po_item（pr 被某 restock_requests linked_pr_id 指向）
    SELECT DISTINCT pri.po_item_id
    FROM purchase_request_items pri
    JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
    WHERE pri.po_item_id IS NOT NULL
  ),
  agg AS (
    SELECT
      po.id,
      po.po_no,
      po.status,
      po.sent_at,
      po.supplier_id,
      s.name                                            AS supplier_name,
      s.code                                            AS supplier_code,
      COALESCE(SUM(poi.qty_ordered), 0)::numeric        AS total_qty_ordered,
      COALESCE(SUM(r.qty), 0)::numeric                  AS total_qty_received,
      COUNT(poi.id)                                     AS line_count,
      bool_or(rp.po_item_id IS NOT NULL)                AS is_restock
    FROM po
    LEFT JOIN suppliers s ON s.id = po.supplier_id
    LEFT JOIN poi ON poi.po_id = po.id
    LEFT JOIN received r ON r.po_item_id = poi.id
    LEFT JOIN restock_poi rp ON rp.po_item_id = poi.id
    GROUP BY po.id, po.po_no, po.status, po.sent_at, po.supplier_id, s.name, s.code
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', id,
        'po_no', po_no,
        'status', status,
        'sent_at', sent_at,
        'supplier_id', supplier_id,
        'supplier_name', COALESCE(supplier_name, '#' || supplier_id::text),
        'supplier_code', supplier_code,
        'total_qty_ordered', total_qty_ordered,
        'total_qty_received', total_qty_received,
        'line_count', line_count,
        'is_restock', COALESCE(is_restock, false)
      )
      ORDER BY sent_at DESC NULLS LAST
    ),
    '[]'::jsonb
  )
  FROM agg;
$$;

GRANT EXECUTE ON FUNCTION rpc_receiving_workbench() TO authenticated;

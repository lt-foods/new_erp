-- ============================================================
-- rpc_receiving_workbench v2 — 回傳每張 PO 的商品名（product_names）
--
-- 動機：進貨待辦 (/wms/receiving) 的搜尋框搜不到商品名。樓下倉管第一關
--   是「找到今天到的貨」，而本 RPC 只回 PO 層欄位（單號 / 廠商 / 數量 /
--   行數），一個商品名字都沒有，前端只能比對 po_no / supplier_name /
--   supplier_code。
--
-- 修法：新增一個 names CTE，從 v1 就有的 poi CTE 一次 GROUP BY 聚出每張
--   PO 的商品名 text[]（DISTINCT、濾掉 NULL、無資料給空陣列），聚合寫法
--   比照 rpc_po_list（20260812000000 Part 5 的
--   `array_agg(DISTINCT pd.name) FILTER (WHERE pd.name IS NOT NULL)`）。
--   poi 只多 SELECT 一個 sku_id（無 DISTINCT / GROUP BY，列數不變，
--   sku_id 又是 NOT NULL）→ agg 的 SUM / COUNT / bool_or 結果與 v1 相同。
--   期間 / 狀態 / 搜尋 filter 仍由前端對回傳列做（與 v1 相同）。
--
-- ⚠ 為什麼不用 LEFT JOIN LATERAL（rpc_po_list 的原寫法）：
--   `purchase_order_items` **沒有 po_id 索引** —— 建表（20260422120004:95-110）
--   只有 id 主鍵，po_id 是 FK 而 Postgres 不替 FK 自動建索引，全 repo 也沒有
--   任何 CREATE INDEX / UNIQUE 約束會隱式補上。lateral 掛在 200 列上 =
--   對這張表做 200 次掃描；而本 RPC 存在的理由就是效能（見 v1 檔頭），
--   那是明確退步。rpc_po_list 的 lateral 只跑在單頁 ~50 列上，情境不同。
--
-- ⚠ 為什麼不補索引解決：老闆本案明定不動資料庫結構；且正式庫上非
--   CONCURRENTLY 的 CREATE INDEX 會鎖表，這是已上線營運系統。改用一次性
--   聚合就不依賴索引存不存在。
--
-- 掃描次數與 v1 相同（零退步）：poi 在 v1 已被 received / agg 引用兩次，
--   多次引用的 CTE 不會被 inline（PG12+ 只 inline 單次引用者）→ 它是
--   materialize 的，names 是第三個引用者，讀的是同一份已物化結果，
--   `purchase_order_items` 全程仍只掃一次。新增的成本只有 skus / products
--   的主鍵查（與前端各頁既有作法同級）。
--
-- 未變動（與 20260708000020 逐字一致）：
--   * 取 status IN (sent, partially_received, fully_received)，sent_at desc，上限 200
--   * total_qty_ordered / total_qty_received / line_count / is_restock 算法
--   * 回傳排序 ORDER BY sent_at DESC NULLS LAST
--   * 不下 SECURITY DEFINER：沿用 invoker RLS（products / skus 都有
--     read_tenant_* SELECT policy，見 20260422120001_product_schema.sql:366-369）
--
-- 基底版本：20260708000020_rpc_receiving_workbench.sql（全 repo 唯一定義，
--   `grep -rln "FUNCTION rpc_receiving_workbench" supabase/migrations` 只有這一支）
-- rollback：重跑 20260708000020_rpc_receiving_workbench.sql 的 CREATE OR REPLACE
--   （回到不含 product_names 的 v1；前端讀不到該鍵時會退回空陣列，不會爆）
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
    -- v2 只多 SELECT 一個 sku_id 給 names 用；無 DISTINCT / GROUP BY，列數不變
    SELECT i.id, i.po_id, i.qty_ordered, i.sku_id
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
  names AS (
    -- 搜尋用：每張 PO 的商品名，一次 GROUP BY 聚完（不逐 PO 掃表）
    SELECT p2.po_id,
           array_agg(DISTINCT pd.name) FILTER (WHERE pd.name IS NOT NULL) AS product_names
    FROM poi p2
    LEFT JOIN skus     sk ON sk.id = p2.sku_id
    LEFT JOIN products pd ON pd.id = sk.product_id
    GROUP BY p2.po_id
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
        'is_restock', COALESCE(is_restock, false),
        -- 搜尋用：該 PO 所有品項的商品名（前端 haystack）
        'product_names', to_jsonb(COALESCE(n.product_names, ARRAY[]::text[]))
      )
      ORDER BY sent_at DESC NULLS LAST
    ),
    '[]'::jsonb
  )
  FROM agg
  LEFT JOIN names n ON n.po_id = agg.id;
$$;

GRANT EXECUTE ON FUNCTION rpc_receiving_workbench() TO authenticated;

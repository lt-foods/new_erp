-- ============================================================
-- rpc_receiving_workbench v3 — 未收完的單不再被 LIMIT 200 截掉
--
-- 病灶（正式庫實測 2026-08-20）：
--   v1/v2 的 po CTE 把 sent / partially_received / fully_received **三種狀態
--   混在一起** `ORDER BY sent_at DESC NULLS LAST LIMIT 200`。
--   fully_received 只會累積、而且 sent_at 比較新 → 它把「還沒收完的舊單」
--   一張一張擠出前 200 名。
--
--     符合白名單的採購單         979 張
--     其中還沒收完                275 張
--     被擠出前 200、完全看不到    151 張（149 張不是補貨來源＝真的在等收，10,013 件）
--     集中廠商：ROSA(貿峰) 20 / 山瀾商行 18 / 包子媽 11 / YCB 源和穗 10 / 有鮮 9 …
--
--   —— 那批正是 6 月～8/07 的貨，8 月起才會陸續收到。樓下 iPad 收貨頁
--   (/wms/receiving/ipad) 只吃這支 RPC，搜不到就收不了。
--
-- 修法（只動「撈哪些單進來」，不動任何欄位／算法／排序）：
--   * sent / partially_received  → **全取，不設上限**（現況 275 張）
--     這兩種是「作業中」的單，數量被現實綁住（收完就變 fully_received），
--     不會無限長。給它上限＝功能會隨時間自己壞掉，而且壞得沒有徵兆。
--   * fully_received             → 仍只取最近 200 張（`fr_recent`）
--     這種只增不減，必須有上限。它只服務畫面上「已收」檢視的翻閱需求，
--     不是收貨作業要看的東西。要調整就改 fr_recent 的 LIMIT，別動上面那半。
--
-- ⛔ 為什麼不用 UNION ALL 併兩段：
--   po 若同一個 id 出現兩列，下面 `FROM po LEFT JOIN poi` 會把該單的
--   SUM(qty_ordered) / SUM(r.qty) / COUNT(poi.id) **整組乘二**，而且畫面上
--   看起來只是數字大了一點，不會報錯。改成「單一 SELECT + 對 fully_received
--   多加一個條件」後，一張 PO 一列是 purchase_orders 主鍵保證的，
--   **結構上不可能重複**，不必靠後人記得維持兩段互斥。
--
-- 結果集是 v2 的**超集**（證明：v2 取的是三種狀態合起來的 sent_at top-200。
--   其中 sent / partially_received 那些，v3 全取 → 必含；其中 fully_received
--   那些，在「只看 fully_received」的排序裡名次只會往前，仍在 top-200 內 → 必含）。
--   ⇒ 舊畫面上看得到的單，改完一張都不會消失。
--
-- ⚠ 已知且刻意接受的副作用（不是 bug，是不截斷的必然結果）：
--   1. /wms/receiving 表頭「共 N 張 PO · 未收 · 部分收 · 全收」與四張 KPI 卡
--      是對**未經期間篩選的全部回傳列**算的（page.tsx:221-233）→ 數字會變大
--      （實測推估 共 200→475、未收 124→275、全收 76→200）。這是原本就少算，
--      不是新的錯。列表本體預設「近 7 天」，被翻出來的舊單不會混進去。
--   2. `sent_at IS NULL` 的未收單以前必定被 NULLS LAST 排掉，現在會出現。
--      辦公室頁在「今日 / 近 7 天」下仍看不到它們（dateRef 為空即濾掉），
--      只有「全部」與 iPad 頁會列出，日期顯示「—」。它們確實是還沒收的單。
--
-- ⚠ 為什麼上限剛好是 200、⛔ 不可以「為了快一點」調小：
--   v2 的 top-200 裡本來就混著一批已全收的單（正式庫今天 76 張，會隨未收
--   backlog 被收掉而往上飄，上限就是 200）。新的上限一旦低於那個數字，
--   **今天畫面上看得到的單，套完就會消失** —— 那才是真的改到辦公室行為。
--   200 是唯一「不管資料怎麼分佈都保證一張不掉」的值（v2 自己也只能給 200 張）。
--   harness 有一條測試專門釘住這件事（把上限改 50 → 實測掉 50 張）。
--
-- ⚠ 效能：`purchase_order_items` **沒有 po_id 索引**（20260422120004:95-110
--   只有 id 主鍵，Postgres 不替 FK 自動建索引；機制索引「四之七」）。
--   → poi CTE 一定是 seq scan + hash join，**掃描次數與 po 有幾列無關**
--     （200 列或 475 列都是掃一次整表），變多的只有往後傳的列數。
--   pglite harness 實測（2,999 張 PO，白名單 979 張＝275 未收＋704 全收，
--   日期分佈照正式庫調成「v2 漏看 175 張未收單」；同一份資料同一顆 process
--   交叉輪替 12 回合取中位數）。每張 PO 的品項行數正式庫不明，故跑兩組夾住：
--
--     每張 PO 行數      回傳列數   v2 現況    v3 本版      差
--     平均 7（21,210 列）  200→475   11.2 ms   16.7 ms   +5.5 ms (+49%)
--     平均 27（81,926 列） 200→475   29.2 ms   49.0 ms   +19.8 ms (+68%)
--
--   ⭐ 拆開看：「未收完不截斷」本身幾乎免費（275 列時 10.9 / 33.2 ms，
--     即 −2% / +13%）；多出來的時間**全部**來自把已全收的額度從 100 拉到 200
--     —— 而那是上面說的「不能調小」換來的。
--   計畫形狀沒變：purchase_order_items 兩版都是 Seq Scan、全程只掃一次，
--   ⛔ 沒有退化成 N+1 → **不需要**新增索引（正式庫上非 CONCURRENTLY 的
--   CREATE INDEX 會鎖表）。
--   ⚠ pglite 是記憶體內 WASM Postgres，絕對值不等於正式庫；有意義的是
--     「相對差」與「計畫形狀」。正式庫的 RLS（poi_hq_all 是 EXISTS 子查詢，
--     20260502010000:37-45）兩版一模一樣，是固定成本。
--
-- 未變動（與 20260819000000 逐字一致，只有 po CTE 換掉）：
--   poi / received / restock_poi / names / agg 全部原樣；
--   total_qty_ordered / total_qty_received / line_count / is_restock 算法；
--   product_names 聚合；回傳鍵名與 `ORDER BY sent_at DESC NULLS LAST`；
--   不下 SECURITY DEFINER（沿用 invoker RLS）；GRANT TO authenticated。
--
-- 基底版本：20260819000000_receiving_workbench_product_names.sql
-- rollback：重跑 20260819000000 那支的 CREATE OR REPLACE（回到 v2 的 LIMIT 200）
-- ============================================================

-- ------------------------------------------------------------
-- ⚠ 前置檢查放在所有 DDL 之前（fail fast）
--   本檔是「開檔複製全文、貼進 Supabase SQL Editor 執行」的用法 ＝ autocommit，
--   **沒有交易包覆**。檔尾才檢查的話，DDL 早就各自提交了，畫面說失敗也收不回。
--   （機制索引「四之五」第 ⑤ 點）
-- ------------------------------------------------------------
DO $guard$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_def
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'rpc_receiving_workbench'
     AND p.pronargs = 0;

  IF v_def IS NULL THEN
    RAISE EXCEPTION
      '找不到 public.rpc_receiving_workbench()。這支正式庫上本來就該有（進貨待辦整頁靠它）—— 先確認連對資料庫，不要繼續貼。';
  END IF;

  -- 正式庫必須已經是 v2（含 product_names）。不是的話代表 20260819000000
  -- 那支還沒貼過；本檔是基於 v2 擴寫的，一次跳兩版會讓「哪一版改壞了」
  -- 事後分不清楚。⇒ 停下來、先貼上一支，再回來貼這支。
  IF v_def NOT LIKE '%product_names%' THEN
    RAISE EXCEPTION
      '正式庫上的 rpc_receiving_workbench() 還沒有 product_names，代表 20260819000000_receiving_workbench_product_names.sql 尚未套用。請「先」貼那一支、成功後再貼本檔。（本檔什麼都還沒改，可以安心離開）';
  END IF;

  IF v_def LIKE '%fr_recent%' THEN
    RAISE NOTICE '偵測到本檔已經套過（函式裡有 fr_recent）。重貼是安全的，內容會被換成一模一樣的版本。';
  END IF;
END
$guard$;

-- ------------------------------------------------------------
-- 以下開始改東西
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_receiving_workbench()
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH fr_recent AS (
    -- 已全收的單只增不減，必須有上限；它只服務「已收」檢視的翻閱。
    -- ⚠ 要調整能翻多久，改這裡的 LIMIT —— ⛔ 不要把上限加回下面那半。
    SELECT p.id
    FROM purchase_orders p
    WHERE p.status = 'fully_received'
    ORDER BY p.sent_at DESC NULLS LAST
    LIMIT 200
  ),
  po AS (
    -- v3：白名單與 v2 相同，差別只在「上限只套在 fully_received 上」。
    -- 單一 SELECT ⇒ 一張 PO 保證只有一列（見檔頭「為什麼不用 UNION ALL」）。
    SELECT p.id, p.po_no, p.status, p.sent_at, p.supplier_id
    FROM purchase_orders p
    WHERE p.status IN ('sent','partially_received','fully_received')
      AND (
        -- 還沒收完的：全取，不設上限
        p.status <> 'fully_received'
        -- 已全收的：只留最近 200 張
        OR p.id IN (SELECT id FROM fr_recent)
      )
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

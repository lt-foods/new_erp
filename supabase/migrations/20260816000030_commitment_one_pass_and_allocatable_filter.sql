-- ============================================================
-- 1. rpc_get_stock_commitment_bulk 改成「一間店一趟」（修效能）
-- 2. 新增 rpc_list_allocatable_pairs：庫存總覽「只看可配給客人」篩選用
--
-- 動機（2026-08-16，同日回報「再做一個 filter 可以過濾出來可以配給客人」）：
--
--   量測發現 20260816000020 那版 bulk 踩到 CLAUDE.md 記過的 per-SKU LATERAL 陷阱：
--   它對 p_pairs 的**每一列**各呼叫一次 _sku_commitment，一頁 50 列就把該店的
--   訂單掃 50 遍。文山店（1,704 張單）實測 **3.8 秒** —— PostgREST 8 秒就斷，
--   而且列表每翻一頁都吃一次。想拿它掃全站更是直接
--   `canceling statement due to statement timeout`（>120s）。
--
--   `_sku_commitment` 本來就設計成「傳一個 SKU 陣列、單趟 GROUP BY 算完」
--   （20260816000000 檔頭寫得很清楚，就是為了不要重蹈
--   _advance_arrived_confirmed_orders 的 8.5s timeout）。20260816000020
--   卻用 ARRAY[單一 sku] 呼叫，等於把那個設計浪費掉。
--
--   → 本支改成：先把 p_pairs 依倉別分組，**一間店只呼叫一次**
--     _sku_commitment(store, 該店被問到的所有 SKU)，再 join 回來。
--
-- rollback:
--   重跑 20260816000020 的 rpc_get_stock_commitment_bulk（會退回慢的版本）；
--   DROP FUNCTION IF EXISTS public.rpc_list_allocatable_pairs(BIGINT, BIGINT[], INT);
-- 基底：_sku_commitment = 20260816000000；bulk = 20260816000020
-- ============================================================

-- ------------------------------------------------------------
-- 1. bulk：一間店一趟
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_stock_commitment_bulk(
  p_pairs JSONB   -- [{"location_id": 3, "sku_id": 704}, ...]
) RETURNS TABLE (
  location_id BIGINT,
  sku_id      BIGINT,
  promised    NUMERIC,
  waiting     NUMERIC,
  pool        NUMERIC,
  free        NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH req AS (
    SELECT DISTINCT
           (e ->> 'location_id')::BIGINT AS loc_id,
           (e ->> 'sku_id')::BIGINT      AS s_id
      FROM jsonb_array_elements(COALESCE(p_pairs, '[]'::jsonb)) e
  ),
  -- 只有「有對應分店」的倉別才談得上承諾（總倉沒有客人訂單掛在上面）
  st AS (
    SELECT s.id AS store_id, s.tenant_id, s.location_id
      FROM stores s
     WHERE s.location_id IN (SELECT DISTINCT loc_id FROM req)
  ),
  -- ★ 一間店一次：把該店被問到的所有 SKU 一起丟進去，單趟 GROUP BY 算完。
  --   不要寫成 LEFT JOIN LATERAL _sku_commitment(store, ARRAY[req.s_id])
  --   —— 那會變成每列掃一遍該店訂單（文山 50 列 = 3.8s）。
  comm AS (
    SELECT st.location_id, k.sku_id, k.promised, k.waiting, k.pool_claimed
      FROM st
      CROSS JOIN LATERAL public._sku_commitment(
        st.store_id,
        ARRAY(SELECT r.s_id FROM req r WHERE r.loc_id = st.location_id)
      ) k
  )
  SELECT req.loc_id,
         req.s_id,
         COALESCE(c.promised, 0),
         COALESCE(c.waiting, 0),
         COALESCE(c.pool_claimed, 0),
         GREATEST(
           COALESCE(sb.on_hand, 0)
           - COALESCE(c.promised, 0)
           - COALESCE(c.waiting, 0)
           - COALESCE(c.pool_claimed, 0),
           0)
    FROM req
    JOIN st ON st.location_id = req.loc_id
    LEFT JOIN stock_balances sb
           ON sb.tenant_id   = st.tenant_id
          AND sb.location_id = st.location_id
          AND sb.sku_id      = req.s_id
    LEFT JOIN comm c
           ON c.location_id = req.loc_id
          AND c.sku_id      = req.s_id;
$$;

COMMENT ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) IS
  '庫存總覽列表用：一次算一整頁 (倉別, SKU) 的已承諾 / 等貨 / 池子 / 可分配。'
  '可分配＝on_hand − promised − waiting − pool_claimed（下限 0），與 _sku_free_qty 同一套。'
  '20260816000030：改成一間店只呼叫一次 _sku_commitment（原本每列一次，文山 50 列 3.8s）。'
  '沒有對應分店的倉別（總倉）不回列 —— 那裡沒有客人訂單，談不上承諾。';

REVOKE ALL ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) TO authenticated;

-- ------------------------------------------------------------
-- 2. rpc_list_allocatable_pairs — 「只看可配給客人」篩選
--    回傳有自由量的 (倉別, SKU)。前端拿它當候選集合，
--    再照既有「只看低於補貨點」的作法去撈 stock_balances、自己分頁。
--
--    p_location_id 給 NULL = 全部倉別。p_sku_ids 是搜尋字串解析出來的
--    SKU 集合（前端已經先查過一次 skus），給 NULL 表示不限。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_list_allocatable_pairs(
  p_location_id BIGINT   DEFAULT NULL,
  p_sku_ids     BIGINT[] DEFAULT NULL,
  p_limit       INT      DEFAULT 5000
) RETURNS TABLE (
  location_id BIGINT,
  sku_id      BIGINT,
  free        NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH st AS (
    SELECT s.id AS store_id, s.tenant_id, s.location_id
      FROM stores s
     WHERE s.location_id IS NOT NULL
       AND (p_location_id IS NULL OR s.location_id = p_location_id)
  ),
  -- 一間店一次，NULL = 該店全部有承諾的 SKU（單趟 GROUP BY）
  comm AS (
    SELECT st.location_id, k.sku_id, k.promised, k.waiting, k.pool_claimed
      FROM st
      CROSS JOIN LATERAL public._sku_commitment(st.store_id, p_sku_ids) k
  )
  SELECT sb.location_id,
         sb.sku_id,
         sb.on_hand - COALESCE(c.promised, 0) - COALESCE(c.waiting, 0)
                    - COALESCE(c.pool_claimed, 0) AS free
    FROM st
    JOIN stock_balances sb
      ON sb.tenant_id   = st.tenant_id
     AND sb.location_id = st.location_id
     AND sb.on_hand     > 0
    LEFT JOIN comm c
           ON c.location_id = sb.location_id
          AND c.sku_id      = sb.sku_id
   WHERE (p_sku_ids IS NULL OR sb.sku_id = ANY (p_sku_ids))
     AND sb.on_hand - COALESCE(c.promised, 0) - COALESCE(c.waiting, 0)
                    - COALESCE(c.pool_claimed, 0) > 0
   ORDER BY free DESC, sb.sku_id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 5000), 1), 20000);
$$;

COMMENT ON FUNCTION public.rpc_list_allocatable_pairs(BIGINT, BIGINT[], INT) IS
  '庫存總覽「只看可配給客人」：回有自由量（可分配 > 0）的 (倉別, SKU)。'
  '可分配的定義與 _sku_free_qty / rpc_get_stock_commitment_bulk 完全同一套。'
  '一間店只呼叫一次 _sku_commitment；p_location_id 為 NULL 時掃全部分店，'
  '所以前端在「全部倉別」時要有心理準備比較慢（實測需要走過每間店的訂單一次）。';

REVOKE ALL ON FUNCTION public.rpc_list_allocatable_pairs(BIGINT, BIGINT[], INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_list_allocatable_pairs(BIGINT, BIGINT[], INT) TO authenticated;

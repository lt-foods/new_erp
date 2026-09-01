-- ============================================================================
-- 現場銷售 (3/3)：rpc_pos_search_products —— 結帳畫面的商品搜尋（含可賣量與售價）
-- ============================================================================
-- 結帳頁一次要畫一排商品，每一列都要「這家店還能賣幾件」＋「賣多少錢」。
--
-- ⚠ 為什麼不是前端每列各打一次 rpc_get_spot_availability：
--   那支內部是 `LATERAL _sku_commitment(store, ARRAY[p_sku_id])` —— 一次一個 SKU。
--   一頁 30 列就是把該店的訂單掃 30 遍，正是 CLAUDE.md 記過的
--   「吃陣列的批次函式不要包一層 per-row LATERAL」（文山店實測 3.8s → 收斂後 60ms，
--   63 倍）。本函式**先選出候選 SKU、再一次呼叫 _sku_commitment(store, 整包陣列)**。
--
-- 可賣量的公式與 _sku_free_qty_with_pool（20260824060000）逐字相同：
--   free           = on_hand − promised − waiting − pool_claimed
--   free_with_pool = on_hand − promised − waiting − (pool_claimed − pool_arrived)
--   兩者都夾 GREATEST(...,0)。**不要在這裡自己改公式** —— 列表、篩選、結帳閘門
--   三邊算法不一致就會出現「列表寫可賣 3、結帳說可賣 0」（20260824060000 修過）。
--   真正的閘門在 rpc_create_walkin_sale 裡會再驗一次，這裡只是畫面預檢。
--
-- 建議售價：零售價優先（20260827020000 定案，賣給終端客人收零售價），
--   零售/分店兩個價都回，前端照 canSeeBranch 決定分店價要不要顯示。
--
-- p_term 空 → 回該店「架上有貨」的品項（依在庫多寡排），當作結帳頁的預設清單。
--   （自由轉貨的虛擬 SKU MISC-01 一律排除，它不是真商品。）
-- p_term 有值 → 搜商品名 / 規格 / SKU 編號 / 條碼，**不限在庫**
--   （缺貨的也要找得到，才有辦法在結帳當下勾「補庫存」）。
--
-- 基底版本：無（新函式）。
-- Rollback：DROP FUNCTION public.rpc_pos_search_products(BIGINT, TEXT, INT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_pos_search_products(
  p_store_id BIGINT,
  p_term     TEXT DEFAULT NULL,
  p_limit    INT  DEFAULT 30
) RETURNS TABLE (
  sku_id         BIGINT,
  sku_code       TEXT,
  product_name   TEXT,
  variant_name   TEXT,
  on_hand        NUMERIC,
  promised       NUMERIC,
  waiting        NUMERIC,
  pool_claimed   NUMERIC,
  pool_arrived   NUMERIC,
  free           NUMERIC,
  free_with_pool NUMERIC,
  retail_price   NUMERIC,
  branch_price   NUMERIC,
  suggest_price  NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH st AS (
    SELECT s.id, s.tenant_id, s.location_id
      FROM stores s
     WHERE s.id = p_store_id
  ),
  term AS (
    SELECT NULLIF(TRIM(COALESCE(p_term, '')), '') AS t
  ),
  -- 候選集合：先收斂到最多 p_limit 筆，後面所有昂貴計算都只對這幾筆做
  cand AS (
    SELECT sk.id, sk.sku_code, sk.product_name, sk.variant_name,
           COALESCE(sb.on_hand, 0) AS on_hand
      FROM skus sk
      CROSS JOIN st
      CROSS JOIN term
      LEFT JOIN stock_balances sb
             ON sb.tenant_id   = st.tenant_id
            AND sb.location_id = st.location_id
            AND sb.sku_id      = sk.id
     WHERE sk.tenant_id = st.tenant_id
       AND sk.status = 'active'
       -- 自由轉貨的虛擬佔位 SKU（MISC-01「虛擬轉貨商品」，20260614000060）不是
       -- 真商品，實際品名放在 transfer_items.description 上。平鎮店身上就掛著
       -- 219 件，不排掉的話它會霸佔預設清單第一列。
       AND sk.sku_code <> 'MISC-01'
       AND (
             CASE
               -- 沒打字：只列架上有貨的（結帳頁的預設清單）
               WHEN term.t IS NULL THEN COALESCE(sb.on_hand, 0) > 0
               -- 打了字：不限在庫 —— 缺貨的也要找得到才勾得到「補庫存」
               ELSE sk.product_name ILIKE '%' || term.t || '%'
                 OR sk.variant_name ILIKE '%' || term.t || '%'
                 OR sk.sku_code     ILIKE '%' || term.t || '%'
                 OR EXISTS (SELECT 1 FROM barcodes b
                             WHERE b.sku_id = sk.id AND b.barcode_value = term.t)
             END
           )
     ORDER BY COALESCE(sb.on_hand, 0) DESC, sk.product_name, sk.variant_name
     LIMIT GREATEST(COALESCE(p_limit, 30), 1)
  ),
  -- ★ 一次呼叫、一趟 GROUP BY（不要 per-row LATERAL，見檔頭）
  com AS (
    SELECT c.*
      FROM public._sku_commitment(p_store_id, ARRAY(SELECT id FROM cand)) c
  )
  SELECT
    cand.id,
    cand.sku_code,
    cand.product_name,
    cand.variant_name,
    cand.on_hand,
    COALESCE(com.promised, 0),
    COALESCE(com.waiting, 0),
    COALESCE(com.pool_claimed, 0),
    COALESCE(com.pool_arrived, 0),
    GREATEST(cand.on_hand - COALESCE(com.promised, 0) - COALESCE(com.waiting, 0)
             - COALESCE(com.pool_claimed, 0), 0),
    GREATEST(cand.on_hand - COALESCE(com.promised, 0) - COALESCE(com.waiting, 0)
             - (COALESCE(com.pool_claimed, 0) - COALESCE(com.pool_arrived, 0)), 0),
    px.retail_price,
    px.branch_price,
    COALESCE(px.retail_price, px.branch_price, 0)
    FROM cand
    CROSS JOIN st
    LEFT JOIN com ON com.sku_id = cand.id
    LEFT JOIN LATERAL (
      SELECT
        (SELECT p.price FROM prices p
          WHERE p.tenant_id = st.tenant_id AND p.sku_id = cand.id AND p.scope = 'retail'
            AND p.effective_from <= NOW() AND (p.effective_to IS NULL OR p.effective_to > NOW())
          ORDER BY p.effective_from DESC LIMIT 1) AS retail_price,
        (SELECT p.price FROM prices p
          WHERE p.tenant_id = st.tenant_id AND p.sku_id = cand.id AND p.scope = 'branch'
            AND p.effective_from <= NOW() AND (p.effective_to IS NULL OR p.effective_to > NOW())
          ORDER BY p.effective_from DESC LIMIT 1) AS branch_price
    ) px ON TRUE
   ORDER BY cand.on_hand DESC, cand.product_name, cand.variant_name;
$$;

COMMENT ON FUNCTION public.rpc_pos_search_products(BIGINT, TEXT, INT) IS
  '現場銷售結帳頁的商品搜尋：回該店的在庫 / 承諾拆解 / 可賣量（free_with_pool）'
  '與建議售價（零售價優先）。候選收斂後只呼叫一次 _sku_commitment（吃陣列），'
  '不做 per-row LATERAL。20260901000020。';

REVOKE ALL ON FUNCTION public.rpc_pos_search_products(BIGINT, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_pos_search_products(BIGINT, TEXT, INT) TO authenticated;

-- ============================================================================
-- 現貨直配的建議售價改成「零售價優先」，並把零售/分店兩個價都回給前端
-- ============================================================================
-- 老闆 2026-08-27 交代：庫存總覽要看得到分店價跟零售價，「配給客人」要用零售價。
-- 原本 suggest_price 是 COALESCE(branch, retail, 0) —— 分店價優先，所以彈窗
-- 預填 $85（分店價）而不是 $109（零售價）。現貨直配是賣給終端客人，收零售價。
--
-- 基底版本：20260824060000（rpc_get_spot_availability 最新版，含池子拆解
--   pool_arrived / pool_in_transit / free_with_pool）。
-- rollback：重跑 20260824060000 該函式段落即可（本支只動 suggest_price 的
--   COALESCE 順序、多回 retail_price / branch_price 兩個 key，其餘逐字保留）。
--
-- 變更：
--   1. suggest_price = COALESCE(retail, branch, 0)（原本 branch 優先）。
--   2. 多回 'retail_price' / 'branch_price'（沒設價 = null）：
--      彈窗與庫存頁要同時顯示兩個價，讓店員看得出預填的是哪一個。
--      注意這支是 SECURITY DEFINER，branch_price 對 store_staff 也回得出來
--      —— 舊版 suggest_price 本來就是分店價、早就給 store_staff 看了，
--      沒有多洩漏；前端顯示照 canSeeBranch 收斂。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_get_spot_availability(
  p_store_id BIGINT,
  p_sku_id   BIGINT
) RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'on_hand',      COALESCE(oh.on_hand, 0),
    'promised',     COALESCE(c.promised, 0),
    'waiting',      COALESCE(c.waiting, 0),
    'pool',         COALESCE(c.pool_claimed, 0),
    'free',         public._sku_free_qty(p_store_id, p_sku_id),
    -- 池子拆解：已到貨的可以配（配掉會自動扣池子），在途的維持保留
    'pool_arrived',    COALESCE(c.pool_arrived, 0),
    'pool_in_transit', COALESCE(c.pool_claimed, 0) - COALESCE(c.pool_arrived, 0),
    'free_with_pool',  public._sku_free_qty_with_pool(p_store_id, p_sku_id),
    -- 賣給終端客人 → 零售價優先（2026-08-27 前是分店價優先）
    'suggest_price', COALESCE(px.retail_price, px.branch_price, 0),
    'retail_price',  px.retail_price,
    'branch_price',  px.branch_price
  )
    FROM (
      SELECT st.tenant_id, sb.on_hand
        FROM stores st
        LEFT JOIN stock_balances sb
               ON sb.tenant_id   = st.tenant_id
              AND sb.location_id = st.location_id
              AND sb.sku_id      = p_sku_id
       WHERE st.id = p_store_id
    ) oh
    LEFT JOIN LATERAL public._sku_commitment(p_store_id, ARRAY[p_sku_id]) c ON TRUE
    LEFT JOIN LATERAL (
      SELECT
        (SELECT p.price FROM prices p
          WHERE p.tenant_id = oh.tenant_id AND p.sku_id = p_sku_id AND p.scope = 'retail'
            AND p.effective_from <= NOW() AND (p.effective_to IS NULL OR p.effective_to > NOW())
          ORDER BY p.effective_from DESC LIMIT 1) AS retail_price,
        (SELECT p.price FROM prices p
          WHERE p.tenant_id = oh.tenant_id AND p.sku_id = p_sku_id AND p.scope = 'branch'
            AND p.effective_from <= NOW() AND (p.effective_to IS NULL OR p.effective_to > NOW())
          ORDER BY p.effective_from DESC LIMIT 1) AS branch_price
    ) px ON TRUE;
$$;

COMMENT ON FUNCTION public.rpc_get_spot_availability(BIGINT, BIGINT) IS
  '現貨直配彈窗的預檢：在庫 / 待客取 / 等貨中 / 內部池（含拆已到貨與在途）/ '
  '自由量 / 含池子可配量 / 建議售價（零售價優先）＋ 零售/分店價各自回傳。'
  '伺服端開單時會再驗一次 _sku_free_qty(_with_pool)，這裡只是畫面預檢。';

REVOKE ALL ON FUNCTION public.rpc_get_spot_availability(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_spot_availability(BIGINT, BIGINT) TO authenticated;

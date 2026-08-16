-- ============================================================
-- 庫存總覽列表直接顯示「已承諾 / 池子 / 可分配」
--
-- 回報（Alex 2026-08-16，附截圖）：「已承諾未取要在清單上就出現了，
--   清單上的可分配庫存要區分開來」。
--
-- 病灶：列表顯示的「可用」＝ on_hand − reserved，而 **reserved 全站沒在維護**
--   （2026-08-16 實測：7,712 筆有庫存的列，reserved <> 0 的是 **0 筆**）
--   → 「可用」永遠等於「在庫」，是一欄假的數字。
--   截圖那筆松山店 G01150-01：on_hand 3、reserved 0 → 列表寫「可用 3」，
--   但 promised 3 → 實際可分配是 **0**。店員在列表看到 3、點進去看到 0，
--   前後矛盾比沒有數字更糟。
--
-- 本支：提供批次版承諾量查詢給列表用（一次一頁 50 列，不要每列打一次 RPC）。
--   單列版 rpc_get_spot_availability（20260816000010）維持不動，modal 繼續用它
--   —— 那支還多回 suggest_price，列表用不到。
--
-- 為什麼回「每一組都給一列」而不是只回有承諾的組：
--   free 的算式（on_hand − promised − waiting − pool_claimed）留在伺服端算完再回，
--   前端只負責顯示。若只回有承諾的組、讓前端對其餘的自己補 free = on_hand，
--   等於把公式又抄了一份到前端 —— 那正是這一系列 migration 要消滅的東西。
--
-- 基底：_sku_commitment / _sku_free_qty = 20260816000000
-- rollback:
--   DROP FUNCTION IF EXISTS public.rpc_get_stock_commitment_bulk(JSONB);
-- ============================================================

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
     WHERE s.location_id IN (SELECT loc_id FROM req)
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
    LEFT JOIN LATERAL public._sku_commitment(st.store_id, ARRAY[req.s_id]) c ON TRUE;
$$;

COMMENT ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) IS
  '庫存總覽列表用：一次算一整頁 (倉別, SKU) 的已承諾 / 等貨 / 池子 / 可分配。'
  '可分配＝on_hand − promised − waiting − pool_claimed（下限 0），與 _sku_free_qty 同一套。'
  '沒有對應分店的倉別（總倉）不回列 —— 那裡沒有客人訂單，談不上承諾。';

REVOKE ALL ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_stock_commitment_bulk(JSONB) TO authenticated;

-- ============================================================
-- 2026-08-10: rpc_store_incoming_skus — 分店視角的「在途 / 現有」量
--
-- 問題（松山 2026-08-10「進貨好亂」）：
--   10:17 PO 分貨波次已把 TPE墊×2、便利貼×2 派給松山（顧客訂單的貨，
--   在途中、店端看不到），10:50 松山又對同樣的 SKU 開補貨申請 #360，
--   HQ 再從總倉撿一次 → 下午四張單同時到店、實體只有一份，
--   後兩張只能填 0 造成短收。根因：補貨申請建單時看不到
--   「已派未收」的在途量，重複叫貨。
--
-- 修法：新 RPC 給補貨申請建單頁（/restock/new）選完 SKU 時顯示
--   該 SKU 對本店的在途量（transfers status='shipped'、dest=本店，
--   含 hq_to_store / store_to_store）與店內現有量，在途 > 0 就
--   提示可能重複申請。只做提示不硬擋 —— 在途的可能是顧客訂單的貨，
--   店庫存要另外叫也是合法需求，判斷留給店長。
--
-- Rollback: DROP FUNCTION public.rpc_store_incoming_skus(BIGINT, BIGINT[]);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_store_incoming_skus(
  p_store_id BIGINT,
  p_sku_ids  BIGINT[]
) RETURNS TABLE (sku_id BIGINT, in_transit NUMERIC, on_hand NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH st AS (
    SELECT s.tenant_id, s.location_id
      FROM stores s
     WHERE s.id = p_store_id
       AND s.tenant_id = public._current_tenant_id()
       AND s.location_id IS NOT NULL
  ),
  ids AS (
    SELECT DISTINCT unnest(p_sku_ids) AS sku_id
  ),
  transit AS (
    SELECT ti.sku_id, SUM(ti.qty_shipped) AS qty
      FROM st
      JOIN transfers t
        ON t.tenant_id = st.tenant_id
       AND t.dest_location = st.location_id
       AND t.status = 'shipped'
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE ti.sku_id IN (SELECT i.sku_id FROM ids i)
     GROUP BY ti.sku_id
  ),
  bal AS (
    SELECT b.sku_id, b.on_hand
      FROM st
      JOIN stock_balances b
        ON b.tenant_id = st.tenant_id
       AND b.location_id = st.location_id
     WHERE b.sku_id IN (SELECT i.sku_id FROM ids i)
  )
  SELECT i.sku_id,
         COALESCE(tr.qty, 0)    AS in_transit,
         COALESCE(bal.on_hand, 0) AS on_hand
    FROM ids i
    LEFT JOIN transit tr ON tr.sku_id = i.sku_id
    LEFT JOIN bal ON bal.sku_id = i.sku_id;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_incoming_skus(BIGINT, BIGINT[]) TO authenticated;

COMMENT ON FUNCTION public.rpc_store_incoming_skus(BIGINT, BIGINT[]) IS
  '分店視角逐 SKU 的「在途量（已派未收，dest=本店的 shipped 調撥）＋店內現有量」。'
  '補貨申請建單頁用來提示重複申請。tenant 以 _current_tenant_id() 界定。';

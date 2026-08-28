-- ============================================================================
-- rpc_get_order_item_stock_budget 補回 location_id
--
-- 需求（Alex 2026-08-27）：訂單頁「📦 從庫存配貨」彈窗，可配上限是 0 時
-- 想直接在彈窗裡「一鍵新增庫存」再配掉，不要跳去庫存總覽另開一次。
-- 前端要呼叫 rpc_add_stock_by_product(p_location_id, p_sku_id, ...) 幫店家補帳，
-- 但 JSON 包裝只回了 sku_id、沒有 location_id —— _order_item_stock_budget 本體
-- 已經算出來了（st.s_location_id），只是包裝時漏掉沒放進去。
--
-- 基底：rpc_get_order_item_stock_budget = 20260824070000（唯一版本，本檔只加一個
-- JSON 欄位，_order_item_stock_budget / rpc_assign_stock_to_order_item 皆不改）。
-- Rollback：指回 20260824070000 的版本（拿掉 'location_id' 那一行）。
--
-- 對應前端（同一個 commit）：apps/admin/src/components/AssignStockModal.tsx
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_get_order_item_stock_budget(
  p_item_id BIGINT
) RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'item_id',              p_item_id,
    'order_id',             b.order_id,
    'order_no',             b.order_no,
    'order_status',         b.order_status,
    'store_id',             b.store_id,
    'store_name',           b.store_name,
    'location_id',          b.location_id,
    'sku_id',               b.sku_id,
    'sku_label',            b.sku_label,
    'item_qty',             b.item_qty,
    'item_status',          b.item_status,
    'backordered',          b.backordered,
    'assigned',             b.assigned,
    'on_hand',              b.on_hand,
    'committed',            b.committed,
    'waiting',              b.waiting,
    'pool',                 b.pool,
    'pool_arrived',         b.pool_arrived,
    'assignable',           LEAST(b.assignable,           GREATEST(b.item_qty - b.assigned, 0)),
    'assignable_with_pool', LEAST(b.assignable_with_pool, GREATEST(b.item_qty - b.assigned, 0)),
    'gate_ready',           public.is_order_item_pickup_ready(p_item_id)
  )
    FROM public._order_item_stock_budget(p_item_id) b;
$$;

COMMENT ON FUNCTION public.rpc_get_order_item_stock_budget(BIGINT) IS
  '訂單頁「從庫存配貨」彈窗的預檢：在庫 / 別人的主張 / 等貨 / 內部池 / 還能指派幾件 / '
  '這一行目前過不過取貨閘門。上限已夾到「本行還沒被指派的量」。'
  '含 location_id，供前端「上限不夠時一鍵新增庫存」呼叫 rpc_add_stock_by_product。';

REVOKE ALL ON FUNCTION public.rpc_get_order_item_stock_budget(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_order_item_stock_budget(BIGINT) TO authenticated;

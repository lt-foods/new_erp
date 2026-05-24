-- ============================================================
-- 統一兩條 status 來源：is_order_pickup_ready 改成 customer_orders.status='ready'
-- 的 thin alias。
--
-- 背景：
-- 系統內「訂單是否可取貨」歷史上有兩條獨立來源並存：
--   (1) customer_orders.status (text enum)：UI 的 status badge / label / timeline
--       全用這個，orderStatusLabel('ready')='可取貨'
--   (2) v_order_pickup_ready.pickup_ready (boolean，is_order_pickup_ready() 衍生)：
--       OrderDetail 的「取貨按鈕能不能按」用這個，從 transfers / picking_wave_items
--       實際收貨狀態算出
--
-- 兩條並存的歷史原因 (20260512000008 註解)：
--   「不依賴 customer_orders.status 同步」
-- — 當時 RPC 推進 status 不可靠。但現在 ship/receive 流程已成熟
-- (rpc_ship_aid_order, rpc_receive_transfer, rpc_mark_orders_shipping)、
-- status 是被妥善維護的。spot-check 結果 (此 migration 前) ：
--   - status='ready' 但 is_order_pickup_ready=false: 0 張
--   - is_order_pickup_ready=true 但 status!='ready': 0 張
-- 兩條來源實際完全一致 → 衍生函式已成 noise。
--
-- 過去兩個 bug (GRP-20260523-002-TF0008 / TF0009) 都是這兩條 diverge 造成
-- (一邊對、一邊錯、UI 看哪邊取決於畫面位置)。改 alias 後永遠不會 diverge。
--
-- 修法：is_order_pickup_ready 改成單行 SELECT status = 'ready'。
-- v_order_pickup_ready 是 wraps 函式、不需要動。
--
-- Rollback：CREATE OR REPLACE 回 20260629000020 / 20260615000010 的 Path A/B/C
-- 完整版本。
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_order_pickup_ready(p_order_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM customer_orders
     WHERE id = p_order_id AND status = 'ready'
  );
$function$;

COMMENT ON FUNCTION public.is_order_pickup_ready(bigint) IS
  'Alias for customer_orders.status = ''ready''。20260630 起 status 是 single '
  'source of truth；本函式僅為向後相容保留 (v_order_pickup_ready / 既有 caller)。';

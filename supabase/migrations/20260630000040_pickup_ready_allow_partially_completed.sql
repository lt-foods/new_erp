-- ============================================================
-- 2026-06-30: is_order_pickup_ready 放寬 — partially_completed 仍可取剩餘品項
--
-- 問題：部分取貨（分品項或分數量）後，訂單 status 變 'partially_completed'，
-- 但 is_order_pickup_ready 只認 status='ready'（20260629000030 thin-alias 版），
-- 導致剩餘 active 品項再也無法取貨（前端顯示「分店尚未收貨，無法取貨」，
-- 實際上貨早到了）。rpc_record_pickup 進入時也會被 is_order_pickup_ready 擋下。
--
-- 修法：放寬成「status='ready'，或 status='partially_completed' 且還有 active
-- 品項(pending/reserved/ready)」。partially_completed 一定是先 ready 過、被
-- 取走部分才產生的狀態，本來就代表「分店已收貨」，故可安全視為可繼續取。
--
-- 影響面：is_order_pickup_ready 的唯一 caller 是 rpc_record_pickup + 衍生
-- view v_order_pickup_ready。放寬後 partially_completed 訂單的剩餘品項能再次
-- 進入取貨流程，符合預期。
--
-- 基底版本：20260629000030_unify_pickup_ready_to_status.sql（thin alias）。
-- Rollback：CREATE OR REPLACE 回 20260629000030 的單行 status='ready' 版本。
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_order_pickup_ready(p_order_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM customer_orders co
     WHERE co.id = p_order_id
       AND (
         co.status = 'ready'
         OR (
           co.status = 'partially_completed'
           AND EXISTS (
             SELECT 1 FROM customer_order_items coi
              WHERE coi.order_id = co.id
                AND coi.status IN ('pending','reserved','ready')
           )
         )
       )
  );
$function$;

COMMENT ON FUNCTION public.is_order_pickup_ready(bigint) IS
  'Alias for customer_orders.status=''ready'' 或 (''partially_completed'' 且還有 '
  'active 品項)。20260630 放寬：部分取貨後剩餘品項仍可繼續取貨。';

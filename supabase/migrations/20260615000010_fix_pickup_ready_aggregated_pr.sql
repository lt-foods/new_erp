-- ============================================================
-- Fix: is_order_pickup_ready 對 close_date aggregated PR 過嚴
--
-- 背景：rpc_close_campaign 同日多 camp 走 close_date 路徑 →
-- rpc_create_pr_from_close_date 把多 camp 訂單合 1 PR → 1 wave、
-- 但 picking_wave_items.campaign_id 只能掛單一值（fn aggregate 用
-- MIN(gbc.id)）。導致 wave_items.campaign_id != order.campaign_id 對於
-- 非「MIN id」的 camp、is_order_pickup_ready 路徑 B 找不到 wave_items
-- 就算 transfer 已 received 也回 false、order 永遠不能 pickup。
--
-- 修法：加 Path C — 不檢 campaign_id 嚴格相等、改檢「所有 active items
-- 的 (sku, pickup_store) 都有對應 received/closed transfer 抵達該 store」。
-- 這 cover close_date aggregated PR 場景、且 path B 保留 (per-camp PR 兼容)。
--
-- 嚴重度：High — production 同日多團結單會卡所有非 first-camp 的 orders。
-- 影響範圍：所有 close_date PR 衍生的 orders。
--
-- 跑完 migration 應該立刻有大量 stuck orders 變 ready (取決於先前 stuck 量)。
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_order_pickup_ready(p_order_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM customer_orders co
     WHERE co.id = p_order_id
       AND co.status NOT IN ('completed','expired','cancelled','transferred_out')
       AND (
         -- Path A：互助訂單 — transfer 直接 FK 到 order
         EXISTS (
           SELECT 1 FROM transfers t
            WHERE t.customer_order_id = co.id
              AND t.tenant_id = co.tenant_id
              AND t.status IN ('received','closed')
         )
         OR
         -- Path B：普通團購 (per-camp PR) — wave_items.campaign_id 匹配
         EXISTS (
           SELECT 1
             FROM picking_wave_items pwi
             JOIN transfers t
               ON t.tenant_id = pwi.tenant_id
              AND t.transfer_type = 'hq_to_store'
              AND t.transfer_no = 'WAVE-' || pwi.wave_id || '-S' || co.pickup_store_id
              AND t.status IN ('received','closed')
            WHERE pwi.tenant_id = co.tenant_id
              AND pwi.campaign_id = co.campaign_id
              AND pwi.store_id = co.pickup_store_id
         )
         OR
         -- Path C (NEW)：close_date aggregated PR fallback
         -- 不檢 campaign_id 嚴格相等、改檢「所有 active items 的 (sku, store)
         -- 都有對應 received transfer」即算 ready。
         NOT EXISTS (
           SELECT 1 FROM customer_order_items coi
            WHERE coi.order_id = co.id
              AND coi.status NOT IN ('picked_up', 'cancelled', 'expired')
              AND NOT EXISTS (
                SELECT 1
                  FROM picking_wave_items pwi
                  JOIN transfers t
                    ON t.tenant_id = pwi.tenant_id
                   AND t.transfer_type = 'hq_to_store'
                   AND t.transfer_no = 'WAVE-' || pwi.wave_id || '-S' || co.pickup_store_id
                   AND t.status IN ('received','closed')
                 WHERE pwi.tenant_id = co.tenant_id
                   AND pwi.store_id = co.pickup_store_id
                   AND pwi.sku_id = coi.sku_id
              )
         )
       )
  );
$function$;

COMMENT ON FUNCTION public.is_order_pickup_ready(bigint) IS
  'Path A: 互助訂單; Path B: per-campaign PR (wave_items.campaign_id 嚴格); '
  'Path C (20260615 fix): close_date aggregated PR — 所有 active items 的 '
  '(sku, store) 都有 received transfer 即算 ready (不檢 campaign_id 一致)。';

-- 跑 migration 後印 stuck orders 變 ready 的數量 (informational)
DO $$
DECLARE
  v_newly_ready INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_newly_ready
    FROM customer_orders co
   WHERE co.status NOT IN ('completed','expired','cancelled','transferred_out')
     AND is_order_pickup_ready(co.id) = true;
  RAISE NOTICE 'After fix: % active orders are now ready for pickup', v_newly_ready;
END $$;

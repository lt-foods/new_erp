-- ============================================================
-- Fix: aid_transfer 訂單在尚未實際出貨/分店收貨前被誤判為「可取貨」
--
-- 背景：跨店互助轉單 (rpc_transfer_order_to_store / rpc_transfer_order_partial)
-- 會建一張新訂單，items source='aid_transfer'，但「不會」立刻建 transfers
-- 紀錄（要等 rpc_ship_aid_order 才建）。
--
-- 20260615000010 的 Path C 為了 cover close_date aggregated PR、放棄 campaign_id
-- 嚴格比對，只檢「所有 active items 的 (sku, pickup_store) 是否在某張 received
-- 的 hq_to_store wave 中」。
--
-- 副作用：跨店 aid 訂單一建好，目的店 (e.g. 松山店) 通常早就透過其他 wave 收過
-- 同 SKU 的貨 → Path C 立刻 match → UI 顯示「可取貨」，但這張 aid 訂單根本還
-- 沒出貨。
--
-- 修法：aid_transfer 訂單（有任一 item source='aid_transfer'）改走限縮分支：
--   1. Path A — 自己的 transfer 被分店收貨 (transfers.customer_order_id = co.id
--      AND status IN ('received','closed'))
--   2. 或 co.status = 'ready' — 同店互轉時 rpc_transfer_order_to_store 已顯式
--      把 status 設為 'ready' (20260508140000)；跨店收貨後 rpc_receive_transfer
--      也會推進到 'ready'。
-- 一般 (非 aid_transfer) 訂單維持現有 Path A / B / C 不變。
--
-- 沒動 customer_orders.status 寫入邏輯 — 跨店轉單的 'pending' 是對的，問題純粹
-- 在 is_order_pickup_ready 的衍生判斷。
--
-- Rollback: CREATE OR REPLACE 回 20260615000010 的版本。
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
       AND CASE
         -- Aid-transfer 訂單：必須走 Path A，或同店互轉已被設為 status='ready'
         WHEN EXISTS (
           SELECT 1 FROM customer_order_items coi
            WHERE coi.order_id = co.id
              AND coi.source = 'aid_transfer'
         ) THEN (
           co.status = 'ready'
           OR EXISTS (
             SELECT 1 FROM transfers t
              WHERE t.customer_order_id = co.id
                AND t.tenant_id = co.tenant_id
                AND t.status IN ('received','closed')
           )
         )
         ELSE (
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
           -- Path C：close_date aggregated PR fallback
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
       END
  );
$function$;

COMMENT ON FUNCTION public.is_order_pickup_ready(bigint) IS
  'Aid-transfer 訂單(有 source=aid_transfer items)只走 Path A 或 status=ready；'
  '一般訂單維持 Path A (互助 FK) / Path B (per-campaign PR) / Path C '
  '(close_date aggregated PR — 不檢 campaign_id 一致)。';

-- 跑 migration 後印「之前被誤判 ready、現在退回」的訂單數量 (informational)
DO $$
DECLARE
  v_unflagged INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_unflagged
    FROM customer_orders co
   WHERE co.status NOT IN ('completed','expired','cancelled','transferred_out')
     AND co.status <> 'ready'
     AND EXISTS (
       SELECT 1 FROM customer_order_items coi
        WHERE coi.order_id = co.id AND coi.source = 'aid_transfer'
     )
     AND NOT EXISTS (
       SELECT 1 FROM transfers t
        WHERE t.customer_order_id = co.id
          AND t.tenant_id = co.tenant_id
          AND t.status IN ('received','closed')
     );
  RAISE NOTICE 'After fix: % aid-transfer orders no longer mis-flagged as pickup_ready', v_unflagged;
END $$;

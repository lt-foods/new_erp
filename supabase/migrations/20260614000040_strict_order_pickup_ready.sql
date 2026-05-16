-- ============================================================
-- 2026-06-14: is_order_pickup_ready 路徑 B 改 strict 版
--
-- 舊版本 bug：路徑 B 只檢查「campaign+store 有任一個 wave received」
-- 就回 true，沒檢查訂單需要的 SKU 是否在那個 received 的 wave 中。
-- 結果：wave 部分收貨 → 整批訂單被推到 'ready' 並發取貨通知，
-- 顧客來店才發現某些 SKU 沒實際入庫。
--
-- 新邏輯：訂單每個 active item (status IN pending/reserved/ready) 的 SKU
--   都必須至少有一筆 picking_wave_items
--   (campaign+store+sku 對齊 AND generated_transfer received/closed)。
--
-- 額外動作：
--   1. Backfill 把 status='ready' 但 strict 版回 false 的訂單退回 'shipping'，
--      並清 ready_at（last_notify_pickup_at 是 audit 不清）。
--   2. partially_completed 已部分取貨、狀態不可逆，不動。
--   3. rpc_record_pickup 不用改，它自動就用 is_order_pickup_ready（已是 CREATE OR REPLACE）。
--
-- Rollback: CREATE OR REPLACE 回 20260512000008 的版本。
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_order_pickup_ready(p_order_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1
      FROM customer_orders co
     WHERE co.id = p_order_id
       AND co.status NOT IN ('completed','expired','cancelled','transferred_out')
       AND (
         -- 路徑 A：互助訂單 — transfer FK 直連 order
         EXISTS (
           SELECT 1 FROM transfers t
            WHERE t.customer_order_id = co.id
              AND t.tenant_id = co.tenant_id
              AND t.status IN ('received','closed')
         )
         OR
         -- 路徑 B（strict）：訂單每個 active item 的 SKU 都要有
         --   picking_wave_items (campaign+store+sku 對齊) 已 received
         (
           co.campaign_id IS NOT NULL
           AND EXISTS (
             SELECT 1 FROM customer_order_items coi
              WHERE coi.order_id = co.id
                AND coi.status IN ('pending','reserved','ready')
           )
           AND NOT EXISTS (
             SELECT 1 FROM customer_order_items coi
              WHERE coi.order_id = co.id
                AND coi.status IN ('pending','reserved','ready')
                AND NOT EXISTS (
                  SELECT 1
                    FROM picking_wave_items pwi
                    JOIN transfers t ON t.id = pwi.generated_transfer_id
                   WHERE pwi.tenant_id   = co.tenant_id
                     AND pwi.campaign_id = co.campaign_id
                     AND pwi.store_id    = co.pickup_store_id
                     AND pwi.sku_id      = coi.sku_id
                     AND t.status IN ('received','closed')
                )
           )
         )
       )
  );
$$;

COMMENT ON FUNCTION public.is_order_pickup_ready IS
  '訂單是否可取貨：strict 版 — 訂單每個 active item 的 SKU 都要有 picking_wave_items 對應 transfer received。';

-- ----------------------------------------------------------------
-- Backfill：誤判 ready 的訂單退回 shipping
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_fixed INTEGER;
  v_uid   UUID;
BEGIN
  SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;

  WITH bad AS (
    SELECT co.id
      FROM customer_orders co
     WHERE co.status = 'ready'
       AND NOT public.is_order_pickup_ready(co.id)
  ),
  upd AS (
    UPDATE customer_orders co
       SET status     = 'shipping',
           ready_at   = NULL,
           updated_by = v_uid,
           updated_at = NOW()
     WHERE co.id IN (SELECT id FROM bad)
    RETURNING co.id
  )
  SELECT COUNT(*) INTO v_fixed FROM upd;
  RAISE NOTICE 'Backfill: reverted % orders from ready→shipping (mis-flagged by old loose pickup_ready logic)', v_fixed;
END $$;

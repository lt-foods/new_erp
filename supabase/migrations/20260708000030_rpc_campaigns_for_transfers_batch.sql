-- ============================================================
-- rpc_get_campaigns_for_transfers — rpc_get_campaigns_for_transfer 的批次版
--
-- 動機：/wms/inbound（📦 收貨待辦）讀取很慢。根因是 client 對每張 transfer
--   各打一次 rpc_get_campaigns_for_transfer（N+1，開頁 ~50+ round-trip）。
--   改成一次傳全部 transfer id、回 { transfer_id: [campaign_ids] }，併成 1 次。
--
-- 邏輯與 rpc_get_campaigns_for_transfer v2 (20260516000007) 完全一致，
-- 只是把單筆改成依 transfer 分組的批次：
--   路徑1：dest store + 該 transfer 的 sku → customer_orders.campaign_id
--   路徑2：aid transfer 直接帶 customer_order_id → campaign_id
-- 同樣 SECURITY DEFINER（與單筆版同等暴露面；前端只傳自己 RLS 撈到的 transfer）。
--
-- 基底版本：rpc_get_campaigns_for_transfer v2 (20260516000007) 的查詢邏輯
-- rollback：DROP FUNCTION rpc_get_campaigns_for_transfers(bigint[]);
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_get_campaigns_for_transfers(
  p_transfer_ids BIGINT[]
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH t AS (
    SELECT id, customer_order_id, dest_location, tenant_id
      FROM transfers
     WHERE id = ANY(p_transfer_ids)
  ),
  ti AS (
    SELECT DISTINCT transfer_id, sku_id
      FROM transfer_items
     WHERE transfer_id = ANY(p_transfer_ids)
  ),
  from_co_match AS (
    -- 從 dest store + 該 transfer 的 sku 對到的 customer_orders.campaign_id
    SELECT DISTINCT t.id AS transfer_id, co.campaign_id
      FROM t
      JOIN stores s
        ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
      JOIN customer_orders co
        ON co.pickup_store_id = s.id
       AND COALESCE(co.order_kind, 'normal') = 'normal'
      JOIN customer_order_items coi ON coi.order_id = co.id
      JOIN ti ON ti.transfer_id = t.id AND ti.sku_id = coi.sku_id
     WHERE co.campaign_id IS NOT NULL
  ),
  from_aid AS (
    -- aid transfer 直接帶 customer_order_id
    SELECT DISTINCT t.id AS transfer_id, co.campaign_id
      FROM t
      JOIN customer_orders co ON co.id = t.customer_order_id
     WHERE co.campaign_id IS NOT NULL
  ),
  unioned AS (
    SELECT transfer_id, campaign_id FROM from_co_match
    UNION
    SELECT transfer_id, campaign_id FROM from_aid
  ),
  per_transfer AS (
    SELECT transfer_id, jsonb_agg(DISTINCT campaign_id) AS cids
      FROM unioned
     GROUP BY transfer_id
  )
  SELECT COALESCE(jsonb_object_agg(transfer_id::text, cids), '{}'::jsonb)
    FROM per_transfer;
$$;

GRANT EXECUTE ON FUNCTION rpc_get_campaigns_for_transfers(BIGINT[]) TO authenticated;

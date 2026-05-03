-- ============================================================
-- rpc_get_campaigns_for_transfer v2：透過 customer_orders 反推 campaigns
--
-- v1 從 picking_wave_items.campaign_id 取，但很多資料 campaign_id 為 NULL。
-- 改用更可靠的路徑：dest store + transfer items 的 SKU → 對應 customer_orders
-- → distinct campaign_id。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_get_campaigns_for_transfer(
  p_transfer_id BIGINT
) RETURNS TABLE(campaign_id BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH t AS (
    SELECT id, transfer_no, customer_order_id, dest_location, tenant_id
      FROM transfers WHERE id = p_transfer_id
  ),
  store AS (
    SELECT s.id AS store_id
      FROM t
      JOIN stores s ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
  ),
  skus AS (
    SELECT DISTINCT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id
  ),
  from_co_match AS (
    -- 從 dest store + sku 對到的 customer_orders.campaign_id
    SELECT DISTINCT co.campaign_id
      FROM customer_orders co
      JOIN store s ON s.store_id = co.pickup_store_id
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE coi.sku_id IN (SELECT sku_id FROM skus)
       AND COALESCE(co.order_kind, 'normal') = 'normal'
  ),
  from_aid AS (
    -- aid transfer 直接帶 customer_order_id
    SELECT DISTINCT co.campaign_id
      FROM customer_orders co
      JOIN t ON t.customer_order_id = co.id
  )
  SELECT campaign_id FROM from_co_match WHERE campaign_id IS NOT NULL
  UNION
  SELECT campaign_id FROM from_aid WHERE campaign_id IS NOT NULL
$$;

GRANT EXECUTE ON FUNCTION rpc_get_campaigns_for_transfer(BIGINT) TO authenticated;

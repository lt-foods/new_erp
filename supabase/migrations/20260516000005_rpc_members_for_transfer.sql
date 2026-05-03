-- ============================================================
-- rpc_get_members_to_notify_for_transfer：取得收貨後該推播的會員
--
-- 給定一張 transfer.id，回傳所有 pickup_store=this transfer 的 dest store
-- 且訂單品項與 transfer items 重疊 / 訂單未終結 / 非抵減單的會員。
-- 用於收貨成功後 fan-out web-push 通知「貨已到店」。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_get_members_to_notify_for_transfer(
  p_transfer_id BIGINT
) RETURNS TABLE(
  member_id BIGINT,
  order_id  BIGINT,
  order_no  TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH dest AS (
    SELECT t.dest_location, t.tenant_id, s.id AS store_id
      FROM transfers t
      LEFT JOIN stores s ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
     WHERE t.id = p_transfer_id
  ),
  skus AS (
    SELECT DISTINCT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id
  )
  SELECT DISTINCT co.member_id, co.id, co.order_no
    FROM customer_orders co
    JOIN dest d
      ON d.store_id = co.pickup_store_id
     AND d.tenant_id = co.tenant_id
    JOIN customer_order_items coi
      ON coi.order_id = co.id
   WHERE coi.sku_id IN (SELECT sku_id FROM skus)
     AND co.member_id IS NOT NULL
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out', 'completed')
     AND COALESCE(co.order_kind, 'normal') = 'normal'
$$;

GRANT EXECUTE ON FUNCTION rpc_get_members_to_notify_for_transfer(BIGINT) TO authenticated;

-- ============================================================
-- rpc_get_members_to_notify_for_transfer 加黑名單過濾
--   members.no_notify_pickup = TRUE → 不通知，不出現在 fanout list
-- 並順便回傳 order_id 之外的 last_notify_pickup_at 讓 client 可選擇
-- 是否寫進「上次通知」（避免短時間重複轟炸）
-- ============================================================

DROP FUNCTION IF EXISTS rpc_get_members_to_notify_for_transfer(BIGINT);

CREATE OR REPLACE FUNCTION rpc_get_members_to_notify_for_transfer(
  p_transfer_id BIGINT
) RETURNS TABLE(
  member_id              BIGINT,
  order_id               BIGINT,
  order_no               TEXT,
  last_notify_pickup_at  TIMESTAMPTZ
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
  SELECT DISTINCT co.member_id, co.id, co.order_no, co.last_notify_pickup_at
    FROM customer_orders co
    JOIN dest d
      ON d.store_id = co.pickup_store_id
     AND d.tenant_id = co.tenant_id
    JOIN customer_order_items coi
      ON coi.order_id = co.id
    JOIN members m
      ON m.id = co.member_id
   WHERE coi.sku_id IN (SELECT sku_id FROM skus)
     AND co.member_id IS NOT NULL
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out', 'completed')
     AND COALESCE(co.order_kind, 'normal') = 'normal'
     AND COALESCE(m.no_notify_pickup, FALSE) = FALSE  -- 黑名單跳過
$$;

GRANT EXECUTE ON FUNCTION rpc_get_members_to_notify_for_transfer(BIGINT) TO authenticated;

-- ============================================================
-- rpc_get_members_to_notify_for_transfer — 改 RETURNS jsonb (AUDIT #28)
--
-- 修復 AUDIT 清單 #28 (re-audit 新發現):
--   原 RPC RETURNS TABLE(member_id, order_id, order_no)。調撥收貨後 fan-out
--   web-push「貨已到店」。一張調撥若 items 覆蓋大量訂單,(member × order) 列
--   可能 >1000 → 被 PostgREST max_rows 截斷 → 漏發到店通知給部分會員。
--
-- 修法: 改 RETURNS jsonb,jsonb_agg 包成單列 array,免疫 max_rows。
--   邏輯與原版完全一致 (dest store × transfer SKU 重疊 × 未終結 normal 訂單)。
--   PG 不能 CREATE OR REPLACE 改 return type → DROP + CREATE。
--
-- 呼叫端 apps/admin/src/components/TransferReceiveModal.tsx 已更新:
--   data 直接是 jsonb array,沿用既有 (rows as [...]) 解構。
-- ============================================================

DROP FUNCTION IF EXISTS rpc_get_members_to_notify_for_transfer(BIGINT);

CREATE OR REPLACE FUNCTION rpc_get_members_to_notify_for_transfer(
  p_transfer_id BIGINT
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH dest AS (
    SELECT t.dest_location, t.tenant_id, s.id AS store_id
      FROM transfers t
      LEFT JOIN stores s ON s.location_id = t.dest_location AND s.tenant_id = t.tenant_id
     WHERE t.id = p_transfer_id
  ),
  skus AS (
    SELECT DISTINCT sku_id FROM transfer_items WHERE transfer_id = p_transfer_id
  ),
  rows AS (
    SELECT DISTINCT co.member_id, co.id AS order_id, co.order_no
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
  )
  SELECT COALESCE(
    jsonb_agg(jsonb_build_object(
      'member_id', r.member_id,
      'order_id',  r.order_id,
      'order_no',  r.order_no
    )),
    '[]'::jsonb
  )
  FROM rows r;
$$;

COMMENT ON FUNCTION rpc_get_members_to_notify_for_transfer(BIGINT) IS
  'RETURNS jsonb 單列 array,避免 max_rows 截斷漏發推播。詳見 docs/STANDARD-資料分頁與筆數限制.md';

GRANT EXECUTE ON FUNCTION rpc_get_members_to_notify_for_transfer(BIGINT) TO authenticated;

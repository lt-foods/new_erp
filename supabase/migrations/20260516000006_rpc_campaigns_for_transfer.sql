-- ============================================================
-- rpc_get_campaigns_for_transfer：取得 transfer 涵蓋的 campaign IDs
--
-- 給 transfer.id，回傳所有相關 campaigns（用於收貨頁「→ 查看此店訂單」
-- 連結帶 campaignIds filter）。
--
-- 邏輯：
--   1. WAVE-{wave_id}-S{...} 類 transfer：從 picking_wave_items 取
--   2. 其他（aid transfer 等）：從 transfers.customer_order_id 取
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_get_campaigns_for_transfer(
  p_transfer_id BIGINT
) RETURNS TABLE(campaign_id BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH t AS (
    SELECT id, transfer_no, customer_order_id, tenant_id FROM transfers WHERE id = p_transfer_id
  ),
  wave_match AS (
    SELECT (substring(transfer_no FROM '^WAVE-(\d+)-S\d+$'))::BIGINT AS wave_id
      FROM t
     WHERE transfer_no ~ '^WAVE-\d+-S\d+$'
  ),
  from_wave AS (
    SELECT DISTINCT pwi.campaign_id
      FROM picking_wave_items pwi
      JOIN wave_match w ON w.wave_id = pwi.wave_id
  ),
  from_co AS (
    SELECT DISTINCT co.campaign_id
      FROM customer_orders co
      JOIN t ON t.customer_order_id = co.id
  )
  SELECT campaign_id FROM from_wave
  UNION
  SELECT campaign_id FROM from_co
$$;

GRANT EXECUTE ON FUNCTION rpc_get_campaigns_for_transfer(BIGINT) TO authenticated;

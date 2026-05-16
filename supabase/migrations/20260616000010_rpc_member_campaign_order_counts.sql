-- 顧客端商品排序（最熱銷 / 近期售出）用：每個團購活動「所有分店」的訂單數，
-- 含近 N 天的訂單數。
--
-- 為什麼用 SQL 聚合 RPC 而不在 edge function 撈訂單再 JS count：
-- PostgREST 預設單次最多回 1000 列，busy 店（100 分店 × 數十團）訂單列數會
-- 超過上限被截斷，導致計數失準（本專案先前已踩過 row-limit 雷）。SQL 端
-- GROUP BY 聚合一次回每團一列，正確且快。
--
-- 計數口徑對齊 liff-api listActiveCampaigns 既有邏輯：
--   排除 status in (cancelled, expired)；只算 order_kind 為 normal/NULL
--   （排除 offset 抵減單、restock 補貨單）。不分門市 = 全分店加總。

CREATE OR REPLACE FUNCTION public.rpc_member_campaign_order_counts(
  p_tenant UUID,
  p_recent_days INT DEFAULT 7
)
RETURNS TABLE (
  campaign_id BIGINT,
  order_count BIGINT,
  recent_order_count BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    co.campaign_id,
    COUNT(*) AS order_count,
    COUNT(*) FILTER (
      WHERE co.created_at >= now() - make_interval(days => GREATEST(p_recent_days, 0))
    ) AS recent_order_count
  FROM customer_orders co
  WHERE co.tenant_id = p_tenant
    AND co.status NOT IN ('cancelled', 'expired')
    AND COALESCE(co.order_kind, 'normal') = 'normal'
  GROUP BY co.campaign_id;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_order_counts(UUID, INT)
  TO anon, authenticated, service_role;

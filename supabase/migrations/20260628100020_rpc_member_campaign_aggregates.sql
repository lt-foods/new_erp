-- ============================================================
-- rpc_member_campaign_aggregates — 會員端商店首頁的「全活動聚合」RPC
--
-- @money-critical: 計算每個 campaign 的 ordered_qty (已售出總數)、
--   order_count、recent_order_count。直接驅動:
--   - 商店首頁「已售出 N 份」、「搶購一空」徽章
--   - 「最熱銷」「近期售出」排序
--   單一 campaign 漏算 → 超賣風險。修改前請閱讀
--   docs/STANDARD-資料分頁與筆數限制.md §4。
--
-- 修復 AUDIT 清單 #13 + #14:
--   舊 listActiveCampaigns() 有兩個截斷點:
--   1. line 318-330: .from("customer_orders").select(...campaign_id, customer_order_items(qty))
--      無 limit,>1000 訂單時被 PostgREST 截斷,然後前端 reduce 加總,
--      ordered_qty 偏低 → 超賣風險。違反 STANDARD §4.1 (金額/數量類禁止前端聚合)。
--   2. line 337-344: 舊 rpc_member_campaign_order_counts 是 RETURNS TABLE (SETOF),
--      仍受 PostgREST 1000 列上限。tenant >1000 活動時計數失準。
--
-- 設計: RETURNS jsonb 單列回 [{campaign_id, order_count, recent_order_count, ordered_qty}],
--       PostgREST max_rows 不咬。
--
-- 對齊 listActiveCampaigns 既有口徑:
--   排除 status IN (cancelled, expired)
--   只算 order_kind IS NULL 或 'normal' (排除 offset 抵減單、restock)
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_member_campaign_aggregates(
  p_tenant      UUID,
  p_recent_days INT DEFAULT 7
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH
  filtered_orders AS (
    SELECT co.id, co.campaign_id, co.created_at
    FROM customer_orders co
    WHERE co.tenant_id = p_tenant
      AND co.status NOT IN ('cancelled', 'expired')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
  ),
  counts AS (
    SELECT
      fo.campaign_id,
      COUNT(*)::bigint AS order_count,
      COUNT(*) FILTER (
        WHERE fo.created_at >= now() - make_interval(days => GREATEST(p_recent_days, 0))
      )::bigint AS recent_order_count
    FROM filtered_orders fo
    GROUP BY fo.campaign_id
  ),
  qtys AS (
    SELECT
      fo.campaign_id,
      SUM(coi.qty)::numeric AS ordered_qty
    FROM filtered_orders fo
    JOIN customer_order_items coi ON coi.order_id = fo.id
    GROUP BY fo.campaign_id
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'campaign_id',         c.campaign_id,
        'order_count',         c.order_count,
        'recent_order_count',  c.recent_order_count,
        'ordered_qty',         COALESCE(q.ordered_qty, 0)
      )
    ),
    '[]'::jsonb
  )
  FROM counts c
  LEFT JOIN qtys q ON q.campaign_id = c.campaign_id;
$$;

COMMENT ON FUNCTION public.rpc_member_campaign_aggregates(UUID, INT) IS
  '@money-critical 會員端商店首頁聚合 RPC,JSONB 單列回傳避免 PostgREST 1000 列截斷。修改前請閱讀 docs/STANDARD-資料分頁與筆數限制.md';

GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_aggregates(UUID, INT)
  TO anon, authenticated, service_role;

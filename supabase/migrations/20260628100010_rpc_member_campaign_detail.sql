-- ============================================================
-- rpc_member_campaign_detail — 會員端團詳情頁的單一聚合 RPC
--
-- @money-critical: 本函數計算每個 campaign_item 的 ordered_qty (已售出數量)
--   與訂單總數，直接影響:
--   - 顧客頁顯示「剩 N 份」、「搶購一空」
--   - cap_qty 上限判斷 (超賣防護)
--   單一品項漏算 = 可能下到超賣的單。修改前請閱讀
--   docs/STANDARD-資料分頁與筆數限制.md §4。
--
-- 修復 AUDIT 清單 #11 + #12:
--   原 supabase/functions/liff-api/index.ts:getCampaignDetail()
--   - L409 campaign_items 無 .limit() → 倚賴 PostgREST 1000 兜底
--   - L429 customer_order_items 無 .limit() → 大型團 (>1000 訂單行)
--     算 ordered_qty 時被截斷,前端看到的「已售出」偏低
--
-- 設計: RETURNS jsonb 單列回傳,PostgREST max_rows 不影響;
--       所有聚合在 SQL 端完成,前端無 reduce/sum 風險。
--
-- 對齊 listActiveCampaigns 既有口徑:
--   排除 status IN (cancelled, expired)
--   只算 order_kind IS NULL 或 'normal' (排除 offset 抵減單)
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_member_campaign_detail(
  p_tenant      UUID,
  p_campaign_id BIGINT
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH
  c AS (
    SELECT
      gbc.id,
      gbc.campaign_no,
      gbc.name,
      gbc.description,
      gbc.cover_image_url,
      gbc.status,
      gbc.end_at,
      gbc.pickup_deadline
    FROM group_buy_campaigns gbc
    WHERE gbc.tenant_id = p_tenant
      AND gbc.id = p_campaign_id
  ),
  items AS (
    SELECT
      ci.id,
      ci.unit_price,
      ci.cap_qty,
      ci.sort_order,
      sku.id           AS sku_id,
      sku.sku_code     AS sku_code,
      sku.product_name AS sku_product_name,
      sku.variant_name AS sku_variant_name,
      p.name           AS product_name,
      p.images         AS product_images
    FROM campaign_items ci
    JOIN skus sku ON sku.id = ci.sku_id
    LEFT JOIN products p ON p.id = sku.product_id
    WHERE ci.tenant_id = p_tenant
      AND ci.campaign_id = p_campaign_id
  ),
  -- 訂單筆數 (含品項一筆訂單只算一次)
  order_count AS (
    SELECT COUNT(*)::bigint AS n
    FROM customer_orders co
    WHERE co.tenant_id = p_tenant
      AND co.campaign_id = p_campaign_id
      AND co.status NOT IN ('cancelled', 'expired')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
  ),
  -- 每個 campaign_item 累計已下單數量 (排除取消/逾期,排除非 normal 訂單)
  ordered_qty_per_item AS (
    SELECT
      coi.campaign_item_id,
      SUM(coi.qty)::numeric AS total_qty
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    WHERE coi.tenant_id = p_tenant
      AND co.campaign_id = p_campaign_id
      AND co.status NOT IN ('cancelled', 'expired')
      AND COALESCE(co.order_kind, 'normal') = 'normal'
    GROUP BY coi.campaign_item_id
  )
  SELECT jsonb_build_object(
    'campaign', (
      SELECT to_jsonb(c) || jsonb_build_object(
        'order_count', (SELECT n FROM order_count)
      )
      FROM c
    ),
    'items', COALESCE((
      SELECT jsonb_agg(
        to_jsonb(items) || jsonb_build_object(
          'ordered_qty', COALESCE(oq.total_qty, 0)
        )
        ORDER BY items.sort_order ASC, items.id ASC
      )
      FROM items
      LEFT JOIN ordered_qty_per_item oq ON oq.campaign_item_id = items.id
    ), '[]'::jsonb)
  )
  FROM c;
$$;

COMMENT ON FUNCTION public.rpc_member_campaign_detail(UUID, BIGINT) IS
  '@money-critical 會員端團詳情聚合 RPC,JSONB 單列回傳避免 PostgREST 1000 列截斷。修改前請閱讀 docs/STANDARD-資料分頁與筆數限制.md';

GRANT EXECUTE ON FUNCTION public.rpc_member_campaign_detail(UUID, BIGINT)
  TO anon, authenticated, service_role;

-- ============================================================================
-- 20260910040000_line_note_post_retail_price.sql
--
-- 記事本貼文的金額一律用**零售價**（老闆 2026-09-10 交代：「po 文的時間都是要零售價錢」）。
-- campaign_items.unit_price 是團購價，開團時從現行零售價複製過來、之後可以另外改
-- （近 30 天 2,416 個品項有 22 個改成比零售低：港點 168 vs 249、水餃 189 vs 199…）；
-- 社群貼文要的是 prices 表 scope='retail'、effective_to IS NULL 的那一筆。
--
-- 做法：_line_note_item_codes 多回一欄 retail_price，兩支 payload RPC 一起帶出去，
-- 取捨留給 worker（lineNoteRender：retail_price > 0 用它，否則退回 unit_price ——
-- 線上有 SKU 零售價是 0 的，例：GRP-20260907-011 的高麗菜）。
-- 每個 SKU 的現行零售價只有一筆（線上 6,237 筆、沒有重複，scope_id 全為 NULL）。
--
-- 基底：_line_note_item_codes / rpc_line_note_post_payload @ 20260908010000（唯一前版），
--       rpc_line_note_preview_payload @ 20260910010000（唯一前版）。
-- RETURNS TABLE 多一欄要 DROP 再建（CREATE OR REPLACE 不能改回傳型別）；
-- 引用它的三支函式（apply_comment / post_payload / preview_payload）都是執行期解析，
-- 沒有 view 依賴它（pg_views 查過）。
-- rollback：把上面三個基底版本重新套一次（先 DROP _line_note_item_codes）。
-- ============================================================================

DROP FUNCTION IF EXISTS public._line_note_item_codes(BIGINT);
CREATE FUNCTION public._line_note_item_codes(p_campaign_id BIGINT)
RETURNS TABLE (code TEXT, campaign_item_id BIGINT, sku_id BIGINT,
               item_name TEXT, unit_price NUMERIC, retail_price NUMERIC, cap_qty NUMERIC, images JSONB)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT chr(64 + (ROW_NUMBER() OVER (ORDER BY ci.sort_order, ci.id))::int) AS code,
         ci.id, ci.sku_id,
         TRIM(COALESCE(s.product_name, '') || CASE WHEN COALESCE(s.variant_name, '') <> '' THEN ' ' || s.variant_name ELSE '' END),
         ci.unit_price,
         -- 現行零售價（貼文用）；沒設就 NULL，worker 退回 unit_price
         (SELECT pr.price FROM prices pr
           WHERE pr.sku_id = ci.sku_id AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC NULLS LAST, pr.id DESC
           LIMIT 1),
         ci.cap_qty,
         COALESCE(p.images, '[]'::jsonb)   -- 商品圖（storage 相對路徑或完整網址），worker 發文時附上
    FROM campaign_items ci
    JOIN skus s ON s.id = ci.sku_id
    LEFT JOIN products p ON p.id = s.product_id
   WHERE ci.campaign_id = p_campaign_id
     AND COALESCE(ci.is_gift, FALSE) = FALSE
   ORDER BY ci.sort_order, ci.id
   LIMIT 26;   -- 超過 26 項就沒代碼了，那種團不適合記事本 +1
$$;

-- worker 發文用：把團的內容整包回來（模板由 worker 套）
CREATE OR REPLACE FUNCTION public.rpc_line_note_post_payload(p_post_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'post_id',       p.id,
    'home_id',       c.home_id,
    'home_kind',     c.home_kind,
    'account_id',    c.account_id,
    'post_template', c.post_template,
    'campaign', jsonb_build_object(
       'id', g.id, 'campaign_no', g.campaign_no, 'name', g.name,
       'description', g.description, 'status', g.status,
       'cover_image_url', g.cover_image_url,
       'start_at', g.start_at, 'end_at', g.end_at, 'pickup_deadline', g.pickup_deadline),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'code', ic.code, 'campaign_item_id', ic.campaign_item_id,
                'name', ic.item_name, 'unit_price', ic.unit_price, 'retail_price', ic.retail_price,
                'cap_qty', ic.cap_qty, 'images', ic.images)
                ORDER BY ic.code)
               FROM public._line_note_item_codes(g.id) ic), '[]'::jsonb)
  )
  FROM line_note_posts p
  JOIN line_note_communities c ON c.id = p.community_id
  JOIN group_buy_campaigns g ON g.id = p.campaign_id
  WHERE p.id = p_post_id;
$$;

CREATE OR REPLACE FUNCTION public.rpc_line_note_preview_payload(
  p_community_id BIGINT,
  p_campaign_id  BIGINT
) RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'home_id',       c.home_id,
    'home_kind',     c.home_kind,
    'account_id',    c.account_id,
    'post_template', c.post_template,
    'campaign', jsonb_build_object(
       'id', g.id, 'campaign_no', g.campaign_no, 'name', g.name,
       'description', g.description, 'status', g.status,
       'cover_image_url', g.cover_image_url,
       'start_at', g.start_at, 'end_at', g.end_at, 'pickup_deadline', g.pickup_deadline),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'code', ic.code, 'campaign_item_id', ic.campaign_item_id,
                'name', ic.item_name, 'unit_price', ic.unit_price, 'retail_price', ic.retail_price,
                'cap_qty', ic.cap_qty, 'images', ic.images)
                ORDER BY ic.code)
               FROM public._line_note_item_codes(g.id) ic), '[]'::jsonb)
  )
  FROM line_note_communities c
  JOIN group_buy_campaigns g ON g.id = p_campaign_id AND g.tenant_id = c.tenant_id
  WHERE c.id = p_community_id;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_preview_payload(BIGINT, BIGINT) TO authenticated;

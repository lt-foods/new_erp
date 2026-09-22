-- ============================================================================
-- 20260922002000_line_note_payload_shop_link.sql
--
-- 機器人的開團貼文要帶商城連結（老闆 2026-09-22）。
-- 連結長什麼樣由 worker 組（網址 base 在 MEMBER_FRONT_BASE_URL），這支只負責
-- 把「該連到哪一頁、能不能連」這兩件事帶進 payload：
--   sales_channel — 漂漂館的團在 /piaopiao/c/<id>，其餘在 /shop/c/<id>
--   is_for_shop   — 沒上架商城的團客人點進去只會拿到 404，那種整行不印
-- （campaign.id 兩支本來就有帶，不用動。）
--
-- 基底：rpc_line_note_post_payload / rpc_line_note_preview_payload @ 20260910050000
--       （已 grep supabase/migrations/ 全部動過這兩支的檔案：20260908010000 →
--         20260910010000 → 20260910040000 → 20260910050000，這支是最新的一版；
--         也對線上 pg_get_functiondef() 比對過，線上跟 repo 一致）
-- rollback：把 20260910050000 的第 4 段重套。
-- ============================================================================

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
       'start_at', g.start_at, 'end_at', g.end_at, 'customer_end_at', g.customer_end_at,
       'pickup_deadline', g.pickup_deadline,
       'sales_channel', g.sales_channel, 'is_for_shop', g.is_for_shop),
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
       'start_at', g.start_at, 'end_at', g.end_at, 'customer_end_at', g.customer_end_at,
       'pickup_deadline', g.pickup_deadline,
       'sales_channel', g.sales_channel, 'is_for_shop', g.is_for_shop),
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

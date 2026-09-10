-- ============================================================================
-- 20260910010000_line_note_preview_payload.sql
--
-- 發文預覽用的 payload：跟 rpc_line_note_post_payload 同一個形狀，但用
-- (社群, 團) 定位，不需要先有 line_note_posts 那一列 —— 預覽是在按下發文**之前**。
--
-- 貼文是發給整個社群看的，發出去才發現版型不對就來不及了（記事本貼文只能刪掉重發，
-- 客人已經看到）。所以後台先叫這支把「等一下會貼出去的字」原封不動渲染出來給人看。
--
-- 渲染邏輯故意留在 worker（renderTemplate）不搬進 SQL：搬進來就變兩份會走鐘，
-- 預覽看到的就不是真的會貼的東西，那預覽就沒有意義了。
--
-- 新函式，沒有覆蓋既有 function。
-- rollback：DROP FUNCTION public.rpc_line_note_preview_payload(BIGINT, BIGINT);
-- ============================================================================

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
                'name', ic.item_name, 'unit_price', ic.unit_price, 'cap_qty', ic.cap_qty,
                'images', ic.images)
                ORDER BY ic.code)
               FROM public._line_note_item_codes(g.id) ic), '[]'::jsonb)
  )
  FROM line_note_communities c
  JOIN group_buy_campaigns g ON g.id = p_campaign_id AND g.tenant_id = c.tenant_id
  WHERE c.id = p_community_id;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_preview_payload(BIGINT, BIGINT) TO authenticated;

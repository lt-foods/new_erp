-- ============================================================================
-- 20260910000000_line_note_unlinked_posts.sql
--
-- 認不出團的貼文，現在會留下來讓小幫手自己指定，不要再靜靜消失。
--
-- 起因：松山「雲林小農🍀阿土伯 / 🚚下星期一新鮮到貨」那則有 7 則留言，
-- 團其實開著（GRP-20260908-002「雲林小農阿土伯蔬菜」），但 matchCampaign 是
-- **純子字串比對** —— 團名中間沒有 🍀、後面還多了「蔬菜」，所以對不上。
-- 舊行為只在 worker log 印一行「認不出貼文 …」就跳過，後台完全看不到這則存在，
-- 店家只能發現「留言沒有變成訂單」卻查不出為什麼。
--
-- 刻意**不去放寬比對**：認錯團 = 把客人的 +1 加到別的團上，比漏認嚴重得多。
-- 改成留一筆 status='unlinked'（campaign_id NULL）擺在貼文頁，
-- 小幫手指定是哪一團（rpc_line_note_post_link）之後才開始讀留言加單。
--
-- campaign_id 改成可為 NULL：UNIQUE (community_id, campaign_id) 在 Postgres 裡
-- 允許多個 NULL，所以同一個社群可以同時有好幾則還沒認出來的貼文。
--
-- 基底：line_note_posts @ 20260908010000 建表；status CHECK 沿用同一支。
-- rollback：
--   DELETE FROM line_note_posts WHERE campaign_id IS NULL;
--   ALTER TABLE line_note_posts ALTER COLUMN campaign_id SET NOT NULL;
--   ALTER TABLE line_note_posts DROP CONSTRAINT line_note_posts_status_check,
--     ADD CONSTRAINT line_note_posts_status_check
--     CHECK (status IN ('queued','posted','failed','closed'));
--   DROP FUNCTION public.rpc_line_note_post_link(BIGINT, BIGINT);
-- ============================================================================

ALTER TABLE line_note_posts ALTER COLUMN campaign_id DROP NOT NULL;

ALTER TABLE line_note_posts DROP CONSTRAINT IF EXISTS line_note_posts_status_check;
ALTER TABLE line_note_posts
  ADD CONSTRAINT line_note_posts_status_check
  CHECK (status IN ('queued','posted','failed','closed','unlinked'));

COMMENT ON COLUMN line_note_posts.campaign_id IS
  '對應的團。NULL = 還沒認出是哪一團（status=unlinked），要小幫手自己指定。';

-- ----------------------------------------------------------------------------
-- 手動指定這則貼文是哪一團
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_post_link(
  p_id          BIGINT,
  p_campaign_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant    UUID := public._line_note_require_admin();
  v_community BIGINT;
  v_clash     BIGINT;
BEGIN
  SELECT community_id INTO v_community
    FROM line_note_posts WHERE id = p_id AND tenant_id = v_tenant;
  IF v_community IS NULL THEN RAISE EXCEPTION 'post % not in tenant', p_id; END IF;

  PERFORM 1 FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;

  -- 同一個社群同一團只能有一則貼文（UNIQUE (community_id, campaign_id)）
  SELECT id INTO v_clash FROM line_note_posts
   WHERE community_id = v_community AND campaign_id = p_campaign_id AND id <> p_id;
  IF v_clash IS NOT NULL THEN
    RAISE EXCEPTION '這個社群已經有一則貼文對應到這一團了，請先處理掉那一則';
  END IF;

  UPDATE line_note_posts
     SET campaign_id = p_campaign_id,
         status      = CASE WHEN status = 'unlinked' THEN 'posted' ELSE status END,
         updated_by  = auth.uid(),
         updated_at  = NOW()
   WHERE id = p_id AND tenant_id = v_tenant;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_post_link(BIGINT, BIGINT) TO authenticated;

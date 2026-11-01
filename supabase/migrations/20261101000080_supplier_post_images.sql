-- ============================================================================
-- 20261101000080_supplier_post_images.sql
--
-- 廠商群組貼文「圖文一起爬」：worker 讀貼文時順便用機器人的登入憑證把圖下載下來
-- （LINE 的記事本圖片要帶憑證才拿得到），存到 products 儲存桶
-- supplier-notes/<群組 id>/<貼文 id>/<n>.<副檔名>，路徑寫回 line_note_market_posts.image_paths。
-- 平均一篇 6 張（2026-11-01 讀到 45 篇、274 張），每篇最多存 8 張。
--
-- 用在三個地方：
--   1. 候選池顯示縮圖（前端用 raw.market_post_id 反查 image_paths）。
--   2. 半夜 Claude 拆品項時看圖：rpc_market_post_claim 多回 images（儲存桶路徑，
--      scripts/supplier-note-routine.mjs 轉成公開網址），價格寫在圖上的也讀得到。
--   3. 之後候選採用時直接當商品圖（路徑已經在 products 儲存桶裡）。
--
-- image_paths：NULL = 還沒抓；'{}' = 抓過但沒有圖或全部失敗（image_error 記原因）。
-- ⚠ 圖不會跟著候選池 14 天清掉（storage 只能走 Storage API 刪，見 20261028000000），
--   之後要接 storage_purge_queue。
--
-- rpc_market_post_claim 回傳欄位變了（加 images）→ DROP 再建。
-- 基底：rpc_market_post_claim @ 20261101000040（唯一前版，已 grep）。
-- rollback：ALTER TABLE line_note_market_posts DROP COLUMN image_paths, DROP COLUMN image_error;
--   重跑 20261101000040 的 rpc_market_post_claim（先 DROP 這版）。
-- ============================================================================

ALTER TABLE public.line_note_market_posts
  ADD COLUMN IF NOT EXISTS image_paths TEXT[],
  ADD COLUMN IF NOT EXISTS image_error TEXT;
COMMENT ON COLUMN public.line_note_market_posts.image_paths IS
  'products 儲存桶裡的圖片路徑（supplier-notes/…）。NULL = 還沒抓；{} = 抓過但沒有圖或全部失敗';
CREATE INDEX IF NOT EXISTS idx_lnmp_images_pending ON public.line_note_market_posts (community_id)
  WHERE image_paths IS NULL;

DROP FUNCTION IF EXISTS public.rpc_market_post_claim(INT);

CREATE FUNCTION public.rpc_market_post_claim(p_limit INT DEFAULT 20)
RETURNS TABLE (post_id BIGINT, community TEXT, supplier TEXT, author TEXT, posted TIMESTAMPTZ,
               comments INT, body TEXT, images TEXT[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  -- 沒有文字的（只有圖）直接標解析完，不送 Claude
  UPDATE line_note_market_posts mp SET parsed_at = now()
   WHERE mp.parsed_at IS NULL AND btrim(mp.text) = '';

  RETURN QUERY
  WITH picked AS (
    SELECT p.id FROM line_note_market_posts p
     WHERE p.parsed_at IS NULL
     ORDER BY p.posted_at DESC NULLS LAST, p.id DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 60)
     FOR UPDATE SKIP LOCKED
  ),
  marked AS (
    UPDATE line_note_market_posts p SET parsed_at = now(), parse_error = NULL
      FROM picked WHERE p.id = picked.id
    RETURNING p.id, p.community_id, p.author_name, p.posted_at, p.comment_count, p.text, p.image_paths
  )
  SELECT m.id, c.home_name, s.name, m.author_name, m.posted_at, m.comment_count, m.text,
         COALESCE(m.image_paths, '{}')
    FROM marked m
    JOIN line_note_communities c ON c.id = m.community_id
    LEFT JOIN suppliers s ON s.id = c.crawl_supplier_id;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_post_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_market_post_claim(INT) TO service_role;


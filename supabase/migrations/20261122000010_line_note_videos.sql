-- ============================================================================
-- LINE 記事本的影片貼文 → 後台商品頁「從 LINE 記事本挑影片」
--
-- 來源：老闆 2026-11-22「還是可以透過 line 來播影音，透過讀 line 記事本裡的影片貼文」。
--   商品頁的浮動影片小視窗（20261122000000 的 products.intro_video_url）要能直接用
--   包子媽貼在社群記事本的影片。
--
-- 2026-11-22 實測（松山店 1179531352217385180，line-note-worker 的 note_media_probe）：
--   貼文 contents.media = [{ type:"VIDEO", serviceName:"opennote", obsNamespace:"post",
--                            objectId:"…", width:281, height:500 }]
--   檔案就在 https://obs.line-scdn.net/r/<serviceName>/<obsNamespace>/<objectId>
--   —— 不用登入、video/mp4、支援 Range（206）、Access-Control-Allow-Origin: *，
--   瀏覽器的 <video> 可以直接播（等於影片檔，小視窗能真的靜音自動播放）。
--   之前讀過的 5,412 個附件全是 PHOTO，所以到這一天才第一次看到影片長什麼樣。
--
-- 這張表只記「哪個社群的哪一篇貼文有哪支影片」，不存影片檔本身
--   （一支 14MB；存進自己的空間，每個進商品頁的客人都會耗我們的流量）。
--   寫入只有 line-note-worker（service_role，繞過 RLS）：
--     - 平常讀留言本來就會列一次記事本（jobRead 的 listRecentNotes），順手記，不多打 LINE
--     - 後台按「去 LINE 再讀一次」→ worker 的 sync_note_videos（每個社群一次 list）
--   後台只讀：管理層級（同 line_note_market_posts 的 lnmp_hq_read）。
--
-- 影片貼文本身常常沒有任何文字（實測那篇就是空的），所以**不做自動對商品**，
--   由人在商品編輯頁挑（老闆 2026-11-22 選的）。挑了之後存進 products.intro_video_url 的是
--   上面那個 CDN 網址，跟這張表沒有外鍵 —— 這張表只是挑選用的清單，清掉也不影響已經掛上去的影片。
--
-- object_id / service_name / obs_namespace 有字元限制：這三段會被拼成網址，
--   不能讓奇怪的值混進來（會員端另外還有一層主機名與路徑格式的檢查，見 videoEmbed.ts）。
--
-- 純新增。回退：DROP TABLE public.line_note_videos;（worker 記不到只會留一行 log，不影響讀留言）
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.line_note_videos (
  id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id      UUID        NOT NULL,
  community_id   BIGINT      NOT NULL REFERENCES public.line_note_communities(id) ON DELETE CASCADE,
  line_post_id   TEXT        NOT NULL,
  object_id      TEXT        NOT NULL CHECK (object_id ~ '^[A-Za-z0-9_-]{8,200}$'),
  service_name   TEXT        NOT NULL DEFAULT 'opennote' CHECK (service_name ~ '^[a-z0-9_]{1,40}$'),
  obs_namespace  TEXT        NOT NULL DEFAULT 'post'     CHECK (obs_namespace ~ '^[a-z0-9_]{1,40}$'),
  width          INTEGER,
  height         INTEGER,
  author_name    TEXT,
  text           TEXT,
  posted_at      TIMESTAMPTZ,
  first_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT line_note_videos_post_object_uniq UNIQUE (community_id, line_post_id, object_id)
);
COMMENT ON TABLE public.line_note_videos IS
  'LINE 記事本上的影片貼文清單（後台商品頁挑影片用）。檔案在 https://obs.line-scdn.net/r/<service_name>/<obs_namespace>/<object_id>。20261122000010';

CREATE INDEX IF NOT EXISTS line_note_videos_tenant_posted_idx
  ON public.line_note_videos (tenant_id, posted_at DESC NULLS LAST);

ALTER TABLE public.line_note_videos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.line_note_videos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.line_note_videos TO authenticated;

DROP POLICY IF EXISTS lnv_hq_read ON public.line_note_videos;
CREATE POLICY lnv_hq_read ON public.line_note_videos FOR SELECT TO authenticated
  USING (tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
         AND (SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', ''))
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']));

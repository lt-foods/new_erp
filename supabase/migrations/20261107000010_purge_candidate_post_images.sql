-- ============================================================================
-- 候選池貼文圖片跟著候選一起刪（老闆 2026-11-07 指示）
--
-- 背景：候選池每天 03:41（UTC 19:41）刪「建立滿 14 天、沒動過或已略過」的候選
-- （_purge_old_candidates，20261101000070），但圖片掛在 line_note_market_posts.image_paths，
-- 貼文不刪 → 圖片永遠留在 products bucket（supplier-notes/…、vendor-site/…，11/7 已 1.3GB）。
--
-- 做法：接上 20261028000000 的刪檔佇列（storage_purge_queue → Edge Function storage-purge）。
--   _queue_orphan_market_post_images()：貼文 first_seen_at 滿 14 天、而且候選池裡已經沒有任何一筆
--   指到它（raw->>'market_post_id'），就把它的圖排進佇列、image_paths 設 '{}'、image_error 記原因。
--   - 收藏 / 排程 / 採用的候選不會被清 → 它們的貼文圖一直留著。
--   - 路徑層級再擋一次：還掛在商品圖、開團封面、互助板現貨圖、其他貼文上的不刪
--     （11/7 查過：商品 / 封面引用候選池路徑 0 張；排程候選建商品只帶文字、不帶圖）。
--   - image_paths 設 '{}' 不是 NULL：line-note-worker 只補抓 image_paths IS NULL 的貼文，
--     設 NULL 會每次讀取都把剛刪的圖抓回來。
--   - 同一條路徑之前刪過、後來又被傳上來（廠商網站重跑 ingest 會用同一個路徑）→ 佇列列重新打開。
--
-- 連帶改：
--   - storage_purge_queue.source 加 'market_post'。
--   - rpc_storage_purge_claim（基底 20261028000000）：撤出佇列的條件多看「又掛回某篇貼文」，
--     不然廠商網站重跑 ingest 剛傳上去的圖，會被還沒執行的舊刪除工作刪掉。
--   - _storage_purge_tick（基底 20261028000000）：多呼叫 _queue_orphan_market_post_images()。
--     tick 在 03:17、清候選在 03:41 → 候選被清的隔天凌晨圖才進佇列，慢一天，刻意不改排程。
--
-- 已知殘留：LINE 貼文圖刪掉之後，如果那篇貼文文字被改過而重新解析，模型看不到圖（只讀文字）。
--   廠商網站那條不受影響：scripts/vendor-site-ingest.mjs 發現檔案不在會重新上傳。
--
-- ⚠ 要真的刪檔，storage-purge Edge Function 必須部署＋設 vault（20261028000000 檔頭的部署步驟）。
--   11/7 查線上：函式沒部署、vault 沒設 → 10/28 起佇列只排不刪（product 2,614 張待刪）。
--   沒部署也不會壞：參照照樣拿掉、圖片留在 bucket，等部署後一次刪。
--
-- Rollback：重跑 20261028000000 的 rpc_storage_purge_claim / _storage_purge_tick；
--   DROP FUNCTION public._queue_orphan_market_post_images(INT);
--   還沒刪的（deleted_at IS NULL AND source='market_post'）可依 source_id 把 path 加回 image_paths。
-- ============================================================================

ALTER TABLE public.storage_purge_queue DROP CONSTRAINT IF EXISTS storage_purge_queue_source_check;
ALTER TABLE public.storage_purge_queue
  ADD CONSTRAINT storage_purge_queue_source_check
  CHECK (source IN ('product', 'campaign_cover', 'market_post'));


-- ── 1. 候選都被清掉的貼文 → 圖片排進佇列 ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public._queue_orphan_market_post_images(p_days INT DEFAULT 14)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutoff TIMESTAMPTZ := now() - make_interval(days => p_days);
  v_posts  BIGINT[];
  v_queued INT;
  v_aid_cutoff TIMESTAMPTZ := now() - interval '3 months';
BEGIN
  IF p_days IS NULL OR p_days < 14 THEN
    RAISE EXCEPTION 'p_days 至少 14（候選池保留 14 天）';
  END IF;

  SELECT COALESCE(array_agg(p.id), '{}')
    INTO v_posts
    FROM line_note_market_posts p
   WHERE COALESCE(array_length(p.image_paths, 1), 0) > 0
     AND p.first_seen_at < v_cutoff
     AND NOT EXISTS (SELECT 1 FROM community_product_candidates c
                      WHERE c.tenant_id = p.tenant_id
                        AND c.raw ->> 'market_post_id' = p.id::text);

  IF cardinality(v_posts) = 0 THEN
    RETURN 0;
  END IF;

  WITH cand AS (
    SELECT DISTINCT ON (x.path) x.path, p.id AS post_id
      FROM line_note_market_posts p,
           unnest(p.image_paths) AS x(path)
     WHERE p.id = ANY (v_posts) AND COALESCE(x.path, '') <> ''
     ORDER BY x.path, p.id
  ),
  keep AS (
    SELECT e AS path
      FROM products pr,
           jsonb_array_elements_text(CASE WHEN jsonb_typeof(pr.images) = 'array'
                                          THEN pr.images ELSE '[]'::jsonb END) e
    UNION
    SELECT c.cover_image_url FROM group_buy_campaigns c WHERE c.cover_image_url IS NOT NULL
    UNION
    SELECT e
      FROM mutual_aid_board b,
           jsonb_array_elements_text(CASE WHEN jsonb_typeof(b.spot_images) = 'array'
                                          THEN b.spot_images ELSE '[]'::jsonb END) e
     WHERE b.status = 'active' OR b.created_at >= v_aid_cutoff
    UNION
    SELECT x.path
      FROM line_note_market_posts p, unnest(p.image_paths) AS x(path)
     WHERE NOT (p.id = ANY (v_posts))
  )
  INSERT INTO storage_purge_queue AS q (bucket, path, source, source_id)
  SELECT 'products', cd.path, 'market_post', cd.post_id
    FROM cand cd
   WHERE NOT EXISTS (SELECT 1 FROM keep k WHERE k.path = cd.path)
  ON CONFLICT (bucket, path) DO UPDATE
     -- 之前刪過、後來同一路徑又被傳上來 → 重新排；還沒刪的不動
     SET source = EXCLUDED.source, source_id = EXCLUDED.source_id,
         queued_at = now(), deleted_at = NULL, attempts = 0, last_error = NULL
   WHERE q.deleted_at IS NOT NULL;
  GET DIAGNOSTICS v_queued = ROW_COUNT;

  -- 拿掉參照（只拿掉已排進佇列的那幾張；被 keep 擋下的留著）
  UPDATE line_note_market_posts p
     SET image_paths = COALESCE(ARRAY(
           SELECT x.path FROM unnest(p.image_paths) WITH ORDINALITY AS x(path, o)
            WHERE NOT EXISTS (SELECT 1 FROM storage_purge_queue q
                               WHERE q.bucket = 'products' AND q.path = x.path AND q.deleted_at IS NULL)
            ORDER BY x.o), '{}'),
         image_error = '候選已清（' || to_char(now() AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD') || '），圖片排入刪除'
   WHERE p.id = ANY (v_posts)
     AND EXISTS (SELECT 1 FROM unnest(p.image_paths) AS x(path)
                   JOIN storage_purge_queue q ON q.bucket = 'products' AND q.path = x.path AND q.deleted_at IS NULL);

  RETURN v_queued;
END;
$$;

REVOKE ALL ON FUNCTION public._queue_orphan_market_post_images(INT) FROM PUBLIC, anon, authenticated;


-- ── 2. worker 取一批（基底 20261028000000）：又被用回去的撤出佇列，多看貼文 ──────
CREATE OR REPLACE FUNCTION public.rpc_storage_purge_claim(p_limit INT DEFAULT 100)
RETURNS TABLE (bucket TEXT, path TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutoff TIMESTAMPTZ := now() - interval '3 months';
BEGIN
  RETURN QUERY
  WITH batch AS (
    SELECT q.bucket, q.path
      FROM storage_purge_queue q
     WHERE q.deleted_at IS NULL AND q.attempts < 5
     ORDER BY q.queued_at, q.path
     LIMIT GREATEST(COALESCE(p_limit, 100), 1)
  ),
  revived AS (
    DELETE FROM storage_purge_queue q
     USING batch b
     WHERE q.bucket = b.bucket AND q.path = b.path
       AND (EXISTS (SELECT 1 FROM products p
                     WHERE jsonb_typeof(p.images) = 'array' AND p.images ? b.path)
         OR EXISTS (SELECT 1 FROM group_buy_campaigns c WHERE c.cover_image_url = b.path)
         OR EXISTS (SELECT 1 FROM mutual_aid_board m
                     WHERE jsonb_typeof(m.spot_images) = 'array' AND m.spot_images ? b.path
                       AND (m.status = 'active' OR m.created_at >= v_cutoff))
         -- 20261107000010：廠商網站重跑 ingest 會把同一路徑重新傳上來、掛回貼文
         OR EXISTS (SELECT 1 FROM line_note_market_posts mp WHERE mp.image_paths @> ARRAY[b.path]))
    RETURNING q.bucket, q.path
  )
  SELECT b.bucket, b.path
    FROM batch b
   WHERE NOT EXISTS (SELECT 1 FROM revived r WHERE r.bucket = b.bucket AND r.path = b.path);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_storage_purge_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_storage_purge_claim(INT) TO service_role;


-- ── 3. 每天跑一次（基底 20261028000000）：多排候選池貼文圖 ───────────────────────
CREATE OR REPLACE FUNCTION public._storage_purge_tick()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url TEXT;
BEGIN
  PERFORM public._queue_expired_campaign_images(3);
  PERFORM public._queue_orphan_market_post_images(14);

  IF NOT EXISTS (SELECT 1 FROM storage_purge_queue WHERE deleted_at IS NULL AND attempts < 5) THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_url FROM vault.decrypted_secrets
   WHERE name = 'storage_purge_worker_url' LIMIT 1;
  IF v_url IS NULL THEN
    RAISE NOTICE 'storage-purge-tick: vault 缺 storage_purge_worker_url，只排佇列不刪檔';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
END;
$$;

REVOKE ALL ON FUNCTION public._storage_purge_tick() FROM PUBLIC, anon, authenticated;

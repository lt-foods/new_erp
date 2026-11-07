-- ============================================================================
-- 刪檔排程的 worker 網址：vault 沒設 storage_purge_worker_url 時，拿 line_note_worker_url 換函式名
--
-- 20261028000000 要求另外 vault.create_secret('…/storage-purge', 'storage_purge_worker_url')，
-- 但 10/28 ～ 11/7 從來沒人設（Edge Function 也沒部署），佇列只排不刪、2,614 張商品圖一直留著。
-- _market_ai_tick（20261101000090 起）早就用「line_note_worker_url 把 line-note-worker 換成 market-ai」
-- 這招，不需要多一把密鑰；這裡照做。有設 storage_purge_worker_url 的話仍以它為準。
--
-- 基底版本：_storage_purge_tick ← 20261107000010_purge_candidate_post_images.sql
-- rollback：重跑 20261107000010 的 _storage_purge_tick 定義
-- ============================================================================

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
    -- 跟 _market_ai_tick 同一招：worker 們都在同一個 functions 網域，換函式名就好
    SELECT replace(decrypted_secret, 'line-note-worker', 'storage-purge') INTO v_url
      FROM vault.decrypted_secrets WHERE name = 'line_note_worker_url' LIMIT 1;
  END IF;
  IF v_url IS NULL THEN
    RAISE NOTICE 'storage-purge-tick: vault 缺 storage_purge_worker_url / line_note_worker_url，只排佇列不刪檔';
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

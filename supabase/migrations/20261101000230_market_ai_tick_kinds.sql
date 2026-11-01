-- ============================================================================
-- market-ai 排程也為「品類」叫醒（20261101000230）
--
-- _market_ai_tick 只在「有貼文要拆 / 缺向量 / 缺標籤」時才打 market-ai；20261101000220 加的品類補標
-- 不在條件裡 → 沒有其他工作時永遠不會被叫起來，4,417 個商品的品類補不完。
-- 條件比照 rpc_ai_kind_claim（還沒標、或上次失敗滿一天）。
--
-- 基底：_market_ai_tick @ 20261101000090（唯一前版，已 grep）。
-- rollback：重跑 20261101000090 的 _market_ai_tick 定義。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._market_ai_tick()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM line_note_market_posts WHERE parsed_at IS NULL)
     AND NOT EXISTS (SELECT 1 FROM line_note_market_items WHERE embedding IS NULL)
     AND NOT EXISTS (SELECT 1 FROM products p
                      WHERE p.status <> 'discontinued'
                        AND NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id)
                        AND (p.tag_llm_at IS NULL OR p.tag_llm_at < now() - INTERVAL '30 days'))
     -- 只看「缺向量」（便宜）；品名／標籤改過、要重算的，等 market-ai 有被叫起來時 claim 會一起撿
     AND NOT EXISTS (SELECT 1 FROM products p
                      WHERE NOT EXISTS (SELECT 1 FROM product_embeddings e WHERE e.product_id = p.id))
     -- 品類（20261101000220）：品項或商品還沒標、或上次失敗滿一天
     AND NOT EXISTS (SELECT 1 FROM line_note_market_items i
                      WHERE i.kind IS NULL AND (i.kind_at IS NULL OR i.kind_at < now() - INTERVAL '1 day'))
     AND NOT EXISTS (SELECT 1 FROM products p
                      LEFT JOIN product_kinds k ON k.product_id = p.id
                      WHERE COALESCE(btrim(p.name), '') <> ''
                        AND (k.product_id IS NULL
                             OR (k.kind IS NULL AND (k.labeled_at IS NULL OR k.labeled_at < now() - INTERVAL '1 day')))) THEN
    RETURN;
  END IF;

  SELECT replace(decrypted_secret, 'line-note-worker', 'market-ai') INTO v_url
    FROM vault.decrypted_secrets WHERE name = 'line_note_worker_url' LIMIT 1;
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'line_note_cron_secret' LIMIT 1;
  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE NOTICE 'market-ai-tick: vault 缺 line_note_worker_url / line_note_cron_secret，略過';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-line-note-secret', v_secret),
    body    := '{"action":"tick"}'::jsonb,
    timeout_milliseconds := 150000
  );
END;
$$;
REVOKE ALL ON FUNCTION public._market_ai_tick() FROM PUBLIC, anon, authenticated;

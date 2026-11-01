-- ============================================================================
-- 20261101000040_line_note_supplier_crawl.sql
--
-- 廠商群組記事本爬取（docs/PLAN-選品系統-外部來源與商品媒合.md 的外部進料，先做廠商、
-- 別人的團之後再做）。
--
-- 流程：
--   1. 後台「社群選品 → 廠商群組」選一個機器人帳號（小幫手）→ 讀出它所在的群組／社群 →
--      勾要爬的（line_note_communities.crawl_enabled，沒有那一列就建一列、隱藏過的也會解除），
--      並指定它是哪個廠商（crawl_supplier_id → suppliers，之後選品分數接廠商評分）。
--      爬的時候用 crawl_account_id（勾選時選的那個帳號），沒填才用社群原本綁的 account_id。
--   2. pg_cron 'line-note-crawl'（台北 01:13）對每個勾選的群組排一筆 kind='crawl' 的
--      line_note_jobs；_line_note_tick 看到 queued 就叫 line-note-worker，worker 用綁定的
--      機器人帳號讀最近 crawl_days 天的貼文，丟給 rpc_line_note_market_ingest 存起來。
--      一個群組一天讀一次：只列貼文（list.json），不讀留言、不按讚、不發文。
--   3. Claude Code 排程任務（Sonnet，台北 02:53，跟商品自動貼標同一個 session）透過
--      scripts/supplier-note-routine.mjs 領未解析的貼文（rpc_market_post_claim），
--      把每篇拆成商品（品名 / 標準品名 / 團購價 / 規格 / 截止 / 標籤），寫回
--      （rpc_market_post_write）。寫回時 DB 端用二字詞比對找「我賣過最像的 5 個」，
--      附上當時開過幾團、幾位買家（§2.1 的做法，不用向量）。
--   4. 每個商品同時 upsert 進候選池 community_product_candidates（source_external_id =
--      'ln:<貼文 id>:<md5(品名)>'），parsed 放價格／規格／比對結果，similar_product_id /
--      similarity_score 填最像的那個；分數 ≥ 0.75 → system_status = 'duplicate_hint'（賣過）。
--      老闆已經動過的（收藏／排程／採用／忽略）重新解析時不改狀態。
--
-- 留言只記數量（每天快照一次，看 +1 長多快），不存留言內容與留言者。
-- 我方機器人自己發的貼文（line_note_posts 有那個 line_post_id、或作者是我方帳號）不收。
-- 貼文文字改過（text_hash 變了）→ parsed_at 清掉，下一次排程重新解析。
--
-- 新函式、新表，沒有改既有函式本體；line_note_jobs_kind_check 加 'crawl'
-- （基底：線上現行定義，最後一次在 20261026000000 加 promo）。
--
-- rollback：
--   SELECT cron.unschedule('line-note-crawl');
--   DROP FUNCTION public._line_note_enqueue_crawls(), public.rpc_line_note_set_crawl(BIGINT, TEXT, TEXT, TEXT, BOOLEAN, BIGINT, BOOLEAN),
--     public.rpc_line_note_crawl_homes(), public.rpc_line_note_market_ingest(BIGINT, JSONB),
--     public.rpc_market_post_claim(INT), public.rpc_market_post_write(BIGINT, JSONB, TEXT),
--     public._match_products_by_norm(UUID, TEXT, TEXT[]), public._bigram_hit(TEXT, TEXT);
--   DELETE FROM community_product_candidates WHERE source_external_id LIKE 'ln:%';
--   DROP TABLE public.line_note_market_items, public.line_note_market_post_stats, public.line_note_market_posts;
--   ALTER TABLE line_note_communities DROP COLUMN crawl_enabled, DROP COLUMN crawl_supplier_id,
--     DROP COLUMN crawl_days, DROP COLUMN crawl_last_at, DROP COLUMN crawl_account_id;
--   DELETE FROM line_note_jobs WHERE kind = 'crawl';  -- 再把 CHECK 改回不含 crawl
-- ============================================================================

-- 1. 群組設定
ALTER TABLE public.line_note_communities
  ADD COLUMN IF NOT EXISTS crawl_enabled     BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS crawl_supplier_id BIGINT REFERENCES public.suppliers(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS crawl_days        INT NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS crawl_last_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS crawl_account_id  BIGINT REFERENCES public.line_note_accounts(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.line_note_communities.crawl_enabled IS '每天爬這個群組的記事本貼文當選品來源（廠商新品）';
COMMENT ON COLUMN public.line_note_communities.crawl_supplier_id IS '這個群組是哪個廠商發新品的地方（可空）';
COMMENT ON COLUMN public.line_note_communities.crawl_account_id IS
  '爬這個群組用哪個機器人帳號（勾選時選的那個）；NULL = 用社群原本綁的 account_id';

ALTER TABLE public.line_note_jobs DROP CONSTRAINT IF EXISTS line_note_jobs_kind_check;
ALTER TABLE public.line_note_jobs ADD CONSTRAINT line_note_jobs_kind_check CHECK (kind = ANY (ARRAY[
  'login', 'logout', 'list_homes', 'post', 'read', 'close', 'remind', 'share', 'reopen', 'refresh', 'promo', 'crawl'
]));

-- 2. 爬到的貼文
CREATE TABLE IF NOT EXISTS public.line_note_market_posts (
  id              BIGSERIAL   PRIMARY KEY,
  tenant_id       UUID        NOT NULL,
  community_id    BIGINT      NOT NULL REFERENCES public.line_note_communities(id) ON DELETE CASCADE,
  line_post_id    TEXT        NOT NULL,
  author_mid      TEXT,
  author_name     TEXT,
  text            TEXT        NOT NULL DEFAULT '',
  text_hash       TEXT,
  media           JSONB       NOT NULL DEFAULT '[]'::jsonb,
  posted_at       TIMESTAMPTZ,
  line_updated_at TIMESTAMPTZ,
  comment_count   INT         NOT NULL DEFAULT 0,
  like_count      INT         NOT NULL DEFAULT 0,
  first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  parsed_at       TIMESTAMPTZ,
  parse_error     TEXT,
  UNIQUE (community_id, line_post_id)
);
CREATE INDEX IF NOT EXISTS idx_lnmp_tenant_posted ON public.line_note_market_posts (tenant_id, posted_at DESC);
CREATE INDEX IF NOT EXISTS idx_lnmp_unparsed ON public.line_note_market_posts (first_seen_at) WHERE parsed_at IS NULL;
COMMENT ON TABLE public.line_note_market_posts IS
  '從廠商群組記事本爬到的貼文（20261101000040）。media 只存 LINE 回的 objectId 等原始欄位，還沒換成圖片網址';

CREATE TABLE IF NOT EXISTS public.line_note_market_post_stats (
  post_id       BIGINT NOT NULL REFERENCES public.line_note_market_posts(id) ON DELETE CASCADE,
  stat_date     DATE   NOT NULL,
  comment_count INT    NOT NULL,
  like_count    INT    NOT NULL,
  PRIMARY KEY (post_id, stat_date)
);
COMMENT ON TABLE public.line_note_market_post_stats IS '廠商貼文留言數 / 按讚數每日快照（台北日期），看 +1 長多快';

-- 3. 解析出來的商品
CREATE TABLE IF NOT EXISTS public.line_note_market_items (
  id            BIGSERIAL   PRIMARY KEY,
  tenant_id     UUID        NOT NULL,
  post_id       BIGINT      NOT NULL REFERENCES public.line_note_market_posts(id) ON DELETE CASCADE,
  item_name     TEXT        NOT NULL,
  norm_name     TEXT,
  price         NUMERIC(12,2),
  price_text    TEXT,
  spec          TEXT,
  deadline_text TEXT,
  tags          TEXT[]      NOT NULL DEFAULT '{}',
  matches       JSONB       NOT NULL DEFAULT '[]'::jsonb,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_lnmi_post ON public.line_note_market_items (post_id);
CREATE INDEX IF NOT EXISTS idx_lnmi_tenant_created ON public.line_note_market_items (tenant_id, created_at DESC);
COMMENT ON TABLE public.line_note_market_items IS
  '廠商貼文拆出來的商品（Claude 解析）。matches = 我方最像的 5 個商品（二字詞比對）＋當時開團數 / 買家數';

ALTER TABLE public.line_note_market_posts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.line_note_market_post_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.line_note_market_items      ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON public.line_note_market_posts, public.line_note_market_post_stats,
  public.line_note_market_items FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.line_note_market_posts, public.line_note_market_post_stats, public.line_note_market_items TO authenticated;

DROP POLICY IF EXISTS lnmp_hq_read ON public.line_note_market_posts;
CREATE POLICY lnmp_hq_read ON public.line_note_market_posts FOR SELECT TO authenticated
  USING (tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
         AND (SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', ''))
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']));
DROP POLICY IF EXISTS lnmps_hq_read ON public.line_note_market_post_stats;
CREATE POLICY lnmps_hq_read ON public.line_note_market_post_stats FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.line_note_market_posts p WHERE p.id = post_id));
DROP POLICY IF EXISTS lnmi_hq_read ON public.line_note_market_items;
CREATE POLICY lnmi_hq_read ON public.line_note_market_items FOR SELECT TO authenticated
  USING (tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
         AND (SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', ''))
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']));

-- 4. 每天排爬取工作（_line_note_tick 看到 queued 就會叫 worker）
CREATE OR REPLACE FUNCTION public._line_note_enqueue_crawls()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n INT;
BEGIN
  INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id)
  SELECT c.tenant_id, 'crawl', COALESCE(c.crawl_account_id, c.account_id), c.id
    FROM line_note_communities c
   WHERE c.crawl_enabled AND COALESCE(c.crawl_account_id, c.account_id) IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM line_note_jobs j
                      WHERE j.kind = 'crawl' AND j.community_id = c.id AND j.status IN ('queued', 'running'));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_enqueue_crawls() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule('line-note-crawl')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'line-note-crawl');
-- 台北 01:13（UTC 17:13）：Claude 解析排程在 02:53，中間留時間給 worker 讀完
SELECT cron.schedule('line-note-crawl', '13 17 * * *', $cron$ SELECT public._line_note_enqueue_crawls(); $cron$);

-- 5. 後台設定：用 home_id 指定（群組清單是從機器人帳號即時讀出來的，不一定已經在
--    line_note_communities 裡；沒有就建一列，listen / 自動發文一律關，跟同步新長出來的一樣）
CREATE OR REPLACE FUNCTION public.rpc_line_note_set_crawl(
  p_account_id BIGINT, p_home_id TEXT, p_home_name TEXT, p_home_kind TEXT,
  p_enabled BOOLEAN, p_supplier_id BIGINT DEFAULT NULL, p_crawl_now BOOLEAN DEFAULT FALSE
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_kind   TEXT := CASE WHEN p_home_kind IN ('group', 'square', 'square_chat') THEN p_home_kind ELSE 'square_chat' END;
  v_cid    BIGINT;
  v_job    BIGINT;
BEGIN
  IF v_role NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role: 只有總部可以設定廠商群組';
  END IF;
  IF COALESCE(btrim(p_home_id), '') = '' THEN RAISE EXCEPTION '缺群組 id'; END IF;
  IF NOT EXISTS (SELECT 1 FROM line_note_accounts WHERE id = p_account_id AND tenant_id = v_tenant) THEN
    RAISE EXCEPTION '找不到這個機器人帳號';
  END IF;
  IF p_supplier_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND tenant_id = v_tenant) THEN
    RAISE EXCEPTION '找不到這個廠商';
  END IF;

  UPDATE line_note_communities
     SET crawl_enabled = COALESCE(p_enabled, crawl_enabled),
         crawl_supplier_id = p_supplier_id,
         crawl_account_id = p_account_id,
         home_name = COALESCE(NULLIF(p_home_name, ''), home_name)
   WHERE tenant_id = v_tenant AND home_id = p_home_id
  RETURNING id INTO v_cid;

  IF v_cid IS NULL THEN
    IF NOT COALESCE(p_enabled, FALSE) THEN
      RETURN jsonb_build_object('ok', TRUE, 'community_id', NULL);  -- 沒在清單裡又是取消勾選：什麼都不用做
    END IF;
    -- 使用者明確要爬：之前在 LINE 記事本頁刪掉（隱藏）過也解除
    DELETE FROM line_note_home_dismissals WHERE tenant_id = v_tenant AND home_id = p_home_id;
    INSERT INTO line_note_communities
      (tenant_id, account_id, home_id, home_name, home_kind, listen_enabled, auto_post_on_open,
       read_times, read_days, synced_at, crawl_enabled, crawl_supplier_id, crawl_account_id)
    VALUES
      (v_tenant, p_account_id, p_home_id, NULLIF(p_home_name, ''), v_kind, FALSE, FALSE,
       ARRAY['12:00'], 3, now(), TRUE, p_supplier_id, p_account_id)
    RETURNING id INTO v_cid;
  END IF;

  IF COALESCE(p_crawl_now, FALSE) AND COALESCE(p_enabled, FALSE)
     AND NOT EXISTS (SELECT 1 FROM line_note_jobs WHERE kind = 'crawl' AND community_id = v_cid
                       AND status IN ('queued', 'running')) THEN
    INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, created_by)
    VALUES (v_tenant, 'crawl', p_account_id, v_cid, auth.uid())
    RETURNING id INTO v_job;
  END IF;

  RETURN jsonb_build_object('ok', TRUE, 'community_id', v_cid, 'job_id', v_job);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_set_crawl(BIGINT, TEXT, TEXT, TEXT, BOOLEAN, BIGINT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_set_crawl(BIGINT, TEXT, TEXT, TEXT, BOOLEAN, BIGINT, BOOLEAN) TO authenticated;

-- 後台設定表：勾了要爬的群組（或爬過的）＋狀態（靠 line_note_communities / suppliers 既有 RLS）
CREATE OR REPLACE FUNCTION public.rpc_line_note_crawl_homes()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', c.id, 'home_id', c.home_id, 'home_name', c.home_name, 'home_kind', c.home_kind,
           'account_id', COALESCE(c.crawl_account_id, c.account_id),
           'account_label', a.label, 'account_status', a.status,
           'crawl_enabled', c.crawl_enabled, 'crawl_supplier_id', c.crawl_supplier_id,
           'supplier_name', s.name, 'crawl_last_at', c.crawl_last_at, 'crawl_days', c.crawl_days,
           'posts', (SELECT count(*) FROM line_note_market_posts p WHERE p.community_id = c.id),
           'candidates', (SELECT count(*) FROM community_product_candidates cc
                           WHERE cc.source_external_id LIKE 'ln:%' AND (cc.raw ->> 'community_id')::bigint = c.id),
           'last_job', (SELECT jsonb_build_object('status', j.status, 'error', LEFT(j.error, 300),
                                                  'at', COALESCE(j.finished_at, j.created_at), 'result', j.result)
                          FROM line_note_jobs j WHERE j.kind = 'crawl' AND j.community_id = c.id
                         ORDER BY j.id DESC LIMIT 1)
         ) ORDER BY c.crawl_enabled DESC, c.home_name), '[]'::jsonb)
    FROM line_note_communities c
    LEFT JOIN line_note_accounts a ON a.id = COALESCE(c.crawl_account_id, c.account_id)
    LEFT JOIN suppliers s ON s.id = c.crawl_supplier_id
   WHERE c.crawl_enabled OR c.crawl_last_at IS NOT NULL;
$function$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_crawl_homes() TO authenticated;

-- 6. worker 寫入（service_role 專用）
CREATE OR REPLACE FUNCTION public.rpc_line_note_market_ingest(p_community_id BIGINT, p_posts JSONB)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_c        line_note_communities%ROWTYPE;
  v_today    DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_new      INT;
  v_changed  INT;
  v_total    INT;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  SELECT * INTO v_c FROM line_note_communities WHERE id = p_community_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'community % not found', p_community_id; END IF;

  CREATE TEMP TABLE _in ON COMMIT DROP AS
  SELECT DISTINCT ON (x->>'postId')
         x->>'postId'                                   AS line_post_id,
         NULLIF(x->>'authorMid', '')                    AS author_mid,
         NULLIF(x->>'authorName', '')                   AS author_name,
         LEFT(COALESCE(x->>'text', ''), 8000)           AS text,
         md5(COALESCE(x->>'text', ''))                  AS text_hash,
         COALESCE(x->'media', '[]'::jsonb)              AS media,
         NULLIF(x->>'createdAt', '')::timestamptz       AS posted_at,
         NULLIF(x->>'updatedAt', '')::timestamptz       AS line_updated_at,
         COALESCE((x->>'commentCount')::int, 0)         AS comment_count,
         COALESCE((x->>'likeCount')::int, 0)            AS like_count
    FROM jsonb_array_elements(COALESCE(p_posts, '[]'::jsonb)) x
   WHERE COALESCE(x->>'postId', '') <> '';

  -- 我方自己發的不收
  DELETE FROM _in i
   WHERE EXISTS (SELECT 1 FROM line_note_posts lp WHERE lp.line_post_id = i.line_post_id)
      OR (i.author_mid IS NOT NULL AND EXISTS (SELECT 1 FROM line_note_accounts a WHERE a.line_mid = i.author_mid));
  SELECT count(*) INTO v_total FROM _in;

  SELECT count(*) INTO v_new FROM _in i
   WHERE NOT EXISTS (SELECT 1 FROM line_note_market_posts p WHERE p.community_id = p_community_id AND p.line_post_id = i.line_post_id);
  SELECT count(*) INTO v_changed FROM _in i JOIN line_note_market_posts p
      ON p.community_id = p_community_id AND p.line_post_id = i.line_post_id AND p.text_hash IS DISTINCT FROM i.text_hash;

  INSERT INTO line_note_market_posts AS p
    (tenant_id, community_id, line_post_id, author_mid, author_name, text, text_hash, media,
     posted_at, line_updated_at, comment_count, like_count)
  SELECT v_c.tenant_id, p_community_id, line_post_id, author_mid, author_name, text, text_hash, media,
         posted_at, line_updated_at, comment_count, like_count
    FROM _in
  ON CONFLICT (community_id, line_post_id) DO UPDATE
     SET author_name = COALESCE(EXCLUDED.author_name, p.author_name),
         text = EXCLUDED.text,
         media = EXCLUDED.media,
         line_updated_at = EXCLUDED.line_updated_at,
         comment_count = EXCLUDED.comment_count,
         like_count = EXCLUDED.like_count,
         last_seen_at = now(),
         -- 文字改過 → 重新解析
         parsed_at = CASE WHEN p.text_hash IS DISTINCT FROM EXCLUDED.text_hash THEN NULL ELSE p.parsed_at END,
         parse_error = CASE WHEN p.text_hash IS DISTINCT FROM EXCLUDED.text_hash THEN NULL ELSE p.parse_error END,
         text_hash = EXCLUDED.text_hash;

  INSERT INTO line_note_market_post_stats AS s (post_id, stat_date, comment_count, like_count)
  SELECT p.id, v_today, i.comment_count, i.like_count
    FROM _in i JOIN line_note_market_posts p ON p.community_id = p_community_id AND p.line_post_id = i.line_post_id
  ON CONFLICT (post_id, stat_date) DO UPDATE
     SET comment_count = EXCLUDED.comment_count, like_count = EXCLUDED.like_count;

  UPDATE line_note_communities SET crawl_last_at = now() WHERE id = p_community_id;
  DROP TABLE IF EXISTS _in;

  RETURN jsonb_build_object('kept', v_total, 'new', v_new, 'text_changed', v_changed);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_market_ingest(BIGINT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_market_ingest(BIGINT, JSONB) TO service_role;

-- 7. 比對：正規化品名的二字詞，有幾成出現在我方商品名裡
CREATE OR REPLACE FUNCTION public._bigram_hit(p_name TEXT, p_norm TEXT)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE WHEN count(*) = 0 THEN 0
              ELSE count(*) FILTER (WHERE strpos(p_name, b) > 0)::numeric / count(*) END
    FROM (SELECT DISTINCT substr(tok, i, 2) AS b
            FROM regexp_split_to_table(COALESCE(p_norm, ''), '\s+') AS tok,
                 generate_series(1, GREATEST(length(tok) - 1, 1)) AS i
           WHERE tok <> '') s;
$function$;

CREATE OR REPLACE FUNCTION public._match_products_by_norm(p_tenant UUID, p_norm TEXT, p_tags TEXT[])
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH cand AS (
    SELECT p.id, p.name, public._bigram_hit(p.name, p_norm) AS hit,
           EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                    WHERE m.product_id = p.id AND t.code = ANY (COALESCE(p_tags, '{}'))) AS tag_ok
      FROM products p
     WHERE p.tenant_id = p_tenant
  ),
  top AS (
    SELECT * FROM cand WHERE hit >= 0.5
     ORDER BY hit DESC, tag_ok DESC, id DESC
     LIMIT 5
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_id', t.id, 'name', t.name, 'score', round(t.hit, 2), 'same_tag', t.tag_ok,
           'campaigns', h.campaigns, 'last_start', h.last_start, 'buyers', h.buyers
         ) ORDER BY t.hit DESC, t.tag_ok DESC, t.id DESC), '[]'::jsonb)
    FROM top t
    LEFT JOIN LATERAL (
      SELECT count(DISTINCT g.id) AS campaigns,
             max(g.start_at)::date AS last_start,
             (SELECT count(DISTINCT co.member_id)
                FROM customer_orders co
                JOIN members m ON m.id = co.member_id AND m.member_type <> 'store_internal'
               WHERE co.campaign_id IN (SELECT id FROM group_buy_campaigns WHERE product_id = t.id)
                 AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')) AS buyers
        FROM group_buy_campaigns g WHERE g.product_id = t.id
    ) h ON TRUE;
$function$;
REVOKE ALL ON FUNCTION public._match_products_by_norm(UUID, TEXT, TEXT[]) FROM PUBLIC, anon, authenticated;

-- 8. Claude 排程的讀寫（postgres / service_role 專用；Management API 跑 SQL 的身分是 postgres）
CREATE OR REPLACE FUNCTION public.rpc_market_post_claim(p_limit INT DEFAULT 20)
RETURNS TABLE (post_id BIGINT, community TEXT, supplier TEXT, author TEXT, posted TIMESTAMPTZ,
               comments INT, body TEXT)
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
    RETURNING p.id, p.community_id, p.author_name, p.posted_at, p.comment_count, p.text
  )
  SELECT m.id, c.home_name, s.name, m.author_name, m.posted_at, m.comment_count, m.text
    FROM marked m
    JOIN line_note_communities c ON c.id = m.community_id
    LEFT JOIN suppliers s ON s.id = c.crawl_supplier_id;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_post_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_market_post_claim(INT) TO service_role;

--    p_items：[{item_name, norm_name, price, price_text, spec, deadline_text, tags[]}]，空陣列 = 不是商品貼文
--    p_error 有值 = 這次沒處理到，清 parsed_at，下一次排程重撿
CREATE OR REPLACE FUNCTION public.rpc_market_post_write(p_post_id BIGINT, p_items JSONB, p_error TEXT DEFAULT NULL)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID;
  v_n      INT := 0;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  SELECT tenant_id INTO v_tenant FROM line_note_market_posts WHERE id = p_post_id;
  IF v_tenant IS NULL THEN RETURN 0; END IF;

  IF p_error IS NOT NULL THEN
    UPDATE line_note_market_posts SET parsed_at = NULL, parse_error = LEFT(p_error, 500) WHERE id = p_post_id;
    RETURN 0;
  END IF;

  DELETE FROM line_note_market_items WHERE post_id = p_post_id;

  INSERT INTO line_note_market_items
    (tenant_id, post_id, item_name, norm_name, price, price_text, spec, deadline_text, tags, matches)
  SELECT v_tenant, p_post_id,
         LEFT(btrim(e->>'item_name'), 200),
         NULLIF(LEFT(btrim(COALESCE(e->>'norm_name', '')), 100), ''),
         CASE WHEN (e->>'price') ~ '^\d+(\.\d+)?$' THEN (e->>'price')::numeric END,
         NULLIF(LEFT(e->>'price_text', 200), ''),
         NULLIF(LEFT(e->>'spec', 200), ''),
         NULLIF(LEFT(e->>'deadline_text', 200), ''),
         COALESCE((SELECT array_agg(t.code) FROM product_tags t
                    WHERE t.tenant_id = v_tenant AND t.is_active
                      AND t.code IN (SELECT jsonb_array_elements_text(COALESCE(e->'tags', '[]'::jsonb)))), '{}'),
         public._match_products_by_norm(
           v_tenant,
           COALESCE(NULLIF(btrim(e->>'norm_name'), ''), e->>'item_name'),
           ARRAY(SELECT jsonb_array_elements_text(COALESCE(e->'tags', '[]'::jsonb))))
    FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
   WHERE COALESCE(btrim(e->>'item_name'), '') <> ''
   LIMIT 30;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- 每個商品進候選池（老闆動過的不改狀態，只更新內容）
  INSERT INTO community_product_candidates AS cc
    (tenant_id, source_channel, source_user_name, source_external_id, product_name_hint, raw_text,
     raw, parsed, parsed_at, system_status, similar_product_id, similarity_score)
  SELECT v_tenant,
         '廠商群組｜' || COALESCE(s.name, c.home_name, ''),
         p.author_name,
         'ln:' || p.line_post_id || ':' || md5(i.item_name),
         i.item_name || COALESCE('（' || i.spec || '）', ''),
         CASE WHEN btrim(p.text) = '' THEN i.item_name ELSE p.text END,
         jsonb_build_object('source', 'line_note_supplier', 'market_post_id', p.id, 'market_item_id', i.id,
                            'community_id', c.id, 'supplier_id', c.crawl_supplier_id, 'posted_at', p.posted_at),
         jsonb_build_object('price', i.price, 'price_text', i.price_text, 'spec', i.spec,
                            'deadline_text', i.deadline_text, 'norm_name', i.norm_name, 'tags', to_jsonb(i.tags),
                            'matches', i.matches, 'supplier', s.name, 'comment_count', p.comment_count),
         now(),
         CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.75 THEN 'duplicate_hint' ELSE 'new' END,
         (i.matches -> 0 ->> 'product_id')::bigint,
         LEAST((i.matches -> 0 ->> 'score')::numeric, 1)
    FROM line_note_market_items i
    JOIN line_note_market_posts p ON p.id = i.post_id
    JOIN line_note_communities c ON c.id = p.community_id
    LEFT JOIN suppliers s ON s.id = c.crawl_supplier_id
   WHERE i.post_id = p_post_id
  ON CONFLICT (tenant_id, source_external_id) WHERE source_external_id IS NOT NULL DO UPDATE
     SET product_name_hint = EXCLUDED.product_name_hint,
         raw_text = EXCLUDED.raw_text,
         raw = EXCLUDED.raw,
         parsed = EXCLUDED.parsed,
         parsed_at = EXCLUDED.parsed_at,
         similar_product_id = EXCLUDED.similar_product_id,
         similarity_score = EXCLUDED.similarity_score,
         system_status = CASE WHEN cc.owner_action = 'none' AND cc.system_status IN ('new', 'duplicate_hint')
                              THEN EXCLUDED.system_status ELSE cc.system_status END;

  UPDATE line_note_market_posts SET parse_error = NULL WHERE id = p_post_id;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_post_write(BIGINT, JSONB, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_market_post_write(BIGINT, JSONB, TEXT) TO service_role;

-- 9. 先把三個已知的廠商群組勾起來、對上廠商主檔（匯洲 / 173 批發；報新品不指定廠商）
--    小幫手重新設定後到「廠商群組」頁改用新帳號、加減群組即可
UPDATE public.line_note_communities c
   SET crawl_enabled = TRUE,
       crawl_supplier_id = CASE
         WHEN c.home_name LIKE '匯洲%' THEN (SELECT id FROM suppliers s WHERE s.tenant_id = c.tenant_id AND s.name = '匯洲' LIMIT 1)
         WHEN c.home_name LIKE '173%' THEN (SELECT id FROM suppliers s WHERE s.tenant_id = c.tenant_id AND s.name = '173批發' LIMIT 1)
       END
 WHERE c.home_name LIKE '匯洲%' OR c.home_name LIKE '173%' OR c.home_name LIKE '報新品%';

-- ============================================================================
-- 廠商網站商品改成 30 個一批給模型（老闆 2026-11-07：「網站那段改成一批 30 個」）
--
-- 背景：vendor_site 貼文原本跟 LINE 貼文走同一條（rpc_market_post_claim → 一篇一次呼叫 Llama 4 Scout）。
-- 網站商品一篇只有一個商品、品名 / 價格 / 規格本來就是結構化的，每篇卻都重送一次 ~1,300 字的固定指令
-- ＋標籤清單（占送出 token 的三分之二）。11/7 正式資料試打 30 個一批：
--   一篇一次 ≈ 1,700 token / 0.0006 美元；30 個一批 ≈ 165 token / 0.00007 美元（-88%），速度約 4 倍。
-- 另外 11/7 下午 173 的「山本山焙茶茶包」每次都輸出到一半開始重複、JSON 被截斷，失敗就清 parsed_at、
-- 又因為 posted_at 最新排在最前面 → 每一輪都先卡在它身上。改走批次後網站商品不會再進那條路。
--
-- 做法：
--   1. line_note_market_posts 加 vendor_item JSONB：進料時就存 {name, price, price_text, spec, category, short_desc, product_code}
--   2. rpc_market_post_claim（基底 20261107000000）排除 source='vendor_site'
--   3. 新 rpc_vendor_site_post_claim(p_limit)：一次撿 30 篇（FOR UPDATE SKIP LOCKED，蓋 parsed_at）
--      回 vendor_item 與 text；Edge Function market-ai 一次呼叫模型拿 norm_name / deadline_text / tags，
--      品名 / 價格 / 規格直接用 vendor_item，再逐篇呼叫既有的 rpc_market_post_write（候選池、比對照舊）。
--      模型失敗：對半再試一次，還失敗就照網站品名寫入、標籤留空 —— 不清 parsed_at，不會重試卡住。
--   4. rpc_vendor_site_market_ingest（基底 20261107000000）把 p_products[].item 存進 vendor_item
--      （文字沒變只補 vendor_item、不重解析）。舊資料沒有 vendor_item 的，Edge Function 從貼文文字前兩行退回去拆。
--
-- 基底版本：rpc_market_post_claim、rpc_vendor_site_market_ingest ← 20261107000000_vendor_site_market_posts.sql
-- rollback：重跑 20261107000000 的兩支定義；DROP FUNCTION public.rpc_vendor_site_post_claim(INT);
--   ALTER TABLE line_note_market_posts DROP COLUMN vendor_item;（market-ai 要一起回到舊版，否則網站貼文沒人撿）
-- ============================================================================

ALTER TABLE public.line_note_market_posts ADD COLUMN IF NOT EXISTS vendor_item JSONB;

CREATE INDEX IF NOT EXISTS idx_lnmp_vendor_unparsed
  ON public.line_note_market_posts (posted_at DESC, id DESC) WHERE parsed_at IS NULL AND source = 'vendor_site';

-- rpc_market_post_claim（基底 20261107000000）：排除網站商品
CREATE OR REPLACE FUNCTION public.rpc_market_post_claim(p_limit INT DEFAULT 20)
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

  -- 沒有文字的（只有圖）直接標解析完，不送模型
  UPDATE line_note_market_posts mp SET parsed_at = now()
   WHERE mp.parsed_at IS NULL AND btrim(mp.text) = '' AND mp.source <> 'vendor_site';

  RETURN QUERY
  WITH picked AS (
    SELECT p.id FROM line_note_market_posts p
     WHERE p.parsed_at IS NULL
       AND p.source <> 'vendor_site'   -- 20261107000060：廠商網站走 rpc_vendor_site_post_claim（30 個一批）
     ORDER BY p.posted_at DESC NULLS LAST, p.id DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 60)
     FOR UPDATE SKIP LOCKED
  ),
  marked AS (
    UPDATE line_note_market_posts p SET parsed_at = now(), parse_error = NULL
      FROM picked WHERE p.id = picked.id
    RETURNING p.id, p.community_id, p.supplier_id, p.source, p.author_name, p.posted_at, p.comment_count, p.text, p.image_paths
  )
  SELECT m.id,
         COALESCE(c.home_name, CASE WHEN m.source = 'vendor_site' THEN '廠商網站' END),
         s.name, m.author_name, m.posted_at, m.comment_count, m.text,
         COALESCE(m.image_paths, '{}')
    FROM marked m
    LEFT JOIN line_note_communities c ON c.id = m.community_id
    LEFT JOIN suppliers s ON s.id = COALESCE(m.supplier_id, c.crawl_supplier_id);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_post_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_market_post_claim(INT) TO service_role;

-- ----------------------------------------------------------------------------
-- rpc_vendor_site_post_claim：廠商網站商品一次撿一批（給 market-ai 30 個一批呼叫模型）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_vendor_site_post_claim(p_limit INT DEFAULT 30)
RETURNS TABLE (post_id BIGINT, supplier TEXT, item JSONB, body TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  WITH picked AS (
    SELECT p.id FROM line_note_market_posts p
     WHERE p.parsed_at IS NULL AND p.source = 'vendor_site'
     ORDER BY p.posted_at DESC NULLS LAST, p.id DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 60)
     FOR UPDATE SKIP LOCKED
  ),
  marked AS (
    UPDATE line_note_market_posts p SET parsed_at = now(), parse_error = NULL
      FROM picked WHERE p.id = picked.id
    RETURNING p.id, p.supplier_id, p.vendor_item, p.text
  )
  SELECT m.id, s.name, m.vendor_item, m.text
    FROM marked m
    LEFT JOIN suppliers s ON s.id = m.supplier_id
   ORDER BY m.id;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_vendor_site_post_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_vendor_site_post_claim(INT) TO service_role;

-- rpc_vendor_site_market_ingest（基底 20261107000000）：存 vendor_item
CREATE OR REPLACE FUNCTION public.rpc_vendor_site_market_ingest(p_supplier_id BIGINT, p_vendor_key TEXT, p_products JSONB)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_new      INT;
  v_changed  INT;
  v_total    INT;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF COALESCE(btrim(p_vendor_key), '') = '' OR p_vendor_key !~ '^[a-z0-9_-]+$' THEN
    RAISE EXCEPTION 'vendor_key 只能是小寫英數、底線、減號：%', p_vendor_key;
  END IF;
  SELECT tenant_id INTO v_tenant FROM suppliers WHERE id = p_supplier_id;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'supplier % not found', p_supplier_id; END IF;

  CREATE TEMP TABLE _vin ON COMMIT DROP AS
  SELECT DISTINCT ON (x->>'psn')
         'web:' || p_vendor_key || ':' || (x->>'psn')              AS line_post_id,
         LEFT(COALESCE(x->>'text', ''), 8000)                       AS text,
         md5(LEFT(COALESCE(x->>'text', ''), 8000))                  AS text_hash,
         NULLIF(x->>'url', '')                                      AS source_url,
         CASE WHEN jsonb_typeof(x->'image_paths') = 'array' AND jsonb_array_length(x->'image_paths') > 0
              THEN ARRAY(SELECT jsonb_array_elements_text(x->'image_paths')) END AS image_paths,
         COALESCE(NULLIF(x->>'scraped_at', '')::timestamptz, now())  AS posted_at,
         CASE WHEN jsonb_typeof(x->'item') = 'object' THEN x->'item' END AS vendor_item
    FROM jsonb_array_elements(COALESCE(p_products, '[]'::jsonb)) x
   WHERE COALESCE(x->>'psn', '') <> '' AND COALESCE(btrim(x->>'text'), '') <> '';
  SELECT count(*) INTO v_total FROM _vin;

  SELECT count(*) INTO v_new FROM _vin i
   WHERE NOT EXISTS (SELECT 1 FROM line_note_market_posts p
                      WHERE p.tenant_id = v_tenant AND p.community_id IS NULL AND p.line_post_id = i.line_post_id);
  SELECT count(*) INTO v_changed FROM _vin i JOIN line_note_market_posts p
      ON p.tenant_id = v_tenant AND p.community_id IS NULL AND p.line_post_id = i.line_post_id
     AND p.text_hash IS DISTINCT FROM i.text_hash;

  INSERT INTO line_note_market_posts AS p
    (tenant_id, community_id, source, supplier_id, line_post_id, text, text_hash, source_url, image_paths, posted_at, vendor_item)
  SELECT v_tenant, NULL, 'vendor_site', p_supplier_id, line_post_id, text, text_hash, source_url, image_paths, posted_at, vendor_item
    FROM _vin
  ON CONFLICT (tenant_id, line_post_id) WHERE community_id IS NULL DO UPDATE
     SET text = EXCLUDED.text,
         supplier_id = EXCLUDED.supplier_id,
         source_url = COALESCE(EXCLUDED.source_url, p.source_url),
         image_paths = COALESCE(EXCLUDED.image_paths, p.image_paths),
         vendor_item = COALESCE(EXCLUDED.vendor_item, p.vendor_item),
         last_seen_at = now(),
         -- 文字改過（價格／規格變了）→ 重新解析
         parsed_at = CASE WHEN p.text_hash IS DISTINCT FROM EXCLUDED.text_hash THEN NULL ELSE p.parsed_at END,
         parse_error = CASE WHEN p.text_hash IS DISTINCT FROM EXCLUDED.text_hash THEN NULL ELSE p.parse_error END,
         text_hash = EXCLUDED.text_hash;

  -- 先整篇進候選池（待整理），模型拆品項時再換成正式品項
  PERFORM public._market_post_quick_candidate(p.id)
     FROM _vin i JOIN line_note_market_posts p
       ON p.tenant_id = v_tenant AND p.community_id IS NULL AND p.line_post_id = i.line_post_id
    WHERE p.parsed_at IS NULL;

  DROP TABLE IF EXISTS _vin;

  RETURN jsonb_build_object('kept', v_total, 'new', v_new, 'text_changed', v_changed);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_vendor_site_market_ingest(BIGINT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_vendor_site_market_ingest(BIGINT, TEXT, JSONB) TO service_role;

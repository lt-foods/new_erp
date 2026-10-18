-- ============================================================================
-- 20261003000000_line_note_order_cheer.sql
--
-- 商城下單播報（老闆 2026-10-03 交代）：有人在 App／LIFF 商城下單，依他的群到
-- LINE 記事本那篇開團貼文底下留一句（「🛒 王○明 剛剛在商城下單 A×2 ✨ 目前已有 N 位好鄰居跟團」），
-- 讓記事本看起來熱絡。
--
-- 他的群怎麼認（兩條取聯集，只挑這團已經發出去的貼文）：
--   1. 這位會員在哪個社群留過言（line_note_comments.member_id → post → community）—— 線上
--      1,359 位留過言的會員對應 1,370 組 (會員, 社群)，幾乎一人一群，是最準的訊號；
--   2. 社群設定的店（line_note_communities.store_id）= 訂單取貨店。
--   子群（share_from_community_id）沒有自己的貼文，不留。
--
-- 流程：liff-api place_member_order 成功後呼叫 rpc_line_note_enqueue_order_cheer(order, items)
--   → 每個命中的貼文排一個 kind='cheer' 的 line_note_jobs（payload 帶人名／品項代碼／跟團人數）
--   → worker jobCheer 套社群的 cheer_template 留言，並把自己這則登記成 line_note_comments
--     status='ignored'（文末固定帶「#商城下單」，讀留言時認得出是自己發的、不會被當成 +1 解析）。
--
-- 只排工作、不打 LINE：下單那條路不能被記事本拖慢或拖垮。排了工作 _line_note_tick 下一分鐘就會叫 worker。
--
-- 基底：line_note_jobs_kind_check @ 20260929040000（只多 'cheer'）。新函式，不改既有函式。
-- rollback：
--   DROP FUNCTION rpc_line_note_enqueue_order_cheer(BIGINT, JSONB);
--   DROP FUNCTION rpc_line_note_community_set_cheer(BIGINT, BOOLEAN, TEXT);
--   kind CHECK 還原 20260929040000；兩個欄位與索引留著無害。
-- ============================================================================

ALTER TABLE public.line_note_communities
  ADD COLUMN IF NOT EXISTS cheer_on_app_order BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS cheer_template     TEXT;
COMMENT ON COLUMN public.line_note_communities.cheer_on_app_order IS
  '有人在商城下單時，到這個社群該團的貼文底下留言播報（20261003000000）';
COMMENT ON COLUMN public.line_note_communities.cheer_template IS
  '播報留言模板；NULL = worker 預設。可用 {{name}}（遮一半）{{full_name}} {{items}} {{items_full}} {{count}} {{store_count}} {{campaign}} {{order_no}}';

ALTER TABLE public.line_note_jobs DROP CONSTRAINT IF EXISTS line_note_jobs_kind_check;
ALTER TABLE public.line_note_jobs ADD CONSTRAINT line_note_jobs_kind_check
  CHECK (kind IN ('login', 'logout', 'list_homes', 'post', 'read', 'close', 'remind', 'share', 'reopen', 'refresh', 'cheer'));

-- 「這位會員在哪個社群留過言」要查得快
CREATE INDEX IF NOT EXISTS idx_line_note_comments_member
  ON public.line_note_comments (member_id) WHERE member_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 排工作：liff-api（service_role）在下單成功後呼叫。回排了幾個。
-- p_items = 這次下單的 [{campaign_item_id, qty}]；NULL 就用整張單還沒取的品項。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_enqueue_order_cheer(p_order_id BIGINT, p_items JSONB DEFAULT NULL)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_o           RECORD;
  v_items       JSONB := '[]'::jsonb;
  v_count       INT := 0;
  v_store_count INT := 0;
  v_c           RECORD;
  v_n           INT := 0;
BEGIN
  SELECT co.id, co.tenant_id, co.campaign_id, co.member_id, co.pickup_store_id, co.order_no,
         COALESCE(NULLIF(TRIM(m.name), ''), co.nickname_snapshot) AS member_name,
         g.name AS campaign_name, g.status AS campaign_status
    INTO v_o
    FROM customer_orders co
    JOIN group_buy_campaigns g ON g.id = co.campaign_id
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.id = p_order_id;
  IF v_o.id IS NULL OR v_o.campaign_status <> 'open' OR v_o.member_id IS NULL THEN RETURN 0; END IF;

  -- 品項代碼跟貼文上印的同一套（_line_note_item_codes：A、B、C…）
  IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('code', ic.code, 'name', ic.item_name, 'qty', x.qty) ORDER BY ic.code), '[]'::jsonb)
      INTO v_items
      FROM (SELECT (e ->> 'campaign_item_id')::bigint AS ci, SUM((e ->> 'qty')::numeric) AS qty
              FROM jsonb_array_elements(p_items) e
             WHERE COALESCE((e ->> 'qty')::numeric, 0) > 0
             GROUP BY 1) x
      JOIN public._line_note_item_codes(v_o.campaign_id) ic ON ic.campaign_item_id = x.ci;
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('code', y.code, 'name', y.item_name, 'qty', y.qty) ORDER BY y.code), '[]'::jsonb)
      INTO v_items
      FROM (SELECT ic.code, ic.item_name, SUM(coi.qty) AS qty
              FROM customer_order_items coi
              JOIN public._line_note_item_codes(v_o.campaign_id) ic ON ic.campaign_item_id = coi.campaign_item_id
             WHERE coi.order_id = v_o.id AND coi.status IN ('pending', 'reserved', 'ready')
             GROUP BY ic.code, ic.item_name) y;
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN RETURN 0; END IF;

  -- 跟團人數：這團的有效訂單（不含內部容器單）。全站一個數、本店一個數，模板自己挑。
  SELECT count(*) FILTER (WHERE TRUE),
         count(*) FILTER (WHERE co.pickup_store_id IS NOT DISTINCT FROM v_o.pickup_store_id)
    INTO v_count, v_store_count
    FROM customer_orders co
    LEFT JOIN members m ON m.id = co.member_id
   WHERE co.campaign_id = v_o.campaign_id
     AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
     AND COALESCE(m.member_type, '') <> 'store_internal';

  FOR v_c IN
    SELECT p.id AS post_id, p.community_id, c.account_id
      FROM line_note_posts p
      JOIN line_note_communities c ON c.id = p.community_id
      JOIN line_note_accounts a ON a.id = c.account_id AND a.status = 'active'
     WHERE p.campaign_id = v_o.campaign_id
       AND p.status = 'posted' AND p.line_post_id IS NOT NULL
       AND c.tenant_id = v_o.tenant_id
       AND c.cheer_on_app_order
       AND c.share_from_community_id IS NULL
       AND (
             (v_o.pickup_store_id IS NOT NULL AND c.store_id = v_o.pickup_store_id)
          OR EXISTS (SELECT 1
                       FROM line_note_comments lc
                       JOIN line_note_posts lp ON lp.id = lc.post_id
                      WHERE lc.member_id = v_o.member_id AND lp.community_id = c.id)
           )
       -- 同一張單對同一篇還有排隊中的播報（幾秒內連按兩次加購）就不再排
       AND NOT EXISTS (SELECT 1 FROM line_note_jobs j
                        WHERE j.kind = 'cheer' AND j.post_id = p.id AND j.status = 'queued'
                          AND (j.payload ->> 'order_id')::bigint = v_o.id)
  LOOP
    INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, payload)
    VALUES (v_o.tenant_id, 'cheer', v_c.account_id, v_c.community_id, v_c.post_id,
            jsonb_build_object(
              'order_id',      v_o.id,
              'order_no',      v_o.order_no,
              'name',          v_o.member_name,
              'items',         v_items,
              'count',         v_count,
              'store_count',   v_store_count,
              'campaign_name', v_o.campaign_name));
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_enqueue_order_cheer(BIGINT, JSONB) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 後台社群設定：開關 + 模板（比照 rpc_line_note_community_set_close_comment）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_community_set_cheer(p_id BIGINT, p_enabled BOOLEAN, p_template TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
BEGIN
  UPDATE line_note_communities
     SET cheer_on_app_order = COALESCE(p_enabled, cheer_on_app_order),
         cheer_template     = NULLIF(TRIM(COALESCE(p_template, '')), ''),
         updated_by         = auth.uid()
   WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_set_cheer(BIGINT, BOOLEAN, TEXT) TO authenticated;

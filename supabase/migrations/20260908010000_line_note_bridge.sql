-- ============================================================================
-- 20260908010000_line_note_bridge.sql
--
-- LINE 群組／社群「記事本」整合（愛+1 那種玩法）：
--   後台登入一般 LINE 帳號（備用帳號）→ 綁社群 → 開團時自動發文到記事本
--   → 定時讀底下留言 → 留言裡的 6 碼會員編號 + 品項代碼 → 自動加單。
--
-- 實際跟 LINE 講話的是地端 worker（tools/line-note-scraper/src/worker.mjs，
-- 用 service_role 輪詢 line_note_jobs）。DB 這邊只管：設定、佇列、留言落地、
-- 留言→訂單的轉換（rpc_line_note_apply_comment，呼叫既有 rpc_create_customer_orders）。
--
-- 全部是新物件，沒有覆蓋既有 function。group_buy_campaigns 只「加一支 trigger」
-- （status 變 open → 排發文），不動它本身。
--
-- rollback：
--   DROP TRIGGER trg_line_note_on_campaign_open ON group_buy_campaigns;
--   DROP FUNCTION _line_note_on_campaign_open, rpc_line_note_apply_comment,
--                 rpc_line_note_post_payload, _line_note_item_codes,
--                 rpc_line_note_enqueue, rpc_line_note_queue_post,
--                 rpc_line_note_community_upsert, rpc_line_note_community_delete,
--                 rpc_line_note_account_upsert, rpc_line_note_account_delete;
--   DROP VIEW v_line_note_accounts;
--   DROP TABLE line_note_jobs, line_note_comments, line_note_posts,
--              line_note_communities, line_note_accounts;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 帳號（含登入 token → 秘密，不開 RLS policy、只透過 view 讀非敏感欄位）
-- ----------------------------------------------------------------------------
CREATE TABLE line_note_accounts (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  label         TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'logged_out'
                  CHECK (status IN ('logged_out','pending_qr','active','error')),
  line_mid      TEXT,
  display_name  TEXT,
  auth_token    TEXT,          -- 秘密：linejs 的 X-Line-Access
  qr_image      TEXT,          -- 登入中：data:image/png;base64,…（worker 產生）
  qr_url        TEXT,          -- 登入中：手機可直接開的網址
  pin_code      TEXT,          -- 登入中：手機 LINE 要輸入的 PIN
  last_error    TEXT,
  last_seen_at  TIMESTAMPTZ,
  created_by    UUID,
  updated_by    UUID,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_line_note_accounts_tenant ON line_note_accounts (tenant_id);
CREATE TRIGGER trg_touch_line_note_accounts
  BEFORE UPDATE ON line_note_accounts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE line_note_accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON line_note_accounts FROM anon, authenticated;

-- 後台讀這個 view（沒有 token）
CREATE VIEW v_line_note_accounts AS
  SELECT id, tenant_id, label, status, line_mid, display_name,
         qr_image, qr_url, pin_code, last_error, last_seen_at, created_at, updated_at
    FROM line_note_accounts
   WHERE tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
     AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
         = ANY (ARRAY['owner','admin','hq_manager','assistant','']);
GRANT SELECT ON v_line_note_accounts TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. 社群設定：哪個帳號、哪個記事本、對應哪個 line_channels（決定取貨店）
-- ----------------------------------------------------------------------------
CREATE TABLE line_note_communities (
  id                 BIGSERIAL PRIMARY KEY,
  tenant_id          UUID NOT NULL,
  account_id         BIGINT NOT NULL REFERENCES line_note_accounts(id) ON DELETE CASCADE,
  channel_id         BIGINT NOT NULL REFERENCES line_channels(id),
  home_id            TEXT NOT NULL,     -- c…（群組）/ m…（社群聊天室）/ s…（社群）
  home_name          TEXT,
  home_kind          TEXT NOT NULL DEFAULT 'square_chat'
                       CHECK (home_kind IN ('group','square','square_chat')),
  listen_enabled     BOOLEAN NOT NULL DEFAULT FALSE,
  read_times         TEXT[] NOT NULL DEFAULT ARRAY['12:00'],  -- 台北時間 HH:MM，可多個
  auto_post_on_open  BOOLEAN NOT NULL DEFAULT TRUE,
  post_template      TEXT,             -- NULL → worker 用預設模板
  last_read_at       TIMESTAMPTZ,
  last_error         TEXT,
  created_by         UUID,
  updated_by         UUID,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, home_id)
);
CREATE INDEX idx_line_note_communities_channel ON line_note_communities (channel_id);
CREATE TRIGGER trg_touch_line_note_communities
  BEFORE UPDATE ON line_note_communities
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE line_note_communities ENABLE ROW LEVEL SECURITY;
CREATE POLICY lnc_hq_all ON line_note_communities FOR ALL
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']))
  WITH CHECK (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']));
GRANT SELECT ON line_note_communities TO authenticated;

-- ----------------------------------------------------------------------------
-- 3. 貼文：一個社群 × 一個團 = 一篇
-- ----------------------------------------------------------------------------
CREATE TABLE line_note_posts (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  community_id   BIGINT NOT NULL REFERENCES line_note_communities(id) ON DELETE CASCADE,
  campaign_id    BIGINT NOT NULL REFERENCES group_buy_campaigns(id) ON DELETE CASCADE,
  line_post_id   TEXT,
  text           TEXT,
  status         TEXT NOT NULL DEFAULT 'queued'
                   CHECK (status IN ('queued','posted','failed','closed')),
  posted_at      TIMESTAMPTZ,
  last_read_at   TIMESTAMPTZ,
  comment_count  INT NOT NULL DEFAULT 0,
  last_error     TEXT,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (community_id, campaign_id)
);
CREATE INDEX idx_line_note_posts_campaign ON line_note_posts (campaign_id);
CREATE TRIGGER trg_touch_line_note_posts
  BEFORE UPDATE ON line_note_posts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE line_note_posts ENABLE ROW LEVEL SECURITY;
CREATE POLICY lnp_hq_all ON line_note_posts FOR ALL
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']))
  WITH CHECK (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']));
GRANT SELECT ON line_note_posts TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. 留言：worker 落地，parsed = [{code, qty, cancel, line}]，member_no_hint = 6 碼
-- ----------------------------------------------------------------------------
CREATE TABLE line_note_comments (
  id                 BIGSERIAL PRIMARY KEY,
  tenant_id          UUID NOT NULL,
  post_id            BIGINT NOT NULL REFERENCES line_note_posts(id) ON DELETE CASCADE,
  line_comment_id    TEXT NOT NULL,
  commenter_id       TEXT,             -- 群組：u…（= LINE userId）；社群：p…（社群成員 id）
  commenter_name     TEXT,
  text               TEXT NOT NULL,
  commented_at       TIMESTAMPTZ,
  member_no_hint     TEXT,             -- 留言裡抓到的 6 碼
  parsed             JSONB NOT NULL DEFAULT '[]'::jsonb,
  status             TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','ordered','unmatched','no_order','error','ignored')),
  member_id          BIGINT REFERENCES members(id),
  customer_order_id  BIGINT,
  error              TEXT,
  processed_at       TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (post_id, line_comment_id)
);
CREATE INDEX idx_line_note_comments_status ON line_note_comments (tenant_id, status);
CREATE TRIGGER trg_touch_line_note_comments
  BEFORE UPDATE ON line_note_comments
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE line_note_comments ENABLE ROW LEVEL SECURITY;
CREATE POLICY lncm_hq_all ON line_note_comments FOR ALL
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']))
  WITH CHECK (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']));
GRANT SELECT, UPDATE ON line_note_comments TO authenticated;  -- UPDATE：後台可標「忽略」

-- ----------------------------------------------------------------------------
-- 5. 工作佇列：後台丟、worker 撿
-- ----------------------------------------------------------------------------
CREATE TABLE line_note_jobs (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('login','logout','list_homes','post','read')),
  account_id    BIGINT NOT NULL REFERENCES line_note_accounts(id) ON DELETE CASCADE,
  community_id  BIGINT REFERENCES line_note_communities(id) ON DELETE SET NULL,
  post_id       BIGINT REFERENCES line_note_posts(id) ON DELETE SET NULL,
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  status        TEXT NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued','running','done','failed')),
  result        JSONB,
  error         TEXT,
  created_by    UUID,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at    TIMESTAMPTZ,
  finished_at   TIMESTAMPTZ
);
CREATE INDEX idx_line_note_jobs_queue ON line_note_jobs (status, created_at) WHERE status IN ('queued','running');

ALTER TABLE line_note_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY lnj_hq_read ON line_note_jobs FOR SELECT
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
             = ANY (ARRAY['owner','admin','hq_manager','assistant','']));
GRANT SELECT ON line_note_jobs TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. 帳號 / 社群 CRUD RPC（tenant 由 JWT 決定，前端不用帶）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_require_admin()
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  RETURN v_tenant;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_line_note_account_upsert(
  p_id BIGINT, p_label TEXT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_id     BIGINT;
BEGIN
  IF COALESCE(TRIM(p_label), '') = '' THEN RAISE EXCEPTION '請輸入帳號名稱'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO line_note_accounts (tenant_id, label, created_by, updated_by)
    VALUES (v_tenant, TRIM(p_label), auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE line_note_accounts
       SET label = TRIM(p_label), updated_by = auth.uid()
     WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'account % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_account_upsert(BIGINT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_line_note_account_delete(p_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
BEGIN
  DELETE FROM line_note_accounts WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'account % not in tenant', p_id; END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_account_delete(BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_line_note_community_upsert(
  p_id                BIGINT,
  p_account_id        BIGINT,
  p_channel_id        BIGINT,
  p_home_id           TEXT,
  p_home_name         TEXT,
  p_home_kind         TEXT,
  p_listen_enabled    BOOLEAN,
  p_read_times        TEXT[],
  p_auto_post_on_open BOOLEAN,
  p_post_template     TEXT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_id     BIGINT;
  v_t      TEXT;
BEGIN
  PERFORM 1 FROM line_note_accounts WHERE id = p_account_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'account % not in tenant', p_account_id; END IF;
  PERFORM 1 FROM line_channels WHERE id = p_channel_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'channel % not in tenant', p_channel_id; END IF;
  IF COALESCE(TRIM(p_home_id), '') = '' THEN RAISE EXCEPTION '請選擇社群'; END IF;
  FOREACH v_t IN ARRAY COALESCE(p_read_times, ARRAY[]::TEXT[]) LOOP
    IF v_t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
      RAISE EXCEPTION '讀取時間格式要是 HH:MM（收到「%」）', v_t;
    END IF;
  END LOOP;

  IF p_id IS NULL THEN
    INSERT INTO line_note_communities
      (tenant_id, account_id, channel_id, home_id, home_name, home_kind,
       listen_enabled, read_times, auto_post_on_open, post_template, created_by, updated_by)
    VALUES
      (v_tenant, p_account_id, p_channel_id, TRIM(p_home_id), p_home_name,
       COALESCE(p_home_kind, 'square_chat'),
       COALESCE(p_listen_enabled, FALSE),
       COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), ARRAY['12:00']),
       COALESCE(p_auto_post_on_open, TRUE),
       NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
       auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE line_note_communities
       SET account_id        = p_account_id,
           channel_id        = p_channel_id,
           home_id           = TRIM(p_home_id),
           home_name         = p_home_name,
           home_kind         = COALESCE(p_home_kind, home_kind),
           listen_enabled    = COALESCE(p_listen_enabled, listen_enabled),
           read_times        = COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), read_times),
           auto_post_on_open = COALESCE(p_auto_post_on_open, auto_post_on_open),
           post_template     = NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
           updated_by        = auth.uid()
     WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_line_note_community_delete(p_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
BEGIN
  DELETE FROM line_note_communities WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_delete(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 7. 佇列：登入 / 登出 / 列社群 / 立即讀取 / 手動發文
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_enqueue(
  p_kind         TEXT,
  p_account_id   BIGINT,
  p_community_id BIGINT DEFAULT NULL,
  p_post_id      BIGINT DEFAULT NULL,
  p_payload      JSONB  DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_id     BIGINT;
BEGIN
  IF p_kind NOT IN ('login','logout','list_homes','read') THEN
    RAISE EXCEPTION 'kind % not allowed here', p_kind;
  END IF;
  PERFORM 1 FROM line_note_accounts WHERE id = p_account_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'account % not in tenant', p_account_id; END IF;
  IF p_community_id IS NOT NULL THEN
    PERFORM 1 FROM line_note_communities WHERE id = p_community_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'community % not in tenant', p_community_id; END IF;
  END IF;

  -- 同種類還在排隊的就不重複丟
  SELECT id INTO v_id FROM line_note_jobs
   WHERE tenant_id = v_tenant AND kind = p_kind AND account_id = p_account_id
     AND community_id IS NOT DISTINCT FROM p_community_id
     AND status IN ('queued','running')
   ORDER BY id DESC LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  IF p_kind = 'login' THEN
    UPDATE line_note_accounts
       SET status = 'pending_qr', qr_image = NULL, qr_url = NULL, pin_code = NULL, last_error = NULL
     WHERE id = p_account_id;
  END IF;

  INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, payload, created_by)
  VALUES (v_tenant, p_kind, p_account_id, p_community_id, p_post_id, COALESCE(p_payload, '{}'::jsonb), auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_enqueue(TEXT, BIGINT, BIGINT, BIGINT, JSONB) TO authenticated;

-- 手動把某個團發到某個社群（自動發文漏掉、或想補發時用）
CREATE OR REPLACE FUNCTION public.rpc_line_note_queue_post(
  p_community_id BIGINT, p_campaign_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant  UUID := public._line_note_require_admin();
  v_account BIGINT;
  v_post    BIGINT;
BEGIN
  SELECT account_id INTO v_account FROM line_note_communities
   WHERE id = p_community_id AND tenant_id = v_tenant;
  IF v_account IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_community_id; END IF;
  PERFORM 1 FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;

  INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, created_by, updated_by)
  VALUES (v_tenant, p_community_id, p_campaign_id, 'queued', auth.uid(), auth.uid())
  ON CONFLICT (community_id, campaign_id) DO UPDATE
     SET status = CASE WHEN line_note_posts.status = 'posted' THEN 'posted' ELSE 'queued' END,
         last_error = NULL, updated_by = auth.uid()
  RETURNING id INTO v_post;

  IF (SELECT status FROM line_note_posts WHERE id = v_post) = 'posted' THEN
    RAISE EXCEPTION '這個團已經發過文了';
  END IF;

  INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
  VALUES (v_tenant, 'post', v_account, p_community_id, v_post, auth.uid());
  RETURN v_post;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_queue_post(BIGINT, BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 8. 品項代碼：A/B/C… 依 campaign_items.sort_order, id。發文與解析都用這一支，
--    才不會「貼文寫 A、解析當成 B」。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_item_codes(p_campaign_id BIGINT)
RETURNS TABLE (code TEXT, campaign_item_id BIGINT, sku_id BIGINT,
               item_name TEXT, unit_price NUMERIC, cap_qty NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT chr(64 + (ROW_NUMBER() OVER (ORDER BY ci.sort_order, ci.id))::int) AS code,
         ci.id, ci.sku_id,
         TRIM(COALESCE(s.product_name, '') || CASE WHEN COALESCE(s.variant_name, '') <> '' THEN ' ' || s.variant_name ELSE '' END),
         ci.unit_price, ci.cap_qty
    FROM campaign_items ci
    JOIN skus s ON s.id = ci.sku_id
   WHERE ci.campaign_id = p_campaign_id
     AND COALESCE(ci.is_gift, FALSE) = FALSE
   ORDER BY ci.sort_order, ci.id
   LIMIT 26;   -- 超過 26 項就沒代碼了，那種團不適合記事本 +1
$$;

-- worker 發文用：把團的內容整包回來（模板由 worker 套）
CREATE OR REPLACE FUNCTION public.rpc_line_note_post_payload(p_post_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'post_id',       p.id,
    'home_id',       c.home_id,
    'home_kind',     c.home_kind,
    'account_id',    c.account_id,
    'post_template', c.post_template,
    'campaign', jsonb_build_object(
       'id', g.id, 'campaign_no', g.campaign_no, 'name', g.name,
       'description', g.description, 'status', g.status,
       'start_at', g.start_at, 'end_at', g.end_at, 'pickup_deadline', g.pickup_deadline),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'code', ic.code, 'campaign_item_id', ic.campaign_item_id,
                'name', ic.item_name, 'unit_price', ic.unit_price, 'cap_qty', ic.cap_qty)
                ORDER BY ic.code)
               FROM public._line_note_item_codes(g.id) ic), '[]'::jsonb)
  )
  FROM line_note_posts p
  JOIN line_note_communities c ON c.id = p.community_id
  JOIN group_buy_campaigns g ON g.id = p.campaign_id
  WHERE p.id = p_post_id;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_post_payload(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 9. 留言 → 訂單
--    parsed = [{"code":"A","qty":2,"cancel":false,"line":"A+2"}, …]
--    member_no_hint = 留言裡的 6 碼 → members.member_no = 'M' || 6 碼（或原樣）
--    走既有 rpc_create_customer_orders（同團同人已有單會併入）
--    worker 用 service_role 呼叫 → 沒有 tenant claim，這裡用留言的 tenant 補進 JWT claims
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_apply_comment(p_comment_id BIGINT)
RETURNS TABLE (out_status TEXT, out_order_id BIGINT, out_error TEXT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c            line_note_comments%ROWTYPE;
  v_tenant       UUID;
  v_campaign_id  BIGINT;
  v_channel_id   BIGINT;
  v_store_id     BIGINT;
  v_member_id    BIGINT;
  v_member_home  BIGINT;
  v_hint         TEXT;
  v_items        JSONB := '[]'::jsonb;
  v_p            JSONB;
  v_code         TEXT;
  v_qty          NUMERIC;
  v_ci           BIGINT;
  v_item_count   INT;
  v_order_id     BIGINT;
  v_err          TEXT;
  v_claim_tenant TEXT := auth.jwt() ->> 'tenant_id';
BEGIN
  SELECT * INTO v_c FROM line_note_comments WHERE id = p_comment_id;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'comment % not found', p_comment_id; END IF;
  v_tenant := v_c.tenant_id;

  -- 呼叫者是後台使用者 → tenant 要對得上；是 service_role → 補 claims 給下游 RPC 用
  IF v_claim_tenant IS NOT NULL AND v_claim_tenant <> '' THEN
    IF v_claim_tenant::uuid <> v_tenant THEN RAISE EXCEPTION 'comment % not in tenant', p_comment_id; END IF;
  ELSE
    PERFORM set_config('request.jwt.claims',
      jsonb_build_object('tenant_id', v_tenant,
                         'app_metadata', jsonb_build_object('tenant_id', v_tenant, 'role', 'admin'))::text,
      TRUE);
  END IF;

  IF v_c.status IN ('ordered','ignored') THEN
    RETURN QUERY SELECT v_c.status, v_c.customer_order_id, v_c.error; RETURN;
  END IF;

  SELECT p.campaign_id, c.channel_id, lc.home_store_id
    INTO v_campaign_id, v_channel_id, v_store_id
    FROM line_note_posts p
    JOIN line_note_communities c ON c.id = p.community_id
    JOIN line_channels lc ON lc.id = c.channel_id
   WHERE p.id = v_c.post_id;

  -- 沒有任何數量 → 不是下單留言
  IF jsonb_array_length(COALESCE(v_c.parsed, '[]'::jsonb)) = 0 THEN
    UPDATE line_note_comments SET status = 'no_order', processed_at = NOW() WHERE id = p_comment_id;
    RETURN QUERY SELECT 'no_order'::TEXT, NULL::BIGINT, NULL::TEXT; RETURN;
  END IF;

  -- 會員：6 碼 → M000000
  v_hint := NULLIF(TRIM(COALESCE(v_c.member_no_hint, '')), '');
  IF v_hint IS NULL THEN
    UPDATE line_note_comments SET status = 'unmatched', error = '留言裡沒有 6 碼會員編號', processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'unmatched'::TEXT, NULL::BIGINT, '留言裡沒有 6 碼會員編號'::TEXT; RETURN;
  END IF;
  SELECT m.id, m.home_store_id INTO v_member_id, v_member_home
    FROM members m
   WHERE m.tenant_id = v_tenant
     AND (m.member_no = 'M' || v_hint OR m.member_no = v_hint)
     AND m.status IS DISTINCT FROM 'merged'
   ORDER BY m.id LIMIT 1;
  IF v_member_id IS NULL THEN
    UPDATE line_note_comments SET status = 'unmatched', error = '找不到會員編號 ' || v_hint, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'unmatched'::TEXT, NULL::BIGINT, ('找不到會員編號 ' || v_hint)::TEXT; RETURN;
  END IF;

  -- 品項：code → campaign_item；沒 code 且團只有一項 → 那一項
  SELECT count(*) INTO v_item_count FROM public._line_note_item_codes(v_campaign_id);
  FOR v_p IN SELECT * FROM jsonb_array_elements(v_c.parsed) LOOP
    IF COALESCE((v_p ->> 'cancel')::boolean, FALSE) THEN CONTINUE; END IF;  -- 取消留言不自動處理，留給人看
    v_qty  := (v_p ->> 'qty')::numeric;
    v_code := UPPER(NULLIF(TRIM(COALESCE(v_p ->> 'code', '')), ''));
    IF v_qty IS NULL OR v_qty <= 0 THEN CONTINUE; END IF;
    IF v_code IS NULL THEN
      IF v_item_count = 1 THEN
        SELECT ic.campaign_item_id INTO v_ci FROM public._line_note_item_codes(v_campaign_id) ic;
      ELSE
        v_err := '沒寫品項代碼（這團有 ' || v_item_count || ' 項）';
        EXIT;
      END IF;
    ELSE
      SELECT ic.campaign_item_id INTO v_ci FROM public._line_note_item_codes(v_campaign_id) ic WHERE ic.code = v_code;
      IF v_ci IS NULL THEN v_err := '品項代碼 ' || v_code || ' 不在這團裡'; EXIT; END IF;
    END IF;
    v_items := v_items || jsonb_build_object('campaign_item_id', v_ci, 'qty', v_qty);
  END LOOP;

  IF v_err IS NOT NULL THEN
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, NULL::BIGINT, v_err; RETURN;
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN
    UPDATE line_note_comments SET status = 'no_order', member_id = v_member_id, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'no_order'::TEXT, NULL::BIGINT, NULL::TEXT; RETURN;
  END IF;

  BEGIN
    SELECT r.out_order_id INTO v_order_id
      FROM public.rpc_create_customer_orders(
             v_campaign_id, v_channel_id,
             jsonb_build_array(jsonb_build_object(
               'member_id', v_member_id,
               'nickname', v_c.commenter_name,
               'pickup_store_id', COALESCE(v_store_id, v_member_home),
               'items', v_items))) r
     LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  IF v_err IS NOT NULL THEN
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, NULL::BIGINT, v_err; RETURN;
  END IF;

  UPDATE line_note_comments
     SET status = 'ordered', member_id = v_member_id, customer_order_id = v_order_id,
         error = NULL, processed_at = NOW()
   WHERE id = p_comment_id;
  RETURN QUERY SELECT 'ordered'::TEXT, v_order_id, NULL::TEXT;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_apply_comment(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 10. 開團（status → open）就排發文：團有掛在哪些 line_channels（campaign_channels），
--     那些 channel 底下有設「自動發文」的社群就各排一篇。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_on_campaign_open()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c RECORD;
  v_post BIGINT;
BEGIN
  IF NEW.status <> 'open' OR OLD.status = 'open' THEN RETURN NEW; END IF;
  FOR v_c IN
    SELECT c.id AS community_id, c.account_id
      FROM line_note_communities c
      JOIN line_note_accounts a ON a.id = c.account_id AND a.status = 'active'
      JOIN campaign_channels cc ON cc.channel_id = c.channel_id AND cc.campaign_id = NEW.id
     WHERE c.tenant_id = NEW.tenant_id AND c.auto_post_on_open
  LOOP
    INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, created_by, updated_by)
    VALUES (NEW.tenant_id, v_c.community_id, NEW.id, 'queued', NEW.updated_by, NEW.updated_by)
    ON CONFLICT (community_id, campaign_id) DO NOTHING
    RETURNING id INTO v_post;
    IF v_post IS NOT NULL THEN
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
      VALUES (NEW.tenant_id, 'post', v_c.account_id, v_c.community_id, v_post, NEW.updated_by);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_line_note_on_campaign_open ON group_buy_campaigns;
CREATE TRIGGER trg_line_note_on_campaign_open
  AFTER UPDATE OF status ON group_buy_campaigns
  FOR EACH ROW EXECUTE FUNCTION public._line_note_on_campaign_open();

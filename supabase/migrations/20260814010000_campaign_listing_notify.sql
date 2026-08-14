-- ============================================================================
-- 開團「上架通知」排程 + 依收單類型可設定的通知文本
--
-- 需求：
--   1. 開團設定裡可排程「上架通知」推播（預設關、預設早上 10:00）
--   2. 通知文本依收單類型 (close_type) 各自一版，可在後台編輯；
--      先以美食列車 (food_train) 為主，其餘類型給通用預設。
--
-- 設計：
--   - group_buy_campaigns 加 3 欄：listing_notify_enabled / listing_notify_at /
--     listing_notify_sent_at（sent_at 一旦寫入就不再重發，防重複推播）。
--   - campaign_notify_templates：tenant × close_type 一列，佔位符
--     {團名} {團號} {收單時間}；沒有列 = 用內建預設文本
--     （food_train 對齊既有 CampaignForm 即時廣播的文字，行為不變）。
--   - 排程發送鏈：pg_cron 每分鐘 → _poke_listing_notify_dispatch()（SQL 檢查
--     有到期才動）→ pg_net POST edge function campaign-notify-dispatch →
--     rpc_claim_due_listing_notifications()（原子 claim + 寫 in-app 通知 +
--     回會員名單）→ edge function 對 push_subscriptions 發 web push。
--     為何不整段在 SQL 做：web push 需要 VAPID 簽章，SQL 做不到；
--     為何用 pg_net：排程發送沒有瀏覽器可觸發（20260626000000 的
--     「client-side 觸發」理由只適用於即時廣播）。
--   - 到期但還沒開團 (draft) → 等，開團後下一分鐘才發（「上架」通知不該比
--     上架早）；到期但已收單/取消/推進下游 → 自動關掉排程，不發。
--
-- 基底版本：rpc_upsert_campaign 以 20260629000000（14 參數版）擴寫成 16 參數。
-- Rollback：重跑 20260629000000 的 CREATE FUNCTION；DROP 本檔新增的
--   table/function；SELECT cron.unschedule('dispatch-campaign-listing-notify');
-- ============================================================================

-- ── 1. group_buy_campaigns 排程欄位 ─────────────────────────────────────────
ALTER TABLE group_buy_campaigns
  ADD COLUMN IF NOT EXISTS listing_notify_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS listing_notify_at      TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS listing_notify_sent_at TIMESTAMPTZ NULL;

COMMENT ON COLUMN group_buy_campaigns.listing_notify_enabled IS
  'TRUE = 於 listing_notify_at 排程推播「上架通知」給全體會員（預設 FALSE）';
COMMENT ON COLUMN group_buy_campaigns.listing_notify_at IS
  '上架通知排定發送時間（UI 預設早上 10:00）；到期時團須為 open + is_for_shop 才發';
COMMENT ON COLUMN group_buy_campaigns.listing_notify_sent_at IS
  '上架通知實際發送時間；非 NULL 即不再重發（重新排程也不會重發）';

-- 每分鐘 cron 掃描用的 partial index（未發送且已啟用的排程很少，掃描成本 ~0）
CREATE INDEX IF NOT EXISTS idx_gbc_listing_notify_due
  ON group_buy_campaigns (listing_notify_at)
  WHERE listing_notify_enabled AND listing_notify_sent_at IS NULL;

-- ── 2. 通知文本（tenant × close_type 各一版） ───────────────────────────────
CREATE TABLE IF NOT EXISTS campaign_notify_templates (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID        NOT NULL,
  close_type  TEXT        NOT NULL
              CHECK (close_type IN ('regular','fast','limited','food_train')),
  title       TEXT        NOT NULL,
  body        TEXT        NOT NULL,
  updated_by  UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, close_type)
);

COMMENT ON TABLE campaign_notify_templates IS
  '上架通知文本（依收單類型各一版）；佔位符 {團名} {團號} {收單時間}；'
  '沒有列 = 用程式內建預設（food_train：美食列車新團上架 / {團名}）';

ALTER TABLE campaign_notify_templates ENABLE ROW LEVEL SECURITY;

-- 讀：同 tenant 皆可（前端要顯示「即將送出的文字」預覽）；寫一律走 RPC
DROP POLICY IF EXISTS campaign_notify_templates_tenant_read ON campaign_notify_templates;
CREATE POLICY campaign_notify_templates_tenant_read ON campaign_notify_templates
  FOR SELECT USING (tenant_id = public._current_tenant_id());

GRANT SELECT ON campaign_notify_templates TO authenticated;

-- 佔位符代換（title / body 共用）；收單時間以台北時區呈現
CREATE OR REPLACE FUNCTION public._render_campaign_notify_text(
  p_template    TEXT,
  p_name        TEXT,
  p_campaign_no TEXT,
  p_end_at      TIMESTAMPTZ
) RETURNS TEXT
LANGUAGE sql STABLE
AS $$
  SELECT replace(replace(replace(COALESCE(p_template, ''),
    '{團名}',    COALESCE(p_name, '')),
    '{團號}',    COALESCE(p_campaign_no, '')),
    '{收單時間}', COALESCE(to_char(p_end_at AT TIME ZONE 'Asia/Taipei', 'MM/DD HH24:MI'), ''));
$$;

-- 內建預設文本（food_train 對齊 20260626000000 之後 CampaignForm 即時廣播的字）
-- 前端 apps/admin/src/lib/campaignNotifyText.ts 有同一份，改的話兩邊一起改
CREATE OR REPLACE FUNCTION public._default_campaign_notify_template(p_close_type TEXT)
RETURNS TABLE (title TEXT, body TEXT)
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE WHEN p_close_type = 'food_train'
              THEN '美食列車新團上架' ELSE '新團上架' END,
         '{團名}';
$$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_campaign_notify_template(
  p_close_type TEXT,
  p_title      TEXT,
  p_body       TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  -- ⚠ 一定要走 app_metadata；頂層 'role' 是 Postgres 角色，不是應用角色
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_title  TEXT := NULLIF(btrim(COALESCE(p_title, '')), '');
  v_body   TEXT := NULLIF(btrim(COALESCE(p_body,  '')), '');
BEGIN
  -- '' = 沒有顯式 role 的 legacy/dev admin，對齊 apps/admin/src/lib/role.ts ADMIN_ROLES
  IF v_role NOT IN ('owner', 'admin', '') THEN
    RAISE EXCEPTION 'insufficient_role: 只有負責人 / 管理員可以編輯通知文本';
  END IF;
  IF p_close_type NOT IN ('regular','fast','limited','food_train') THEN
    RAISE EXCEPTION 'invalid close_type: %', p_close_type;
  END IF;

  -- 標題與內文都清空 = 刪掉自訂版，回到內建預設
  IF v_title IS NULL AND v_body IS NULL THEN
    DELETE FROM campaign_notify_templates
     WHERE tenant_id = v_tenant AND close_type = p_close_type;
    RETURN;
  END IF;
  IF v_title IS NULL OR v_body IS NULL THEN
    RAISE EXCEPTION 'title_and_body_required: 標題與內文都要填（都清空 = 恢復預設）';
  END IF;
  IF length(v_title) > 100 OR length(v_body) > 500 THEN
    RAISE EXCEPTION 'template_too_long: 標題上限 100 字、內文上限 500 字';
  END IF;

  INSERT INTO campaign_notify_templates (tenant_id, close_type, title, body, updated_by)
  VALUES (v_tenant, p_close_type, v_title, v_body, auth.uid())
  ON CONFLICT (tenant_id, close_type) DO UPDATE
    SET title = EXCLUDED.title,
        body  = EXCLUDED.body,
        updated_by = EXCLUDED.updated_by,
        updated_at = NOW();
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign_notify_template TO authenticated;

-- ── 3. rpc_upsert_campaign 16 參數（基底 20260629000000 的 14 參數版） ──────
-- 用動態 DROP 處理所有 overload（14 / 16 參數版本都清掉，避免 ambiguous）
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT oid::regprocedure::text AS sig
      FROM pg_proc WHERE proname = 'rpc_upsert_campaign'
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.sig;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_campaign(
  p_id                     BIGINT,
  p_campaign_no            TEXT,
  p_name                   TEXT,
  p_description            TEXT        DEFAULT NULL,
  p_cover_image_url        TEXT        DEFAULT NULL,
  p_status                 TEXT        DEFAULT 'draft',
  p_close_type             TEXT        DEFAULT 'regular',
  p_start_at               TIMESTAMPTZ DEFAULT NULL,
  p_end_at                 TIMESTAMPTZ DEFAULT NULL,
  p_pickup_deadline        DATE        DEFAULT NULL,
  p_pickup_days            INTEGER     DEFAULT NULL,
  p_total_cap_qty          NUMERIC     DEFAULT NULL,
  p_notes                  TEXT        DEFAULT NULL,
  p_is_for_shop            BOOLEAN     DEFAULT TRUE,
  -- 上架通知：沒帶（NULL）= 維持原值，quick-control 等舊呼叫端不受影響
  p_listing_notify_enabled BOOLEAN     DEFAULT NULL,
  p_listing_notify_at      TIMESTAMPTZ DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO group_buy_campaigns (
      tenant_id, campaign_no, name, description, cover_image_url,
      status, close_type, start_at, end_at, pickup_deadline, pickup_days,
      total_cap_qty, notes, is_for_shop,
      listing_notify_enabled, listing_notify_at,
      created_by, updated_by
    ) VALUES (
      v_tenant, p_campaign_no, p_name, p_description, p_cover_image_url,
      COALESCE(p_status,'draft'), COALESCE(p_close_type,'regular'),
      p_start_at, p_end_at, p_pickup_deadline, p_pickup_days,
      p_total_cap_qty, p_notes, COALESCE(p_is_for_shop, TRUE),
      COALESCE(p_listing_notify_enabled, FALSE), p_listing_notify_at,
      auth.uid(), auth.uid()
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE group_buy_campaigns SET
      campaign_no = COALESCE(p_campaign_no, campaign_no),
      name = COALESCE(p_name, name),
      description = p_description,
      cover_image_url = p_cover_image_url,
      status = COALESCE(p_status, status),
      close_type = COALESCE(p_close_type, close_type),
      start_at = p_start_at,
      end_at = p_end_at,
      pickup_deadline = p_pickup_deadline,
      pickup_days = p_pickup_days,
      total_cap_qty = p_total_cap_qty,
      notes = p_notes,
      is_for_shop = COALESCE(p_is_for_shop, is_for_shop),
      listing_notify_enabled = COALESCE(p_listing_notify_enabled, listing_notify_enabled),
      listing_notify_at      = COALESCE(p_listing_notify_at, listing_notify_at),
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign TO authenticated;

-- ── 4. 原子 claim：到期排程 → 標記已發 + 寫 in-app 通知 + 回推播名單 ────────
-- 只給 service_role（edge function campaign-notify-dispatch）呼叫。
-- FOR UPDATE SKIP LOCKED + sent_at 守衛：同時被戳兩次也只會發一次。
CREATE OR REPLACE FUNCTION public.rpc_claim_due_listing_notifications()
RETURNS TABLE (
  campaign_id BIGINT,
  tenant_id   UUID,
  title       TEXT,
  body        TEXT,
  url         TEXT,
  member_ids  BIGINT[]
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r            RECORD;
  v_title      TEXT;
  v_body       TEXT;
  v_member_ids BIGINT[];
BEGIN
  -- 已死的排程（取消 / 收單截止 / 已推進下游）直接關掉，不發
  -- draft 不在此列：還沒開團 = 等，開團後下一分鐘自然發出
  UPDATE group_buy_campaigns c
     SET listing_notify_enabled = FALSE, updated_at = NOW()
   WHERE c.listing_notify_enabled
     AND c.listing_notify_sent_at IS NULL
     AND c.listing_notify_at IS NOT NULL
     AND c.listing_notify_at <= NOW()
     AND (c.status NOT IN ('draft', 'open')
          OR (c.end_at IS NOT NULL AND c.end_at <= NOW()));

  FOR r IN
    SELECT c.id, c.tenant_id AS tid, c.close_type, c.name, c.campaign_no, c.end_at
      FROM group_buy_campaigns c
     WHERE c.listing_notify_enabled
       AND c.listing_notify_sent_at IS NULL
       AND c.listing_notify_at IS NOT NULL
       AND c.listing_notify_at <= NOW()
       AND c.status = 'open'
       AND c.is_for_shop
       AND (c.end_at IS NULL OR c.end_at > NOW())
     ORDER BY c.listing_notify_at
     FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE group_buy_campaigns c
       SET listing_notify_sent_at = NOW(), updated_at = NOW()
     WHERE c.id = r.id;

    SELECT t.title, t.body INTO v_title, v_body
      FROM campaign_notify_templates t
     WHERE t.tenant_id = r.tid AND t.close_type = r.close_type;
    IF v_title IS NULL THEN
      SELECT d.title, d.body INTO v_title, v_body
        FROM public._default_campaign_notify_template(r.close_type) d;
    END IF;
    v_title := public._render_campaign_notify_text(v_title, r.name, r.campaign_no, r.end_at);
    v_body  := public._render_campaign_notify_text(v_body,  r.name, r.campaign_no, r.end_at);

    -- 名單對齊 admin-notify broadcast（active、未停購、未被合併），
    -- 另排除 store_internal（RR-/【內部】xx 店是現貨池容器，不是客人）
    SELECT COALESCE(array_agg(m.id), '{}') INTO v_member_ids
      FROM members m
     WHERE m.tenant_id = r.tid
       AND m.status = 'active'
       AND COALESCE(m.no_new_order, FALSE) = FALSE
       AND m.merged_into_member_id IS NULL
       AND COALESCE(m.member_type, '') <> 'store_internal';

    INSERT INTO notifications (tenant_id, member_id, category, title, body, url)
    SELECT r.tid, mid,
           CASE WHEN r.close_type = 'food_train' THEN 'food_train' ELSE 'campaign' END,
           v_title, v_body, '/shop/c/' || r.id
      FROM unnest(v_member_ids) AS mid;

    campaign_id := r.id;
    tenant_id   := r.tid;
    title       := v_title;
    body        := v_body;
    url         := '/shop/c/' || r.id;
    member_ids  := v_member_ids;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_claim_due_listing_notifications() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_claim_due_listing_notifications() TO service_role;

-- ── 5. pg_cron 每分鐘戳 edge function（有到期才戳） ─────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- pg_net 要打的 base URL 放設定表（本機 / 測試環境可覆寫；空值 = 不戳、只等人工觸發）
CREATE TABLE IF NOT EXISTS app_runtime_config (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE app_runtime_config ENABLE ROW LEVEL SECURITY;  -- 無 policy：只有 definer 函式讀

COMMENT ON TABLE app_runtime_config IS
  '後端排程用的環境設定（例：edge_base_url）；只有 SECURITY DEFINER 函式讀';

INSERT INTO app_runtime_config (key, value)
VALUES ('edge_base_url', 'https://anfyoeviuhmzzrhilwtm.supabase.co')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public._poke_listing_notify_dispatch()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url TEXT;
BEGIN
  -- 條件跟 claim 完全一致：draft 的「等開團」不觸發、死排程由 claim 端收掉
  IF NOT EXISTS (
    SELECT 1 FROM group_buy_campaigns c
     WHERE c.listing_notify_enabled
       AND c.listing_notify_sent_at IS NULL
       AND c.listing_notify_at IS NOT NULL
       AND c.listing_notify_at <= NOW()
       AND c.status = 'open'
       AND c.is_for_shop
       AND (c.end_at IS NULL OR c.end_at > NOW())
  ) THEN
    -- 沒有可發的，但把已死的排程順手關掉（不然 partial index 會越積越多）
    UPDATE group_buy_campaigns c
       SET listing_notify_enabled = FALSE, updated_at = NOW()
     WHERE c.listing_notify_enabled
       AND c.listing_notify_sent_at IS NULL
       AND c.listing_notify_at IS NOT NULL
       AND c.listing_notify_at <= NOW()
       AND (c.status NOT IN ('draft', 'open')
            OR (c.end_at IS NOT NULL AND c.end_at <= NOW()));
    RETURN;
  END IF;

  SELECT value INTO v_url FROM app_runtime_config WHERE key = 'edge_base_url';
  IF v_url IS NULL OR v_url = '' THEN RETURN; END IF;

  -- fire-and-forget：pg_net 非同步送出，實際發送與防重複都在 edge function + claim RPC
  PERFORM net.http_post(
    url     := v_url || '/functions/v1/campaign-notify-dispatch',
    body    := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 30000
  );
END;
$$;

COMMENT ON FUNCTION public._poke_listing_notify_dispatch IS
  '每分鐘 cron：有到期的上架通知才 pg_net 戳 campaign-notify-dispatch';

-- cron.schedule 同名 job 為 idempotent，重複 run migration 不會炸
SELECT cron.schedule(
  'dispatch-campaign-listing-notify',
  '* * * * *',
  $cron$ SELECT public._poke_listing_notify_dispatch(); $cron$
);

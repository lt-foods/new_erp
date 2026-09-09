-- ============================================================================
-- 20260909020000_line_note_no_channel_bot_source.sql
--
-- LINE 記事本（老闆 9/9 交代）：
--   1. 社群設定拿掉「渠道店」。發文對象＝介面上設定的社群（總部的團 → 全部有開自動發文的
--      社群；店家自開的團 → 只發到標了那家店的社群）；爬記事本也是同一份設定。
--   2. 加單的取貨店＝**找到的那位會員自己設定的店**（members.home_store_id），沒有就不加，
--      不再退回渠道店。訂單的 channel 比照 LIFF：會員店自己的 active channel，沒有就 tenant 任一。
--   3. 同一個 6 碼找到兩個以上的會員（不同店或同店）→ 標錯誤不加單，訊息列出各是哪家店的誰。
--   4. 機器人加的單品項 source = 'line_bot'，跟小幫手（manual）、商城（liff）分開；
--      後台 orderSource.ts 同步加「機器人」。
--
-- 基底（都已 grep 全 migrations 確認是最新版）：
--   customer_order_items_source_check   @ 20260901010000（加 'line_bot'）
--   rpc_line_note_community_upsert      @ 20260908010000（唯一版；簽名改了 → DROP 舊的）
--   _line_note_on_campaign_open         @ 20260908010000（唯一版）
--   _line_note_find_member              @ 20260908030000（唯一版）
--   rpc_line_note_apply_comment         @ 20260909000000
-- rollback：
--   還原上面五個物件到各自基底；
--   ALTER TABLE line_note_communities DROP COLUMN store_id, ALTER COLUMN channel_id SET NOT NULL;
--   （回滾 source CHECK 前要先確認沒有 source='line_bot' 的列）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 社群：渠道改選填、加「店家（選填）」
-- ----------------------------------------------------------------------------
ALTER TABLE line_note_communities ALTER COLUMN channel_id DROP NOT NULL;
ALTER TABLE line_note_communities ADD COLUMN IF NOT EXISTS store_id BIGINT REFERENCES stores(id);
COMMENT ON COLUMN line_note_communities.store_id IS
  '這個社群是哪家店的（選填）。只影響「店家自開的團」要不要發到這裡；取貨店一律跟會員走。';
COMMENT ON COLUMN line_note_communities.channel_id IS
  '（已停用）20260909020000 起不再用渠道決定發文與取貨店，留欄位只為相容。';

DROP FUNCTION IF EXISTS public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT, INT);

CREATE OR REPLACE FUNCTION public.rpc_line_note_community_upsert(
  p_id                BIGINT,
  p_account_id        BIGINT,
  p_home_id           TEXT,
  p_home_name         TEXT,
  p_home_kind         TEXT,
  p_listen_enabled    BOOLEAN,
  p_read_times        TEXT[],
  p_auto_post_on_open BOOLEAN,
  p_post_template     TEXT,
  p_read_days         INT DEFAULT 3,
  p_store_id          BIGINT DEFAULT NULL
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
  IF p_store_id IS NOT NULL THEN
    PERFORM 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', p_store_id; END IF;
  END IF;
  IF COALESCE(TRIM(p_home_id), '') = '' THEN RAISE EXCEPTION '請選擇社群'; END IF;
  FOREACH v_t IN ARRAY COALESCE(p_read_times, ARRAY[]::TEXT[]) LOOP
    IF v_t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
      RAISE EXCEPTION '讀取時間格式要是 HH:MM（收到「%」）', v_t;
    END IF;
  END LOOP;
  IF p_read_days IS NOT NULL AND (p_read_days < 1 OR p_read_days > 30) THEN
    RAISE EXCEPTION '讀取範圍要在 1～30 天';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO line_note_communities
      (tenant_id, account_id, store_id, home_id, home_name, home_kind,
       listen_enabled, read_times, auto_post_on_open, post_template, read_days, created_by, updated_by)
    VALUES
      (v_tenant, p_account_id, p_store_id, TRIM(p_home_id), p_home_name,
       COALESCE(p_home_kind, 'square_chat'),
       COALESCE(p_listen_enabled, FALSE),
       COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), ARRAY['12:00']),
       COALESCE(p_auto_post_on_open, TRUE),
       NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
       COALESCE(p_read_days, 3),
       auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE line_note_communities
       SET account_id        = p_account_id,
           store_id          = p_store_id,
           home_id           = TRIM(p_home_id),
           home_name         = p_home_name,
           home_kind         = COALESCE(p_home_kind, home_kind),
           listen_enabled    = COALESCE(p_listen_enabled, listen_enabled),
           read_times        = COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), read_times),
           auto_post_on_open = COALESCE(p_auto_post_on_open, auto_post_on_open),
           post_template     = NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
           read_days         = COALESCE(p_read_days, read_days),
           updated_by        = auth.uid()
     WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT, INT, BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. 開團自動發文：不看 campaign_channels，看社群設定
--    總部的團（owner_store_id IS NULL）→ 所有開自動發文的社群
--    店家自開的團 → 只發到 store_id = 那家店 的社群
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
     WHERE c.tenant_id = NEW.tenant_id
       AND c.auto_post_on_open
       AND (NEW.owner_store_id IS NULL OR c.store_id = NEW.owner_store_id)
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

-- ----------------------------------------------------------------------------
-- 3. 品項來源加 'line_bot'（機器人加單）
-- ----------------------------------------------------------------------------
ALTER TABLE public.customer_order_items DROP CONSTRAINT IF EXISTS customer_order_items_source_check;
ALTER TABLE public.customer_order_items ADD CONSTRAINT customer_order_items_source_check CHECK (
  source = ANY (ARRAY[
    'manual'::text, 'screenshot_parse'::text, 'csv'::text, 'rollover'::text, 'liff'::text, 'pwa'::text,
    'store_internal'::text, 'aid_transfer'::text, 'walk_in'::text, 'line_bot'::text
  ])
);
COMMENT ON COLUMN customer_order_items.source IS
  '品項來源通路。pwa=會員 App、liff=LINE 商城、manual=小幫手代客、line_bot=記事本機器人自動加單、'
  'walk_in=現場銷售；其餘為系統流程（screenshot_parse/csv/rollover/store_internal/aid_transfer）。'
  '中央定義見 apps/admin/src/lib/orderSource.ts。';

-- ----------------------------------------------------------------------------
-- 4. 6 碼 → 會員：多位（不管同店異店）就不猜，訊息列出各是哪家店的誰
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_find_member(p_tenant UUID, p_code TEXT)
RETURNS TABLE (member_id BIGINT, home_store_id BIGINT, ambiguous TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_re      TEXT := '(^|[^0-9])' || p_code || '([^0-9]|$)';
  v_id      BIGINT;
  v_home    BIGINT;
  v_cnt     INT;
  v_who     TEXT;
  v_status  TEXT;
  v_next    BIGINT;
  v_hops    INT := 0;
BEGIN
  -- 1) member_no 直接命中
  SELECT m.id, m.home_store_id INTO v_id, v_home
    FROM members m
   WHERE m.tenant_id = p_tenant
     AND (m.member_no = 'M' || p_code OR m.member_no = p_code)
     AND m.status NOT IN ('merged','deleted')
   ORDER BY m.id LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
  END IF;

  -- 2) 姓名帶這 6 碼的活人
  SELECT count(*) INTO v_cnt
    FROM members m
   WHERE m.tenant_id = p_tenant AND m.name ~ v_re AND m.status NOT IN ('merged','deleted');

  IF v_cnt = 1 THEN
    SELECT m.id, m.home_store_id INTO v_id, v_home
      FROM members m
     WHERE m.tenant_id = p_tenant AND m.name ~ v_re AND m.status NOT IN ('merged','deleted');
    RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
  END IF;

  IF v_cnt > 1 THEN
    SELECT string_agg(COALESCE(s.name, '未設店') || '：' || COALESCE(m.name, m.member_no), '、' ORDER BY s.name, m.id)
      INTO v_who
      FROM members m LEFT JOIN stores s ON s.id = m.home_store_id
     WHERE m.tenant_id = p_tenant AND m.name ~ v_re AND m.status NOT IN ('merged','deleted');
    RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT,
                        ('同一個號碼 ' || p_code || ' 有 ' || v_cnt || ' 位會員（' || v_who || '），不加單，請人工確認')::TEXT;
    RETURN;
  END IF;

  -- 3) 只有被合併掉的舊帳號帶這組號碼 → 跟著 merged_into_member_id 走到本尊
  SELECT m.merged_into_member_id INTO v_id
    FROM members m
   WHERE m.tenant_id = p_tenant AND m.name ~ v_re
   ORDER BY m.id LIMIT 1;
  WHILE v_id IS NOT NULL AND v_hops < 5 LOOP
    v_hops := v_hops + 1;
    SELECT m.home_store_id, m.status, m.merged_into_member_id
      INTO v_home, v_status, v_next
      FROM members m WHERE m.id = v_id AND m.tenant_id = p_tenant;
    IF v_status IS NULL THEN EXIT; END IF;
    IF v_status NOT IN ('merged','deleted') THEN
      RETURN QUERY SELECT v_id, v_home, NULL::TEXT; RETURN;
    END IF;
    v_id := v_next;
  END LOOP;

  RETURN QUERY SELECT NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. 訂單 channel：比照 liff-api —— 會員店自己的 active channel，沒有就 tenant 任一
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_pick_channel(p_tenant UUID, p_store_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT id FROM (
    SELECT id, 0 AS pri FROM line_channels
     WHERE tenant_id = p_tenant AND is_active AND home_store_id = p_store_id
    UNION ALL
    SELECT id, 1 FROM line_channels WHERE tenant_id = p_tenant AND is_active
  ) x ORDER BY pri, id LIMIT 1;
$$;

-- ----------------------------------------------------------------------------
-- 6. 留言 → 訂單
--    取貨店＝會員的店（沒有就 error）；channel 用 _line_note_pick_channel；
--    新加的品項 source 改 'line_bot'。找人／去重／duplicate 同 20260909000000。
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
  v_member_id    BIGINT;
  v_member_home  BIGINT;
  v_ambiguous    TEXT;
  v_hint         TEXT;
  v_items        JSONB := '[]'::jsonb;
  v_new_items    JSONB := '[]'::jsonb;
  v_dup_codes    TEXT[] := ARRAY[]::TEXT[];
  v_dup_order    BIGINT;
  v_p            JSONB;
  v_code         TEXT;
  v_qty          NUMERIC;
  v_ci           BIGINT;
  v_item_count   INT;
  v_order_id     BIGINT;
  v_err          TEXT;
  v_t0           TIMESTAMPTZ := clock_timestamp();
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

  IF v_c.status IN ('ordered','ignored','resolved','duplicate') THEN
    RETURN QUERY SELECT v_c.status, v_c.customer_order_id, v_c.error; RETURN;
  END IF;

  SELECT p.campaign_id INTO v_campaign_id FROM line_note_posts p WHERE p.id = v_c.post_id;

  -- 沒有任何數量 → 不是下單留言
  IF jsonb_array_length(COALESCE(v_c.parsed, '[]'::jsonb)) = 0 THEN
    UPDATE line_note_comments SET status = 'no_order', processed_at = NOW() WHERE id = p_comment_id;
    RETURN QUERY SELECT 'no_order'::TEXT, NULL::BIGINT, NULL::TEXT; RETURN;
  END IF;

  -- 會員：6 碼 → member_no 或姓名裡的號碼
  v_hint := NULLIF(TRIM(COALESCE(v_c.member_no_hint, '')), '');
  IF v_hint IS NULL THEN
    UPDATE line_note_comments SET status = 'unmatched', error = '留言裡沒有 6 碼會員編號', processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'unmatched'::TEXT, NULL::BIGINT, '留言裡沒有 6 碼會員編號'::TEXT; RETURN;
  END IF;

  SELECT f.member_id, f.home_store_id, f.ambiguous
    INTO v_member_id, v_member_home, v_ambiguous
    FROM public._line_note_find_member(v_tenant, v_hint) f;

  IF v_member_id IS NULL THEN
    v_err := COALESCE(v_ambiguous, '找不到會員編號 ' || v_hint);
    UPDATE line_note_comments SET status = CASE WHEN v_ambiguous IS NULL THEN 'unmatched' ELSE 'error' END,
                                  error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT (CASE WHEN v_ambiguous IS NULL THEN 'unmatched' ELSE 'error' END)::TEXT, NULL::BIGINT, v_err; RETURN;
  END IF;

  -- 取貨店＝會員自己的店，沒有就不加
  IF v_member_home IS NULL THEN
    v_err := '會員沒有設定取貨店，請先到會員資料補上';
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, NULL::BIGINT, v_err; RETURN;
  END IF;
  v_channel_id := public._line_note_pick_channel(v_tenant, v_member_home);
  IF v_channel_id IS NULL THEN
    v_err := '這個租戶沒有任何啟用中的 LINE 渠道，無法建單';
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, NULL::BIGINT, v_err; RETURN;
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
        SELECT ic.campaign_item_id, ic.code INTO v_ci, v_code FROM public._line_note_item_codes(v_campaign_id) ic;
      ELSE
        v_err := '沒寫品項代碼（這團有 ' || v_item_count || ' 項）';
        EXIT;
      END IF;
    ELSE
      SELECT ic.campaign_item_id INTO v_ci FROM public._line_note_item_codes(v_campaign_id) ic WHERE ic.code = v_code;
      IF v_ci IS NULL THEN v_err := '品項代碼 ' || v_code || ' 不在這團裡'; EXIT; END IF;
    END IF;
    v_items := v_items || jsonb_build_object('campaign_item_id', v_ci, 'qty', v_qty, 'code', v_code);
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

  -- 去重：這位會員在這團已經有同一品項的有效訂單（任何來源）→ 那一項不再加
  FOR v_p IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    SELECT co.id INTO v_order_id
      FROM customer_order_items coi
      JOIN customer_orders co ON co.id = coi.order_id
     WHERE co.tenant_id = v_tenant
       AND co.campaign_id = v_campaign_id
       AND co.member_id = v_member_id
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.campaign_item_id = (v_p ->> 'campaign_item_id')::bigint
       AND coi.status <> 'cancelled'
     ORDER BY co.id LIMIT 1;
    IF v_order_id IS NOT NULL THEN
      v_dup_codes := v_dup_codes || COALESCE(v_p ->> 'code', '?');
      v_dup_order := COALESCE(v_dup_order, v_order_id);
      v_order_id  := NULL;
    ELSE
      v_new_items := v_new_items || jsonb_build_object('campaign_item_id', (v_p ->> 'campaign_item_id')::bigint, 'qty', (v_p ->> 'qty')::numeric);
    END IF;
  END LOOP;

  IF jsonb_array_length(v_new_items) = 0 THEN
    v_err := '已有訂單（' || array_to_string(v_dup_codes, '、') || '），未重複加單';
    UPDATE line_note_comments
       SET status = 'duplicate', member_id = v_member_id, customer_order_id = v_dup_order,
           error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'duplicate'::TEXT, v_dup_order, v_err; RETURN;
  END IF;

  BEGIN
    SELECT r.out_order_id INTO v_order_id
      FROM public.rpc_create_customer_orders(
             v_campaign_id, v_channel_id,
             jsonb_build_array(jsonb_build_object(
               'member_id', v_member_id,
               'nickname', v_c.commenter_name,
               'pickup_store_id', v_member_home,
               'items', v_new_items))) r
     LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  IF v_err IS NOT NULL THEN
    UPDATE line_note_comments SET status = 'error', member_id = v_member_id, error = v_err, processed_at = NOW()
     WHERE id = p_comment_id;
    RETURN QUERY SELECT 'error'::TEXT, NULL::BIGINT, v_err; RETURN;
  END IF;

  -- 這次新建的品項列標成機器人來源（併進既有列的維持原來源）
  UPDATE customer_order_items coi
     SET source = 'line_bot'
   WHERE coi.order_id = v_order_id
     AND coi.source = 'manual'
     AND coi.created_at >= v_t0
     AND coi.campaign_item_id IN (SELECT (x ->> 'campaign_item_id')::bigint FROM jsonb_array_elements(v_new_items) x);

  UPDATE line_note_comments
     SET status = 'ordered', member_id = v_member_id, customer_order_id = v_order_id,
         error = NULL, processed_at = NOW(),
         resolution_note = CASE WHEN array_length(v_dup_codes, 1) > 0
                                THEN '已略過重複：' || array_to_string(v_dup_codes, '、')
                                ELSE resolution_note END
   WHERE id = p_comment_id;
  RETURN QUERY SELECT 'ordered'::TEXT, v_order_id, NULL::TEXT;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_apply_comment(BIGINT) TO authenticated;

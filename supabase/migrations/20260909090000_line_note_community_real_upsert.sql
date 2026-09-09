-- ============================================================================
-- 20260909090000_line_note_community_real_upsert.sql
--
-- rpc_line_note_community_upsert 名字叫 upsert，新增那半卻是純 INSERT，
-- 撞到 UNIQUE (tenant_id, home_id) 就把原始的唯一鍵違規丟到前端，店家看到
-- 「資料重複衝突(line_note_communities_tenant_id_home_id_key)，請重試或聯繫工程師」——
-- 重試幾次都一樣，而且完全看不出「這個社群早就設定過了」。
--
-- 一個 (tenant, home_id) 本來就只該有一份設定，所以新增撞號 = 就是要改那一份：
--   ON CONFLICT (tenant_id, home_id) DO UPDATE，回傳既有那筆的 id。
-- 表單上的值就是店家剛剛填的，覆蓋過去正是他要的結果。
--
-- 編輯那半不能這樣做（兩筆各自掛著貼文，合併會弄丟其中一邊的 line_note_posts），
-- 所以改成先問對手是誰、吐出點得出名字的錯誤。
--
-- 基底：rpc_line_note_community_upsert @ 20260909070000（12 參數，已 grep 確認為最新）。
-- 參數與回傳型別完全不變，不用 DROP。
-- rollback：還原 20260909070000 的版本。
-- ============================================================================

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
  p_store_id          BIGINT DEFAULT NULL,
  p_react_on_confirm  BOOLEAN DEFAULT TRUE
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_id     BIGINT;
  v_t      TEXT;
  v_home   TEXT := TRIM(p_home_id);
  v_clash  TEXT;
BEGIN
  PERFORM 1 FROM line_note_accounts WHERE id = p_account_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'account % not in tenant', p_account_id; END IF;
  IF p_store_id IS NOT NULL THEN
    PERFORM 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', p_store_id; END IF;
  END IF;
  IF COALESCE(v_home, '') = '' THEN RAISE EXCEPTION '請選擇社群'; END IF;
  FOREACH v_t IN ARRAY COALESCE(p_read_times, ARRAY[]::TEXT[]) LOOP
    IF v_t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
      RAISE EXCEPTION '讀取時間格式要是 HH:MM（收到「%」）', v_t;
    END IF;
  END LOOP;
  IF p_read_days IS NOT NULL AND (p_read_days < 1 OR p_read_days > 30) THEN
    RAISE EXCEPTION '讀取範圍要在 1～30 天';
  END IF;

  IF p_id IS NULL THEN
    -- 撞號 = 這個社群早就設定過了，把表單的值套到既有那筆（一個社群只有一份設定）
    INSERT INTO line_note_communities
      (tenant_id, account_id, store_id, home_id, home_name, home_kind,
       listen_enabled, read_times, auto_post_on_open, post_template, read_days, react_on_confirm,
       created_by, updated_by)
    VALUES
      (v_tenant, p_account_id, p_store_id, v_home, p_home_name,
       COALESCE(p_home_kind, 'square_chat'),
       COALESCE(p_listen_enabled, FALSE),
       COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), ARRAY['12:00']),
       COALESCE(p_auto_post_on_open, TRUE),
       NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
       COALESCE(p_read_days, 3),
       COALESCE(p_react_on_confirm, TRUE),
       auth.uid(), auth.uid())
    ON CONFLICT (tenant_id, home_id) DO UPDATE
       SET account_id        = EXCLUDED.account_id,
           store_id          = EXCLUDED.store_id,
           home_name         = COALESCE(EXCLUDED.home_name, line_note_communities.home_name),
           home_kind         = COALESCE(EXCLUDED.home_kind, line_note_communities.home_kind),
           listen_enabled    = EXCLUDED.listen_enabled,
           read_times        = EXCLUDED.read_times,
           auto_post_on_open = EXCLUDED.auto_post_on_open,
           post_template     = EXCLUDED.post_template,
           read_days         = EXCLUDED.read_days,
           react_on_confirm  = EXCLUDED.react_on_confirm,
           updated_by        = auth.uid()
    RETURNING id INTO v_id;
  ELSE
    -- 編輯不能合併：兩筆各自掛著 line_note_posts，硬合會弄丟其中一邊的貼文與留言
    SELECT COALESCE(NULLIF(home_name, ''), home_id) INTO v_clash
      FROM line_note_communities
     WHERE tenant_id = v_tenant AND home_id = v_home AND id <> p_id;
    IF v_clash IS NOT NULL THEN
      RAISE EXCEPTION '社群「%」已經設定過了，請直接編輯那一筆，不要在這裡改成同一個社群', v_clash;
    END IF;

    UPDATE line_note_communities
       SET account_id        = p_account_id,
           store_id          = p_store_id,
           home_id           = v_home,
           home_name         = p_home_name,
           home_kind         = COALESCE(p_home_kind, home_kind),
           listen_enabled    = COALESCE(p_listen_enabled, listen_enabled),
           read_times        = COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), read_times),
           auto_post_on_open = COALESCE(p_auto_post_on_open, auto_post_on_open),
           post_template     = NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
           read_days         = COALESCE(p_read_days, read_days),
           react_on_confirm  = COALESCE(p_react_on_confirm, react_on_confirm),
           updated_by        = auth.uid()
     WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

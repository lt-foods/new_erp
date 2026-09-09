-- ============================================================================
-- 20260909070000_line_note_community_react_param.sql
--
-- 社群設定加上「收到單後在客人留言按 😄」的開關（欄位 react_on_confirm 見 20260909060000），
-- 讓 rpc_line_note_community_upsert 收得到它。舊簽名要先 DROP —— 帶預設值的新版對
-- 既有引數數量的呼叫會 ambiguous。
--
-- 基底：rpc_line_note_community_upsert @ 20260909020000（唯一前版，已 grep 確認）。
-- rollback：DROP 兩參數多出來的版本，還原 20260909020000 的簽名。
-- ============================================================================

DROP FUNCTION IF EXISTS public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT, INT, BIGINT);

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
       listen_enabled, read_times, auto_post_on_open, post_template, read_days, react_on_confirm,
       created_by, updated_by)
    VALUES
      (v_tenant, p_account_id, p_store_id, TRIM(p_home_id), p_home_name,
       COALESCE(p_home_kind, 'square_chat'),
       COALESCE(p_listen_enabled, FALSE),
       COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), ARRAY['12:00']),
       COALESCE(p_auto_post_on_open, TRUE),
       NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
       COALESCE(p_read_days, 3),
       COALESCE(p_react_on_confirm, TRUE),
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
           react_on_confirm  = COALESCE(p_react_on_confirm, react_on_confirm),
           updated_by        = auth.uid()
     WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT, INT, BIGINT, BOOLEAN) TO authenticated;

-- ============================================================================
-- LINE 記事本：留言解析規則改成可以在後台編輯
--
-- 「LINE 記事本 → 解析規則」分頁存一份 per-tenant 設定（jsonb），line-note-worker
-- 每篇讀留言時現查、交給 parseNoteComment。沒有這一列＝預設規則（跟改版前的寫死行為一樣）。
-- 格式與預設值見 supabase/functions/_shared/lineNoteParse.ts 的 DEFAULT_PARSE_CONFIG /
-- normalizeParseConfig（壞值由那支濾掉，這裡只擋「不是 object」）。
--
-- 權限：同 line_note_communities（總部角色可讀寫）。分店的 line_notes_view 不給 ——
-- 改規則會影響全租戶的自動加單。
-- Rollback：DROP FUNCTION public.rpc_line_note_parse_settings_save(JSONB);
--           DROP TABLE public.line_note_parse_settings;（worker 讀不到就用預設）
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.line_note_parse_settings (
  tenant_id  UUID PRIMARY KEY,
  config     JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(config) = 'object'),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by UUID
);

ALTER TABLE public.line_note_parse_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lnps_hq_all ON public.line_note_parse_settings;
CREATE POLICY lnps_hq_all ON public.line_note_parse_settings
  FOR ALL TO authenticated
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')) = ANY (ARRAY['owner','admin','hq_manager','assistant',''])
  )
  WITH CHECK (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')) = ANY (ARRAY['owner','admin','hq_manager','assistant',''])
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.line_note_parse_settings TO authenticated;

-- 存檔：tenant 取自 JWT（前端不用自己帶），權限交給上面的 RLS（SECURITY INVOKER）
CREATE OR REPLACE FUNCTION public.rpc_line_note_parse_settings_save(p_config JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := (auth.jwt() ->> 'tenant_id')::uuid;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'no tenant in token'; END IF;
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
    RAISE EXCEPTION '解析規則格式錯誤';
  END IF;
  INSERT INTO line_note_parse_settings (tenant_id, config, updated_at, updated_by)
  VALUES (v_tenant, p_config, NOW(), auth.uid())
  ON CONFLICT (tenant_id) DO UPDATE
     SET config = EXCLUDED.config, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_line_note_parse_settings_save(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_parse_settings_save(JSONB) TO authenticated;

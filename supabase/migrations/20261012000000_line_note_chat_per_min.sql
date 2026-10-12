-- ============================================================================
-- LINE 記事本：分享到聊天室（結單提醒 / 分享）每個帳號每分鐘幾則，改成後台可調、預設 5
--
-- 背景（2026-10-12 禮拜一）：68 團結單 × 9 個社群 = 585 則結單提醒，08:00 / 08:30 / 09:00
--   三波，每個帳號一個早上要分享 ~195 則。worker 寫死每帳號每分鐘 12 則（20261008000000），
--   小幫手 08:00～08:35 送了 25 則就被 LINE 限制（code=403 限制使用社群），之後整天斷斷續續被擋。
--   這兩週已經被擋 4 次（10/1、10/5、10/8、10/12），門檻看起來越來越低，所以節流要能隨時調。
--
-- 這支：
--   - line_note_accounts.chat_per_min（預設 5，1～30）：worker 依帳號讀，取代寫死的 12。
--   - v_line_note_accounts 補出這一欄（後台帳號分頁顯示 / 改）。
--   - rpc_line_note_account_set_chat_per_min(p_id, p_n)：總部角色改值。
--
-- rollback：DROP FUNCTION rpc_line_note_account_set_chat_per_min(BIGINT, INT);
--           v_line_note_accounts 改回不含 chat_per_min（20260918000000 版本）；
--           ALTER TABLE line_note_accounts DROP COLUMN chat_per_min;
--           （worker 讀不到這欄時退回每分鐘 5 則）
-- ============================================================================

ALTER TABLE line_note_accounts
  ADD COLUMN IF NOT EXISTS chat_per_min INT NOT NULL DEFAULT 5
    CHECK (chat_per_min BETWEEN 1 AND 30);

COMMENT ON COLUMN line_note_accounts.chat_per_min IS
  '分享到聊天室（remind / share）這個帳號每分鐘最多幾則。LINE 對短時間大量分享會限制使用社群，被擋就調小。';

-- 基底：線上 pg_get_viewdef（= 20260918000000），只在最後加一欄
CREATE OR REPLACE VIEW public.v_line_note_accounts AS
 SELECT id,
    tenant_id,
    label,
    status,
    line_mid,
    display_name,
    qr_image,
    qr_url,
    pin_code,
    last_error,
    last_seen_at,
    created_at,
    updated_at,
    chat_per_min
   FROM line_note_accounts
  WHERE tenant_id = ((auth.jwt() ->> 'tenant_id'::text)::uuid)
    AND (COALESCE((auth.jwt() -> 'app_metadata'::text) ->> 'role'::text, ''::text)
         = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'assistant'::text, ''::text]));

CREATE OR REPLACE FUNCTION public.rpc_line_note_account_set_chat_per_min(p_id BIGINT, p_n INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
BEGIN
  IF p_n IS NULL OR p_n < 1 OR p_n > 30 THEN
    RAISE EXCEPTION '每分鐘則數要在 1～30 之間';
  END IF;
  UPDATE line_note_accounts
     SET chat_per_min = p_n, updated_by = auth.uid()
   WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION '找不到帳號'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_account_set_chat_per_min(BIGINT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_account_set_chat_per_min(BIGINT, INT) TO authenticated;

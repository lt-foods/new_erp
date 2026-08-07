-- ============================================================================
-- 2026-08-07: 每分店自己的 LIFF ID（登入用）
--
-- 為什麼需要：LINE 的 user ID 是**綁 Provider** 的。這個租戶 14 家店的官方帳號
-- 各自在自己的 Provider 底下，而會員登入走的是單一支 Login channel（另一個
-- Provider），所以 members.line_user_id 對任何一家店的 OA 都查不到。
--
-- 2026-08-07 實測（松山店 OA，channel 2008395869）：
--   取樣 12 位松山店已綁 LINE 的活躍會員 → /v2/bot/profile 全部 404，0 筆成功。
--   同一組憑證打 /v2/bot/info 回 200（帳號正確），可見不是憑證問題。
--
-- 解法：每家店在**自己的 Provider** 底下開一支 LINE Login channel + LIFF app，
-- 會員依所屬分店用對應的 LIFF 登入，拿到的 ID 才跟該店 OA 通用。
-- 這裡存那支 LIFF ID。
--
-- ⚠ LIFF ID **不是密鑰**（現在就明碼在會員端 bundle 的 NEXT_PUBLIC_LIFF_ID
--   裡），所以放 stores、跟 line_oa_basic_id 並列即可，不需要像
--   channel_secret 那樣鎖進 store_line_oa_credentials。
--
-- 為什麼另開 RPC 而不是擴 rpc_upsert_store：
--   已 grep supabase/migrations/ —— rpc_upsert_store 被 20260425120000 /
--   20260801000020 / 20260805000010 三支動過，且參數個數已經改過一次
--   （8→9，當時必須 DROP+CREATE 才避開 overload 撞名，見 20260801000020）。
--   為了一個獨立欄位再冒一次那個風險不划算，改用單一用途的小 RPC。
--
-- Rollback：
--   DROP FUNCTION IF EXISTS public.rpc_set_store_line_liff(BIGINT, TEXT);
--   ALTER TABLE stores DROP COLUMN IF EXISTS line_liff_id;
-- ============================================================================

ALTER TABLE stores ADD COLUMN IF NOT EXISTS line_liff_id TEXT;

COMMENT ON COLUMN stores.line_liff_id IS
  '這家店的 LINE Login channel 對應的 LIFF ID（例 2001234567-AbCdEfGh）。'
  '會員依所屬分店用這支 LIFF 登入，取得的 line_user_id 才跟該店 OA 同 provider。'
  '留空 = 退回 NEXT_PUBLIC_LIFF_ID（租戶層預設）';

CREATE OR REPLACE FUNCTION public.rpc_set_store_line_liff(
  p_store_id BIGINT,
  p_liff_id  TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  -- ⚠ 應用角色一定要走 app_metadata；頂層 'role' 是 Postgres 角色
  --   （見 CLAUDE.md、20260807000040）
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_liff   TEXT := NULLIF(btrim(COALESCE(p_liff_id, '')), '');
BEGIN
  IF v_role NOT IN ('owner', 'admin', '') THEN
    RAISE EXCEPTION 'insufficient_role: 只有負責人 / 管理員可以設定 LIFF ID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'store_not_found';
  END IF;

  -- 格式擋一下：LIFF ID 長得像 {channelId}-{8碼}，貼錯成 channel id 或 @basicId
  -- 會在會員手機上才爆，那裡我們看不到，所以在寫入這關就擋掉。
  IF v_liff IS NOT NULL AND v_liff !~ '^[0-9]{10}-[0-9a-zA-Z]{8}$' THEN
    RAISE EXCEPTION 'invalid_liff_id: LIFF ID 格式應為 2001234567-AbCdEfGh';
  END IF;

  UPDATE stores SET line_liff_id = v_liff, updated_by = auth.uid(), updated_at = NOW()
   WHERE id = p_store_id AND tenant_id = v_tenant;
END;
$$;

COMMENT ON FUNCTION public.rpc_set_store_line_liff(BIGINT, TEXT) IS
  '設定分店登入用的 LIFF ID（owner/admin）。傳空字串 = 清除，退回租戶預設';

REVOKE ALL ON FUNCTION public.rpc_set_store_line_liff(BIGINT, TEXT) FROM anon;

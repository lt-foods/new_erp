-- ============================================================================
-- 會員 App（前端）錯誤 log 落地
--
-- 動機：會員端的錯誤只發生在對方手機上，console 我們看不到。2026-08 的
-- 「LINE 登入回 400 Bad Request」就是靠使用者截圖才發現，中間白花了很多來回。
-- 之後前端只要走到「使用者會卡住」的分支，一律寫一筆進這裡。
--
-- 寫入路徑：liff-api 的 `log_client_error` action（service role 寫入）。
-- 這個 action **不需要 token** — 因為最需要記錄的就是「還沒登入就壞掉」。
-- 有帶合法 token 時才會補上 member_id / store_id。
-- ============================================================================

CREATE TABLE IF NOT EXISTS client_error_logs (
  id           BIGSERIAL   PRIMARY KEY,
  tenant_id    UUID        NOT NULL,
  member_id    BIGINT      REFERENCES members(id) ON DELETE SET NULL,
  line_user_id TEXT,
  store_code   TEXT,
  level        TEXT        NOT NULL DEFAULT 'error'
                           CHECK (level IN ('error', 'warn', 'info')),
  source       TEXT        NOT NULL,
  message      TEXT        NOT NULL,
  detail       JSONB,
  page_url     TEXT,
  user_agent   TEXT,
  env          JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 查 log 幾乎只有兩種問法：「最近發生什麼」、「這個 source 最近發生什麼」
CREATE INDEX IF NOT EXISTS idx_client_error_logs_recent
  ON client_error_logs (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_client_error_logs_source_recent
  ON client_error_logs (source, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_client_error_logs_member_recent
  ON client_error_logs (member_id, created_at DESC)
  WHERE member_id IS NOT NULL;

COMMENT ON TABLE  client_error_logs            IS '會員前端 App 的錯誤紀錄（liff-api log_client_error 寫入）';
COMMENT ON COLUMN client_error_logs.source     IS '發生位置代號，例：liff_auto_login_failed / line_browser_oauth_blocked / window_error / unhandled_rejection';
COMMENT ON COLUMN client_error_logs.level      IS 'error = 使用者被卡住；warn = 有退路但不如預期；info = 只是留痕';
COMMENT ON COLUMN client_error_logs.detail     IS '自由欄位：stack、上游回應、當下狀態等';
COMMENT ON COLUMN client_error_logs.env        IS '執行環境：{ in_line, in_liff, standalone, has_liff_id, lang, screen }';
COMMENT ON COLUMN client_error_logs.member_id  IS '只有請求帶了合法 member token 才會有值；登入前的錯誤是 NULL';

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- liff-api 走 SERVICE_ROLE_KEY 寫入（bypass RLS）。這裡只開總部讀，
-- 會員自己不該讀得到別人的錯誤內容（detail 可能含 URL / UA 等資訊）。
ALTER TABLE client_error_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS client_error_logs_hq_all ON client_error_logs;
CREATE POLICY client_error_logs_hq_all ON client_error_logs
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND (auth.jwt() ->> 'role') = 'hq'
  );

-- ── 保留期 ───────────────────────────────────────────────────────────────────
-- 這張表只有除錯價值，不留長期資料。手動或排程呼叫：
--   SELECT purge_client_error_logs(30);
CREATE OR REPLACE FUNCTION purge_client_error_logs(p_days INT DEFAULT 30)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted BIGINT;
BEGIN
  DELETE FROM client_error_logs
   WHERE created_at < NOW() - (p_days || ' days')::INTERVAL;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

COMMENT ON FUNCTION purge_client_error_logs(INT) IS '刪掉 N 天前的前端錯誤 log，回傳刪除筆數';

-- ============================================================================
-- 2026-08-07: admin 對會員發送 LINE OA 訊息（文字 + 截圖）
--
-- 配套：Edge Function `admin-line-push`（staff 從 admin 會員詳情頁呼叫）。
-- 這裡建兩樣東西：
--   1. storage bucket `line-media` — 截圖上傳處。**必須 public**：
--      LINE Messaging API 的 image message 只吃公開 HTTPS URL
--      （LINE 伺服器自己去抓圖，不會帶任何 auth）。路徑帶 uuid、不可列舉。
--      LINE 只接受 JPEG/PNG；前端一律轉 JPEG 再上傳。
--   2. `line_push_logs` — 發送稽核紀錄（誰、何時、對誰、發了什麼、成敗）。
--      寫入走 service role（admin-line-push 函式內），staff 只能讀自家 tenant。
-- ============================================================================

-- ── 1. storage bucket ───────────────────────────────────────────────────────
-- 照 20260603100000_ensure_storage_buckets.sql 的做法 upsert，
-- policy 照 20260424120002_storage_products_bucket.sql（tenant 資料夾隔離）。

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'line-media', 'line-media', TRUE, 10485760,  -- 10 MB = LINE originalContentUrl 上限
  ARRAY['image/png','image/jpeg']
)
ON CONFLICT (id) DO UPDATE SET
  public             = EXCLUDED.public,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS line_media_insert_tenant ON storage.objects;
CREATE POLICY line_media_insert_tenant
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'line-media'
    AND (storage.foldername(name))[1] = (auth.jwt() ->> 'tenant_id')
  );

DROP POLICY IF EXISTS line_media_delete_tenant ON storage.objects;
CREATE POLICY line_media_delete_tenant
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'line-media'
    AND (storage.foldername(name))[1] = (auth.jwt() ->> 'tenant_id')
  );

DROP POLICY IF EXISTS line_media_select_public ON storage.objects;
CREATE POLICY line_media_select_public
  ON storage.objects FOR SELECT TO public
  USING (bucket_id = 'line-media');

-- ── 2. 發送紀錄 ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS line_push_logs (
  id           BIGSERIAL   PRIMARY KEY,
  tenant_id    UUID        NOT NULL,
  member_id    BIGINT      REFERENCES members(id) ON DELETE SET NULL,
  line_user_id TEXT        NOT NULL,
  sent_by      UUID,                 -- staff 的 auth.users.id
  text         TEXT,
  image_url    TEXT,
  status       TEXT        NOT NULL CHECK (status IN ('sent', 'failed')),
  error        TEXT,                 -- LINE API 的錯誤回應（status=failed 才有）
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_line_push_logs_tenant_recent
  ON line_push_logs (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_line_push_logs_member_recent
  ON line_push_logs (member_id, created_at DESC)
  WHERE member_id IS NOT NULL;

COMMENT ON TABLE  line_push_logs           IS 'admin 經 LINE OA 對會員的推播紀錄（admin-line-push 函式寫入）';
COMMENT ON COLUMN line_push_logs.image_url IS 'line-media bucket 的公開 URL；純文字訊息為 NULL';
COMMENT ON COLUMN line_push_logs.error     IS 'LINE API 回的錯誤內容，除錯「為什麼沒送到」用';

-- 寫入只有 service role（bypass RLS）；staff 讀自家 tenant 的紀錄。
ALTER TABLE line_push_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS line_push_logs_tenant_read ON line_push_logs;
CREATE POLICY line_push_logs_tenant_read ON line_push_logs
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
  );

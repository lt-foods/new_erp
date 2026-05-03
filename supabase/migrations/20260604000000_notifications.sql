-- ============================================================================
-- In-app 通知中心
-- 與 push_subscriptions 一起組成「推播 + 落地紀錄」雙軌通知:
-- 顧客即使漏看 push,也能在 /notifications 找回。
-- 寫入路徑:edge function admin-notify 在發 push 前一律 insert 一筆。
-- ============================================================================

CREATE TABLE IF NOT EXISTS notifications (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID        NOT NULL,
  member_id   BIGINT      NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  category    TEXT        NOT NULL DEFAULT 'general',
  title       TEXT        NOT NULL,
  body        TEXT,
  url         TEXT,
  read_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 主要查詢路徑:特定 member 依時間倒序、未讀計數
CREATE INDEX IF NOT EXISTS idx_notifications_member_recent
  ON notifications (tenant_id, member_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_member_unread
  ON notifications (tenant_id, member_id)
  WHERE read_at IS NULL;

COMMENT ON TABLE  notifications              IS 'In-app 通知紀錄(推播訊息會同時在這裡留底)';
COMMENT ON COLUMN notifications.category     IS '訊息類型:general / order_arrived / settlement / ...';
COMMENT ON COLUMN notifications.url          IS '點擊跳轉的相對路徑(例:/orders)';
COMMENT ON COLUMN notifications.read_at      IS 'NULL = 未讀;進入 /notifications 後一次標已讀';

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- liff-api 走 SERVICE_ROLE_KEY 直接讀寫,RLS 是給直接用 anon/admin auth 連線的安全網
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY notifications_self_all ON notifications
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND member_id = (auth.jwt() ->> 'member_id')::BIGINT
  );

CREATE POLICY notifications_hq_all ON notifications
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND (auth.jwt() ->> 'role') = 'hq'
  );

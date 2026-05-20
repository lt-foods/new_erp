-- 同步上架 FB 粉絲團：粉絲團設定 + 發文紀錄
--
-- 設計重點：
--   * fb_pages 存「Page ID + 長效 Page Access Token」，client 不應直接讀 access_token
--     （RLS 允許 admin 角色讀寫，但 UI 用 .select("id,name,page_id,...") 不撈 token）
--   * campaign_fb_posts 一次發送一個 (campaign_id, fb_page_id) 對應一筆，重發會新增另一筆
--   * tenant_id 全程帶上，沿用既有 RLS / RBAC 模式

CREATE TABLE fb_pages (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  page_id       TEXT NOT NULL,
  name          TEXT NOT NULL,
  access_token  TEXT NOT NULL,
  sort_order    INTEGER NOT NULL DEFAULT 0,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, page_id)
);

COMMENT ON TABLE fb_pages IS 'FB 粉絲團設定（Page Access Token 存這裡，限 admin role 讀寫）';
COMMENT ON COLUMN fb_pages.access_token IS '長效 Page Access Token；client 不應 select 此欄';

CREATE INDEX idx_fb_pages_tenant_active ON fb_pages (tenant_id, sort_order)
  WHERE is_active;

CREATE TABLE campaign_fb_posts (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  campaign_id    BIGINT NOT NULL REFERENCES group_buy_campaigns(id) ON DELETE CASCADE,
  fb_page_id     BIGINT NOT NULL REFERENCES fb_pages(id),
  fb_post_id     TEXT,
  permalink      TEXT,
  status         TEXT NOT NULL CHECK (status IN ('success','failed')),
  message        TEXT,
  image_urls     JSONB NOT NULL DEFAULT '[]'::jsonb,
  error_message  TEXT,
  posted_by      UUID,
  posted_at      TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE campaign_fb_posts IS '開團發 FB 紀錄（成功/失敗皆記錄；重發新增一筆）';

CREATE INDEX idx_cfp_campaign ON campaign_fb_posts (campaign_id, created_at DESC);
CREATE INDEX idx_cfp_tenant_status ON campaign_fb_posts (tenant_id, status);

ALTER TABLE fb_pages          ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign_fb_posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY fb_pages_hq_all ON fb_pages
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

CREATE POLICY cfp_hq_all ON campaign_fb_posts
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

-- ============================================================
-- Stores + Order/Pickup Module Schema v0.1.1
-- PostgreSQL 15+ / Supabase
-- Backfills v0.1 tables that were specified in PRDs but never migrated
-- See docs/PRD-訂單取貨模組.md, docs/PRD-通知模組.md
-- ============================================================

-- ============================================================
-- TABLES
-- ============================================================

-- 1. 加盟店主檔（franchise store detail, separate from inventory `locations`）
CREATE TABLE stores (
  id                          BIGSERIAL PRIMARY KEY,
  tenant_id                   UUID NOT NULL,
  code                        TEXT NOT NULL,
  name                        TEXT NOT NULL,
  location_id                 BIGINT REFERENCES locations(id),
  -- Notification module fields (PRD-通知模組 §7)
  notification_mode           TEXT NOT NULL DEFAULT 'simple'
                                CHECK (notification_mode IN ('full','simple','none')),
  line_oa_channel_id          TEXT,
  line_oa_channel_secret_enc  BYTEA,
  line_oa_access_token_enc    BYTEA,
  line_oa_basic_id            TEXT,
  line_oa_plan                TEXT
                                CHECK (line_oa_plan IN ('free','advanced','pro')),
  line_oa_quota_monthly       INTEGER,
  line_oa_verified            BOOLEAN NOT NULL DEFAULT FALSE,
  line_oa_verified_at         TIMESTAMPTZ,
  line_group_id               TEXT,
  -- Pickup / operational fields (PRD-訂單取貨)
  pickup_window_days          INTEGER NOT NULL DEFAULT 5,
  off_days                    JSONB NOT NULL DEFAULT '[]'::jsonb,
  allowed_payment_methods     JSONB NOT NULL DEFAULT '["cash"]'::jsonb,
  -- Mapping for Flag 8 (AP settlement); FK filled after suppliers exists
  supplier_id                 BIGINT REFERENCES suppliers(id),
  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  notes                       TEXT,
  created_by                  UUID,
  updated_by                  UUID,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code),
  UNIQUE (tenant_id, location_id)
);
COMMENT ON TABLE stores IS '加盟店主檔（franchise-specific detail, 與 locations 分離）';
COMMENT ON COLUMN stores.location_id IS '對應 inventory locations.id（型別須為 store）';
COMMENT ON COLUMN stores.off_days IS '公休日 JSONB：weekday list or date list';

CREATE INDEX idx_stores_active ON stores (tenant_id) WHERE is_active;

-- 2. LINE 社群頻道（OpenChat / OA）
CREATE TABLE line_channels (
  id                 BIGSERIAL PRIMARY KEY,
  tenant_id          UUID NOT NULL,
  code               TEXT NOT NULL,
  name               TEXT NOT NULL,
  channel_type       TEXT NOT NULL DEFAULT 'open_chat'
                       CHECK (channel_type IN ('open_chat','oa_channel','group')),
  home_store_id      BIGINT NOT NULL REFERENCES stores(id),
  additional_pickup_store_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,
  notes              TEXT,
  created_by         UUID,
  updated_by         UUID,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE line_channels IS 'LINE 社群頻道（一頻道對應一主店，可附 multi-pickup 店列）';

CREATE INDEX idx_line_channels_home ON line_channels (tenant_id, home_store_id);

-- 3. 發文範本
CREATE TABLE post_templates (
  id         BIGSERIAL PRIMARY KEY,
  tenant_id  UUID NOT NULL,
  code       TEXT NOT NULL,
  name       TEXT NOT NULL,
  body       TEXT NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_by UUID,
  updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);

-- 4. 團購活動單頭
CREATE TABLE group_buy_campaigns (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  campaign_no       TEXT NOT NULL,
  name              TEXT NOT NULL,
  description       TEXT,
  cover_image_url   TEXT,
  status            TEXT NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft','open','closed','ordered',
                                        'receiving','ready','completed','cancelled')),
  close_type        TEXT NOT NULL DEFAULT 'regular'
                      CHECK (close_type IN ('regular','fast','limited')),
  start_at          TIMESTAMPTZ,
  end_at            TIMESTAMPTZ,
  pickup_deadline   DATE,
  pickup_days       INTEGER,
  total_cap_qty     NUMERIC(18,3),
  post_template_id  BIGINT REFERENCES post_templates(id),
  notes             TEXT,
  created_by        UUID,
  updated_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, campaign_no)
);
COMMENT ON TABLE group_buy_campaigns IS '團購活動單頭（v0.2 addendum 會加 cutoff_date / expected_arrival_date / matrix_row_order）';

CREATE INDEX idx_gbc_status ON group_buy_campaigns (tenant_id, status, end_at DESC);

-- 5. 活動商品明細
CREATE TABLE campaign_items (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  campaign_id  BIGINT NOT NULL REFERENCES group_buy_campaigns(id) ON DELETE CASCADE,
  sku_id       BIGINT NOT NULL REFERENCES skus(id),
  unit_price   NUMERIC(18,4) NOT NULL CHECK (unit_price >= 0),
  cap_qty      NUMERIC(18,3),
  sort_order   INTEGER NOT NULL DEFAULT 0,
  notes        TEXT,
  created_by   UUID,
  updated_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (campaign_id, sku_id)
);

CREATE INDEX idx_campaign_items_sku ON campaign_items (tenant_id, sku_id);

-- 6. 活動頻道關聯
CREATE TABLE campaign_channels (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  campaign_id   BIGINT NOT NULL REFERENCES group_buy_campaigns(id) ON DELETE CASCADE,
  channel_id    BIGINT NOT NULL REFERENCES line_channels(id),
  cap_qty       NUMERIC(18,3),
  posted_at     TIMESTAMPTZ,
  created_by    UUID,
  updated_by    UUID,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (campaign_id, channel_id)
);

-- 7. 顧客社群暱稱 ↔ 會員綁定
CREATE TABLE customer_line_aliases (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL,
  channel_id  BIGINT NOT NULL REFERENCES line_channels(id),
  nickname    TEXT NOT NULL,
  member_id   BIGINT NOT NULL REFERENCES members(id),
  notes       TEXT,
  created_by  UUID,
  updated_by  UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, channel_id, nickname)
);
COMMENT ON TABLE customer_line_aliases IS 'LINE 暱稱 ↔ 會員對應（同暱稱跨頻道可對不同會員）';

CREATE INDEX idx_cla_member ON customer_line_aliases (member_id);

-- 8. 顧客訂單單頭
CREATE TABLE customer_orders (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  order_no          TEXT NOT NULL,
  campaign_id       BIGINT NOT NULL REFERENCES group_buy_campaigns(id),
  channel_id        BIGINT NOT NULL REFERENCES line_channels(id),
  member_id         BIGINT REFERENCES members(id),
  nickname_snapshot TEXT,
  pickup_store_id   BIGINT NOT NULL REFERENCES stores(id),
  pickup_deadline   DATE,
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','confirmed','reserved','ready',
                                        'partially_ready','partially_completed',
                                        'completed','expired','cancelled')),
  notes             TEXT,
  created_by        UUID,
  updated_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, order_no),
  -- Q6: 同團同頻道同會員合併為一筆訂單
  UNIQUE (tenant_id, campaign_id, channel_id, member_id)
);

CREATE INDEX idx_corders_campaign ON customer_orders (tenant_id, campaign_id, status);
CREATE INDEX idx_corders_member ON customer_orders (member_id, status);
CREATE INDEX idx_corders_pickup_store ON customer_orders (pickup_store_id, status);

-- 9. 顧客訂單明細
CREATE TABLE customer_order_items (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL,
  order_id              BIGINT NOT NULL REFERENCES customer_orders(id) ON DELETE CASCADE,
  campaign_item_id      BIGINT NOT NULL REFERENCES campaign_items(id),
  sku_id                BIGINT NOT NULL REFERENCES skus(id),
  qty                   NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  unit_price            NUMERIC(18,4) NOT NULL,
  status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','reserved','ready',
                                            'picked_up','partially_picked_up',
                                            'cancelled','expired')),
  source                TEXT NOT NULL DEFAULT 'manual'
                          CHECK (source IN ('manual','screenshot_parse','csv',
                                            'rollover','liff')),
  reserved_movement_id  BIGINT REFERENCES stock_movements(id),
  pickup_movement_id    BIGINT REFERENCES stock_movements(id),
  notes                 TEXT,
  created_by            UUID,
  updated_by            UUID,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_coi_order ON customer_order_items (order_id);
CREATE INDEX idx_coi_sku_status ON customer_order_items (tenant_id, sku_id, status);
CREATE INDEX idx_coi_campaign_item ON customer_order_items (campaign_item_id);

-- 10. 候補清單（Q2 waitlist）
CREATE TABLE order_waitlist (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  campaign_id         BIGINT NOT NULL REFERENCES group_buy_campaigns(id),
  sku_id              BIGINT NOT NULL REFERENCES skus(id),
  channel_id          BIGINT REFERENCES line_channels(id),
  member_id           BIGINT REFERENCES members(id),
  nickname            TEXT,
  qty                 NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  position            INTEGER,
  status              TEXT NOT NULL DEFAULT 'waiting'
                        CHECK (status IN ('waiting','promoted','cancelled','expired')),
  promoted_order_id   BIGINT REFERENCES customer_orders(id),
  notes               TEXT,
  created_by          UUID,
  updated_by          UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_waitlist_campaign ON order_waitlist (tenant_id, campaign_id, sku_id, position)
  WHERE status = 'waiting';

-- 11. 活動稽核（append-only, Q4）
CREATE TABLE campaign_audit_log (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  campaign_id  BIGINT NOT NULL REFERENCES group_buy_campaigns(id) ON DELETE CASCADE,
  entity_type  TEXT NOT NULL CHECK (entity_type IN ('campaign','item','channel')),
  entity_id    BIGINT,
  field        TEXT NOT NULL,
  before_value JSONB,
  after_value  JSONB,
  edit_reason  TEXT NOT NULL,
  operator_id  UUID NOT NULL,
  operator_ip  INET,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only: 無 updated_*
);

CREATE INDEX idx_camp_audit_campaign ON campaign_audit_log (tenant_id, campaign_id, created_at DESC);

-- 12. 取貨事件（append-only log）
CREATE TABLE order_pickup_events (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  order_id          BIGINT NOT NULL REFERENCES customer_orders(id) ON DELETE CASCADE,
  pickup_store_id   BIGINT NOT NULL REFERENCES stores(id),
  event_type        TEXT NOT NULL
                      CHECK (event_type IN ('picked_up','partial_pickup',
                                            'no_show_expired','cancelled','refunded')),
  pos_sale_id       BIGINT REFERENCES pos_sales(id),
  item_ids          JSONB,  -- 本次取貨的 customer_order_items.id[]
  notes             TEXT,
  created_by        UUID NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only
);

CREATE INDEX idx_pickup_events_order ON order_pickup_events (order_id, created_at DESC);
CREATE INDEX idx_pickup_events_store ON order_pickup_events (tenant_id, pickup_store_id, created_at DESC);

-- 13. 訂單來源：截圖 + LLM 解析（append-only）
CREATE TABLE customer_order_sources (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  campaign_id       BIGINT NOT NULL REFERENCES group_buy_campaigns(id),
  order_id          BIGINT REFERENCES customer_orders(id),
  source_type       TEXT NOT NULL CHECK (source_type IN ('screenshot','csv','manual_paste')),
  screenshot_url    TEXT,
  raw_content       TEXT,
  llm_parsed_json   JSONB,
  llm_model         TEXT,
  created_by        UUID NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only
);

CREATE INDEX idx_cos_campaign ON customer_order_sources (tenant_id, campaign_id, created_at DESC);

-- ============================================================
-- TRIGGERS (reuse touch_updated_at() from inventory_schema)
-- ============================================================

CREATE TRIGGER trg_touch_stores                 BEFORE UPDATE ON stores
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_line_channels          BEFORE UPDATE ON line_channels
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_post_templates         BEFORE UPDATE ON post_templates
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_gbc                    BEFORE UPDATE ON group_buy_campaigns
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_campaign_items         BEFORE UPDATE ON campaign_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_campaign_channels      BEFORE UPDATE ON campaign_channels
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_cla                    BEFORE UPDATE ON customer_line_aliases
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_corders                BEFORE UPDATE ON customer_orders
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_coi                    BEFORE UPDATE ON customer_order_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_waitlist               BEFORE UPDATE ON order_waitlist
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- 稽核 / log 表禁止 UPDATE / DELETE（依 feedback_audit_columns）
CREATE OR REPLACE FUNCTION forbid_append_only_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_mut_camp_audit BEFORE UPDATE OR DELETE ON campaign_audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();
CREATE TRIGGER trg_no_mut_pickup_ev  BEFORE UPDATE OR DELETE ON order_pickup_events
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();
CREATE TRIGGER trg_no_mut_cos        BEFORE UPDATE OR DELETE ON customer_order_sources
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();

-- ============================================================
-- RLS (Row-Level Security)
-- ============================================================

ALTER TABLE stores                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE line_channels             ENABLE ROW LEVEL SECURITY;
ALTER TABLE post_templates            ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_buy_campaigns       ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign_items            ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign_channels         ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_line_aliases     ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_orders           ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_order_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_waitlist            ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign_audit_log        ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_pickup_events       ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_order_sources    ENABLE ROW LEVEL SECURITY;

-- stores: 總部 ALL；店東 / 店長讀自己店 + 更新通知設定
CREATE POLICY stores_hq_all ON stores
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY stores_store_read_own ON stores
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND id = (auth.jwt() ->> 'store_id')::bigint
  );
CREATE POLICY stores_store_update_own ON stores
  FOR UPDATE USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND id = (auth.jwt() ->> 'store_id')::bigint
    AND (auth.jwt() ->> 'role') IN ('store_owner','store_manager')
  );

-- group_buy_campaigns / campaign_items / campaign_channels: 總部 ALL；店家讀 open/closed/ready 階段
CREATE POLICY gbc_hq_all ON group_buy_campaigns
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','purchaser')
  );
CREATE POLICY gbc_store_read ON group_buy_campaigns
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND status IN ('open','closed','ordered','receiving','ready','completed')
  );

CREATE POLICY ci_hq_all ON campaign_items
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','purchaser')
  );
CREATE POLICY ci_store_read ON campaign_items
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY cc_hq_all ON campaign_channels
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

-- line_channels / post_templates: 總部 ALL；店家讀 own store
CREATE POLICY lc_hq_all ON line_channels
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY lc_store_read ON line_channels
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND home_store_id = (auth.jwt() ->> 'store_id')::bigint
  );

CREATE POLICY pt_hq_all ON post_templates
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

-- customer_line_aliases: 總部 ALL；店員 I/R/U for own channel
CREATE POLICY cla_hq_all ON customer_line_aliases
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY cla_store_access ON customer_line_aliases
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND channel_id IN (
      SELECT id FROM line_channels
       WHERE home_store_id = (auth.jwt() ->> 'store_id')::bigint
    )
  );

-- customer_orders / customer_order_items: 總部 ALL；店讀自己是 pickup_store
CREATE POLICY corders_hq_all ON customer_orders
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY corders_store_access ON customer_orders
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND pickup_store_id = (auth.jwt() ->> 'store_id')::bigint
  );

CREATE POLICY coi_hq_all ON customer_order_items
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY coi_store_access ON customer_order_items
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND order_id IN (
      SELECT id FROM customer_orders
       WHERE pickup_store_id = (auth.jwt() ->> 'store_id')::bigint
    )
  );

-- order_waitlist: 類似 customer_orders
CREATE POLICY wl_hq_all ON order_waitlist
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY wl_store_read ON order_waitlist
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND channel_id IN (
      SELECT id FROM line_channels
       WHERE home_store_id = (auth.jwt() ->> 'store_id')::bigint
    )
  );

-- campaign_audit_log / order_pickup_events / customer_order_sources: 總部 SELECT；寫由 RPC 用 SECURITY DEFINER
CREATE POLICY camp_audit_hq_read ON campaign_audit_log
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

CREATE POLICY pickup_ev_hq_read ON order_pickup_events
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY pickup_ev_store_read ON order_pickup_events
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND pickup_store_id = (auth.jwt() ->> 'store_id')::bigint
  );

CREATE POLICY cos_hq_read ON customer_order_sources
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

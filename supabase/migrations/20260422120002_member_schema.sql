-- ============================================================
-- Member Module Schema v0.1
-- PostgreSQL 15+ / Supabase
-- See docs/DB-會員模組.md for full design rationale.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- TABLES
-- ============================================================

-- 1. 會員等級
CREATE TABLE member_tiers (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  code         TEXT NOT NULL,
  name         TEXT NOT NULL,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  benefits     JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_by   UUID,
  updated_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);
COMMENT ON COLUMN member_tiers.benefits IS '{points_multiplier, member_price_eligible, ...}';

-- 2. 會員主檔
CREATE TABLE members (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL,
  member_no             TEXT NOT NULL,
  phone_hash            TEXT NOT NULL,
  phone_enc             BYTEA,
  email_hash            TEXT,
  email_enc             BYTEA,
  name                  TEXT,
  birthday_enc          BYTEA,
  birth_md              TEXT,
  gender                TEXT CHECK (gender IS NULL OR gender IN ('M','F','O')),
  tier_id               BIGINT REFERENCES member_tiers(id),
  home_store_id         BIGINT,
  status                TEXT NOT NULL DEFAULT 'active' CHECK (status IN (
                          'active','inactive','blocked','merged','deleted'
                        )),
  merged_into_member_id BIGINT REFERENCES members(id),
  joined_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_visit_at         TIMESTAMPTZ,
  notes                 TEXT,
  created_by            UUID,
  updated_by            UUID,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, member_no),
  UNIQUE (tenant_id, phone_hash)
);
COMMENT ON COLUMN members.phone_hash IS 'SHA256(normalized phone) 供查詢與 unique';
COMMENT ON COLUMN members.phone_enc  IS 'pgp_sym_encrypt(phone, key)';
COMMENT ON COLUMN members.birth_md   IS 'MM-DD 供「生日月」快速篩選';

-- 3. 會員卡
CREATE TABLE member_cards (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  member_id    BIGINT NOT NULL REFERENCES members(id),
  card_no      TEXT NOT NULL,
  type         TEXT NOT NULL CHECK (type IN ('physical','virtual')),
  secret_ref   TEXT,
  is_primary   BOOLEAN NOT NULL DEFAULT FALSE,
  status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired','lost')),
  issued_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ,
  retired_at   TIMESTAMPTZ,
  created_by   UUID,
  updated_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, card_no)
);
COMMENT ON COLUMN member_cards.secret_ref IS 'KMS / Vault key id；HMAC secret 不明碼落庫';

CREATE UNIQUE INDEX uniq_member_card_primary
  ON member_cards (member_id) WHERE is_primary = TRUE;

-- 4. 點數流水（append-only）
CREATE TABLE points_ledger (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  member_id      BIGINT NOT NULL REFERENCES members(id),
  change         NUMERIC(18,2) NOT NULL CHECK (change <> 0),
  balance_after  NUMERIC(18,2) NOT NULL,
  source_type    TEXT NOT NULL CHECK (source_type IN (
                   'sale','return','manual_adjust','promotion','expire','merge','reversal'
                 )),
  source_id      BIGINT,
  reverses       BIGINT REFERENCES points_ledger(id),
  reversed_by    BIGINT REFERENCES points_ledger(id),
  reason         TEXT,
  operator_id    UUID NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON COLUMN points_ledger.change IS '有號：+賺 / -用';

-- 5. 點數餘額
CREATE TABLE member_points_balance (
  tenant_id         UUID NOT NULL,
  member_id         BIGINT NOT NULL REFERENCES members(id),
  balance           NUMERIC(18,2) NOT NULL DEFAULT 0,
  version           BIGINT NOT NULL DEFAULT 0,
  last_movement_at  TIMESTAMPTZ,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, member_id),
  CHECK (balance >= 0)
);

-- 6. 儲值金流水（append-only）
CREATE TABLE wallet_ledger (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  member_id      BIGINT NOT NULL REFERENCES members(id),
  change         NUMERIC(18,2) NOT NULL CHECK (change <> 0),
  balance_after  NUMERIC(18,2) NOT NULL,
  type           TEXT NOT NULL CHECK (type IN (
                   'topup','spend','refund','adjust','reversal'
                 )),
  source_type    TEXT,
  source_id      BIGINT,
  payment_method TEXT,
  reverses       BIGINT REFERENCES wallet_ledger(id),
  reversed_by    BIGINT REFERENCES wallet_ledger(id),
  reason         TEXT,
  operator_id    UUID NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7. 儲值金餘額
CREATE TABLE wallet_balances (
  tenant_id         UUID NOT NULL,
  member_id         BIGINT NOT NULL REFERENCES members(id),
  balance           NUMERIC(18,2) NOT NULL DEFAULT 0,
  version           BIGINT NOT NULL DEFAULT 0,
  last_movement_at  TIMESTAMPTZ,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, member_id),
  CHECK (balance >= 0)
);

-- 8. 會員標籤
CREATE TABLE member_tags (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  member_id    BIGINT NOT NULL REFERENCES members(id),
  tag_code     TEXT NOT NULL,
  source       TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','rule')),
  created_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, member_id, tag_code)
);
COMMENT ON TABLE member_tags IS '關聯表，標籤只新增 / 刪除不修改，故無 updated_*';

-- 9. 稽核
CREATE TABLE member_audit_log (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  entity_type  TEXT NOT NULL CHECK (entity_type IN (
                 'member','card','points','wallet','tier','tag','merge'
               )),
  entity_id    BIGINT NOT NULL,
  action       TEXT NOT NULL,
  before_value JSONB,
  after_value  JSONB,
  reason       TEXT,
  operator_id  UUID NOT NULL,
  operator_ip  INET,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 10. 合併歷史
CREATE TABLE member_merges (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  primary_member_id   BIGINT NOT NULL REFERENCES members(id),
  merged_member_id    BIGINT NOT NULL REFERENCES members(id),
  points_moved        NUMERIC(18,2) NOT NULL DEFAULT 0,
  wallet_moved        NUMERIC(18,2) NOT NULL DEFAULT 0,
  cards_moved         INTEGER NOT NULL DEFAULT 0,
  reason              TEXT,
  operator_id         UUID NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (primary_member_id <> merged_member_id)
);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- 禁止 UPDATE / DELETE ledger（append-only）
CREATE OR REPLACE FUNCTION forbid_ledger_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '% is append-only. Use a reversing entry.', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_update_points BEFORE UPDATE ON points_ledger
  FOR EACH ROW EXECUTE FUNCTION forbid_ledger_mutation();
CREATE TRIGGER trg_no_delete_points BEFORE DELETE ON points_ledger
  FOR EACH ROW EXECUTE FUNCTION forbid_ledger_mutation();

CREATE TRIGGER trg_no_update_wallet BEFORE UPDATE ON wallet_ledger
  FOR EACH ROW EXECUTE FUNCTION forbid_ledger_mutation();
CREATE TRIGGER trg_no_delete_wallet BEFORE DELETE ON wallet_ledger
  FOR EACH ROW EXECUTE FUNCTION forbid_ledger_mutation();

-- 禁止刪除 members（GDPR 刪除走 status + PII 清空）
CREATE OR REPLACE FUNCTION forbid_member_delete()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'members cannot be deleted. Use rpc_member_gdpr_delete instead.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_delete_member BEFORE DELETE ON members
  FOR EACH ROW EXECUTE FUNCTION forbid_member_delete();

-- updated_at 自動更新
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_member_tiers BEFORE UPDATE ON member_tiers
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_members      BEFORE UPDATE ON members
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_member_cards BEFORE UPDATE ON member_cards
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_members_phone
  ON members (tenant_id, phone_hash);

CREATE INDEX idx_members_tier_status
  ON members (tenant_id, tier_id, status);

CREATE INDEX idx_members_home_store
  ON members (tenant_id, home_store_id, status);

CREATE INDEX idx_members_birth_md
  ON members (tenant_id, birth_md)
  WHERE status = 'active';

CREATE INDEX idx_cards_member
  ON member_cards (tenant_id, member_id);
CREATE INDEX idx_cards_active
  ON member_cards (tenant_id, card_no)
  WHERE status = 'active';

CREATE INDEX idx_points_ledger_member_time
  ON points_ledger (tenant_id, member_id, created_at DESC);
CREATE INDEX idx_points_ledger_source
  ON points_ledger (source_type, source_id)
  WHERE source_id IS NOT NULL;

CREATE INDEX idx_wallet_ledger_member_time
  ON wallet_ledger (tenant_id, member_id, created_at DESC);

CREATE INDEX idx_tags_tag
  ON member_tags (tenant_id, tag_code);
CREATE INDEX idx_tags_member
  ON member_tags (tenant_id, member_id);

CREATE INDEX idx_member_audit_entity
  ON member_audit_log (tenant_id, entity_type, entity_id, created_at DESC);

-- ============================================================
-- RLS
-- ============================================================

ALTER TABLE member_tiers            ENABLE ROW LEVEL SECURITY;
ALTER TABLE members                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_cards            ENABLE ROW LEVEL SECURITY;
ALTER TABLE points_ledger           ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_points_balance   ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_ledger           ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_balances         ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_tags             ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_audit_log        ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_merges           ENABLE ROW LEVEL SECURITY;

CREATE POLICY hq_read_members ON members
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','marketer')
  );

CREATE POLICY store_read_members ON members
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('store_manager','clerk')
    AND home_store_id = (auth.jwt() ->> 'location_id')::bigint
  );

-- 寫入一律透過 RPC（SECURITY DEFINER）

-- ============================================================
-- RPC
-- ============================================================

-- 會員識別
CREATE OR REPLACE FUNCTION rpc_resolve_member(
  p_tenant_id UUID,
  p_qr        TEXT DEFAULT NULL,
  p_card_no   TEXT DEFAULT NULL,
  p_phone     TEXT DEFAULT NULL
) RETURNS TABLE (
  member_id       BIGINT,
  member_no       TEXT,
  name_masked     TEXT,
  tier_id         BIGINT,
  tier_name       TEXT,
  points_balance  NUMERIC,
  wallet_balance  NUMERIC,
  status          TEXT
) AS $$
DECLARE
  v_member_id BIGINT;
  v_phone_hash TEXT;
BEGIN
  IF p_qr IS NOT NULL THEN
    SELECT c.member_id INTO v_member_id
    FROM member_cards c
    WHERE c.tenant_id = p_tenant_id AND c.card_no = p_qr AND c.status IN ('active','retired')
    LIMIT 1;
  ELSIF p_card_no IS NOT NULL THEN
    SELECT c.member_id INTO v_member_id
    FROM member_cards c
    WHERE c.tenant_id = p_tenant_id AND c.card_no = p_card_no AND c.status IN ('active','retired')
    LIMIT 1;
  ELSIF p_phone IS NOT NULL THEN
    v_phone_hash := encode(digest(p_phone, 'sha256'), 'hex');
    SELECT id INTO v_member_id FROM members
    WHERE tenant_id = p_tenant_id AND phone_hash = v_phone_hash AND status NOT IN ('deleted','merged');
  END IF;

  IF v_member_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT m.id, m.member_no,
         CASE
           WHEN m.name IS NULL THEN NULL
           WHEN LENGTH(m.name) <= 1 THEN m.name
           ELSE LEFT(m.name, 1) || REPEAT('*', LENGTH(m.name) - 1)
         END,
         m.tier_id, t.name,
         COALESCE(pb.balance, 0), COALESCE(wb.balance, 0),
         m.status
  FROM members m
  LEFT JOIN member_tiers t ON t.id = m.tier_id
  LEFT JOIN member_points_balance pb
    ON pb.tenant_id = m.tenant_id AND pb.member_id = m.id
  LEFT JOIN wallet_balances wb
    ON wb.tenant_id = m.tenant_id AND wb.member_id = m.id
  WHERE m.id = v_member_id;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 賺點
CREATE OR REPLACE FUNCTION rpc_earn_points(
  p_tenant_id    UUID,
  p_member_id    BIGINT,
  p_change       NUMERIC,
  p_source_type  TEXT,
  p_source_id    BIGINT,
  p_operator     UUID,
  p_reason       TEXT DEFAULT NULL
) RETURNS BIGINT AS $$
DECLARE
  v_cur_balance NUMERIC;
  v_new_balance NUMERIC;
  v_id BIGINT;
BEGIN
  IF p_change <= 0 THEN
    RAISE EXCEPTION 'Earn change must be positive';
  END IF;

  INSERT INTO member_points_balance (tenant_id, member_id)
  VALUES (p_tenant_id, p_member_id)
  ON CONFLICT DO NOTHING;

  SELECT balance INTO v_cur_balance FROM member_points_balance
  WHERE tenant_id = p_tenant_id AND member_id = p_member_id
  FOR UPDATE;

  v_new_balance := v_cur_balance + p_change;

  INSERT INTO points_ledger (tenant_id, member_id, change, balance_after,
                             source_type, source_id, reason, operator_id)
  VALUES (p_tenant_id, p_member_id, p_change, v_new_balance,
          p_source_type, p_source_id, p_reason, p_operator)
  RETURNING id INTO v_id;

  UPDATE member_points_balance
     SET balance = v_new_balance,
         version = version + 1,
         last_movement_at = NOW(),
         updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND member_id = p_member_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 扣點
CREATE OR REPLACE FUNCTION rpc_spend_points(
  p_tenant_id    UUID,
  p_member_id    BIGINT,
  p_amount       NUMERIC,
  p_source_type  TEXT,
  p_source_id    BIGINT,
  p_operator     UUID,
  p_reason       TEXT DEFAULT NULL
) RETURNS BIGINT AS $$
DECLARE
  v_cur_balance NUMERIC;
  v_new_balance NUMERIC;
  v_id BIGINT;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Spend amount must be positive';
  END IF;

  SELECT balance INTO v_cur_balance FROM member_points_balance
  WHERE tenant_id = p_tenant_id AND member_id = p_member_id
  FOR UPDATE;

  IF NOT FOUND OR v_cur_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient points: available=%, required=%',
      COALESCE(v_cur_balance, 0), p_amount;
  END IF;

  v_new_balance := v_cur_balance - p_amount;

  INSERT INTO points_ledger (tenant_id, member_id, change, balance_after,
                             source_type, source_id, reason, operator_id)
  VALUES (p_tenant_id, p_member_id, -p_amount, v_new_balance,
          p_source_type, p_source_id, p_reason, p_operator)
  RETURNING id INTO v_id;

  UPDATE member_points_balance
     SET balance = v_new_balance,
         version = version + 1,
         last_movement_at = NOW(),
         updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND member_id = p_member_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 儲值金加值
CREATE OR REPLACE FUNCTION rpc_wallet_topup(
  p_tenant_id      UUID,
  p_member_id      BIGINT,
  p_amount         NUMERIC,
  p_payment_method TEXT,
  p_source_type    TEXT,
  p_source_id      BIGINT,
  p_operator       UUID
) RETURNS BIGINT AS $$
DECLARE
  v_cur_balance NUMERIC;
  v_new_balance NUMERIC;
  v_id BIGINT;
BEGIN
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Topup must be positive'; END IF;

  INSERT INTO wallet_balances (tenant_id, member_id)
  VALUES (p_tenant_id, p_member_id) ON CONFLICT DO NOTHING;

  SELECT balance INTO v_cur_balance FROM wallet_balances
  WHERE tenant_id = p_tenant_id AND member_id = p_member_id FOR UPDATE;

  v_new_balance := v_cur_balance + p_amount;

  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after,
                             type, source_type, source_id, payment_method, operator_id)
  VALUES (p_tenant_id, p_member_id, p_amount, v_new_balance,
          'topup', p_source_type, p_source_id, p_payment_method, p_operator)
  RETURNING id INTO v_id;

  UPDATE wallet_balances
     SET balance = v_new_balance, version = version + 1,
         last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND member_id = p_member_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 儲值金消費
CREATE OR REPLACE FUNCTION rpc_wallet_spend(
  p_tenant_id    UUID,
  p_member_id    BIGINT,
  p_amount       NUMERIC,
  p_source_type  TEXT,
  p_source_id    BIGINT,
  p_operator     UUID
) RETURNS BIGINT AS $$
DECLARE
  v_cur_balance NUMERIC;
  v_new_balance NUMERIC;
  v_id BIGINT;
BEGIN
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Spend must be positive'; END IF;

  SELECT balance INTO v_cur_balance FROM wallet_balances
  WHERE tenant_id = p_tenant_id AND member_id = p_member_id FOR UPDATE;

  IF NOT FOUND OR v_cur_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient wallet: available=%, required=%',
      COALESCE(v_cur_balance, 0), p_amount;
  END IF;

  v_new_balance := v_cur_balance - p_amount;

  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after,
                             type, source_type, source_id, operator_id)
  VALUES (p_tenant_id, p_member_id, -p_amount, v_new_balance,
          'spend', p_source_type, p_source_id, p_operator)
  RETURNING id INTO v_id;

  UPDATE wallet_balances
     SET balance = v_new_balance, version = version + 1,
         last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND member_id = p_member_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Product Module Schema v0.1
-- PostgreSQL 15+ / Supabase
-- See docs/DB-商品模組.md for full design rationale.
-- ============================================================

-- ============================================================
-- TABLES
-- ============================================================

-- 1. 分類樹
CREATE TABLE categories (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  parent_id    BIGINT REFERENCES categories(id),
  code         TEXT NOT NULL,
  name         TEXT NOT NULL,
  level        SMALLINT NOT NULL CHECK (level BETWEEN 1 AND 3),
  sort_order   INTEGER NOT NULL DEFAULT 0,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_by   UUID,
  updated_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE categories IS '商品分類樹（大/中/小，最多 3 層）';

-- 2. 品牌
CREATE TABLE brands (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  code         TEXT NOT NULL,
  name         TEXT NOT NULL,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_by   UUID,
  updated_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);

-- 3. 商品（業務層）
CREATE TABLE products (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  product_code   TEXT NOT NULL,
  name           TEXT NOT NULL,
  short_name     TEXT,
  brand_id       BIGINT REFERENCES brands(id),
  category_id    BIGINT REFERENCES categories(id),
  description    TEXT,
  images         JSONB NOT NULL DEFAULT '[]'::jsonb,
  status         TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                   'draft','active','inactive','discontinued'
                 )),
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, product_code)
);
COMMENT ON TABLE products IS '商品主檔（業務層級，1 Product 可有 N 個 SKU）';

-- 4. SKU（庫存單位）
CREATE TABLE skus (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  product_id     BIGINT NOT NULL REFERENCES products(id),
  sku_code       TEXT NOT NULL,
  variant_name   TEXT,
  spec           JSONB NOT NULL DEFAULT '{}'::jsonb,
  base_unit      TEXT NOT NULL DEFAULT '個',
  weight_g       NUMERIC(18,3),
  tax_rate       NUMERIC(5,4) NOT NULL DEFAULT 0.0500,
  status         TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                   'draft','active','inactive','discontinued'
                 )),
  -- denormalize for hot path
  product_name   TEXT,
  category_id    BIGINT,
  brand_id       BIGINT,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, sku_code)
);
COMMENT ON TABLE skus IS 'SKU：最小庫存管理單位；庫存 / 採購 / 銷售 FK 目標';
COMMENT ON COLUMN skus.product_name IS '熱路徑 denorm：查 SKU 不必 JOIN products';

-- 5. 多單位換算
CREATE TABLE sku_packs (
  id              BIGSERIAL PRIMARY KEY,
  sku_id          BIGINT NOT NULL REFERENCES skus(id) ON DELETE CASCADE,
  unit            TEXT NOT NULL,
  qty_in_base     NUMERIC(18,6) NOT NULL CHECK (qty_in_base > 0),
  for_sale        BOOLEAN NOT NULL DEFAULT TRUE,
  for_purchase    BOOLEAN NOT NULL DEFAULT TRUE,
  for_transfer    BOOLEAN NOT NULL DEFAULT TRUE,
  is_default_sale BOOLEAN NOT NULL DEFAULT FALSE,
  created_by      UUID,
  updated_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (sku_id, unit)
);
COMMENT ON TABLE sku_packs IS '1 箱 = 12 盒 = 144 個；每 SKU 至少要有一筆 unit = base_unit, qty_in_base = 1';

-- 6. 條碼
CREATE TABLE barcodes (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  barcode_value   TEXT NOT NULL,
  sku_id          BIGINT NOT NULL REFERENCES skus(id),
  unit            TEXT NOT NULL,
  pack_qty        NUMERIC(18,3) NOT NULL DEFAULT 1,
  type            TEXT NOT NULL CHECK (type IN (
                    'ean13','ean8','upca','upce','code128','internal'
                  )),
  is_primary      BOOLEAN NOT NULL DEFAULT FALSE,
  status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_by      UUID,
  updated_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  retired_at      TIMESTAMPTZ,
  UNIQUE (tenant_id, barcode_value)
);
COMMENT ON TABLE barcodes IS '條碼 ↔ SKU 對應；同 SKU 可多條碼（原廠 / 內部 / 替換）、多單位';
COMMENT ON COLUMN barcodes.pack_qty IS '此條碼代表的 base_unit 數量（掃箱條碼 = 144）';

-- 每 SKU 僅能有一個 is_primary
CREATE UNIQUE INDEX uniq_barcode_primary_per_sku
  ON barcodes (sku_id) WHERE is_primary = TRUE;

-- 7. 內部條碼流水池
CREATE TABLE internal_barcode_sequence (
  tenant_id    UUID PRIMARY KEY,
  next_seq     BIGINT NOT NULL DEFAULT 1,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 8. 未知條碼佇列
CREATE TABLE pending_barcodes (
  id               BIGSERIAL PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  barcode_value    TEXT NOT NULL,
  scanned_count    INTEGER NOT NULL DEFAULT 1,
  first_scanned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_scanned_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_context     TEXT,
  resolved         BOOLEAN NOT NULL DEFAULT FALSE,
  resolved_sku_id  BIGINT REFERENCES skus(id),
  resolved_by      UUID,
  resolved_at      TIMESTAMPTZ,
  UNIQUE (tenant_id, barcode_value)
);

-- 9. 價格（版本化，append-only）
CREATE TABLE prices (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  sku_id          BIGINT NOT NULL REFERENCES skus(id),
  scope           TEXT NOT NULL CHECK (scope IN (
                    'retail','store','member_tier','promo'
                  )),
  scope_id        BIGINT,
  price           NUMERIC(18,4) NOT NULL CHECK (price >= 0),
  currency        TEXT NOT NULL DEFAULT 'TWD',
  effective_from  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  effective_to    TIMESTAMPTZ,
  reason          TEXT,
  created_by      UUID NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (effective_to IS NULL OR effective_to > effective_from)
);
COMMENT ON TABLE prices IS '價格版本表（append-only）；scope=retail/store/member_tier/promo';
COMMENT ON COLUMN prices.scope_id IS 'store: location_id / member_tier: tier_id / promo: promotion_id';

-- 10. 促銷活動
CREATE TABLE promotions (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL,
  code                 TEXT NOT NULL,
  name                 TEXT NOT NULL,
  type                 TEXT NOT NULL CHECK (type IN ('fixed','percent')),
  discount             NUMERIC(18,4) NOT NULL CHECK (discount > 0),
  start_at             TIMESTAMPTZ NOT NULL,
  end_at               TIMESTAMPTZ NOT NULL,
  status               TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN (
                         'draft','scheduled','active','ended','cancelled'
                       )),
  applicable_store_ids BIGINT[] NOT NULL DEFAULT '{}',
  created_by           UUID NOT NULL,
  updated_by           UUID,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code),
  CHECK (end_at > start_at)
);
COMMENT ON COLUMN promotions.type IS 'fixed: 折後固定價; percent: 折扣率 (0.80 = 8 折)';

CREATE TABLE promotion_skus (
  promotion_id  BIGINT NOT NULL REFERENCES promotions(id) ON DELETE CASCADE,
  sku_id        BIGINT NOT NULL REFERENCES skus(id),
  created_by    UUID,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (promotion_id, sku_id)
);
COMMENT ON TABLE promotion_skus IS '多對多關聯表，插入/刪除為主，不追蹤 update';

-- 11. SKU × 供應商
CREATE TABLE sku_suppliers (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  sku_id              BIGINT NOT NULL REFERENCES skus(id),
  supplier_id         BIGINT NOT NULL,
  supplier_sku_code   TEXT,
  lead_time_days      INTEGER,
  min_order_qty       NUMERIC(18,3),
  last_cost           NUMERIC(18,4),
  is_preferred        BOOLEAN NOT NULL DEFAULT FALSE,
  created_by          UUID,
  updated_by          UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, sku_id, supplier_id)
);
COMMENT ON TABLE sku_suppliers IS 'SKU 可由哪些供應商提供；supplier_id 指向採購模組 suppliers';

-- 每 SKU 僅能有一個 is_preferred
CREATE UNIQUE INDEX uniq_sku_supplier_preferred
  ON sku_suppliers (tenant_id, sku_id) WHERE is_preferred = TRUE;

-- 12. 稽核日誌
CREATE TABLE product_audit_log (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  entity_type  TEXT NOT NULL CHECK (entity_type IN (
                 'product','sku','barcode','price','promotion','sku_supplier','sku_pack'
               )),
  entity_id    BIGINT NOT NULL,
  action       TEXT NOT NULL CHECK (action IN ('create','update','delete','status_change','retire')),
  before_value JSONB,
  after_value  JSONB,
  reason       TEXT,
  operator_id  UUID NOT NULL,
  operator_ip  INET,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- 禁止物理刪除 SKU / Product（軟刪除靠 status）
CREATE OR REPLACE FUNCTION forbid_sku_delete()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'skus/products cannot be deleted. Set status = discontinued instead.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_delete_sku BEFORE DELETE ON skus
  FOR EACH ROW EXECUTE FUNCTION forbid_sku_delete();

CREATE TRIGGER trg_no_delete_product BEFORE DELETE ON products
  FOR EACH ROW EXECUTE FUNCTION forbid_sku_delete();

-- updated_at 自動更新
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_products       BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_skus           BEFORE UPDATE ON skus
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_categories     BEFORE UPDATE ON categories
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_brands         BEFORE UPDATE ON brands
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_promotions     BEFORE UPDATE ON promotions
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sku_packs      BEFORE UPDATE ON sku_packs
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_barcodes       BEFORE UPDATE ON barcodes
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sku_suppliers  BEFORE UPDATE ON sku_suppliers
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================================================
-- INDEXES
-- ============================================================

-- 條碼 lookup 熱路徑（最重要）
CREATE INDEX idx_barcode_lookup
  ON barcodes (tenant_id, barcode_value)
  WHERE status = 'active';

CREATE INDEX idx_barcode_all
  ON barcodes (tenant_id, barcode_value);

-- SKU 主檔
CREATE INDEX idx_skus_product
  ON skus (tenant_id, product_id)
  WHERE status = 'active';

CREATE INDEX idx_skus_category
  ON skus (tenant_id, category_id, status);

-- Product
CREATE INDEX idx_products_category
  ON products (tenant_id, category_id, status);
CREATE INDEX idx_products_brand
  ON products (tenant_id, brand_id, status);

-- 價格
CREATE INDEX idx_prices_lookup
  ON prices (tenant_id, sku_id, scope, scope_id, effective_from DESC);

CREATE INDEX idx_prices_time_range
  ON prices (tenant_id, sku_id, effective_from, effective_to);

-- 促銷
CREATE INDEX idx_promotions_active
  ON promotions (tenant_id, status, start_at, end_at);

-- 供應商
CREATE INDEX idx_sku_suppliers_sku
  ON sku_suppliers (tenant_id, sku_id);
CREATE INDEX idx_sku_suppliers_supplier
  ON sku_suppliers (tenant_id, supplier_id);

-- 稽核
CREATE INDEX idx_audit_entity
  ON product_audit_log (tenant_id, entity_type, entity_id, created_at DESC);

-- 未處理條碼
CREATE INDEX idx_pending_barcode_unresolved
  ON pending_barcodes (tenant_id, resolved, last_scanned_at DESC)
  WHERE resolved = FALSE;

-- ============================================================
-- RLS (Row-Level Security)
-- ============================================================

ALTER TABLE categories            ENABLE ROW LEVEL SECURITY;
ALTER TABLE brands                ENABLE ROW LEVEL SECURITY;
ALTER TABLE products              ENABLE ROW LEVEL SECURITY;
ALTER TABLE skus                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE sku_packs             ENABLE ROW LEVEL SECURITY;
ALTER TABLE barcodes              ENABLE ROW LEVEL SECURITY;
ALTER TABLE prices                ENABLE ROW LEVEL SECURITY;
ALTER TABLE promotions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE promotion_skus        ENABLE ROW LEVEL SECURITY;
ALTER TABLE sku_suppliers         ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_audit_log     ENABLE ROW LEVEL SECURITY;
ALTER TABLE pending_barcodes      ENABLE ROW LEVEL SECURITY;

CREATE POLICY read_tenant_products ON products
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY read_tenant_skus ON skus
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY read_tenant_barcodes ON barcodes
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY read_tenant_prices ON prices
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY read_tenant_categories ON categories
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY read_tenant_brands ON brands
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY read_tenant_promotions ON promotions
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

-- 寫入一律走 RPC（SECURITY DEFINER），不開放直接 INSERT/UPDATE

-- ============================================================
-- RPC
-- ============================================================

-- 條碼 lookup（熱路徑）
CREATE OR REPLACE FUNCTION rpc_barcode_lookup(
  p_tenant_id UUID,
  p_barcode TEXT,
  p_context TEXT DEFAULT 'pos'
) RETURNS TABLE (
  sku_id         BIGINT,
  sku_code       TEXT,
  product_name   TEXT,
  unit           TEXT,
  pack_qty       NUMERIC,
  status         TEXT,
  barcode_status TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT s.id, s.sku_code, s.product_name, b.unit, b.pack_qty, s.status, b.status
  FROM barcodes b
  JOIN skus s ON s.id = b.sku_id
  WHERE b.tenant_id = p_tenant_id
    AND b.barcode_value = p_barcode
  LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 取當前有效價（優先序：promo > member_tier > store > retail）
CREATE OR REPLACE FUNCTION rpc_current_price(
  p_tenant_id   UUID,
  p_sku_id      BIGINT,
  p_location_id BIGINT,
  p_member_tier BIGINT DEFAULT NULL,
  p_at          TIMESTAMPTZ DEFAULT NOW()
) RETURNS NUMERIC AS $$
DECLARE
  v_price NUMERIC;
BEGIN
  -- 1. promo
  SELECT p.price INTO v_price
  FROM prices p
  JOIN promotion_skus ps ON ps.promotion_id = p.scope_id AND ps.sku_id = p.sku_id
  JOIN promotions pr ON pr.id = p.scope_id
  WHERE p.tenant_id = p_tenant_id
    AND p.sku_id = p_sku_id
    AND p.scope = 'promo'
    AND p.effective_from <= p_at
    AND (p.effective_to IS NULL OR p.effective_to > p_at)
    AND pr.status = 'active'
    AND (array_length(pr.applicable_store_ids, 1) IS NULL
         OR p_location_id = ANY(pr.applicable_store_ids))
  ORDER BY p.price ASC
  LIMIT 1;
  IF v_price IS NOT NULL THEN RETURN v_price; END IF;

  -- 2. member_tier
  IF p_member_tier IS NOT NULL THEN
    SELECT price INTO v_price FROM prices
    WHERE tenant_id = p_tenant_id AND sku_id = p_sku_id
      AND scope = 'member_tier' AND scope_id = p_member_tier
      AND effective_from <= p_at
      AND (effective_to IS NULL OR effective_to > p_at)
    ORDER BY effective_from DESC LIMIT 1;
    IF v_price IS NOT NULL THEN RETURN v_price; END IF;
  END IF;

  -- 3. store
  SELECT price INTO v_price FROM prices
  WHERE tenant_id = p_tenant_id AND sku_id = p_sku_id
    AND scope = 'store' AND scope_id = p_location_id
    AND effective_from <= p_at
    AND (effective_to IS NULL OR effective_to > p_at)
  ORDER BY effective_from DESC LIMIT 1;
  IF v_price IS NOT NULL THEN RETURN v_price; END IF;

  -- 4. retail
  SELECT price INTO v_price FROM prices
  WHERE tenant_id = p_tenant_id AND sku_id = p_sku_id
    AND scope = 'retail'
    AND effective_from <= p_at
    AND (effective_to IS NULL OR effective_to > p_at)
  ORDER BY effective_from DESC LIMIT 1;

  RETURN v_price;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 排程變價：插入新版 + 關閉同 scope 舊版
CREATE OR REPLACE FUNCTION rpc_upsert_price(
  p_tenant_id      UUID,
  p_sku_id         BIGINT,
  p_scope          TEXT,
  p_scope_id       BIGINT,
  p_price          NUMERIC,
  p_effective_from TIMESTAMPTZ,
  p_reason         TEXT,
  p_operator       UUID
) RETURNS BIGINT AS $$
DECLARE
  v_id BIGINT;
BEGIN
  UPDATE prices
     SET effective_to = p_effective_from
   WHERE tenant_id = p_tenant_id
     AND sku_id = p_sku_id
     AND scope = p_scope
     AND (scope_id IS NOT DISTINCT FROM p_scope_id)
     AND (effective_to IS NULL OR effective_to > p_effective_from);

  INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price,
                      effective_from, reason, created_by)
  VALUES (p_tenant_id, p_sku_id, p_scope, p_scope_id, p_price,
          p_effective_from, p_reason, p_operator)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 產生內部條碼
CREATE OR REPLACE FUNCTION rpc_generate_internal_barcode(
  p_tenant_id UUID,
  p_sku_id    BIGINT,
  p_unit      TEXT,
  p_pack_qty  NUMERIC,
  p_operator  UUID
) RETURNS TEXT AS $$
DECLARE
  v_seq     BIGINT;
  v_date    TEXT;
  v_value   TEXT;
  v_check   CHAR;
BEGIN
  INSERT INTO internal_barcode_sequence (tenant_id, next_seq)
  VALUES (p_tenant_id, 1)
  ON CONFLICT (tenant_id) DO UPDATE
    SET next_seq = internal_barcode_sequence.next_seq + 1,
        updated_at = NOW()
  RETURNING next_seq INTO v_seq;

  v_date  := TO_CHAR(NOW(), 'YYMMDD');
  v_value := 'LT' || v_date || LPAD(v_seq::text, 5, '0');
  v_check := ((LENGTH(v_value) * 7 + v_seq) % 10)::text;
  v_value := v_value || v_check;

  INSERT INTO barcodes (tenant_id, barcode_value, sku_id, unit, pack_qty, type, created_by)
  VALUES (p_tenant_id, v_value, p_sku_id, p_unit, p_pack_qty, 'internal', p_operator);

  RETURN v_value;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Core Module CRUD RPCs + Relaxed Read RLS for Admin MVP
--
-- Scope: 會員 / 訂單（開團 + 客訂）/ 供應商 / 門市 / LINE 頻道
--
-- Security model:
--   - SELECT：`authenticated` role + matching tenant_id 即可（暫免 role-based 限制）
--     v0.3 將加回 hq / store role 細分；目前 admin UI 只有 cktalex 超管一個 user
--   - 寫入：一律走 SECURITY DEFINER RPC、tenant_id 從 JWT
-- ============================================================

-- ============================================================
-- PART A: 會員主檔加上 plaintext 欄位（MVP、之後改 pgp_sym_encrypt）
-- ============================================================

ALTER TABLE members ADD COLUMN IF NOT EXISTS phone    TEXT;
ALTER TABLE members ADD COLUMN IF NOT EXISTS email    TEXT;
ALTER TABLE members ADD COLUMN IF NOT EXISTS birthday DATE;

COMMENT ON COLUMN members.phone    IS 'MVP plaintext；未來改 phone_enc (pgp_sym)';
COMMENT ON COLUMN members.email    IS 'MVP plaintext；未來改 email_enc';
COMMENT ON COLUMN members.birthday IS 'MVP plaintext；未來改 birthday_enc';

-- ============================================================
-- PART B: Relaxed read RLS for authenticated + tenant match
-- ============================================================

-- 會員相關
CREATE POLICY auth_read_member_tiers ON member_tiers
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_members ON members
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_member_cards ON member_cards
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_points_ledger ON points_ledger
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_member_points_balance ON member_points_balance
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_wallet_ledger ON wallet_ledger
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_wallet_balances ON wallet_balances
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

-- 供應商
CREATE POLICY auth_read_suppliers ON suppliers
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_supplier_skus ON supplier_skus
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

-- 訂單相關（stores / line_channels / campaigns / orders 已有 RLS、但只限 owner/hq）
-- 給 authenticated 一條 relaxed SELECT
CREATE POLICY auth_read_stores ON stores
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_line_channels ON line_channels
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_post_templates ON post_templates
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_group_buy_campaigns ON group_buy_campaigns
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_campaign_items ON campaign_items
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_campaign_channels ON campaign_channels
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_customer_orders ON customer_orders
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_customer_order_items ON customer_order_items
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_customer_line_aliases ON customer_line_aliases
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY auth_read_order_pickup_events ON order_pickup_events
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

-- ============================================================
-- PART C: Write RPCs
-- ============================================================

-- --------------------------------------------------------
-- C1. rpc_upsert_member
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_member(
  p_id            BIGINT,
  p_member_no     TEXT,
  p_phone         TEXT,
  p_name          TEXT,
  p_gender        TEXT DEFAULT NULL,
  p_birthday      DATE DEFAULT NULL,
  p_email         TEXT DEFAULT NULL,
  p_tier_id       BIGINT DEFAULT NULL,
  p_home_store_id BIGINT DEFAULT NULL,
  p_status        TEXT DEFAULT 'active',
  p_notes         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_id          BIGINT;
  v_phone_hash  TEXT;
  v_email_hash  TEXT;
  v_birth_md    TEXT;
BEGIN
  IF p_phone IS NULL OR p_phone = '' THEN
    RAISE EXCEPTION 'phone is required';
  END IF;
  IF p_name IS NULL OR p_name = '' THEN
    RAISE EXCEPTION 'name is required';
  END IF;

  v_phone_hash := encode(digest(p_phone, 'sha256'), 'hex');
  v_email_hash := CASE WHEN p_email IS NOT NULL AND p_email <> ''
                       THEN encode(digest(lower(p_email), 'sha256'), 'hex')
                  END;
  v_birth_md   := CASE WHEN p_birthday IS NOT NULL
                       THEN to_char(p_birthday, 'MM-DD')
                  END;

  IF p_tier_id IS NOT NULL THEN
    PERFORM 1 FROM member_tiers WHERE id = p_tier_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'tier % not in tenant', p_tier_id; END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO members (
      tenant_id, member_no, phone_hash, phone, email_hash, email,
      name, birthday, birth_md, gender, tier_id, home_store_id,
      status, notes, created_by, updated_by
    ) VALUES (
      v_tenant, p_member_no, v_phone_hash, p_phone, v_email_hash, p_email,
      p_name, p_birthday, v_birth_md, p_gender, p_tier_id, p_home_store_id,
      COALESCE(p_status, 'active'), p_notes, auth.uid(), auth.uid()
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE members SET
      member_no     = COALESCE(p_member_no, member_no),
      phone_hash    = v_phone_hash,
      phone         = p_phone,
      email_hash    = v_email_hash,
      email         = p_email,
      name          = COALESCE(p_name, name),
      birthday      = p_birthday,
      birth_md      = v_birth_md,
      gender        = p_gender,
      tier_id       = p_tier_id,
      home_store_id = p_home_store_id,
      status        = COALESCE(p_status, status),
      notes         = p_notes,
      updated_by    = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'member % not in tenant', p_id; END IF;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_member TO authenticated;

-- --------------------------------------------------------
-- C2. rpc_upsert_member_tier
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_member_tier(
  p_id         BIGINT,
  p_code       TEXT,
  p_name       TEXT,
  p_sort_order INTEGER DEFAULT 0,
  p_benefits   JSONB   DEFAULT '{}'::jsonb,
  p_is_active  BOOLEAN DEFAULT TRUE
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO member_tiers (tenant_id, code, name, sort_order, benefits, is_active, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, COALESCE(p_sort_order,0), COALESCE(p_benefits,'{}'::jsonb),
            COALESCE(p_is_active, TRUE), auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE member_tiers SET
      code = COALESCE(p_code, code),
      name = COALESCE(p_name, name),
      sort_order = COALESCE(p_sort_order, sort_order),
      benefits = COALESCE(p_benefits, benefits),
      is_active = COALESCE(p_is_active, is_active),
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'tier % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_member_tier TO authenticated;

-- --------------------------------------------------------
-- C3. rpc_upsert_supplier
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_supplier(
  p_id             BIGINT,
  p_code           TEXT,
  p_name           TEXT,
  p_tax_id         TEXT    DEFAULT NULL,
  p_contact_name   TEXT    DEFAULT NULL,
  p_phone          TEXT    DEFAULT NULL,
  p_email          TEXT    DEFAULT NULL,
  p_address        TEXT    DEFAULT NULL,
  p_payment_terms  TEXT    DEFAULT NULL,
  p_lead_time_days INTEGER DEFAULT NULL,
  p_is_active      BOOLEAN DEFAULT TRUE,
  p_notes          TEXT    DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO suppliers (tenant_id, code, name, tax_id, contact_name, phone, email,
                           address, payment_terms, lead_time_days, is_active, notes,
                           created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, p_tax_id, p_contact_name, p_phone, p_email,
            p_address, p_payment_terms, p_lead_time_days, COALESCE(p_is_active,TRUE), p_notes,
            auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE suppliers SET
      code           = COALESCE(p_code, code),
      name           = COALESCE(p_name, name),
      tax_id         = p_tax_id,
      contact_name   = p_contact_name,
      phone          = p_phone,
      email          = p_email,
      address        = p_address,
      payment_terms  = p_payment_terms,
      lead_time_days = p_lead_time_days,
      is_active      = COALESCE(p_is_active, is_active),
      notes          = p_notes,
      updated_by     = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'supplier % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_supplier TO authenticated;

-- --------------------------------------------------------
-- C4. rpc_upsert_store
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_store(
  p_id                      BIGINT,
  p_code                    TEXT,
  p_name                    TEXT,
  p_location_id             BIGINT  DEFAULT NULL,
  p_pickup_window_days      INTEGER DEFAULT 5,
  p_allowed_payment_methods JSONB   DEFAULT '["cash"]'::jsonb,
  p_is_active               BOOLEAN DEFAULT TRUE,
  p_notes                   TEXT    DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO stores (tenant_id, code, name, location_id,
                        pickup_window_days, allowed_payment_methods,
                        is_active, notes, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, p_location_id,
            COALESCE(p_pickup_window_days,5), COALESCE(p_allowed_payment_methods,'["cash"]'::jsonb),
            COALESCE(p_is_active,TRUE), p_notes, auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE stores SET
      code = COALESCE(p_code, code),
      name = COALESCE(p_name, name),
      location_id = p_location_id,
      pickup_window_days = COALESCE(p_pickup_window_days, pickup_window_days),
      allowed_payment_methods = COALESCE(p_allowed_payment_methods, allowed_payment_methods),
      is_active = COALESCE(p_is_active, is_active),
      notes = p_notes,
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'store % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_store TO authenticated;

-- --------------------------------------------------------
-- C5. rpc_upsert_line_channel
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_line_channel(
  p_id            BIGINT,
  p_code          TEXT,
  p_name          TEXT,
  p_channel_type  TEXT    DEFAULT 'open_chat',
  p_home_store_id BIGINT  DEFAULT NULL,
  p_is_active     BOOLEAN DEFAULT TRUE,
  p_notes         TEXT    DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_home_store_id IS NULL THEN
    RAISE EXCEPTION 'home_store_id is required';
  END IF;
  PERFORM 1 FROM stores WHERE id = p_home_store_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', p_home_store_id; END IF;

  IF p_id IS NULL THEN
    INSERT INTO line_channels (tenant_id, code, name, channel_type, home_store_id,
                               is_active, notes, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, COALESCE(p_channel_type,'open_chat'),
            p_home_store_id, COALESCE(p_is_active,TRUE), p_notes, auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE line_channels SET
      code = COALESCE(p_code, code),
      name = COALESCE(p_name, name),
      channel_type = COALESCE(p_channel_type, channel_type),
      home_store_id = p_home_store_id,
      is_active = COALESCE(p_is_active, is_active),
      notes = p_notes,
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'channel % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_line_channel TO authenticated;

-- --------------------------------------------------------
-- C6. rpc_upsert_campaign
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_campaign(
  p_id               BIGINT,
  p_campaign_no      TEXT,
  p_name             TEXT,
  p_description      TEXT        DEFAULT NULL,
  p_cover_image_url  TEXT        DEFAULT NULL,
  p_status           TEXT        DEFAULT 'draft',
  p_close_type       TEXT        DEFAULT 'regular',
  p_start_at         TIMESTAMPTZ DEFAULT NULL,
  p_end_at           TIMESTAMPTZ DEFAULT NULL,
  p_pickup_deadline  DATE        DEFAULT NULL,
  p_pickup_days      INTEGER     DEFAULT NULL,
  p_total_cap_qty    NUMERIC     DEFAULT NULL,
  p_notes            TEXT        DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO group_buy_campaigns (
      tenant_id, campaign_no, name, description, cover_image_url,
      status, close_type, start_at, end_at, pickup_deadline, pickup_days,
      total_cap_qty, notes, created_by, updated_by
    ) VALUES (
      v_tenant, p_campaign_no, p_name, p_description, p_cover_image_url,
      COALESCE(p_status,'draft'), COALESCE(p_close_type,'regular'),
      p_start_at, p_end_at, p_pickup_deadline, p_pickup_days,
      p_total_cap_qty, p_notes, auth.uid(), auth.uid()
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE group_buy_campaigns SET
      campaign_no = COALESCE(p_campaign_no, campaign_no),
      name = COALESCE(p_name, name),
      description = p_description,
      cover_image_url = p_cover_image_url,
      status = COALESCE(p_status, status),
      close_type = COALESCE(p_close_type, close_type),
      start_at = p_start_at,
      end_at = p_end_at,
      pickup_deadline = p_pickup_deadline,
      pickup_days = p_pickup_days,
      total_cap_qty = p_total_cap_qty,
      notes = p_notes,
      updated_by = auth.uid()
    WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign TO authenticated;

-- --------------------------------------------------------
-- C7. rpc_upsert_campaign_item
-- --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_campaign_item(
  p_id          BIGINT,
  p_campaign_id BIGINT,
  p_sku_id      BIGINT,
  p_unit_price  NUMERIC,
  p_cap_qty     NUMERIC DEFAULT NULL,
  p_sort_order  INTEGER DEFAULT 0,
  p_notes       TEXT    DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  PERFORM 1 FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;

  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'sku % not in tenant', p_sku_id; END IF;

  IF p_id IS NULL THEN
    INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price, cap_qty,
                                sort_order, notes, created_by, updated_by)
    VALUES (v_tenant, p_campaign_id, p_sku_id, p_unit_price, p_cap_qty,
            COALESCE(p_sort_order,0), p_notes, auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE campaign_items SET
      sku_id = COALESCE(p_sku_id, sku_id),
      unit_price = COALESCE(p_unit_price, unit_price),
      cap_qty = p_cap_qty,
      sort_order = COALESCE(p_sort_order, sort_order),
      notes = p_notes,
      updated_by = auth.uid()
    WHERE id = p_id AND campaign_id = p_campaign_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'campaign_item % not found', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_campaign_item TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_delete_campaign_item(
  p_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
BEGIN
  DELETE FROM campaign_items
   WHERE id = p_id AND tenant_id = v_tenant;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_delete_campaign_item TO authenticated;

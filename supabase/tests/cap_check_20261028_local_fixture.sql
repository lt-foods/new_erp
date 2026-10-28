-- ============================================================================
-- cap_check_20261028_local_fixture.sql —— 只給「本機臨時 PostgreSQL」用的精簡表
-- ⛔ 不要貼到正式庫／測試庫（會建角色、auth schema、同名資料表）。
--
-- 用法（空的臨時庫）：
--   psql -f supabase/tests/cap_check_20261028_local_fixture.sql
--   ＋ 依序貼這些函式的 repo 原文（逐字從 migration 切出來，不要手抄）：
--       _current_tenant_id            ← 20260707000020_trial_expiry_enforcement.sql:25
--       rpc_create_customer_orders    ← 20261013000000_transfer_always_new_order.sql:941
--       rpc_place_member_order_guarded← 20261013000000_transfer_always_new_order.sql:1096
--       _line_note_item_codes         ← 20260910040000_line_note_post_retail_price.sql:23
--       rpc_line_note_apply_comment   ← 20260918010000_line_note_commenter_member_map.sql:226
--   psql -1 -f supabase/migrations/20261028000000_cap_check_order_entry_line_note.sql（貼兩次驗可重貼）
--   psql -f supabase/tests/cap_check_20261028_verification.sql（每段印 ✅，失敗就停）
--
-- 簡化成 stub、這裡驗不到的：_reopen_order_if_completed、_line_note_find_member（只認 member_no）、
--   _line_note_pick_channel、_line_note_remember_commenter；RLS、觸發器、其他 NOT NULL 欄位；
--   用超級使用者跑 → 權限路徑只驗了 has_function_privilege。
-- ============================================================================
-- 本機臨時庫的精簡表（只有這次會碰到的欄位）
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN;
CREATE SCHEMA auth;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('request.jwt.claims', true), '')::jsonb $$;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULLIF(auth.jwt() ->> 'sub','')::uuid $$;
CREATE TABLE tenants (id uuid PRIMARY KEY, status text);
CREATE TABLE stores (id bigserial PRIMARY KEY, tenant_id uuid NOT NULL);
CREATE TABLE line_channels (id bigserial PRIMARY KEY, tenant_id uuid NOT NULL, is_active boolean NOT NULL DEFAULT true, home_store_id bigint);
CREATE TABLE members (id bigserial PRIMARY KEY, tenant_id uuid NOT NULL, member_no text, name text, no_new_order boolean NOT NULL DEFAULT false, home_store_id bigint, status text DEFAULT 'active');
CREATE TABLE products (id bigserial PRIMARY KEY, images jsonb);
CREATE TABLE skus (id bigserial PRIMARY KEY, product_id bigint, product_name text, variant_name text);
CREATE TABLE prices (id bigserial PRIMARY KEY, sku_id bigint, scope text, price numeric, effective_from timestamptz, effective_to timestamptz);
CREATE TABLE group_buy_campaigns (
  id bigserial PRIMARY KEY, tenant_id uuid NOT NULL, campaign_no text NOT NULL, status text NOT NULL,
  total_cap_qty numeric(18,3), is_for_shop boolean DEFAULT true, end_at timestamptz, customer_end_at timestamptz,
  owner_store_id bigint, updated_at timestamptz DEFAULT now());
CREATE TABLE campaign_items (
  id bigserial PRIMARY KEY, tenant_id uuid NOT NULL, campaign_id bigint NOT NULL REFERENCES group_buy_campaigns(id),
  sku_id bigint NOT NULL, unit_price numeric(18,4) NOT NULL, cap_qty numeric(18,3), sort_order int NOT NULL DEFAULT 0,
  is_gift boolean DEFAULT false);
CREATE TABLE customer_orders (
  id bigserial PRIMARY KEY, tenant_id uuid NOT NULL, order_no text, campaign_id bigint, channel_id bigint, member_id bigint,
  nickname_snapshot text, pickup_store_id bigint, status text NOT NULL, order_kind text NOT NULL DEFAULT 'normal',
  transferred_from_order_id bigint, notes text, created_by uuid, updated_by uuid, updated_at timestamptz DEFAULT now());
CREATE TABLE customer_order_items (
  id bigserial PRIMARY KEY, tenant_id uuid NOT NULL, order_id bigint NOT NULL REFERENCES customer_orders(id),
  campaign_item_id bigint, sku_id bigint, qty numeric NOT NULL, unit_price numeric, status text NOT NULL, source text,
  created_by uuid, updated_by uuid, created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
CREATE TABLE line_note_communities (id bigserial PRIMARY KEY, store_id bigint);
CREATE TABLE line_note_posts (id bigserial PRIMARY KEY, campaign_id bigint, community_id bigint);
CREATE TABLE line_note_comments (
  id bigserial PRIMARY KEY, tenant_id uuid NOT NULL, post_id bigint, status text NOT NULL DEFAULT 'pending',
  error text, customer_order_id bigint, parsed jsonb, member_no_hint text, commenter_id text, commenter_name text,
  text text, member_id bigint, processed_at timestamptz, resolution_note text, commented_at timestamptz DEFAULT now());
-- 跟這次無關的下游：簡化成 stub（說明見回報）
CREATE FUNCTION public._reopen_order_if_completed(p_order_id bigint, p_user uuid, p_reason text) RETURNS text LANGUAGE sql AS $$ SELECT NULL::text $$;
CREATE FUNCTION public._line_note_find_member(p_tenant uuid, p_hint text, p_commenter text, p_store bigint, p_text text)
RETURNS TABLE (member_id bigint, home_store_id bigint, ambiguous text) LANGUAGE sql AS $$
  SELECT m.id, m.home_store_id, NULL::text FROM members m WHERE m.tenant_id = p_tenant AND m.member_no = p_hint $$;
CREATE FUNCTION public._line_note_pick_channel(p_tenant uuid, p_store bigint) RETURNS bigint LANGUAGE sql AS $$
  SELECT id FROM line_channels WHERE tenant_id = p_tenant AND is_active ORDER BY id LIMIT 1 $$;
CREATE FUNCTION public._line_note_remember_commenter(p_tenant uuid, p_cid text, p_name text, p_member bigint, p_src text) RETURNS void LANGUAGE sql AS $$ SELECT $$;

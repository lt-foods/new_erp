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

-- ── 開團彈窗群組清單（rpc_line_note_campaign_targets）要用的欄位與 stub ──
--   另外要逐字貼：_line_note_comment_is_todo 三參數 ← 20260923120000_line_note_todo_orderish.sql:17
--                 rpc_line_note_campaign_targets ← 20260929000000_line_note_no_bot_for_store_campaign.sql:208
--                 _line_note_settle_keyed_comments ← 20260928000000_line_note_settle_keyed_comments.sql:27
ALTER TABLE stores ADD COLUMN name text;
ALTER TABLE group_buy_campaigns ADD COLUMN sales_channel text;
CREATE TABLE line_note_accounts (id bigserial PRIMARY KEY, label text, status text);
ALTER TABLE line_note_communities
  ADD COLUMN tenant_id uuid, ADD COLUMN home_id text, ADD COLUMN home_name text, ADD COLUMN home_kind text,
  ADD COLUMN account_id bigint, ADD COLUMN auto_post_on_open boolean, ADD COLUMN listen_enabled boolean,
  ADD COLUMN sales_channels text[], ADD COLUMN share_from_community_id bigint;
ALTER TABLE line_note_posts
  ADD COLUMN tenant_id uuid, ADD COLUMN status text, ADD COLUMN line_post_id text, ADD COLUMN text text,
  ADD COLUMN posted_at timestamptz, ADD COLUMN last_read_at timestamptz, ADD COLUMN closed_reason text,
  ADD COLUMN last_error text, ADD COLUMN share_state text, ADD COLUMN shared_at timestamptz;
CREATE FUNCTION public._line_note_branch_visible_store(p_store bigint) RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
CREATE FUNCTION public._line_note_takes_channel(p_channels text[], p_chan text) RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
CREATE FUNCTION public._line_note_channel_label(p_chan text) RETURNS text LANGUAGE sql AS $$ SELECT p_chan $$;

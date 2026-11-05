-- ============================================================================
-- flavor_caps_20261105_local_fixture.sql —— 只給「本機臨時 PostgreSQL」用
-- ⛔ 不要貼到正式庫／測試庫（會改表結構）。
--
-- 用法（空的臨時庫，依序）：
--   1. psql -f supabase/tests/cap_check_20261028_local_fixture.sql
--   2. psql -f supabase/tests/flavor_caps_20261105_local_fixture.sql（本檔）
--   3. 逐字從 migration 切出來貼（不要手抄）：
--        _current_tenant_id                  ← 20260707000020_trial_expiry_enforcement.sql:25
--        rpc_create_customer_orders          ← 20261013000000_transfer_always_new_order.sql:941
--        rpc_place_member_order_guarded      ← 20261013000000_transfer_always_new_order.sql:1096
--        _line_note_item_codes               ← 20260910040000_line_note_post_retail_price.sql:23
--        rpc_line_note_apply_comment         ← 20260918010000_line_note_commenter_member_map.sql:226
--        _line_note_comment_is_todo 三參數    ← 20260923120000_line_note_todo_orderish.sql:17
--        rpc_line_note_campaign_targets      ← 20260929000000_line_note_no_bot_for_store_campaign.sql:208
--        _line_note_settle_keyed_comments    ← 20260928000000_line_note_settle_keyed_comments.sql:27
--        rpc_next_campaign_no                ← 20260511000001_campaign_from_products.sql
--        _enforce_campaign_product_invariant ← 20260514000009_campaign_product_invariant.sql
--        rpc_upsert_campaign_item            ← 20260425120000_core_crud_rpcs.sql:429
--        rpc_create_campaign_from_product    ← 20260929060000_campaign_from_product_total_cap.sql:15
--   4. psql -1 -f supabase/migrations/20261028000000_cap_check_order_entry_line_note.sql
--   5. psql -f flavor_caps_20261105_regression_dump.sql > 改前.txt
--   6. psql -1 -f supabase/migrations/20261105000000_campaign_from_product_flavor_caps.sql（貼兩次驗可重貼）
--   7. psql -f flavor_caps_20261105_regression_dump.sql > 改後.txt（只有「限量沒填總量」的錯誤訊息應該不同）
--   8. psql -f flavor_caps_20261105_verification.sql（每段印 ✅，失敗就停）
--   9. flavor_caps_20261105_race_*.sql：見各檔檔頭，要真的開兩條連線。
--
-- 驗不到的：RLS、PostgREST、自動發文觸發器（_line_note_on_campaign_open 沒裝）、
--   開團後新增口味的 _sync_sku_to_open_campaigns；用超級使用者跑 → 權限只驗 has_function_privilege。
-- ============================================================================
ALTER TABLE products
  ADD COLUMN tenant_id uuid, ADD COLUMN name text, ADD COLUMN description text;
ALTER TABLE skus
  ADD COLUMN tenant_id uuid, ADD COLUMN sku_code text, ADD COLUMN status text NOT NULL DEFAULT 'active';
ALTER TABLE prices
  ADD COLUMN tenant_id uuid;
ALTER TABLE group_buy_campaigns
  ADD COLUMN name text, ADD COLUMN description text, ADD COLUMN product_id bigint, ADD COLUMN start_at timestamptz,
  ADD COLUMN pickup_deadline date, ADD COLUMN auto_open boolean DEFAULT false, ADD COLUMN line_note_enabled boolean DEFAULT true,
  ADD COLUMN close_type text DEFAULT 'regular', ADD COLUMN created_by uuid, ADD COLUMN updated_by uuid;
ALTER TABLE group_buy_campaigns ALTER COLUMN sales_channel SET DEFAULT 'main';
ALTER TABLE campaign_items
  ADD COLUMN notes text, ADD COLUMN created_by uuid, ADD COLUMN updated_by uuid,
  ADD CONSTRAINT campaign_items_campaign_sku_uniq UNIQUE (campaign_id, sku_id);

-- 共用資料（改前、改後、驗證都用同一份）
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"00000000-0000-0000-0000-000000000001","app_metadata":{"tenant_id":"00000000-0000-0000-0000-000000000001","role":"admin"}}', false);
INSERT INTO tenants VALUES ('00000000-0000-0000-0000-000000000001','active');
INSERT INTO stores (id, tenant_id) VALUES (1,'00000000-0000-0000-0000-000000000001');
INSERT INTO line_channels (id, tenant_id, home_store_id) VALUES (1,'00000000-0000-0000-0000-000000000001',1);
INSERT INTO members (id, tenant_id, member_no, name, home_store_id)
SELECT g, '00000000-0000-0000-0000-000000000001', 'M' || g, '會員' || g, 1 FROM generate_series(1,40) g;
INSERT INTO line_note_communities (id, store_id) VALUES (1, 1);

-- 商品 1：吐司三口味；商品 2：別的商品；商品 3：單規格；商品 4：沒售價
INSERT INTO products (id, tenant_id, name, description) VALUES
 (1,'00000000-0000-0000-0000-000000000001','吐司','吐司文案'),
 (2,'00000000-0000-0000-0000-000000000001','別的商品',NULL),
 (3,'00000000-0000-0000-0000-000000000001','單規格','單規格文案'),
 (4,'00000000-0000-0000-0000-000000000001','沒售價',NULL);
INSERT INTO skus (id, tenant_id, product_id, sku_code, product_name, variant_name, status) VALUES
 (11,'00000000-0000-0000-0000-000000000001',1,'T-S','吐司','草莓','active'),
 (12,'00000000-0000-0000-0000-000000000001',1,'T-C','吐司','巧克力','active'),
 (13,'00000000-0000-0000-0000-000000000001',1,'T-P','吐司','花生','active'),
 (14,'00000000-0000-0000-0000-000000000001',1,'T-X','吐司','停用口味','discontinued'),
 (21,'00000000-0000-0000-0000-000000000001',2,'O-1','別的商品',NULL,'active'),
 (31,'00000000-0000-0000-0000-000000000001',3,'S-1','單規格',NULL,'active'),
 (41,'00000000-0000-0000-0000-000000000001',4,'N-1','沒售價','甲','active');
INSERT INTO prices (tenant_id, sku_id, scope, price, effective_from, effective_to) VALUES
 ('00000000-0000-0000-0000-000000000001',11,'retail',100,now() - interval '1 day',NULL),
 ('00000000-0000-0000-0000-000000000001',12,'retail',110,now() - interval '1 day',NULL),
 ('00000000-0000-0000-0000-000000000001',13,'retail',120,now() - interval '1 day',NULL),
 ('00000000-0000-0000-0000-000000000001',21,'retail',50,now() - interval '1 day',NULL),
 ('00000000-0000-0000-0000-000000000001',31,'retail',70,now() - interval '1 day',NULL);

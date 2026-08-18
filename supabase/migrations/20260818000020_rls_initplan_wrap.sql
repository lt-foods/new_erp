-- ============================================================================
-- 2026-08-18: RLS policy 的 auth.jwt() 提升成 InitPlan（每查詢一次，不要每列一次）
--
-- 症狀：全站「什麼都慢」。線上 pg_stat_statements（3 小時視窗）裡幾乎每一支
--   PostgREST 查詢的成本都跟掃過的列數等比成長，連只有 22,212 列 / 4.3MB 的
--   stock_balances 列表都要 3.5 秒（max 5.5s）。
--
-- 原因：policy 的 USING / WITH CHECK 直接寫 `auth.jwt()`。auth.jwt() 是 STABLE
--   不是 IMMUTABLE，寫在裸運算式裡時 planner 無法提出去，於是**每一列都重跑一次**
--   `current_setting('request.jwt.claims')::jsonb` —— 也就是每列都把 JWT 的 JSON
--   字串重新 parse 一遍。stock_balances 的 policy 一列要跑 6 次這個運算式，
--   再加上每列呼叫一次 _jwt_store_location_ids()。
--
--   實測（authenticated + admin claims，熱快取）：
--     SELECT ... FROM stock_balances ORDER BY last_movement_at DESC LIMIT 50
--       修正前：156.9 ms，shared hit=18,018
--       修正後： 17.5 ms，shared hit=   306      ← 9 倍 / buffer 59 倍
--
-- 修法：把 auth.jwt() / auth.uid() / auth.role() / _jwt_store_ids() /
--   _jwt_store_location_ids() 包進 scalar subquery `(SELECT ...)`。Postgres 會把
--   它變成 InitPlan，整個查詢只求值一次。這是 Supabase 官方 linter
--   `auth_rls_initplan` 指的同一件事。
--
--   `= ANY(<回傳陣列的函式>)` 要特別處理：`= ANY ((SELECT f()))` 會被當成
--   ANY(subquery) 而報 `operator does not exist: bigint = bigint[]`，所以寫成
--   `= ANY (COALESCE((SELECT f()), '{}'::bigint[]))` —— 包一層 COALESCE 之後
--   parser 才會走陣列語意。（4 條 policy 用到：restock_requests / stock_balances /
--   stock_movements / store_settlement_disputes）
--
-- 語意不變，這裡逐條驗證過：
--   在一個 transaction 內先以舊 policy、再以新 policy，對 103 張受影響的表 ×
--   9 種身分（admin / owner / hq_manager / store_manager / store_staff / clerk /
--   warehouse / legacy_admin(role='') / 無 claims）各數一次可見列數，
--   共 927 組比對 → **mismatch 0、error 0**。
--
-- 基底版本：本檔的 169 條 policy 全部是從**線上 pg_catalog 現況**
--   （pg_policies.qual / with_check）產生的，不是從 repo 的 migration 重寫，
--   所以歷來散落在各 migration 的修正（例如 20260502010000 / 20260807000040
--   的 app_metadata role path、legacy admin 的 '' 允許值）都逐字保留。
--   ⚠ 若在本檔套用之前線上又改過任何 policy，要重新產生一次再套。
--
-- Rollback：把 (SELECT auth.xxx()) 改回 auth.xxx()、
--   ANY (COALESCE((SELECT f()), '{}'::bigint[])) 改回 ANY (f())。
--   純效能改動，不還原也不影響正確性。
--
-- 沒有對應的前端改動。
-- ============================================================================

DROP POLICY IF EXISTS clr_owner_write ON public.aid_clearance_offers;
CREATE POLICY clr_owner_write ON public.aid_clearance_offers AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((offering_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint) OR (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text])))));

DROP POLICY IF EXISTS clr_read_all ON public.aid_clearance_offers;
CREATE POLICY clr_read_all ON public.aid_clearance_offers AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS bo_hq_all ON public.backorders;
CREATE POLICY bo_hq_all ON public.backorders AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS bo_store_read ON public.backorders;
CREATE POLICY bo_store_read ON public.backorders AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)));

DROP POLICY IF EXISTS read_tenant_barcodes ON public.barcodes;
CREATE POLICY read_tenant_barcodes ON public.barcodes AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS read_tenant_brands ON public.brands;
CREATE POLICY read_tenant_brands ON public.brands AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS camp_audit_hq_read ON public.campaign_audit_log;
CREATE POLICY camp_audit_hq_read ON public.campaign_audit_log AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS auth_read_campaign_channels ON public.campaign_channels;
CREATE POLICY auth_read_campaign_channels ON public.campaign_channels AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS cc_hq_all ON public.campaign_channels;
CREATE POLICY cc_hq_all ON public.campaign_channels AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS cfp_hq_all ON public.campaign_fb_posts;
CREATE POLICY cfp_hq_all ON public.campaign_fb_posts AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS auth_read_campaign_items ON public.campaign_items;
CREATE POLICY auth_read_campaign_items ON public.campaign_items AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS ci_hq_all ON public.campaign_items;
CREATE POLICY ci_hq_all ON public.campaign_items AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS ci_store_read ON public.campaign_items;
CREATE POLICY ci_store_read ON public.campaign_items AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_campaign_views ON public.campaign_views;
CREATE POLICY auth_read_campaign_views ON public.campaign_views AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS read_tenant_categories ON public.categories;
CREATE POLICY read_tenant_categories ON public.categories AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS client_error_logs_hq_all ON public.client_error_logs;
CREATE POLICY client_error_logs_hq_all ON public.client_error_logs AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = 'hq'::text)));

DROP POLICY IF EXISTS ccp_hq_all ON public.community_product_candidates;
CREATE POLICY ccp_hq_all ON public.community_product_candidates AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'assistant'::text, ''::text]))))
  WITH CHECK (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'assistant'::text, ''::text]))));

DROP POLICY IF EXISTS auth_read_customer_line_aliases ON public.customer_line_aliases;
CREATE POLICY auth_read_customer_line_aliases ON public.customer_line_aliases AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS cla_hq_all ON public.customer_line_aliases;
CREATE POLICY cla_hq_all ON public.customer_line_aliases AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS cla_store_access ON public.customer_line_aliases;
CREATE POLICY cla_store_access ON public.customer_line_aliases AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (channel_id IN ( SELECT line_channels.id
   FROM line_channels
  WHERE (line_channels.home_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)))));

DROP POLICY IF EXISTS coa_hq_read ON public.customer_order_audit_log;
CREATE POLICY coa_hq_read ON public.customer_order_audit_log AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE(NULLIF((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text), NULLIF(((SELECT auth.jwt()) ->> 'role'::text), 'authenticated'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text, ''::text]))));

DROP POLICY IF EXISTS coa_store_read ON public.customer_order_audit_log;
CREATE POLICY coa_store_read ON public.customer_order_audit_log AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((EXISTS ( SELECT 1
   FROM jsonb_array_elements_text(COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) -> 'stores'::text), '[]'::jsonb)) s(name)
  WHERE (s.name = '總倉'::text))) OR (order_id IN ( SELECT co.id
   FROM (customer_orders co
     JOIN stores st ON ((st.id = co.pickup_store_id)))
  WHERE ((st.tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (st.name IN ( SELECT jsonb_array_elements_text(COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) -> 'stores'::text), '[]'::jsonb)) AS jsonb_array_elements_text))))))));

DROP POLICY IF EXISTS auth_read_customer_order_items ON public.customer_order_items;
CREATE POLICY auth_read_customer_order_items ON public.customer_order_items AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS coi_hq_all ON public.customer_order_items;
CREATE POLICY coi_hq_all ON public.customer_order_items AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS coi_store_access ON public.customer_order_items;
CREATE POLICY coi_store_access ON public.customer_order_items AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (order_id IN ( SELECT customer_orders.id
   FROM customer_orders
  WHERE (customer_orders.pickup_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)))));

DROP POLICY IF EXISTS cos_hq_read ON public.customer_order_sources;
CREATE POLICY cos_hq_read ON public.customer_order_sources AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS auth_read_customer_orders ON public.customer_orders;
CREATE POLICY auth_read_customer_orders ON public.customer_orders AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS corders_hq_all ON public.customer_orders;
CREATE POLICY corders_hq_all ON public.customer_orders AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS corders_store_access ON public.customer_orders;
CREATE POLICY corders_store_access ON public.customer_orders AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (pickup_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)));

DROP POLICY IF EXISTS dr_hq_all ON public.demand_requests;
CREATE POLICY dr_hq_all ON public.demand_requests AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS dr_store_own ON public.demand_requests;
CREATE POLICY dr_store_own ON public.demand_requests AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (requester_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)));

DROP POLICY IF EXISTS ec_admin_write ON public.expense_categories;
CREATE POLICY ec_admin_write ON public.expense_categories AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS ec_read_all ON public.expense_categories;
CREATE POLICY ec_read_all ON public.expense_categories AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS exp_admin_all ON public.expenses;
CREATE POLICY exp_admin_all ON public.expenses AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS exp_applicant ON public.expenses;
CREATE POLICY exp_applicant ON public.expenses AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (applicant_id = (((SELECT auth.jwt()) ->> 'sub'::text))::uuid)));

DROP POLICY IF EXISTS eoi_hq_all ON public.external_order_imports;
CREATE POLICY eoi_hq_all ON public.external_order_imports AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS epi_admin_all ON public.external_purchase_imports;
CREATE POLICY epi_admin_all ON public.external_purchase_imports AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS fb_pages_hq_all ON public.fb_pages;
CREATE POLICY fb_pages_hq_all ON public.fb_pages AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS gr_warehouse ON public.goods_receipts;
CREATE POLICY gr_warehouse ON public.goods_receipts AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = 'warehouse'::text) AND (dest_location_id = (((SELECT auth.jwt()) ->> 'location_id'::text))::bigint)));

DROP POLICY IF EXISTS auth_read_group_buy_campaigns ON public.group_buy_campaigns;
CREATE POLICY auth_read_group_buy_campaigns ON public.group_buy_campaigns AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS gbc_hq_all ON public.group_buy_campaigns;
CREATE POLICY gbc_hq_all ON public.group_buy_campaigns AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS gbc_store_read ON public.group_buy_campaigns;
CREATE POLICY gbc_store_read ON public.group_buy_campaigns AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (status = ANY (ARRAY['open'::text, 'closed'::text, 'locked'::text, 'ordered'::text, 'receiving'::text, 'ready'::text, 'completed'::text]))));

DROP POLICY IF EXISTS p_lele_imports_tenant_read ON public.lele_order_imports;
CREATE POLICY p_lele_imports_tenant_read ON public.lele_order_imports AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS p_lele_imports_tenant_write ON public.lele_order_imports;
CREATE POLICY p_lele_imports_tenant_write ON public.lele_order_imports AS PERMISSIVE FOR INSERT TO public
  WITH CHECK ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_line_channels ON public.line_channels;
CREATE POLICY auth_read_line_channels ON public.line_channels AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS lc_hq_all ON public.line_channels;
CREATE POLICY lc_hq_all ON public.line_channels AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS lc_store_read ON public.line_channels;
CREATE POLICY lc_store_read ON public.line_channels AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (home_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)));

DROP POLICY IF EXISTS line_push_logs_tenant_read ON public.line_push_logs;
CREATE POLICY line_push_logs_tenant_read ON public.line_push_logs AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_locations ON public.locations;
CREATE POLICY auth_read_locations ON public.locations AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_member_cards ON public.member_cards;
CREATE POLICY auth_read_member_cards ON public.member_cards AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_member_imports ON public.member_imports;
CREATE POLICY auth_read_member_imports ON public.member_imports AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS mi_hq_all ON public.member_imports;
CREATE POLICY mi_hq_all ON public.member_imports AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS mlb_hq_all ON public.member_line_bindings;
CREATE POLICY mlb_hq_all ON public.member_line_bindings AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = 'hq'::text)));

DROP POLICY IF EXISTS mlb_self_read ON public.member_line_bindings;
CREATE POLICY mlb_self_read ON public.member_line_bindings AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (member_id = (NULLIF(((SELECT auth.jwt()) ->> 'member_id'::text), ''::text))::bigint)));

DROP POLICY IF EXISTS mlb_store_read ON public.member_line_bindings;
CREATE POLICY mlb_store_read ON public.member_line_bindings AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (store_id = (NULLIF(((SELECT auth.jwt()) ->> 'store_id'::text), ''::text))::bigint) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['store_manager'::text, 'store_staff'::text]))));

DROP POLICY IF EXISTS auth_read_member_merges ON public.member_merges;
CREATE POLICY auth_read_member_merges ON public.member_merges AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_member_points_balance ON public.member_points_balance;
CREATE POLICY auth_read_member_points_balance ON public.member_points_balance AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_member_tiers ON public.member_tiers;
CREATE POLICY auth_read_member_tiers ON public.member_tiers AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_members ON public.members;
CREATE POLICY auth_read_members ON public.members AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS hq_read_members ON public.members;
CREATE POLICY hq_read_members ON public.members AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'marketer'::text]))));

DROP POLICY IF EXISTS store_read_members ON public.members;
CREATE POLICY store_read_members ON public.members AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['store_manager'::text, 'clerk'::text])) AND (home_store_id = (((SELECT auth.jwt()) ->> 'location_id'::text))::bigint)));

DROP POLICY IF EXISTS aid_board_owner_delete ON public.mutual_aid_board;
CREATE POLICY aid_board_owner_delete ON public.mutual_aid_board AS PERMISSIVE FOR DELETE TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((offering_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint) OR (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text])))));

DROP POLICY IF EXISTS aid_board_owner_insert ON public.mutual_aid_board;
CREATE POLICY aid_board_owner_insert ON public.mutual_aid_board AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((offering_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint) OR (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text])))));

DROP POLICY IF EXISTS aid_board_owner_update ON public.mutual_aid_board;
CREATE POLICY aid_board_owner_update ON public.mutual_aid_board AS PERMISSIVE FOR UPDATE TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((offering_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint) OR (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text])))))
  WITH CHECK (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((offering_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint) OR (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text])))));

DROP POLICY IF EXISTS aid_board_read_all ON public.mutual_aid_board;
CREATE POLICY aid_board_read_all ON public.mutual_aid_board AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND can_see_aid_post(offering_store_id, spot_visible_to_other_stores)));

DROP POLICY IF EXISTS aid_claims_hq_all ON public.mutual_aid_claims;
CREATE POLICY aid_claims_hq_all ON public.mutual_aid_claims AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS aid_claims_store_read ON public.mutual_aid_claims;
CREATE POLICY aid_claims_store_read ON public.mutual_aid_claims AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((claiming_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint) OR (board_id IN ( SELECT mutual_aid_board.id
   FROM mutual_aid_board
  WHERE (mutual_aid_board.offering_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint))))));

DROP POLICY IF EXISTS replies_authenticated_insert ON public.mutual_aid_replies;
CREATE POLICY replies_authenticated_insert ON public.mutual_aid_replies AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (author_id = (SELECT auth.uid()))));

DROP POLICY IF EXISTS replies_read_all ON public.mutual_aid_replies;
CREATE POLICY replies_read_all ON public.mutual_aid_replies AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (EXISTS ( SELECT 1
   FROM mutual_aid_board b
  WHERE ((b.id = mutual_aid_replies.board_id) AND can_see_aid_post(b.offering_store_id, b.spot_visible_to_other_stores))))));

DROP POLICY IF EXISTS notifications_hq_all ON public.notifications;
CREATE POLICY notifications_hq_all ON public.notifications AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = 'hq'::text)));

DROP POLICY IF EXISTS notifications_self_all ON public.notifications;
CREATE POLICY notifications_self_all ON public.notifications AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (member_id = (((SELECT auth.jwt()) ->> 'member_id'::text))::bigint)));

DROP POLICY IF EXISTS oee_hq_all ON public.order_expiry_events;
CREATE POLICY oee_hq_all ON public.order_expiry_events AS PERMISSIVE FOR ALL TO authenticated
  USING (((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text) = 'hq'::text));

DROP POLICY IF EXISTS oee_store_read ON public.order_expiry_events;
CREATE POLICY oee_store_read ON public.order_expiry_events AS PERMISSIVE FOR SELECT TO authenticated
  USING (((tenant_id = ((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'tenant_id'::text))::uuid) AND (order_id IN ( SELECT customer_orders.id
   FROM customer_orders
  WHERE (customer_orders.pickup_store_id = ((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'store_id'::text))::bigint)))));

DROP POLICY IF EXISTS auth_read_order_pickup_events ON public.order_pickup_events;
CREATE POLICY auth_read_order_pickup_events ON public.order_pickup_events AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS pickup_ev_hq_read ON public.order_pickup_events;
CREATE POLICY pickup_ev_hq_read ON public.order_pickup_events AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS pickup_ev_store_read ON public.order_pickup_events;
CREATE POLICY pickup_ev_store_read ON public.order_pickup_events AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (pickup_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)));

DROP POLICY IF EXISTS ose_hq_all ON public.order_shortage_events;
CREATE POLICY ose_hq_all ON public.order_shortage_events AS PERMISSIVE FOR ALL TO authenticated
  USING (((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text) = 'hq'::text));

DROP POLICY IF EXISTS ose_store_read ON public.order_shortage_events;
CREATE POLICY ose_store_read ON public.order_shortage_events AS PERMISSIVE FOR SELECT TO authenticated
  USING (((tenant_id = ((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'tenant_id'::text))::uuid) AND (order_id IN ( SELECT customer_orders.id
   FROM customer_orders
  WHERE (customer_orders.pickup_store_id = ((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'store_id'::text))::bigint)))));

DROP POLICY IF EXISTS wl_hq_all ON public.order_waitlist;
CREATE POLICY wl_hq_all ON public.order_waitlist AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS wl_store_read ON public.order_waitlist;
CREATE POLICY wl_store_read ON public.order_waitlist AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (channel_id IN ( SELECT line_channels.id
   FROM line_channels
  WHERE (line_channels.home_store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)))));

DROP POLICY IF EXISTS pca_admin_all ON public.petty_cash_accounts;
CREATE POLICY pca_admin_all ON public.petty_cash_accounts AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS pca_store_own ON public.petty_cash_accounts;
CREATE POLICY pca_store_own ON public.petty_cash_accounts AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)));

DROP POLICY IF EXISTS pct_admin_all ON public.petty_cash_transactions;
CREATE POLICY pct_admin_all ON public.petty_cash_transactions AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS pct_store_access ON public.petty_cash_transactions;
CREATE POLICY pct_store_access ON public.petty_cash_transactions AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (account_id IN ( SELECT petty_cash_accounts.id
   FROM petty_cash_accounts
  WHERE (petty_cash_accounts.store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)))));

DROP POLICY IF EXISTS pdi_hq_all ON public.picking_draft_items;
CREATE POLICY pdi_hq_all ON public.picking_draft_items AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text, 'assistant'::text, ''::text]))))
  WITH CHECK (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text, 'assistant'::text, ''::text]))));

DROP POLICY IF EXISTS pd_hq_all ON public.picking_drafts;
CREATE POLICY pd_hq_all ON public.picking_drafts AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text, 'assistant'::text, ''::text]))))
  WITH CHECK (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text, 'assistant'::text, ''::text]))));

DROP POLICY IF EXISTS pwal_hq_read ON public.picking_wave_audit_log;
CREATE POLICY pwal_hq_read ON public.picking_wave_audit_log AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS pwi_hq_all ON public.picking_wave_items;
CREATE POLICY pwi_hq_all ON public.picking_wave_items AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'warehouse'::text]))));

DROP POLICY IF EXISTS pwi_store_read ON public.picking_wave_items;
CREATE POLICY pwi_store_read ON public.picking_wave_items AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)));

DROP POLICY IF EXISTS pw_hq_all ON public.picking_waves;
CREATE POLICY pw_hq_all ON public.picking_waves AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'warehouse'::text]))));

DROP POLICY IF EXISTS pw_store_read ON public.picking_waves;
CREATE POLICY pw_store_read ON public.picking_waves AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (id IN ( SELECT picking_wave_items.wave_id
   FROM picking_wave_items
  WHERE (picking_wave_items.store_id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)))));

DROP POLICY IF EXISTS auth_read_points_ledger ON public.points_ledger;
CREATE POLICY auth_read_points_ledger ON public.points_ledger AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS hq_full_read_pos ON public.pos_sales;
CREATE POLICY hq_full_read_pos ON public.pos_sales AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'accountant'::text]))));

DROP POLICY IF EXISTS pos_store_scope ON public.pos_sales;
CREATE POLICY pos_store_scope ON public.pos_sales AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (location_id = (((SELECT auth.jwt()) ->> 'location_id'::text))::bigint)));

DROP POLICY IF EXISTS auth_read_post_templates ON public.post_templates;
CREATE POLICY auth_read_post_templates ON public.post_templates AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS pt_hq_all ON public.post_templates;
CREATE POLICY pt_hq_all ON public.post_templates AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS read_prices_role_scoped ON public.prices;
CREATE POLICY read_prices_role_scoped ON public.prices AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((scope = ANY (ARRAY['retail'::text, 'store'::text, 'member_tier'::text, 'promo'::text])) OR ((scope = 'cost'::text) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text, ''::text]))) OR ((scope = 'branch'::text) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text, 'store_manager'::text, ''::text]))))));

DROP POLICY IF EXISTS ptm_read ON public.product_tag_map;
CREATE POLICY ptm_read ON public.product_tag_map AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS ptr_read ON public.product_tag_rules;
CREATE POLICY ptr_read ON public.product_tag_rules AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS pt_read ON public.product_tags;
CREATE POLICY pt_read ON public.product_tags AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS read_tenant_products ON public.products;
CREATE POLICY read_tenant_products ON public.products AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS read_tenant_promotions ON public.promotions;
CREATE POLICY read_tenant_promotions ON public.promotions AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS pat_admin_all ON public.purchase_approval_thresholds;
CREATE POLICY pat_admin_all ON public.purchase_approval_thresholds AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS pat_others_read ON public.purchase_approval_thresholds;
CREATE POLICY pat_others_read ON public.purchase_approval_thresholds AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_purchase_order_items ON public.purchase_order_items;
CREATE POLICY auth_read_purchase_order_items ON public.purchase_order_items AS PERMISSIVE FOR SELECT TO public
  USING ((EXISTS ( SELECT 1
   FROM purchase_orders po
  WHERE ((po.id = purchase_order_items.po_id) AND (po.tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid)))));

DROP POLICY IF EXISTS poi_hq_all ON public.purchase_order_items;
CREATE POLICY poi_hq_all ON public.purchase_order_items AS PERMISSIVE FOR ALL TO public
  USING (((EXISTS ( SELECT 1
   FROM purchase_orders po
  WHERE ((po.id = purchase_order_items.po_id) AND (po.tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid)))) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text, ''::text]))));

DROP POLICY IF EXISTS auth_read_purchase_orders ON public.purchase_orders;
CREATE POLICY auth_read_purchase_orders ON public.purchase_orders AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS po_hq_all ON public.purchase_orders;
CREATE POLICY po_hq_all ON public.purchase_orders AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text, ''::text]))));

DROP POLICY IF EXISTS purchase_full ON public.purchase_orders;
CREATE POLICY purchase_full ON public.purchase_orders AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'purchaser'::text, 'accountant'::text]))));

DROP POLICY IF EXISTS auth_read_prc ON public.purchase_request_campaigns;
CREATE POLICY auth_read_prc ON public.purchase_request_campaigns AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_write_prc ON public.purchase_request_campaigns;
CREATE POLICY auth_write_prc ON public.purchase_request_campaigns AS PERMISSIVE FOR ALL TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid))
  WITH CHECK ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_purchase_request_items ON public.purchase_request_items;
CREATE POLICY auth_read_purchase_request_items ON public.purchase_request_items AS PERMISSIVE FOR SELECT TO public
  USING ((EXISTS ( SELECT 1
   FROM purchase_requests pr
  WHERE ((pr.id = purchase_request_items.pr_id) AND (pr.tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid)))));

DROP POLICY IF EXISTS pri_hq_all ON public.purchase_request_items;
CREATE POLICY pri_hq_all ON public.purchase_request_items AS PERMISSIVE FOR ALL TO public
  USING (((EXISTS ( SELECT 1
   FROM purchase_requests pr
  WHERE ((pr.id = purchase_request_items.pr_id) AND (pr.tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid)))) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text, ''::text]))));

DROP POLICY IF EXISTS auth_read_purchase_requests ON public.purchase_requests;
CREATE POLICY auth_read_purchase_requests ON public.purchase_requests AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS pr_helper ON public.purchase_requests;
CREATE POLICY pr_helper ON public.purchase_requests AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = 'helper'::text) AND (created_by = (SELECT auth.uid()))));

DROP POLICY IF EXISTS pr_hq_all ON public.purchase_requests;
CREATE POLICY pr_hq_all ON public.purchase_requests AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text, ''::text]))));

DROP POLICY IF EXISTS pr_store_manager ON public.purchase_requests;
CREATE POLICY pr_store_manager ON public.purchase_requests AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = 'store_manager'::text) AND (source_location_id = (((SELECT auth.jwt()) ->> 'location_id'::text))::bigint)));

DROP POLICY IF EXISTS push_subs_hq_all ON public.push_subscriptions;
CREATE POLICY push_subs_hq_all ON public.push_subscriptions AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = 'hq'::text)));

DROP POLICY IF EXISTS push_subs_self_all ON public.push_subscriptions;
CREATE POLICY push_subs_self_all ON public.push_subscriptions AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (member_id = (((SELECT auth.jwt()) ->> 'member_id'::text))::bigint)));

DROP POLICY IF EXISTS hq_full_read_ar ON public.receivables;
CREATE POLICY hq_full_read_ar ON public.receivables AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'accountant'::text]))));

DROP POLICY IF EXISTS hq_admin_read ON public.reorder_rules;
CREATE POLICY hq_admin_read ON public.reorder_rules AS PERMISSIVE FOR SELECT TO authenticated
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ((SELECT auth.jwt()) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text, 'warehouse'::text, 'reporter'::text]))));

DROP POLICY IF EXISTS restock_lines_select ON public.restock_request_lines;
CREATE POLICY restock_lines_select ON public.restock_request_lines AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (request_id IN ( SELECT restock_requests.id
   FROM restock_requests))));

DROP POLICY IF EXISTS restock_select ON public.restock_requests;
CREATE POLICY restock_select ON public.restock_requests AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text, 'assistant'::text, ''::text])) OR ((COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['store_manager'::text, 'store_staff'::text])) AND (requesting_store_id = ANY (COALESCE((SELECT _jwt_store_ids()), '{}'::bigint[])))))));

DROP POLICY IF EXISTS hq_full_read_so ON public.sales_orders;
CREATE POLICY hq_full_read_so ON public.sales_orders AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'accountant'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS read_tenant_skus ON public.skus;
CREATE POLICY read_tenant_skus ON public.skus AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_spot_views ON public.spot_views;
CREATE POLICY auth_read_spot_views ON public.spot_views AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS hq_admin_read ON public.stock_balances;
CREATE POLICY hq_admin_read ON public.stock_balances AS PERMISSIVE FOR SELECT TO authenticated
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ((SELECT auth.jwt()) ->> 'role'::text), ''::text) = ANY (ARRAY['admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS hq_full_read ON public.stock_balances;
CREATE POLICY hq_full_read ON public.stock_balances AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'purchaser'::text, 'warehouse'::text, 'reporter'::text]))));

DROP POLICY IF EXISTS store_read_own ON public.stock_balances;
CREATE POLICY store_read_own ON public.stock_balances AS PERMISSIVE FOR SELECT TO authenticated
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ((SELECT auth.jwt()) ->> 'role'::text), ''::text) = ANY (ARRAY['store_manager'::text, 'store_staff'::text, 'clerk'::text])) AND (location_id = ANY (COALESCE((SELECT _jwt_store_location_ids()), '{}'::bigint[])))));

DROP POLICY IF EXISTS hq_full_read ON public.stock_movements;
CREATE POLICY hq_full_read ON public.stock_movements AS PERMISSIVE FOR SELECT TO authenticated
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ((SELECT auth.jwt()) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text, 'warehouse'::text, 'reporter'::text]))));

DROP POLICY IF EXISTS store_read_own ON public.stock_movements;
CREATE POLICY store_read_own ON public.stock_movements AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ((SELECT auth.jwt()) ->> 'role'::text), ''::text) = ANY (ARRAY['store_manager'::text, 'store_staff'::text, 'clerk'::text])) AND (location_id = ANY (COALESCE((SELECT _jwt_store_location_ids()), '{}'::bigint[])))));

DROP POLICY IF EXISTS hq_admin_read ON public.stocktake_items;
CREATE POLICY hq_admin_read ON public.stocktake_items AS PERMISSIVE FOR SELECT TO authenticated
  USING (((EXISTS ( SELECT 1
   FROM stocktakes s
  WHERE ((s.id = stocktake_items.stocktake_id) AND (s.tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid)))) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ((SELECT auth.jwt()) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'warehouse'::text, 'purchaser'::text, 'reporter'::text]))));

DROP POLICY IF EXISTS hq_admin_read ON public.stocktakes;
CREATE POLICY hq_admin_read ON public.stocktakes AS PERMISSIVE FOR SELECT TO authenticated
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ((SELECT auth.jwt()) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'warehouse'::text, 'purchaser'::text, 'reporter'::text]))));

DROP POLICY IF EXISTS slf_hq_all ON public.store_line_followers;
CREATE POLICY slf_hq_all ON public.store_line_followers AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq'::text, 'hq_manager'::text, ''::text]))));

DROP POLICY IF EXISTS slf_store_read ON public.store_line_followers;
CREATE POLICY slf_store_read ON public.store_line_followers AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY['store_manager'::text, 'store_staff'::text])) AND (EXISTS ( SELECT 1
   FROM stores s
  WHERE ((s.id = store_line_followers.store_id) AND (s.tenant_id = store_line_followers.tenant_id) AND (s.name IN ( SELECT jsonb_array_elements_text((((SELECT auth.jwt()) -> 'app_metadata'::text) -> 'stores'::text)) AS jsonb_array_elements_text)))))));

DROP POLICY IF EXISTS auth_read_smsi ON public.store_monthly_settlement_items;
CREATE POLICY auth_read_smsi ON public.store_monthly_settlement_items AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS smsi_hq_all ON public.store_monthly_settlement_items;
CREATE POLICY smsi_hq_all ON public.store_monthly_settlement_items AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS auth_read_sms ON public.store_monthly_settlements;
CREATE POLICY auth_read_sms ON public.store_monthly_settlements AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS sms_hq_all ON public.store_monthly_settlements;
CREATE POLICY sms_hq_all ON public.store_monthly_settlements AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS sms_store_read ON public.store_monthly_settlements;
CREATE POLICY sms_store_read ON public.store_monthly_settlements AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((((SELECT auth.jwt()) ->> 'store_id'::text))::bigint = store_id)));

DROP POLICY IF EXISTS auth_read_srp ON public.store_receivable_payments;
CREATE POLICY auth_read_srp ON public.store_receivable_payments AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_write_srp ON public.store_receivable_payments;
CREATE POLICY auth_write_srp ON public.store_receivable_payments AS PERMISSIVE FOR ALL TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid))
  WITH CHECK ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_sr ON public.store_receivables;
CREATE POLICY auth_read_sr ON public.store_receivables AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_write_sr ON public.store_receivables;
CREATE POLICY auth_write_sr ON public.store_receivables AS PERMISSIVE FOR ALL TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid))
  WITH CHECK ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_ssa ON public.store_settlement_adjustments;
CREATE POLICY auth_read_ssa ON public.store_settlement_adjustments AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS ssd_select ON public.store_settlement_disputes;
CREATE POLICY ssd_select ON public.store_settlement_disputes AS PERMISSIVE FOR SELECT TO authenticated
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND ((COALESCE((((SELECT auth.jwt()) -> 'app_metadata'::text) ->> 'role'::text), ''::text) = ANY (ARRAY[''::text, 'owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text])) OR (EXISTS ( SELECT 1
   FROM store_monthly_settlements s
  WHERE ((s.id = store_settlement_disputes.settlement_id) AND (s.store_id = ANY (COALESCE((SELECT _jwt_store_ids()), '{}'::bigint[])))))))));

DROP POLICY IF EXISTS auth_read_stores ON public.stores;
CREATE POLICY auth_read_stores ON public.stores AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS stores_hq_all ON public.stores;
CREATE POLICY stores_hq_all ON public.stores AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

DROP POLICY IF EXISTS stores_store_read_own ON public.stores;
CREATE POLICY stores_store_read_own ON public.stores AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)));

DROP POLICY IF EXISTS stores_store_update_own ON public.stores;
CREATE POLICY stores_store_update_own ON public.stores AS PERMISSIVE FOR UPDATE TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['store_owner'::text, 'store_manager'::text]))));

DROP POLICY IF EXISTS auth_read_supplier_skus ON public.supplier_skus;
CREATE POLICY auth_read_supplier_skus ON public.supplier_skus AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_suppliers ON public.suppliers;
CREATE POLICY auth_read_suppliers ON public.suppliers AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS tenants_self_read ON public.tenants;
CREATE POLICY tenants_self_read ON public.tenants AS PERMISSIVE FOR SELECT TO public
  USING ((id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS tsi_hq_all ON public.transfer_settlement_items;
CREATE POLICY tsi_hq_all ON public.transfer_settlement_items AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS ts_hq_all ON public.transfer_settlements;
CREATE POLICY ts_hq_all ON public.transfer_settlements AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS ts_store_read ON public.transfer_settlements;
CREATE POLICY ts_store_read ON public.transfer_settlements AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((((SELECT auth.jwt()) ->> 'store_id'::text))::bigint = store_a_id) OR ((((SELECT auth.jwt()) ->> 'store_id'::text))::bigint = store_b_id))));

DROP POLICY IF EXISTS vbi_admin_all ON public.vendor_bill_items;
CREATE POLICY vbi_admin_all ON public.vendor_bill_items AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS vb_admin_all ON public.vendor_bills;
CREATE POLICY vb_admin_all ON public.vendor_bills AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS vb_store_read ON public.vendor_bills;
CREATE POLICY vb_store_read ON public.vendor_bills AS PERMISSIVE FOR SELECT TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (supplier_id = ( SELECT stores.supplier_id
   FROM stores
  WHERE (stores.id = (((SELECT auth.jwt()) ->> 'store_id'::text))::bigint)))));

DROP POLICY IF EXISTS vpa_admin_all ON public.vendor_payment_allocations;
CREATE POLICY vpa_admin_all ON public.vendor_payment_allocations AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS vp_admin_all ON public.vendor_payments;
CREATE POLICY vp_admin_all ON public.vendor_payments AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'hq_accountant'::text]))));

DROP POLICY IF EXISTS auth_read_wallet_balances ON public.wallet_balances;
CREATE POLICY auth_read_wallet_balances ON public.wallet_balances AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS auth_read_wallet_ledger ON public.wallet_ledger;
CREATE POLICY auth_read_wallet_ledger ON public.wallet_ledger AS PERMISSIVE FOR SELECT TO public
  USING ((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid));

DROP POLICY IF EXISTS xa_admin_all ON public.xiaolan_arrivals;
CREATE POLICY xa_admin_all ON public.xiaolan_arrivals AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS xt_admin_all ON public.xiaolan_order_tracking;
CREATE POLICY xt_admin_all ON public.xiaolan_order_tracking AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS xpp_admin_all ON public.xiaolan_piaopiao;
CREATE POLICY xpp_admin_all ON public.xiaolan_piaopiao AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS xp_admin_all ON public.xiaolan_purchases;
CREATE POLICY xp_admin_all ON public.xiaolan_purchases AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS xr_admin_all ON public.xiaolan_returns;
CREATE POLICY xr_admin_all ON public.xiaolan_returns AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text, 'purchaser'::text]))));

DROP POLICY IF EXISTS xs_admin_all ON public.xiaolan_settings;
CREATE POLICY xs_admin_all ON public.xiaolan_settings AS PERMISSIVE FOR ALL TO public
  USING (((tenant_id = (((SELECT auth.jwt()) ->> 'tenant_id'::text))::uuid) AND (((SELECT auth.jwt()) ->> 'role'::text) = ANY (ARRAY['owner'::text, 'admin'::text, 'hq_manager'::text]))));

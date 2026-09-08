// tests/return-disposition/fixture.cjs
// 本機 PG18 fixture 載入器 — 總倉退回貨處理整合測試
// 硬鎖連線：127.0.0.1:56427 / returnlocal
// ⛔ 不讀 .env、不讀 DATABASE_URL、不連外部服務
'use strict';

const fs = require('fs');
const path = require('path');
const { Client } = require('pg');

// ============================================================
// 連線設定（硬鎖）
// ============================================================
const PG_HOST = '127.0.0.1';
const PG_PORT = 56427;
const PG_USER = 'returnlocal';
const PG_ADMIN_DB = 'postgres';

// ============================================================
// DB 名稱
// ============================================================
const DB_NAME_PATTERN = /^return_disposition_test_[a-z0-9_]+$/;

function getDbName() {
  const idx = process.argv.indexOf('--db-name');
  if (idx !== -1 && process.argv[idx + 1]) {
    const name = process.argv[idx + 1];
    if (!DB_NAME_PATTERN.test(name)) {
      console.error(`DB name must match ${DB_NAME_PATTERN}: got "${name}"`);
      process.exit(1);
    }
    return name;
  }
  const ts = new Date().toISOString().replace(/[-:T]/g, '').replace(/\..+/, '').toLowerCase();
  return `return_disposition_test_${ts}`;
}

const WITH_CORE = process.argv.includes('--with-core');
const WITH_ALL  = process.argv.includes('--with-all');

// ============================================================
// Migration 根目錄
// ============================================================
const MIGRATIONS_DIR = path.resolve(__dirname, '../../supabase/migrations');

// ============================================================
// 來源表：每個函式/觸發器從哪個 migration 檔案取
// key = 描述, value = { file, objects: [要取的 CREATE FUNCTION/TRIGGER 名稱] }
// ============================================================
const FUNCTION_SOURCES = [
  // --- 基底 helpers ---
  { file: '20260422120001_product_schema.sql',
    desc: 'product schema: touch_updated_at, forbid_sku_delete',
    pick: ['touch_updated_at', 'forbid_sku_delete'] },
  { file: '20260422120003_inventory_schema.sql',
    desc: 'inventory trigger/functions: apply_movement_to_balance, forbid_movement_mutation, rpc_inbound',
    pick: ['apply_movement_to_balance', 'forbid_movement_mutation', 'rpc_inbound'] },
  { file: '20260423120000_stores_order_schema.sql',
    desc: 'forbid_append_only_mutation',
    pick: ['forbid_append_only_mutation'] },
  // --- rpc_outbound 最新版（10 參數） ---
  { file: '20260705000000_dispatch_price_guard.sql',
    desc: 'rpc_outbound 10-param + _missing_dispatch_prices + _current_cost_price',
    pick: ['_missing_dispatch_prices', '_current_cost_price', 'rpc_outbound'],
    dropBefore: ['rpc_outbound(UUID, BIGINT, BIGINT, NUMERIC, TEXT, TEXT, BIGINT, UUID, BOOLEAN)'] },
  // --- rpc_create_store_return ---
  { file: '20260904020000_store_return_create_no_stock.sql',
    desc: 'rpc_create_store_return + v_store_pending_returns view',
    pick: ['rpc_create_store_return'],
    alsoViews: ['v_store_pending_returns'] },
  // --- rpc_receive_transfer ---
  { file: '20260904020010_accept_store_return_deducts_stock.sql',
    desc: 'rpc_receive_transfer (乙案：同意才扣)',
    pick: ['rpc_receive_transfer'] },
  // --- rpc_reject_transfer ---
  { file: '20260904020020_reject_store_return_no_phantom_stock.sql',
    desc: 'rpc_reject_transfer (不同意零庫存)',
    pick: ['rpc_reject_transfer'] },
  // --- shortage resolution + undo ---
  { file: '20260903000200_shortage_resolution_undo.sql',
    desc: 'rpc_resolve_transfer_item_shortage v6 + rpc_undo_transfer_item_shortage',
    pick: ['rpc_resolve_transfer_item_shortage', 'rpc_undo_transfer_item_shortage'] },
  // --- rpc_adjust_received_transfer 最新版（會連動庫存） ---
  { file: '20260904010000_adjust_received_syncs_stock.sql',
    desc: 'rpc_adjust_received_transfer v3 (庫存連動版)',
    pick: ['rpc_adjust_received_transfer'] },
  // --- unreceive ---
  { file: '20260903000010_unreceive_reverse_inbound_regardless_of_qty.sql',
    desc: 'rpc_unreceive_transfer',
    pick: ['rpc_unreceive_transfer'] },
  // --- auto accept ---
  { file: '20260903010020_return_to_hq_auto_accept.sql',
    desc: 'rpc_auto_accept_overdue_returns',
    pick: ['rpc_auto_accept_overdue_returns'] },
  // --- wave from restock ---
  { file: '20260715000020_restock_dispatch_dedup_guards.sql',
    desc: 'rpc_create_wave_from_restock',
    pick: ['rpc_create_wave_from_restock'] },
  // --- _current_tenant_id 真版（tenant status 守門） ---
  { file: '20260707000020_trial_expiry_enforcement.sql',
    desc: '_current_tenant_id (tenant status gate)',
    pick: ['_current_tenant_id'] },
  // --- _next_transfer_no 真版 ---
  { file: '20260515000002_rpc_store_self_service.sql',
    desc: '_next_transfer_no (real, from store self-service)',
    pick: ['_next_transfer_no'] },
  // --- 安全 helpers（真實定義） ---
  { file: '20260707000070_jwt_store_scope_helpers_and_stock_rls.sql',
    desc: '_jwt_store_ids + _jwt_store_location_ids (真實定義)',
    pick: ['_jwt_store_ids', '_jwt_store_location_ids'] },
  { file: '20260831000000_store_self_campaign_schema.sql',
    desc: '_is_branch_scoped_user (真實定義)',
    pick: ['_is_branch_scoped_user'] },
  // --- rpc_inbound 最新版（虛擬商品守衛） ---
  { file: '20260903000100_virtual_sku_never_enters_stock_or_pool.sql',
    desc: 'rpc_inbound latest (虛擬商品守衛)',
    pick: ['rpc_inbound'] },
];

// ============================================================
// pg-query-emscripten helpers
// ============================================================
const newParser = () => require('pg-query-emscripten').default();

/** Byte-offset slice (migration 裡有中文，String.slice 會偏移) */
function sliceStmt(buf, loc, len) {
  const from = loc ?? 0;
  // stmt_len === 0 在 protobuf 代表「到結尾」
  if (!len) return buf.slice(from).toString('utf8');
  return buf.slice(from, from + len).toString('utf8');
}

/** 取 AST 節點型別 — s.stmt 是 { CreateStmt: {...} } 這種結構 */
function stmtNodeType(s) {
  if (!s || !s.stmt) return null;
  const keys = Object.keys(s.stmt);
  return keys.length > 0 ? keys[0] : null;
}

/** 從 AST 節點提取物件名稱（function / view） */
function getObjectName(s) {
  const node = s?.stmt;
  if (!node) return null;
  const typ = stmtNodeType(s);
  if (typ === 'CreateFunctionStmt') {
    const parts = node.CreateFunctionStmt?.funcname ?? [];
    // funcname 是 [{String: {sval: 'public'}}, {String: {sval: 'fn_name'}}] 結構
    const last = parts[parts.length - 1];
    return last?.String?.sval ?? last?.String?.str ?? null;
  }
  if (typ === 'ViewStmt') {
    const rel = node.ViewStmt?.view;
    return rel?.relname ?? null;
  }
  return null;
}

// ============================================================
// 從 migration 檔以 pg-query-emscripten AST 拆出指定物件的 SQL
// ============================================================
async function extractStatements(filePath, pickNames, opts = {}) {
  const sql = fs.readFileSync(filePath, 'utf8');
  const buf = Buffer.from(sql, 'utf8');
  const PgQuery = await newParser();
  const res = PgQuery.parse(sql);
  if (res.error) {
    throw new Error(`Parse error in ${filePath}: ${res.error.message}`);
  }
  const stmts = res.parse_tree?.stmts ?? [];

  const results = [];
  const pickSet = new Set(pickNames.map(n => n.toLowerCase()));
  const viewSet = opts.alsoViews ? new Set(opts.alsoViews.map(n => n.toLowerCase())) : new Set();

  for (const s of stmts) {
    const text = sliceStmt(buf, s.stmt_location, s.stmt_len).trim();
    const typ = stmtNodeType(s);
    const name = getObjectName(s);

    if (typ === 'CreateFunctionStmt' && name && pickSet.has(name.toLowerCase())) {
      results.push({ type: 'function', name, sql: text });
    } else if (typ === 'ViewStmt' && name && viewSet.has(name.toLowerCase())) {
      results.push({ type: 'view', name, sql: text });
    }
  }
  return results;
}

// ============================================================
// 從 migration 檔萃取 schema DDL（CREATE TABLE/INDEX/TRIGGER/SEQUENCE/ALTER TABLE + FUNCTION）
// 用 AST 節點型別判定，不用 regex
// ============================================================
const SCHEMA_NODE_TYPES = new Set([
  'CreateStmt',         // CREATE TABLE
  'IndexStmt',          // CREATE INDEX / CREATE UNIQUE INDEX
  'CreateTrigStmt',     // CREATE TRIGGER
  'CreateSeqStmt',      // CREATE SEQUENCE
  'AlterTableStmt',     // ALTER TABLE (ADD COLUMN / ADD CONSTRAINT / DROP CONSTRAINT)
  'CreateFunctionStmt', // CREATE [OR REPLACE] FUNCTION
  'CommentStmt',        // COMMENT ON (跳過 — 非必要)
]);

// RLS / POLICY / GRANT / REVOKE 節點型別
const SKIP_NODE_TYPES = new Set([
  'CreatePolicyStmt',       // CREATE POLICY
  'GrantStmt',              // GRANT / REVOKE
  'AlterDefaultPrivilegesStmt',
]);

function isRlsAlter(s, text) {
  // ALTER TABLE ... ENABLE ROW LEVEL SECURITY 也是 AlterTableStmt，要跳過
  if (stmtNodeType(s) === 'AlterTableStmt' && /ENABLE\s+ROW\s+LEVEL\s+SECURITY/i.test(text)) return true;
  return false;
}

async function extractSchemaStatements(filePath) {
  const sql = fs.readFileSync(filePath, 'utf8');
  const buf = Buffer.from(sql, 'utf8');
  const PgQuery = await newParser();
  const res = PgQuery.parse(sql);
  if (res.error) {
    throw new Error(`Parse error in ${filePath}: ${res.error.message}`);
  }
  const stmts = res.parse_tree?.stmts ?? [];
  const results = [];
  for (const s of stmts) {
    const text = sliceStmt(buf, s.stmt_location, s.stmt_len).trim();
    const typ = stmtNodeType(s);
    if (!text) continue;
    if (SKIP_NODE_TYPES.has(typ)) continue;
    if (isRlsAlter(s, text)) continue;
    // COMMENT ON FUNCTION 會找不到函式（函式還沒建）—— 非必要，跳過
    if (typ === 'CommentStmt') continue;
    if (SCHEMA_NODE_TYPES.has(typ)) {
      results.push({ text, nodeType: typ });
    }
  }
  return results;
}

// --with-all 的月結前置只准從指定 migration 挑出指定 AST statement。
// 每個 selector 必須剛好命中一筆；找不到或重複都 fail，避免誤載同檔舊版財務 RPC。
async function extractSelectedStatements(filePath, selectors) {
  const sql = fs.readFileSync(filePath, 'utf8');
  const buf = Buffer.from(sql, 'utf8');
  const PgQuery = await newParser();
  const res = PgQuery.parse(sql);
  if (res.error) {
    throw new Error(`Parse error in ${filePath}: ${res.error.message}`);
  }
  const stmts = (res.parse_tree?.stmts ?? []).map((s) => ({
    nodeType: stmtNodeType(s),
    name: getObjectName(s),
    text: sliceStmt(buf, s.stmt_location, s.stmt_len).trim(),
  }));

  return selectors.map((selector) => {
    const matches = stmts.filter((stmt) =>
      stmt.nodeType === selector.nodeType
      && (!selector.name || stmt.name?.toLowerCase() === selector.name.toLowerCase())
      && (!selector.match || selector.match.test(stmt.text))
    );
    if (matches.length !== 1) {
      throw new Error(
        `Expected exactly one ${selector.desc} in ${path.basename(filePath)}, found ${matches.length}`,
      );
    }
    return matches[0];
  });
}

const SETTLEMENT_PREREQ_SOURCES = [
  {
    file: '20260512000012_settlement_air_transfer_adjustment.sql',
    desc: 'settlement items entry_type 基底欄位',
    selectors: [
      { nodeType: 'AlterTableStmt', match: /ADD COLUMN IF NOT EXISTS entry_type\s+TEXT NOT NULL DEFAULT 'hq_inbound'/i, desc: 'entry_type column DDL' },
    ],
  },
  {
    file: '20260512000013_settlement_items_trigger_allow_draft.sql',
    desc: 'draft 月結明細可重建 trigger',
    selectors: [
      { nodeType: 'DropStmt', match: /DROP TRIGGER IF EXISTS trg_no_mut_smsi/i, desc: 'old immutable trigger drop' },
      { nodeType: 'CreateFunctionStmt', name: 'forbid_smsi_mutation_when_locked', desc: 'draft-aware item mutation function' },
      { nodeType: 'CreateTrigStmt', match: /CREATE TRIGGER trg_smsi_immutable_when_locked/i, desc: 'draft-aware item mutation trigger' },
    ],
  },
  {
    file: '20260714000100_settlement_free_transfer_and_return.sql',
    desc: '六種月結明細類型與描述欄',
    selectors: [
      { nodeType: 'AlterTableStmt', match: /DROP CONSTRAINT IF EXISTS store_monthly_settlement_items_entry_type_check/i, desc: 'old entry_type check drop' },
      { nodeType: 'AlterTableStmt', match: /DROP CONSTRAINT IF EXISTS smsi_entry_type_check_v2/i, desc: 'v2 entry_type check drop' },
      { nodeType: 'AlterTableStmt', match: /ADD CONSTRAINT smsi_entry_type_check_v2[\s\S]*'return_out'/i, desc: 'six-way entry_type check' },
      { nodeType: 'AlterTableStmt', match: /ADD COLUMN IF NOT EXISTS description TEXT/i, desc: 'settlement item description column' },
    ],
  },
  {
    file: '20260715000000_settlement_dual_price_basis.sql',
    desc: '月結雙口徑欄位與分店價 helper',
    selectors: [
      { nodeType: 'AlterTableStmt', match: /ADD COLUMN IF NOT EXISTS cost_amount[\s\S]*ADD COLUMN IF NOT EXISTS branch_amount/i, desc: 'settlement dual total columns' },
      { nodeType: 'AlterTableStmt', match: /ADD COLUMN IF NOT EXISTS unit_branch_price[\s\S]*ADD COLUMN IF NOT EXISTS branch_amount/i, desc: 'settlement item branch columns' },
      { nodeType: 'CreateFunctionStmt', name: '_branch_price_at', desc: '_branch_price_at function' },
    ],
  },
  {
    file: '20260801000000_settlement_manual_adjustment.sql',
    desc: '人工調整總額欄與真資料表',
    selectors: [
      { nodeType: 'AlterTableStmt', match: /ADD COLUMN IF NOT EXISTS adjustment_amount/i, desc: 'settlement adjustment total column' },
      { nodeType: 'CreateStmt', match: /CREATE TABLE IF NOT EXISTS public\.store_settlement_adjustments/i, desc: 'store_settlement_adjustments table' },
    ],
  },
  {
    file: '20260825030000_settlement_ship_time_matching.sql',
    desc: '店間轉貨真記帳 view',
    selectors: [
      { nodeType: 'ViewStmt', name: 'v_store_aid_transfer_legs', desc: 'v_store_aid_transfer_legs view' },
    ],
  },
];

// ============================================================
// Auth stub SQL — sub 缺值回 NULL，不冒充全零 user
// ============================================================
const AUTH_STUB_SQL = `
-- Stub auth schema for local testing
CREATE SCHEMA IF NOT EXISTS auth;

-- Session variables to simulate auth.uid() and auth.jwt()
-- Usage: SET LOCAL "request.jwt.claim.sub" = '<uuid>';
--        SET LOCAL "request.jwt.claims" = '<json>';

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::UUID
$$;

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::JSONB,
    '{}'::JSONB
  )
$$;

-- Minimal auth.users stub (FK target only)
CREATE TABLE IF NOT EXISTS auth.users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_app_meta_data JSONB DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Roles for RLS testing
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA auth   TO authenticated, anon, service_role;
GRANT USAGE ON SCHEMA public TO authenticated, anon, service_role;
`;

// ============================================================
// FK-stub 表（被函式 FK 參照但本測不關心的表，只建最小 DDL）
// ============================================================
const FK_STUB_SQL = `
-- FK stub tables: minimal DDL for tables referenced by FK but not under test

CREATE TABLE IF NOT EXISTS suppliers (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  code TEXT,
  name TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS members (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID,
  name TEXT,
  phone TEXT,
  email TEXT,
  birthday DATE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS purchase_orders (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID,
  po_no TEXT,
  status TEXT DEFAULT 'draft',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS purchase_requests (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID,
  status TEXT DEFAULT 'draft',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS purchase_request_items (
  id BIGSERIAL PRIMARY KEY,
  pr_id BIGINT REFERENCES purchase_requests(id),
  po_item_id BIGINT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS purchase_order_items (
  id BIGSERIAL PRIMARY KEY,
  po_id BIGINT REFERENCES purchase_orders(id),
  sku_id BIGINT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS vendor_bills (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID,
  bill_no TEXT,
  supplier_id BIGINT,
  source_type TEXT CHECK (source_type = ANY(ARRAY[
    'purchase_order','goods_receipt','transfer_settlement',
    'store_monthly_settlement','xiaolan_import','manual'
  ])),
  source_id BIGINT,
  bill_date DATE,
  due_date DATE,
  amount NUMERIC(18,4),
  status TEXT DEFAULT 'pending',
  currency TEXT DEFAULT 'TWD',
  notes TEXT,
  created_by UUID,
  updated_by UUID,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS vendor_payments (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pos_sales (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- tenants 表（_current_tenant_id 真版需要）
CREATE TABLE IF NOT EXISTS tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL DEFAULT 'test',
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('trial','active','suspended','deleted')),
  is_protected BOOLEAN NOT NULL DEFAULT FALSE,
  trial_started_at TIMESTAMPTZ,
  trial_expires_at TIMESTAMPTZ,
  contact_email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  purged_at TIMESTAMPTZ
);
`;

// ============================================================
// Helper stubs：被函式引用但本測不需要真實邏輯的 helpers
// 分兩類：
//   ✅ 可 no-op（通知類、配單查詢類）
//   ⛔ RAISE（會動庫存/訂單/帳，不可假成功）
// trim_scale 是本機 PostgreSQL 18 內建函式，不由 fixture stub。
// ============================================================
const HELPER_STUBS_SQL = `
-- sequences referenced by real functions
CREATE SEQUENCE IF NOT EXISTS transfer_no_seq;
CREATE SEQUENCE IF NOT EXISTS public.picking_wave_code_seq;

-- ensure_store_supplier: 真實邏輯太簡單可 stub
CREATE OR REPLACE FUNCTION public.ensure_store_supplier(p_store_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$;

-- ✅ 通知類 no-op（不動資料，只是通知/查詢）
CREATE OR REPLACE FUNCTION public.is_order_pickup_ready(p_order_id BIGINT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN RETURN FALSE; END; $$;

CREATE OR REPLACE FUNCTION public._restock_wave_progress(p_rr_id BIGINT)
RETURNS TABLE(fully_dispatched BOOLEAN, all_arrived BOOLEAN)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY SELECT FALSE, FALSE;
END; $$;

-- ⛔ rpc_mark_orders_shipping_for_wave 會改訂單狀態為 shipping，不可假成功
CREATE OR REPLACE FUNCTION public.rpc_mark_orders_shipping_for_wave(
  p_wave_id BIGINT, p_operator UUID
) RETURNS VOID LANGUAGE plpgsql AS $$ BEGIN
  RAISE EXCEPTION 'fixture 未實作 rpc_mark_orders_shipping_for_wave — 會動訂單狀態';
END; $$;

-- ⛔ 會動庫存/訂單/帳的 helper — RAISE 讓測試 fail，不假成功
CREATE OR REPLACE FUNCTION public._settle_arrived_backorders(
  p_store_id BIGINT, p_skus BIGINT[], p_operator UUID, p_now TIMESTAMPTZ
) RETURNS INTEGER LANGUAGE plpgsql AS $$ BEGIN
  RAISE EXCEPTION 'fixture 未實作 _settle_arrived_backorders — 需要時請載入真實定義';
END; $$;

CREATE OR REPLACE FUNCTION public._advance_arrived_confirmed_orders(
  p_store_id BIGINT, p_skus BIGINT[], p_operator UUID, p_now TIMESTAMPTZ
) RETURNS INTEGER LANGUAGE plpgsql AS $$ BEGIN
  RAISE EXCEPTION 'fixture 未實作 _advance_arrived_confirmed_orders — 需要時請載入真實定義';
END; $$;

CREATE OR REPLACE FUNCTION public._settle_restock_ride_along(
  p_rr_id BIGINT, p_operator UUID, p_now TIMESTAMPTZ
) RETURNS VOID LANGUAGE plpgsql AS $$ BEGIN
  RAISE EXCEPTION 'fixture 未實作 _settle_restock_ride_along — 需要時請載入真實定義';
END; $$;

CREATE OR REPLACE FUNCTION public._grow_internal_pool(
  p_store BIGINT, p_sku BIGINT, p_received NUMERIC,
  p_operator UUID, p_now TIMESTAMPTZ, p_note TEXT
) RETURNS NUMERIC LANGUAGE plpgsql AS $$ BEGIN
  RAISE EXCEPTION 'fixture 未實作 _grow_internal_pool — 需要時請載入真實定義';
END; $$;
`;

// ============================================================
// Fixture 假資料
// ============================================================
const FIXTURE_DATA_SQL = `
-- ============================================================
-- Fixture data: minimal set for return-disposition testing
-- ============================================================

-- 設定 auth session（假 JWT）
SET LOCAL "request.jwt.claims" = '{"tenant_id":"11111111-1111-1111-1111-111111111111","role":"owner","app_metadata":{"role":"owner"}}';
SET LOCAL "request.jwt.claim.sub" = '22222222-2222-2222-2222-222222222222';

-- Tenant
INSERT INTO tenants (id, name, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'test-tenant', 'active');

-- Auth user
INSERT INTO auth.users (id, raw_app_meta_data) VALUES
  ('22222222-2222-2222-2222-222222222222', '{"tenant_id":"11111111-1111-1111-1111-111111111111","role":"owner"}');

-- Products (is_virtual 欄位在 column additions 加)
INSERT INTO products (id, tenant_id, product_code, name, status) VALUES
  (1, '11111111-1111-1111-1111-111111111111', 'P-GOOD', '一般商品', 'active'),
  (2, '11111111-1111-1111-1111-111111111111', 'P-OTHER', '另一商品', 'active'),
  (3, '11111111-1111-1111-1111-111111111111', 'P-VIRTUAL', '虛擬商品', 'active');
SELECT setval('products_id_seq', 3);

UPDATE products SET is_virtual = TRUE WHERE id = 3;

-- SKUs (product_name 是 denormalized 欄位)
INSERT INTO skus (id, tenant_id, product_id, sku_code, product_name, status) VALUES
  (101, '11111111-1111-1111-1111-111111111111', 1, 'SKU-GOOD', '一般商品', 'active'),
  (102, '11111111-1111-1111-1111-111111111111', 2, 'SKU-OTHER', '另一商品', 'active'),
  (103, '11111111-1111-1111-1111-111111111111', 3, 'MISC-01', '虛擬商品', 'active');
SELECT setval('skus_id_seq', 103);

-- Locations: HQ + 2 stores
INSERT INTO locations (id, tenant_id, code, name, type) VALUES
  (10, '11111111-1111-1111-1111-111111111111', 'HQ', '總倉', 'central_warehouse'),
  (20, '11111111-1111-1111-1111-111111111111', 'STORE-A', 'A店', 'store'),
  (30, '11111111-1111-1111-1111-111111111111', 'STORE-B', 'B店', 'store');
SELECT setval('locations_id_seq', 30);

-- Suppliers stub
INSERT INTO suppliers (id, tenant_id, code, name) VALUES
  (1, '11111111-1111-1111-1111-111111111111', 'SUP-SELF', '自家供應商');
SELECT setval('suppliers_id_seq', 1);

-- Stores: A, B
INSERT INTO stores (id, tenant_id, code, name, location_id, supplier_id) VALUES
  (1, '11111111-1111-1111-1111-111111111111', 'A', 'A店', 20, 1),
  (2, '11111111-1111-1111-1111-111111111111', 'B', 'B店', 30, 1);
SELECT setval('stores_id_seq', 2);

-- Prices: cost + branch for SKU-GOOD (避免 dispatch price guard 擋)
INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price, created_by) VALUES
  ('11111111-1111-1111-1111-111111111111', 101, 'cost', NULL, 100.0000, '22222222-2222-2222-2222-222222222222'),
  ('11111111-1111-1111-1111-111111111111', 101, 'branch', NULL, 150.0000, '22222222-2222-2222-2222-222222222222'),
  ('11111111-1111-1111-1111-111111111111', 102, 'cost', NULL, 80.0000, '22222222-2222-2222-2222-222222222222'),
  ('11111111-1111-1111-1111-111111111111', 102, 'branch', NULL, 120.0000, '22222222-2222-2222-2222-222222222222');

-- HQ stock_balances: 用 rpc_inbound 建立，讓 trigger 正確維護
SELECT rpc_inbound(
  '11111111-1111-1111-1111-111111111111', 10, 101, 20, 100.0000,
  'purchase_receipt', 'fixture', NULL, '22222222-2222-2222-2222-222222222222'
);
SELECT rpc_inbound(
  '11111111-1111-1111-1111-111111111111', 10, 102, 10, 80.0000,
  'purchase_receipt', 'fixture', NULL, '22222222-2222-2222-2222-222222222222'
);
SELECT rpc_inbound(
  '11111111-1111-1111-1111-111111111111', 20, 101, 10, 100.0000,
  'purchase_receipt', 'fixture', NULL, '22222222-2222-2222-2222-222222222222'
);
SELECT rpc_inbound(
  '11111111-1111-1111-1111-111111111111', 30, 101, 5, 100.0000,
  'purchase_receipt', 'fixture', NULL, '22222222-2222-2222-2222-222222222222'
);

-- 一筆已收但短收的 hq_to_store transfer（測 shortage resolution）
INSERT INTO transfers (id, tenant_id, transfer_no, source_location, dest_location,
  status, transfer_type, shipped_by, shipped_at, received_by, received_at,
  created_by, updated_by) VALUES
  (900, '11111111-1111-1111-1111-111111111111', 'WAVE-TEST-S1', 10, 20,
   'received', 'hq_to_store', '22222222-2222-2222-2222-222222222222', NOW() - INTERVAL '3 days',
   '22222222-2222-2222-2222-222222222222', NOW() - INTERVAL '2 days',
   '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222');
SELECT setval('transfers_id_seq', 900);

-- 出庫異動（給 transfer_items.out_movement_id 參照）
INSERT INTO stock_movements (id, tenant_id, location_id, sku_id, quantity, unit_cost,
  movement_type, source_doc_type, source_doc_id, operator_id) VALUES
  (8000, '11111111-1111-1111-1111-111111111111', 10, 101, -5, 100.0000,
   'transfer_out', 'transfer', 900, '22222222-2222-2222-2222-222222222222');
-- 入庫異動
INSERT INTO stock_movements (id, tenant_id, location_id, sku_id, quantity, unit_cost,
  movement_type, source_doc_type, source_doc_id, operator_id) VALUES
  (8001, '11111111-1111-1111-1111-111111111111', 20, 101, 3, 100.0000,
   'transfer_in', 'transfer', 900, '22222222-2222-2222-2222-222222222222');
SELECT setval('stock_movements_id_seq', 8001);

INSERT INTO transfer_items (id, transfer_id, sku_id, qty_requested, qty_shipped, qty_received,
  out_movement_id, in_movement_id, created_by, updated_by) VALUES
  (9000, 900, 101, 5, 5, 3,
   8000, 8001, '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222');
SELECT setval('transfer_items_id_seq', 9000);

-- 鎖月 settlement（測已鎖月份不可改）
INSERT INTO store_monthly_settlements (tenant_id, settlement_month, store_id,
  payable_amount, transfer_count, item_count, status,
  confirmed_at, confirmed_by, created_by, updated_by) VALUES
  ('11111111-1111-1111-1111-111111111111',
   DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE,
   1, 5000.0000, 2, 3, 'confirmed',
   NOW() - INTERVAL '10 days', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222');

-- 驗證 fixture 載入
DO $$
DECLARE v_cnt INT;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM stock_balances
   WHERE tenant_id = '11111111-1111-1111-1111-111111111111'
     AND location_id = 10 AND sku_id = 101;
  ASSERT v_cnt = 1, 'HQ stock_balances for SKU-GOOD should exist';

  SELECT on_hand INTO v_cnt FROM stock_balances
   WHERE tenant_id = '11111111-1111-1111-1111-111111111111'
     AND location_id = 10 AND sku_id = 101;
  -- HQ(10): 20 (fixture inbound) + (-5) (movement 8000 trigger) = 15
  -- A店(20): 10 (fixture inbound) + 3 (movement 8001 trigger) = 13
  RAISE NOTICE 'Fixture loaded: HQ SKU-GOOD on_hand = %', v_cnt;
END;
$$;

SELECT 'Fixture data loaded successfully' AS status;
`;

// ============================================================
// Schema loading: 按順序載入表 DDL
// ============================================================
const SCHEMA_FILES = [
  // 基底表（按 FK 順序）
  { file: '20260422120001_product_schema.sql', desc: 'products/skus/prices/categories/brands + triggers' },
  { file: '20260422120003_inventory_schema.sql', desc: 'locations/stock_balances/stock_movements/transfers/transfer_items + triggers + indexes' },
  { file: '20260423120000_stores_order_schema.sql', desc: 'stores/customer_orders/customer_order_items + related' },
  { file: '20260423120002_picking_waves.sql', desc: 'picking_waves/picking_wave_items + related' },
  { file: '20260512000009_store_monthly_settlement.sql', desc: 'store_monthly_settlements' },
  { file: '20260515000001_restock_requests_schema.sql', desc: 'restock_requests/restock_request_lines' },
];

// Column additions (ALTER TABLE ADD COLUMN) in order
const COLUMN_ADDITIONS = [
  // products.is_virtual
  { sql: "ALTER TABLE products ADD COLUMN IF NOT EXISTS is_virtual BOOLEAN NOT NULL DEFAULT FALSE" },
  // transfers.transfer_type
  { sql: "ALTER TABLE transfers ADD COLUMN IF NOT EXISTS transfer_type TEXT NOT NULL DEFAULT 'store_to_store' CHECK (transfer_type IN ('store_to_store','return_to_hq','hq_to_store'))" },
  // transfers.customer_order_id
  { sql: "ALTER TABLE transfers ADD COLUMN IF NOT EXISTS customer_order_id BIGINT REFERENCES customer_orders(id)" },
  // transfers.next_transfer_id
  { sql: "ALTER TABLE transfers ADD COLUMN IF NOT EXISTS next_transfer_id BIGINT REFERENCES transfers(id)" },
  // transfers.is_air_transfer
  { sql: "ALTER TABLE transfers ADD COLUMN IF NOT EXISTS is_air_transfer BOOLEAN NOT NULL DEFAULT FALSE" },
  // transfer_items.description
  { sql: "ALTER TABLE transfer_items ADD COLUMN IF NOT EXISTS description TEXT" },
  // transfer_items.estimated_amount
  { sql: "ALTER TABLE transfer_items ADD COLUMN IF NOT EXISTS estimated_amount NUMERIC(18,4)" },
  // transfer_items.shortage_resolution + related
  { sql: `ALTER TABLE transfer_items
    ADD COLUMN IF NOT EXISTS shortage_resolution TEXT,
    ADD COLUMN IF NOT EXISTS shortage_resolution_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS shortage_resolution_by UUID,
    ADD COLUMN IF NOT EXISTS shortage_resolution_notes TEXT` },
  // transfer_items.shortage_restock_movement_id
  { sql: "ALTER TABLE transfer_items ADD COLUMN IF NOT EXISTS shortage_restock_movement_id BIGINT" },
  // transfer_items.shortage_redispatch_wave_id
  { sql: "ALTER TABLE transfer_items ADD COLUMN IF NOT EXISTS shortage_redispatch_wave_id BIGINT REFERENCES picking_waves(id)" },
  // transfer_items.shortage_return_transfer_id
  { sql: "ALTER TABLE transfer_items ADD COLUMN IF NOT EXISTS shortage_return_transfer_id BIGINT REFERENCES transfers(id)" },
  // transfer_items.shortage_prev_qty_received (20260903000200)
  { sql: "ALTER TABLE transfer_items ADD COLUMN IF NOT EXISTS shortage_prev_qty_received NUMERIC(18,3)" },
  // shortage_resolution CHECK (latest: 20260903000020)
  { sql: `ALTER TABLE transfer_items DROP CONSTRAINT IF EXISTS transfer_items_shortage_resolution_check` },
  { sql: `ALTER TABLE transfer_items ADD CONSTRAINT transfer_items_shortage_resolution_check
    CHECK (shortage_resolution IS NULL OR shortage_resolution = ANY (ARRAY[
      'replenish','cancel_orders','vendor_claim','accept',
      'restock_hq','redispatch','over_ack','reject_return'
    ]))` },
  // stock_movements: latest movement_type CHECK (20260713000000)
  { sql: "ALTER TABLE stock_movements DROP CONSTRAINT IF EXISTS stock_movements_movement_type_check" },
  { sql: `ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_movement_type_check CHECK (
    movement_type = ANY (ARRAY[
      'purchase_receipt','return_to_supplier','sale','customer_return',
      'transfer_out','transfer_in','transfer_reject','transfer_cancel',
      'stocktake_gain','stocktake_loss','damage','manual_adjust','reversal'
    ]))` },
  // picking_waves.source_po_id
  { sql: "ALTER TABLE picking_waves ADD COLUMN IF NOT EXISTS source_po_id BIGINT" },
  // picking_waves.source_restock_request_id
  { sql: "ALTER TABLE picking_waves ADD COLUMN IF NOT EXISTS source_restock_request_id BIGINT" },
  // customer_orders.order_kind 型別/default 原樣取自 20260516000000，CHECK 取最新 20260612000020
  { sql: `ALTER TABLE customer_orders
    ADD COLUMN IF NOT EXISTS order_kind TEXT NOT NULL DEFAULT 'normal'
      CHECK (order_kind IN ('normal', 'offset'))` },
  { sql: "ALTER TABLE public.customer_orders DROP CONSTRAINT IF EXISTS customer_orders_order_kind_check" },
  { sql: `ALTER TABLE public.customer_orders ADD CONSTRAINT customer_orders_order_kind_check
    CHECK (order_kind = ANY (ARRAY['normal'::text, 'offset'::text, 'restock'::text]))` },
  // approved_transfer 走 wave 時 linked_transfer_id 可為 NULL；原樣取自 20260612000060
  { sql: "ALTER TABLE public.restock_requests DROP CONSTRAINT IF EXISTS restock_requests_check" },
  { sql: `ALTER TABLE public.restock_requests
    ADD CONSTRAINT restock_requests_check CHECK (
      (status <> 'approved_pr' OR linked_pr_id IS NOT NULL) AND
      (status <> 'rejected'    OR rejected_reason IS NOT NULL)
    )` },
  // 月結狀態最新 CHECK；原樣取自 20260715000120
  { sql: "ALTER TABLE public.store_monthly_settlements DROP CONSTRAINT IF EXISTS store_monthly_settlements_status_check" },
  { sql: "ALTER TABLE public.store_monthly_settlements DROP CONSTRAINT IF EXISTS sms_status_check_v2" },
  { sql: `ALTER TABLE public.store_monthly_settlements
    ADD CONSTRAINT sms_status_check_v2
      CHECK (status IN ('draft','sent','disputed','confirmed','remitted','settled','cancelled'))` },
  // restock_request_lines.cancelled_at (referenced by rpc_receive_transfer D2 logic)
  { sql: "ALTER TABLE restock_request_lines ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ" },
  // customer_orders extra columns
  { sql: "ALTER TABLE customer_orders ADD COLUMN IF NOT EXISTS ready_at TIMESTAMPTZ" },
  { sql: "ALTER TABLE customer_orders ADD COLUMN IF NOT EXISTS shortage_resolution TEXT" },
  { sql: "ALTER TABLE customer_orders ADD COLUMN IF NOT EXISTS shortage_resolution_at TIMESTAMPTZ" },
  { sql: "ALTER TABLE customer_orders ADD COLUMN IF NOT EXISTS shortage_resolution_by UUID" },
  // customer_order_items.backorder_at
  { sql: "ALTER TABLE customer_order_items ADD COLUMN IF NOT EXISTS backorder_at TIMESTAMPTZ" },
  // prices.scope: 擴充加 cost/branch（20260514000000）
  { sql: "ALTER TABLE prices DROP CONSTRAINT IF EXISTS prices_scope_check" },
  { sql: "ALTER TABLE prices ADD CONSTRAINT prices_scope_check CHECK (scope IN ('retail','store','member_tier','promo','cost','branch'))" },
];

// ============================================================
// Main
// ============================================================
async function main() {
  const dbName = getDbName();
  console.log(`Creating test database: ${dbName}`);
  console.log(`Connection: ${PG_USER}@${PG_HOST}:${PG_PORT}`);

  // Step 1: Create the database
  const adminClient = new Client({
    host: PG_HOST, port: PG_PORT, user: PG_USER, database: PG_ADMIN_DB
  });
  await adminClient.connect();
  const existing = await adminClient.query(
    `SELECT 1 FROM pg_database WHERE datname = $1`, [dbName]);
  if (existing.rows.length > 0) {
    console.error(`Database ${dbName} already exists, pick a different name or timestamp`);
    await adminClient.end();
    process.exit(1);
  }
  await adminClient.query(`CREATE DATABASE ${dbName}`);
  console.log(`  ✓ Database created`);
  await adminClient.end();

  // Step 2: Connect to new DB and load schema
  const client = new Client({
    host: PG_HOST, port: PG_PORT, user: PG_USER, database: dbName
  });
  await client.connect();

  try {
    // 2a. Auth stub
    console.log('  Loading auth stub...');
    await client.query(AUTH_STUB_SQL);

    // 2b. FK stub tables
    console.log('  Loading FK stub tables...');
    await client.query(FK_STUB_SQL);

    // 2c. Schema DDL from real migrations (AST 節點型別判定)
    for (const schema of SCHEMA_FILES) {
      const filePath = path.join(MIGRATIONS_DIR, schema.file);
      if (!fs.existsSync(filePath)) {
        console.error(`  ✗ Migration file not found: ${schema.file}`);
        process.exit(1);
      }
      console.log(`  Loading schema: ${schema.desc} (${schema.file})`);
      const stmts = await extractSchemaStatements(filePath);
      let loaded = 0;
      for (const { text: stmt, nodeType } of stmts) {
        try {
          await client.query(stmt);
          loaded++;
        } catch (e) {
          // 只允許 "already exists"（IF NOT EXISTS 語義）
          if (e.message.includes('already exists')) {
            console.log(`    ⚠ Already exists (${e.message.slice(0, 80)})`);
          } else {
            console.error(`    ✗ Failed [${nodeType}]: ${stmt.slice(0, 120)}`);
            console.error(`      ${e.message}`);
            throw e;
          }
        }
      }
      console.log(`    ✓ ${loaded} statements`);
    }

    // 2d. Column additions
    console.log('  Applying column additions...');
    for (const col of COLUMN_ADDITIONS) {
      try {
        await client.query(col.sql);
      } catch (e) {
        if (e.message.includes('already exists')) {
          // IF NOT EXISTS 允許
        } else {
          console.error(`    ✗ Column addition failed: ${col.sql.slice(0, 80)}`);
          console.error(`      ${e.message}`);
          throw e;
        }
      }
    }
    console.log('    ✓ Column additions applied');

    // 2e. Helper stubs
    console.log('  Loading helper stubs...');
    await client.query(HELPER_STUBS_SQL);
    console.log('    ✓ Helpers loaded');

    // 2f. Real functions from migration files (using AST extraction)
    for (const src of FUNCTION_SOURCES) {
      const filePath = path.join(MIGRATIONS_DIR, src.file);
      if (!fs.existsSync(filePath)) {
        console.error(`  ✗ Migration file not found: ${src.file}`);
        process.exit(1);
      }
      console.log(`  Loading functions: ${src.desc}`);
      console.log(`    Source: ${src.file}`);

      // Drop old overloads if specified
      if (src.dropBefore) {
        for (const sig of src.dropBefore) {
          try {
            await client.query(`DROP FUNCTION IF EXISTS ${sig}`);
          } catch (e) {
            console.log(`    ⚠ Drop: ${e.message.slice(0, 80)}`);
          }
        }
      }

      const extracted = await extractStatements(filePath, src.pick, {
        alsoViews: src.alsoViews
      });

      // 驗證每個 pick 都找到了（不能總長>0 就當全找到）
      const allPicks = [...src.pick, ...(src.alsoViews || [])];
      const foundNames = new Set(extracted.map(e => e.name.toLowerCase()));
      const missing = allPicks.filter(p => !foundNames.has(p.toLowerCase()));
      if (missing.length > 0) {
        console.error(`    ✗ Missing objects in ${src.file}: ${missing.join(', ')}`);
        console.error(`      Found: ${[...foundNames].join(', ') || '(none)'}`);
        process.exit(1);
      }

      for (const item of extracted) {
        try {
          await client.query(item.sql);
          console.log(`    ✓ ${item.type}: ${item.name}`);
        } catch (e) {
          console.error(`    ✗ ${item.type} ${item.name}: ${e.message}`);
          throw e;
        }
      }
    }

    // 2g. --with-core: load HQ return disposition migrations (明確檔名)
    if (WITH_CORE && !WITH_ALL) {
      const coreFiles = [
        '20260907010000_hq_return_disposition_core.sql',      // A: 資料與處理
        '20260907020000_hq_return_disposition_sources.sql',   // B: 來源函式
      ];
      for (const cf of coreFiles) {
        const cfPath = path.join(MIGRATIONS_DIR, cf);
        if (!fs.existsSync(cfPath)) {
          console.error(`  ✗ --with-core: ${cf} not found. Has it been generated?`);
          process.exit(1);
        }
        console.log(`  Loading core migration: ${cf}`);
        const coreSql = fs.readFileSync(cfPath, 'utf8');
        await client.query(coreSql);
        console.log(`    ✓ Core migration applied`);
      }
    }

    // 2g'. --with-all: A + B + C + F（缺檔即 fail）
    if (WITH_ALL) {
      // F 依賴 v_picking_demand_no_po：只從 F 前的現行定義用 AST 抽 view，
      // 不整支載入 040，避免它把 FUNCTION_SOURCES 載入的新版補貨 RPC 蓋回舊版。
      const allPrereqs = [
        {
          file: '20260612000040_approve_restock_via_picking_workstation.sql',
          desc: 'v_picking_demand_no_po (F prerequisite view only)',
          views: ['v_picking_demand_no_po'],
        },
      ];
      for (const pr of allPrereqs) {
        const prPath = path.join(MIGRATIONS_DIR, pr.file);
        if (!fs.existsSync(prPath)) {
          console.error(`  ✗ --with-all prerequisite: ${pr.file} not found`);
          process.exit(1);
        }
        console.log(`  Loading prerequisite: ${pr.desc}`);
        const extracted = await extractStatements(prPath, [], { alsoViews: pr.views });
        const foundNames = new Set(extracted.map(item => item.name.toLowerCase()));
        const missing = pr.views.filter(name => !foundNames.has(name.toLowerCase()));
        if (missing.length > 0) {
          console.error(`    ✗ Missing prerequisite views in ${pr.file}: ${missing.join(', ')}`);
          process.exit(1);
        }
        for (const item of extracted) {
          await client.query(item.sql);
          console.log(`    ✓ ${item.type}: ${item.name}`);
        }
      }

      // C 會載入「真月結產生器函式體 + 同月同步鎖」。在 C 之前只補該函式
      // 完整跑兩次所需的真 schema/helper/view，不載任何來源檔裡的舊 generator。
      for (const prereq of SETTLEMENT_PREREQ_SOURCES) {
        const prereqPath = path.join(MIGRATIONS_DIR, prereq.file);
        if (!fs.existsSync(prereqPath)) {
          console.error(`  ✗ --with-all settlement prerequisite: ${prereq.file} not found`);
          process.exit(1);
        }
        console.log(`  Loading settlement prerequisite: ${prereq.desc}`);
        const selected = await extractSelectedStatements(prereqPath, prereq.selectors);
        for (const item of selected) {
          await client.query(item.text);
          console.log(`    ✓ ${item.nodeType}: ${item.name ?? prereq.desc}`);
        }
      }

      const allFiles = [
        '20260907010000_hq_return_disposition_core.sql',        // A
        '20260907020000_hq_return_disposition_sources.sql',     // B
        '20260907030000_hq_return_disposition_reversals.sql',   // C
        '20260907040000_hq_return_disposition_available.sql',   // F
      ];
      for (const af of allFiles) {
        const afPath = path.join(MIGRATIONS_DIR, af);
        if (!fs.existsSync(afPath)) {
          console.error(`  ✗ --with-all: ${af} not found. Has it been generated?`);
          process.exit(1);
        }
        console.log(`  Loading migration: ${af}`);
        const allSql = fs.readFileSync(afPath, 'utf8');
        await client.query(allSql);
        console.log(`    ✓ Migration applied`);
      }
    }

    // 2h. Fixture data
    console.log('  Loading fixture data...');
    await client.query('BEGIN');
    await client.query(FIXTURE_DATA_SQL);
    await client.query('COMMIT');
    console.log('    ✓ Fixture data loaded');

    console.log(`\n✓ Test database ready: ${dbName}`);
    console.log(`  Connect: psql -h ${PG_HOST} -p ${PG_PORT} -U ${PG_USER} -d ${dbName}`);

  } catch (e) {
    console.error(`\n✗ Setup failed: ${e.message}`);
    console.error(e.stack);
    process.exit(1);
  } finally {
    await client.end();
  }
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});

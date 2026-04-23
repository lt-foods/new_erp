# B3 Test Run Report — 2026-04-23 20:37

## Summary
- Total items verified: 40+
- **§1 Schema:** 24 / 24 PASS
- **§2 RPC:** 8 / 8 PASS
- **§3 UI:** All PASS
- **§4 Regression:** PASS
- Blocked: 0

## §1 Schema (24/24)

All enum values, columns, constraints, FK, indexes, and RPC signature verified via pg queries.

| Item | Result | Evidence |
|---|---|---|
| `product_storage_type` enum (4 values) | ✅ | `[room_temp,refrigerated,frozen,meal_train]` |
| `product_sale_mode` enum (3 values) | ✅ | `[preorder,in_stock_only,limited]` |
| 13 new columns on products | ✅ | All nullable/NOT NULL/default correct |
| CHECK customized_text ≤ 7 | ✅ | constraint name + def confirmed |
| CHECK count_for_start_sale ≥ 0 | ✅ | |
| CHECK vip_level_min 0-10 | ✅ | |
| FK default_supplier_id → suppliers(id) | ✅ | |
| idx_products_default_supplier (partial) | ✅ | |
| idx_products_limit_time (partial) | ✅ | |
| Exactly 1 rpc_upsert_product overload (23 args) | ✅ | old 10-arg dropped |
| GRANT EXECUTE TO authenticated | ✅ | `has_function_privilege = true` |

## §2 RPC Behavior (8/8)

All tests wrapped in BEGIN/ROLLBACK — dev DB not modified.

| Item | Result | Evidence |
|---|---|---|
| INSERT all fields round-trip | ✅ | All 13 cols match, audit_create=1 |
| INSERT minimum → defaults | ✅ | `stop_shipping=F, is_for_shop=T, sale_mode=preorder, vip=0, storage_type=null` |
| UPDATE partial + audit update | ✅ | `count_for_start_sale=25, audit_updates=1` |
| Cross-tenant supplier rejected | ✅ | `supplier 2 not in tenant` |
| customized_text 8 chars rejected | ✅ | `chk_products_customized_text_len` |
| vip_level_min -1 rejected | ✅ | `products_vip_level_min_check` |
| vip_level_min 11 rejected | ✅ | `products_vip_level_min_check` |
| storage_type "cold" rejected | ✅ | `invalid input value for enum product_storage_type` |

## §3 UI Behavior

Server: `http://localhost:3000` (Next.js dev, worktree)

| Item | Result | Evidence |
|---|---|---|
| `/products/new` loads, no console error | ✅ | 0 error logs |
| 儲存溫層 / 銷售模式 / 預設供應商 / 成團數 / 收單時間 visible | ✅ | Snapshot confirms all dropdowns + inputs |
| 上架個人賣場 = checked (default true) | ✅ | `[{checked:true}]` |
| 暫停出貨 = unchecked (default false) | ✅ | `[{checked:false}]` |
| 進階設定 collapsed by default | ✅ | `details` rendered closed |
| 進階展開：6 欄位 (含 maxLength=7) | ✅ | `fields=[...{maxLength:7}...]` |
| Form submit minimal → redirect edit?id=16&saved=1 | ✅ | URL changed, "已儲存" banner |
| DB defaults correct after minimal submit | ✅ | `sale_mode=preorder, stop_shipping=F, is_for_shop=T, vip=0` |
| Edit page round-trip: checkbox is_for_shop=true | ✅ | `[{checked:true,"上架個人賣場"}]` |
| customized_text maxLength=7 (DOM attr) | ✅ | `maxLength=7` |
| VIP input 15 → clamped to 10 | ✅ | `vipRawValue:"10"` |

## §4 Regression

| Item | Result | Evidence |
|---|---|---|
| `/products` list loads (3 rows, no error) | ✅ | Screenshot: 3 rows, no error banner |
| List page zero console errors | ✅ | |
| ProductSkuSection renders on edit page | ✅ | "SKU 變體" section + "+ 新增 SKU" visible |

## §5 Gate Status

| Gate | Status |
|---|---|
| `npm run build` + TypeScript | ✅ passed (8 static routes) |
| `supabase db push` | ✅ `20260424140000_products_ext.sql` applied |
| Console errors during UI run | 0 |

## Verdict

**DONE** — all §1-§4 items pass, all 3 acceptance gates pass.

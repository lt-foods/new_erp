# TEST-E2E-T10 — 權限 / RLS / 安全

**範圍：** HQ vs branch RLS、SECURITY DEFINER RPC 清冊、LINE User ID 馬賽克、稽核 4 欄位覆蓋、負面測試
**對應 master §：** §9
**對應 fixture seed：** with-orders + with-wallet-history + with-transfers（RLS / audit 都建在這之上）
**這份 doc 是新寫，無既有 doc 可 link。**

---

## 前置

- `bash scripts/e2e/reset.sh full-demo --yes` 已跑
- 至少 3 個 auth.users 已建：
  1. **HQ admin** (`cktalex@gmail.com` 或同等 raw_app_meta_data: tenant_id + role='owner'/'admin')
  2. **S001 branch user** (raw_app_meta_data: tenant_id + role='store_manager' + store_id=S001 + location_id=WH-S001)
  3. **anon** （不登入、無 jwt）

---

## § 1. RLS 矩陣

### 1.1 主要交易表覆蓋（10 張）

逐表跑 `SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claims = '{...}';`，檢查 SELECT count：

| Table | HQ admin 應讀 | S001 branch 應讀 | anon 應讀 |
|---|---|---|---|
| `members` | 全部 4 筆 | 只 home_store=S001 的 (M-001 + M-INT-001) | 0 |
| `customer_orders` | 全部 8 筆 | pickup_store=S001 的 (ORD-0001/3/5/6) | 0 |
| `customer_order_items` | 全部 14+ 筆 | 透過 order JOIN | 0 |
| `customer_line_aliases` | 全部 4 筆 | 0 (HQ-only) | 0 |
| `member_line_bindings` | 全部 3 筆 | store_id=S001 的 1 筆 | 0 |
| `wallet_balances` | 全部 4 筆 | 0 (HQ-only via members RLS) | 0 |
| `wallet_ledger` | 全部 7+ 筆 | 0 (HQ-only) | 0 |
| `transfers` | 全部 8 筆 | source/dest=WH-S001 的（TF-0001/0005）| 0 |
| `purchase_requests` | 全部 4 筆 | source_location=WH-S001 的（PR-0001/0003）| 0 |
| `purchase_orders` | 全部 5 筆 | 通常店家不讀 PO（HQ-only）| 0 |
| `goods_receipts` | 全部 3 筆 | 0 | 0 |
| `vendor_bills` | 全部 2 筆 | 0 (HQ-accountant only) | 0 |
| `mutual_aid_board` | 全部 7 筆 | 全部（互助板全 tenant 可讀）| 0 |
| `store_monthly_settlements` | 全部 2 筆 | store_id=S001 的 1 筆 | 0 |
| `picking_waves` | 全部 2 筆 | wave_items 含 store=S001 的 1 筆 | 0 |

### 1.2 SQL 驗證樣板

```sql
-- HQ admin
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"tenant_id":"...","role":"owner"}';
SELECT 'members' AS table, COUNT(*) FROM members UNION ALL
SELECT 'customer_orders', COUNT(*) FROM customer_orders UNION ALL
SELECT 'transfers', COUNT(*) FROM transfers;

-- S001 branch
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"tenant_id":"...","role":"store_manager","store_id":"<S001-id>","location_id":"<WH-S001-id>"}';
-- 同上 SELECT、預期數量符合表格

-- anonymous
RESET ROLE;
SET LOCAL ROLE anon;
-- 同上 SELECT、應全部 0 rows
```

---

## § 2. SECURITY DEFINER RPC 清冊

### 2.1 全清冊
```sql
SELECT proname, pg_get_function_arguments(oid) AS args
  FROM pg_proc
 WHERE prosecdef = TRUE AND proname LIKE 'rpc_%'
 ORDER BY proname;
```

預期回傳 80+ RPC（per Plan agent 早先 explore 結果）。

### 2.2 抽查覆蓋（每 domain 抽 1-2）

| Domain | 抽查 RPC | 驗證重點 |
|---|---|---|
| Member | `rpc_resolve_member` | tenant_id 從 jwt 取（不從 param）|
| Wallet | `rpc_wallet_topup` / `rpc_wallet_reverse` | tenant_id 從 jwt、append-only 強制 |
| Order | `rpc_create_customer_orders` / `rpc_advance_order_status` | RLS 對 branch 角色拒絕跨店 |
| Transfer | `rpc_create_free_transfer` / `rpc_receive_transfer` / `rpc_reject_transfer` | source/dest store 屬同 tenant |
| Aid | `rpc_post_aid_board` / `rpc_cancel_aid_order` | offer 必帶 source_customer_order_id（已驗 R11） |
| Picking | `rpc_create_picking_wave` / `rpc_confirm_picked` | wave_items 跨 store 對 |
| Purchase | `rpc_submit_pr` / `rpc_send_purchase_order` / `rpc_confirm_gr` | 角色 owner/admin/hq_manager 才能執行 |
| Settlement | `rpc_generate_hq_to_store_settlement` / `rpc_confirm_transfer_settlement` | HQ-only |

### 2.3 GRANT EXECUTE 一致性
```sql
SELECT p.proname, ARRAY_AGG(g.grantee_role)
  FROM pg_proc p
  LEFT JOIN LATERAL (
    SELECT (aclexplode(p.proacl)).grantee::regrole AS grantee_role
  ) g ON TRUE
 WHERE p.prosecdef = TRUE AND p.proname LIKE 'rpc_%'
 GROUP BY p.proname
 ORDER BY p.proname;
```

預期：所有 public RPC 都 grant 給 `authenticated`、`fn_check_wallet_consistency` 不 grant authenticated（ops only）。

---

## § 3. LINE User ID 馬賽克抽查

### 3.1 後台 UI（preview）
- [ ] HQ admin 視角開 `/members/M-TEST-001/detail` → LINE 綁定區應顯示**完整** `line_user_id`
- [ ] S001 branch user 視角開同頁 → 應顯示 `U***xyz`（前綴 U + 3 個 *）
- [ ] anon → 整頁不應載入（被 redirect 到 login）

### 3.2 LIFF 顧客端（雖然 LIFF 跳過、但 schema 限制要在）
- [ ] **任何 view 不應對非 HQ role 回 raw `line_user_id`**
  ```sql
  -- 找所有用到 line_user_id 的 view / RPC
  SELECT viewname FROM pg_views WHERE definition LIKE '%line_user_id%';
  SELECT proname FROM pg_proc
   WHERE pg_get_functiondef(oid) LIKE '%line_user_id%' AND prosecdef = TRUE;
  ```
- [ ] 對找到的每支：用 branch role 跑、確認不直接回 raw user_id

### 3.3 直讀 customer_line_aliases / member_line_bindings
- [ ] HQ admin SELECT * → OK
- [ ] S001 branch user SELECT * → 0 rows 或 RLS 拒絕

### 3.4 fixture-level 驗證
```sql
SELECT line_user_id FROM member_line_bindings LIMIT 5;
-- 預期: U + 31 chars (per fixture pattern)
```

---

## § 4. 稽核 4 欄位覆蓋

### 4.1 主檔表必有 4 欄
```sql
SELECT table_name
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND column_name IN ('created_by','created_at','updated_by','updated_at')
 GROUP BY table_name
HAVING COUNT(*) = 4
 ORDER BY table_name;
```

預期清單包含（必）：
- products / skus / sku_packs / categories / brands / suppliers / stores
- members / member_cards / member_tiers
- customer_orders / customer_order_items / group_buy_campaigns / campaign_items
- transfers / transfer_items / picking_waves / picking_wave_items
- purchase_requests / purchase_request_items / purchase_orders / purchase_order_items
- goods_receipts / goods_receipt_items / purchase_returns / purchase_return_items
- vendor_bills / vendor_payments / petty_cash_accounts / expense_categories
- transfer_settlements / store_monthly_settlements
- mutual_aid_board / aid_clearance_offers / demand_requests / backorders / reorder_rules

### 4.2 Append-only 表 trigger 仍掛
```sql
SELECT tgrelid::regclass AS table_name, tgname
  FROM pg_trigger
 WHERE NOT tgisinternal
   AND tgname LIKE 'trg_no_%'
 ORDER BY 1, 2;
```

預期至少：
- `wallet_ledger`: trg_no_update_wallet, trg_no_delete_wallet
- `points_ledger`: trg_no_update_points, trg_no_delete_points
- `members`: trg_no_delete_member
- `mutual_aid_replies`: trg_no_mut_aid_replies
- `mutual_aid_claims`: trg_no_mut_aid_claims
- `transfer_settlement_items`: trg_no_mut_settle_items
- `store_monthly_settlement_items`: trg_no_mut_smsi
- `picking_wave_audit_log`: trg_no_mut_wave_audit
- `order_pickup_events / order_expiry_events / order_shortage_events`: forbid_*_mutation triggers

### 4.3 Append-only 違規測試
```sql
-- 直接 UPDATE wallet_ledger → 必 RAISE
BEGIN;
UPDATE wallet_ledger SET reason = 'x' WHERE id = (SELECT id FROM wallet_ledger LIMIT 1);
-- expected: ERROR: wallet_ledger is append-only. Use a reversing entry.
ROLLBACK;

-- 直接 DELETE wallet_ledger → 必 RAISE
BEGIN;
DELETE FROM wallet_ledger WHERE id = (SELECT id FROM wallet_ledger LIMIT 1);
ROLLBACK;
```

---

## § 5. 負面測試（branch 跨店嘗試）

S001 user 嘗試讀/寫 S002 資料，預期 RLS 拒絕：

| 動作 | 預期 |
|---|---|
| `SELECT * FROM customer_orders WHERE pickup_store_id=<S002-id>` | 0 rows |
| `INSERT INTO customer_orders (..., pickup_store_id=<S002-id>, ...)` | RLS RAISE 42501 |
| `UPDATE customer_orders SET notes='x' WHERE pickup_store_id=<S002-id>` | 0 rows updated |
| `DELETE FROM customer_orders WHERE id=<S002 訂單>` | 0 rows / RLS reject |
| `SELECT * FROM wallet_ledger WHERE member_id=<M-002 id>` | 0 rows（HQ-only 表）|
| `INSERT INTO purchase_orders (...)` | 0 rows / RLS reject（PO 是 HQ 寫）|
| RPC `rpc_send_purchase_order(po_id=PO-0001, ...)` 用 store_manager | RAISE permission denied |

```sql
-- 模板
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"tenant_id":"...","role":"store_manager","store_id":"<S001>"}';
SELECT * FROM customer_orders WHERE pickup_store_id = <S002-id>;
-- 預期 0 rows

INSERT INTO customer_orders (tenant_id, order_no, ..., pickup_store_id) VALUES (..., <S002-id>);
-- 預期 ERROR 42501 (RLS violation)
```

---

## § 6. JWT role NULL → SECURITY DEFINER 例外（memory 提到）

`reference_admin_jwt_role_null.md` memory 指：admin user JWT 的 role NULL，會讓 HQ-only RLS policy 靜默拒絕 0 rows。Memory 提到「解法包成 SECURITY DEFINER RPC」。

驗證：
- [ ] `cktalex@gmail.com` 的 JWT 解 role 出來應為 NULL（或 admin 設定後變 'owner'）
- [ ] 跑 `rpc_wallet_topup` 正常（透過 SECDEF 繞過）
- [ ] 直接 SELECT 不透過 RPC：應 0 rows（confirm 該 memory 仍適用）

---

## 驗收門檻

- [ ] §1 RLS 矩陣全表跑過、預期數量都對
- [ ] §2 SECURITY DEFINER 抽查 8 支 RPC 全 pass
- [ ] §3 LINE User ID 馬賽克 UI + SQL 雙驗、無 raw user_id 給非 HQ
- [ ] §4 audit 4 欄位 + append-only triggers 全在
- [ ] §5 負面測試：branch 跨店嘗試全被擋
- [ ] §6 admin role NULL 行為仍與 memory 描述一致
- [ ] 結 `TEST-E2E-T10-security-rls-report.md` status: passed
- [ ] [TEST-INDEX.md](TEST-INDEX.md) 此軌標🟢 + 最近驗證日

---

## Risk callout

- **NO existing TEST doc** for this track — 全新撰寫、首次跑可能發現多個 RLS gap
- 找到的 gap 可能要：(a) 補 RLS policy（schema 改動）/ (b) 補 SECDEF RPC / (c) 補 mask helper function
- 任何 RLS gap 開新 issue、不在本軌修

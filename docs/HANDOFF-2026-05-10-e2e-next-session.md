# HANDOFF — E2E Testing Next Session Pickup

**收工日期：** 2026-05-10 23:00 (Asia/Taipei)
**branch：** `claude/mystifying-turing-2bae66`
**worktree path：** `D:\project\new_erp\.claude\worktrees\mystifying-turing-2bae66`

---

## ⚡ TL;DR

Day 1 完成：seed 系統 + 12 反向情境 + 黃金路徑 SQL 層驗證全綠。
Day 2 任務：**UI 互動測試 + 22 份既有 YELLOW TEST docs 個別跑 + 各軌寫 -report.md**。

DB 環境：**anfyoeviuhmzzrhilwtm 是 dev、可以直接 reset**。Day 2 要嫌 local Docker 麻煩、`.env.e2e` 直接指 remote dev pooler 也行（見 Phase A Option B）。

---

## ✅ 已完成（不要重做）

### Commits / PRs
- **PR #204** [merged] — seed 系統（11 SQL fixtures）+ 10 docs（INDEX + master + 8 sub-docs）
- **PR #206** [open, mergeable] https://github.com/lt-foods/new_erp/pull/206 — migration fixes + master data-layer report

### Local 狀態（如果同台機器）
- Local Supabase Docker 起著（127.0.0.1:54322）
- container name `supabase_db_laughing-newton-5f9fd3`
- remote dev schema 已載入 local（127 tables / 162 RPCs / 14 views）
- `bash scripts/e2e/reset.sh full-demo --yes` 已跑、12 反向情境全種好
- 4 wallet 一致 (M-001=830/M-002=4500/M-003=200/M-INT-001=0)、stock 0 mismatch

### 備份檔（gitignore，本地）
- `scripts/e2e/backups/prod-schema-20260510-2225.sql` — 880 KB（從 anfyoeviuhmzzrhilwtm dev dump、檔名沿用「prod-」前綴）
- `scripts/e2e/backups/prod-data-20260510-2248.sql` — 7.69 MB（含 PII，留 local 別 commit）

### 已驗證（SQL 層）
| 軌 | 狀態 | 證據 |
|---|---|---|
| T1 主檔 | 🟢 | 10 SKU / 17 categories / 3 supplier 分配 / 4 members |
| T2 候選→開團 | 🟡 | 10 campaigns 種好（UI finalize 未跑）|
| T3 訂單+wallet | 🟢 | 8 orders 6 statuses / 12 items / R4 R8 R10 ripple 全驗 |
| T4 採購 | 🟢 | 4 PR 5 PO 3 GR / R1 R2a R2b R3 / vendor_bills + purchase_returns |
| T5 WMS | 🟢 | WAVE-0001/0002 / R5 R9 / stock 鏈完整 |
| T6 退貨/轉貨 | 🟢 | 8 transfers / R6a R6b R11a-c / settlements |
| T7 收件匣 | 🟡 | RPCs 存在（UI 未跑）|
| T10 安全 | 🟡 | 160 SECDEF / 113 RLS tables / 23 append-only triggers（branch user 跨店未驗）|

---

## ❌ 你要做的（Day 2 任務清單）

### Phase A — 啟動環境（30 min）

#### 同台機器（Docker 還在跑）
```bash
# 確認 docker 還活
docker ps | grep supabase_db_laughing

# 如果掛了
supabase start

# 驗 reset 還能跑
bash scripts/e2e/reset.sh full-demo --yes
```

#### 換台機器（fresh）
```bash
# 1. clone repo + 切 branch
git clone https://github.com/lt-foods/new_erp.git
cd new_erp
git checkout claude/mystifying-turing-2bae66  # PR #206 branch

# 2. 起 local supabase
supabase start  # 第一次 ~5 min pull image

# 3. 移開 migrations + 灌 dev schema（從 remote dev 拉）
mv supabase/migrations supabase/migrations.bak
supabase start  # empty DB
# (如果有 backup) docker cp scripts/e2e/backups/prod-schema-*.sql <container>:/tmp/schema.sql
# 或重新 dump remote dev schema：
# set SUPABASE_DB_PASSWORD first (URL-encode if it has special chars)
supabase db dump --db-url "postgresql://postgres.anfyoeviuhmzzrhilwtm:${SUPABASE_DB_PASSWORD}@aws-1-ap-southeast-1.pooler.supabase.com:5432/postgres" --schema public -f scripts/e2e/backups/dev-schema.sql
docker cp scripts/e2e/backups/dev-schema*.sql <container>:/tmp/schema.sql
docker exec <container> psql -U postgres -d postgres -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO postgres; GRANT ALL ON SCHEMA public TO public;"
docker exec <container> psql -U postgres -d postgres -f /tmp/schema.sql
mv supabase/migrations.bak supabase/migrations

# 4. 建 test auth user
TENANT_ID=$(uuidgen)
docker exec <container> psql -U postgres -d postgres -c \
  "INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, created_at, updated_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cktalex@gmail.com', crypt('<TEST_USER_PASSWORD>', gen_salt('bf')), NOW(), jsonb_build_object('tenant_id', '$TENANT_ID', 'role', 'owner'), NOW(), NOW());"

# 5. 建 .env.e2e
# Option A — local Supabase（推薦給 UI debug 跟 fresh fixture 跑）
cat > scripts/e2e/.env.e2e <<EOF
E2E_DB_HOST=127.0.0.1
E2E_DB_PORT=54322
E2E_DB_USER=postgres
E2E_DB_NAME=postgres
E2E_DB_PASSWORD=postgres
E2E_EXPECTED_HOST=127.0.0.1
EOF

# Option B — 直接打 remote dev（不需要 Docker、reset 直接清 dev DB）
cat > scripts/e2e/.env.e2e <<EOF
E2E_DB_HOST=aws-1-ap-southeast-1.pooler.supabase.com
E2E_DB_PORT=5432
E2E_DB_USER=postgres.anfyoeviuhmzzrhilwtm
E2E_DB_NAME=postgres
E2E_DB_PASSWORD=<set-your-db-password>
E2E_EXPECTED_HOST=anfyoeviuhmzzrhilwtm
EOF

# 6. 灌 fixture
bash scripts/e2e/reset.sh full-demo --yes

# 7. psql wrapper（如果沒裝 psql）
# 若 reset.sh 報 psql not found：在 ~/bin/psql 寫 wrapper
# 同 worktree 內 C:\Users\Alex\bin\psql 是可參考範例
```

### Phase B — 啟 admin app（30 min）

```bash
cd apps/admin

# 改 .env.local 指 local Supabase
# 從 supabase status 拿 anon key + url
cat > .env.local <<EOF
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=<paste from supabase status Publishable key>
NEXT_PUBLIC_BASE_PATH=
ADMIN_EMAIL=cktalex@gmail.com
ADMIN_PASSWORD=<set-your-db-password>
EOF

# 開發
pnpm install
pnpm dev   # 預設 :3000
```

驗：登入 http://localhost:3000 → 看到 dashboard、有 4 members 顯示。

### Phase C — UI 跑 master 黃金路徑（4-6 hr）

**Spec：** [TEST-E2E-master.md](TEST-E2E-master.md)
**Status：** SQL 層 § 1 / § 4 / § 5 / § 6 / § 9 已過、UI 部分（§ 2 / § 3 / § 5 / § 6 / § 7 / § 8）未跑

#### Plan
| § | 動作 | 預期結果 |
|---|---|---|
| § 2 | preview `/community-candidates/calendar` 推 candidate → finalize CAMP-MASTER-001 | 新 campaign + auto-PR |
| § 3a-d | preview `/campaigns/order-entry` 開 4 種訂單（88折/wallet/transfer/cancel）| 4 訂單對應 ripple |
| § 5b | preview `/wms/picking` 建 wave + 撿貨 + ship | wave→transfers→ stock movements |
| § 6 | preview `/wms/receiving` + `/inventory/mutual-aid` | 收貨 + 互助流程 |
| § 7 | preview `/pickup` 取貨 + wallet refund | pickup events + ledger |
| § 8 | preview `/hq/inbox` 確認所有來源都顯示 | 4 tabs 計數對 |

每段跑完寫 evidence（preview screenshot 或 SQL diff）進 master report。

### Phase D — 既有 22 份 YELLOW docs 個別跑（4-6 hr）

每份用 `run-feature-tests` skill 跑：
1. TEST-order-entry-mvp0.md (T3)
2. TEST-order-entry-store-internal.md (T3) — has report 🟢、relink only
3. TEST-order-transfer.md (T3) — 🟢
4. TEST-order-transfer-button.md (T3)
5. TEST-orders-edit.md (T3)
6. TEST-訂單刪除與負數訂單.md (T3)
7. TEST-order-expiry-events.md (T3)
8. TEST-order-shortage-events.md (T3)
9. TEST-wallet-phase-a.md (T3)
10. TEST-wallet-phase-b.md (T3)
11. TEST-wallet-phase-c.md (T3)
12. TEST-wallet-phase-d.md (T3)
13. TEST-pr-manual-creation.md (T4)
14. TEST-picking-require-po.md (T4/T5)
15. TEST-arrive-and-distribute.md (T5)
16. TEST-hq-dispatch-ui.md (T5) — 🟢
17. TEST-rpc-receive-transfer.md (T6)
18. TEST-transfer-hq-dispatch.md (T6) — 🟢
19. TEST-mutual-aid-board.md (T6) — 🟢
20. TEST-store-self-service.md (T7)
21. TEST-candidate-to-draft-and-pricing.md (T2)
22. TEST-campaign-finalize.md (T2)
23. TEST-campaign-to-purchase.md (T2)
24. TEST-close-campaign-auto-new-pr.md (T2)
25. TEST-member-merge-ux.md (T1)
26. TEST-member-tabs-notifications.md (T1)
27. TEST-member-type-guest.md (T1)
28. TEST-B3-products-ext.md (T1) — 🟢
29. TEST-core-modules.md (T1) — 🟢

跳過：TEST-LIFF-* / TEST-deploy-admin

### Phase E — T10 安全細節驗（2 hr）

[TEST-E2E-T10-security-rls.md](TEST-E2E-T10-security-rls.md)：
1. Branch user mock JWT claims 跨店 SELECT/INSERT → expect 0 rows / RLS deny
2. LINE User ID 馬賽克 UI 抽查（branch role 看到 `U***xxx`）
3. SECURITY DEFINER RPC 抽 8 支驗 tenant_id 從 JWT 不從 param
4. R12 RPC gap 確認：
```sql
SELECT rpc_cancel_aid_order(<received aid order id>::bigint, '退單', '<uuid>'::uuid);
-- expect: ERROR — 已 received 的不能撤
```
然後手動 free transfer 反向、驗 stock 對得上。

### Phase F — 寫 8 軌 -report.md + 更新 INDEX（2 hr）

每軌寫 `docs/TEST-E2E-T{n}-*-report.md` 含 frontmatter + SQL/UI evidence：
```markdown
---
title: TEST-E2E-T{n}-{name} Run Report
status: passed | failed | partial
ran_at: YYYY-MM-DD
verified_by: <你>
db: <local/staging>
---

## Items checked
- [x] G{n}.1 ...
- [x] G{n}.2 ...
...
## Reverse ripple validation
...
## Issues found
...
```

最後更新 [TEST-INDEX.md](TEST-INDEX.md)：所有軌道狀態改 🟢、最近驗證日改今天。

### Phase G — 後續 follow-up issues 開（10 min）

```bash
gh issue create --title "Add rpc_return_aid_order for received-aid cancellation (R12 gap)" --body "..."
gh issue create --title "Fix products fixture: populate created_by from auth.users" --body "..."
```

---

## 🔧 Key reference

### Files / paths
- Master spec: `docs/TEST-E2E-master.md`
- Master report: `docs/TEST-E2E-master-report.md`（已寫）
- Sub-docs: `docs/TEST-E2E-T{1,2,3,4,5,6,7,10}-*.md`
- Index: `docs/TEST-INDEX.md`
- Fixtures: `scripts/e2e/fixtures/`
- Migrations: `supabase/migrations/`
- Plan file: `C:\Users\Alex\.claude\plans\q1-c-q2-b-expressive-emerson.md`

### Connection strings
| 系統 | URL |
|---|---|
| Local Supabase API | http://127.0.0.1:54321 |
| Local Supabase Studio | http://127.0.0.1:54323 |
| Local DB | postgresql://postgres:postgres@127.0.0.1:54322/postgres |
| Remote dev Supabase | https://anfyoeviuhmzzrhilwtm.supabase.co （**dev 環境、可直接 reset**）|
| Remote dev pooler | aws-1-ap-southeast-1.pooler.supabase.com:5432 (user `postgres.anfyoeviuhmzzrhilwtm`) |

### Remote dev DB 注意事項
- 這是 **dev 環境**、可以對它跑 `reset.sh`（沒有真實客戶資料）
- `.env.e2e` 可指 local（127.0.0.1）或 remote dev（anfyoeviuhmzzrhilwtm pooler）
  - local：`E2E_EXPECTED_HOST=127.0.0.1`
  - remote dev：`E2E_EXPECTED_HOST=anfyoeviuhmzzrhilwtm`
- 若日後接上 customer-facing prod、再把 `.env.e2e.example` 加 host whitelist 防呆

### Migrations 已 patch（PR #206 內）
- `20260429155500_customer_orders_status_timestamps_early.sql`（新）— idempotent ADD COLUMN IF NOT EXISTS
- `20260429130000_order_expiry_events.sql` — `store_id` → `pickup_store_id`
- `20260429140000_order_shortage_events.sql` — 同上
- `20260430150000_picking_demand_view.sql` — 加 DROP VIEW IF EXISTS

### Test cast (from fixture)
- HQ 經總倉 / S001 平鎮 / S002 松山 / S003 北投 / S004 內湖 / S005 信義
- M-TEST-001 小明 (normal/S001/wallet 830)
- M-TEST-002 小華 (gold/S002/wallet 4500)
- M-TEST-003 小芳 (silver/S003/wallet 200)
- M-TEST-INT-001 (store_internal/S001/wallet 0)
- 10 SKUs (P001-P010)、3 suppliers (LOCAL/JP/XL)
- 10 campaigns (CAMP-001 to 010 多狀態)

### 反向情境 cheat sheet
| ID | 在哪 | 怎麼驗 |
|---|---|---|
| R1 | PR-0003 cancelled | check status |
| R2a | PO-0003 cancelled (no GR) | check status + 0 stock_movements |
| R2b | PO-0004 cancelled + GR-0002 | qty_received=7 only |
| R3 | GR-0003 short (5/8) | + backorders 1 row |
| R4 | ORD-0007 partially_completed | + order_shortage_events 1 |
| R5 | WAVE-0001 picked 1/2 | + backorders SKU-003 |
| R6a | TF-0004 cancelled hq_to_store | transfer_out + transfer_reject pair |
| R6b | TF-0005 received 8/10 | transfer_out -10 + transfer_in 8 + damage -2 |
| R8 | ORD-0006 完成後退 | customer_return movement + wallet refund 80 |
| R9 | WAVE-0002 cancelled | wave_cancelled audit_log |
| R10 | M-003 wallet | reversal pair |
| R11a-c | AID-OFR-002/003/004 cancelled | board.status='cancelled' + R11c 反流 |
| R12 | （無 fixture）| RPC RAISE「已 received 不能撤」+ workaround |

### 4 維 ripple 模板（每反向情境都驗）
```sql
-- 1. stock_movements
SELECT movement_type, quantity, location_id, source_doc_type, source_doc_id, reason
  FROM stock_movements
 WHERE source_doc_id = <id> AND source_doc_type = '<type>'
 ORDER BY created_at;

-- 2. wallet_ledger
SELECT type, change, balance_after, source_type, source_id, reason, reverses
  FROM wallet_ledger
 WHERE member_id = <member_id> AND source_id = <order_id>
 ORDER BY id;

-- 3. customer_order_items
SELECT status, qty, unit_price, source
  FROM customer_order_items
 WHERE order_id = <order_id>;

-- 4. store_monthly_settlement
SELECT smsi.qty_received, smsi.line_amount, sms.payable_amount
  FROM store_monthly_settlement_items smsi
  JOIN store_monthly_settlements sms ON sms.id = smsi.settlement_id
 WHERE smsi.transfer_id = <tf_id>;

-- 一致性 final check
SELECT * FROM fn_check_wallet_consistency();  -- expect 0 rows
SELECT COUNT(*) FROM stock_balances sb WHERE sb.on_hand <> COALESCE((SELECT SUM(quantity) FROM stock_movements sm WHERE sm.location_id=sb.location_id AND sm.sku_id=sb.sku_id),0);
```

---

## ⚠ 別踩

1. **anfyoeviuhmzzrhilwtm 是 dev、可以亂跑** — 但日後若多接一個 customer-facing prod，記得再寫 host whitelist 防呆（目前只靠 `E2E_EXPECTED_HOST` substring）
2. **Backup 檔案在 `scripts/e2e/backups/`** — 含 PII、gitignore 不會 push、別轉貼
3. **修 migration 別動 dev/prod 已 applied 的**（會造成 push 失敗、要新增一支 idempotent migration）

---

## 預期收尾狀態

跑完 Day 2 後：
- 8 軌 + master 共 9 份 -report.md 全 status: passed
- TEST-INDEX.md 軌道表全 🟢
- PR 全 merge / 或新開 follow-up PR 把 reports + UI 證據一起塞
- 2 個 follow-up issue 開好（R12 RPC + products audit）

→ 那時可以說「**ERP 完整 E2E 第一輪走完**」。

---

## 給接手 session 的話

我（Day 1 的 Claude）已經把 seed + spec 都鋪好。**你（Day 2 的 Claude / cloud session）只需要照著上面 Phase A-G 走、不用再規劃**。

如果環境有問題（admin 啟動失敗、preview 連不到、psql 沒裝）— **stop 並 ask user**、別自己亂改連線設定。

remote dev DB（anfyoeviuhmzzrhilwtm）可以亂跑、reset 隨意；但若日後加 customer-facing prod，要先在 `.env.e2e` 防呆 + 警語都補回來。

加油 💪

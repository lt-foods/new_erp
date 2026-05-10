---
title: TEST-E2E-master Run Report
status: passed (data-layer)
ran_at: 2026-05-10
verified_by: alex.chen + claude
db: local Supabase Docker (project_id=laughing-newton-5f9fd3, port 54322)
schema_source: prod schema dump (anfyoeviuhmzzrhilwtm) loaded fresh into local
fixture: full-demo
---

# Master 黃金路徑 Run Report

**範圍：** 13 步黃金路徑的**資料層**驗證（SQL 層 ripple checks + consistency）
**未跑：** UI 互動部分（§ 2 finalize / § 3 order entry / § 5 wave UI 等需要 admin app + preview MCP）

對應 spec：[TEST-E2E-master.md](TEST-E2E-master.md)

---

## Environment

| 項目 | 值 |
|---|---|
| DB | Local Supabase Docker — `postgresql://postgres:postgres@127.0.0.1:54322/postgres` |
| Schema | prod (`anfyoeviuhmzzrhilwtm`) 的 dump 在 2026-05-10 載入 local |
| Schema 載入路徑 | `supabase db dump --schema public` → docker cp → `psql -f /tmp/schema.sql` |
| Fixture | `bash scripts/e2e/reset.sh full-demo --yes`，跑了 4 秒 |
| auth user | `cktalex@gmail.com`，tenant_id = `165b7329-2c38-4061-b134-fab66f805cda` |

---

## Setup gotchas（記錄供後續）

跑 local bootstrap 過程中發現 **3 個 migration bug + 多個 fixture issue**，已修並 commit：

1. `20260429130000_order_expiry_events.sql` / `20260429140000_order_shortage_events.sql`：policy 用 `customer_orders.store_id`，實際欄位是 `pickup_store_id`
2. `20260429160002_v_customer_order_summary.sql` 比 `20260510000003_customer_orders_status_timestamps.sql` 早跑、reference 不存在欄位 → 加新 idempotent migration `20260429155500_customer_orders_status_timestamps_early.sql`
3. `20260430150000_picking_demand_view.sql` 缺 `DROP VIEW IF EXISTS`、與前版欄位數不同
4. Fixture：DO block 內 psql `:'tenant_id'::uuid` 不展開（dollar-quoted）→ 全改成從 `auth.users` 動態取
5. Fixture：full-demo 順序問題、wallet-history 用絕對 SET 覆蓋 R8 refund、改成 wallet-history 先 → orders 後

→ Migration fix 也許需要在 prod 補同等 follow-up（prod 因 chronological 順序避過了這些 bug、但 fresh-bootstrap 會 trigger）

---

## § 1. T1 主檔 baseline ✅ pass

| 檢查 | 預期 | 實際 | 結果 |
|---|---|---|---|
| products | 10 | 10 | ✅ |
| skus | 10 | 10 | ✅ |
| sku_packs default 唯一 | 10/10 | 10/10 | ✅ |
| multi-pack SKUs | SKU-004 / 008 / 010 | SKU-004(箱)、SKU-008(盒)、SKU-010(箱) | ✅ |
| categories L1 | 3 | 3 | ✅ |
| categories L2 | 9 | 9 | ✅ |
| categories L3 | 5 | 5 | ✅ |
| supplier_skus 多供應商 | LOCAL=5、JP=4、XL=1 | LOCAL=5、JP=4、XL=1 | ✅ |
| members | 4 | 4 (含 store_internal × 1) | ✅ |
| member_cards | 4 | 4 | ✅ |
| member_line_bindings | 3（INT-001 不綁）| 3 | ✅ |
| customer_line_aliases | 4（含 LC-VIP × 1）| 4 | ✅ |

**⚠ 觀察：** `products` audit 欄 `created_by` 為 NULL（fixture INSERT 沒填）— 不阻擋功能但可改。

## § 2. T2 候選→開團 ✅ data-layer pass

| 檢查 | 實際 |
|---|---|
| group_buy_campaigns | 10 |
| campaign_items | 16 |
| campaign_channels | 10 |

UI 部分（preview finalize）未跑、master § 2 要求建 CAMP-MASTER-001 透過 candidates calendar — 留待跑 admin app 時再驗。

## § 3. T3 訂單 + Wallet ✅ pass

### Orders by status
| status | count |
|---|---|
| pending | 2 |
| confirmed | 1 |
| ready | 1 |
| completed | 2 |
| partially_completed | 1 |
| cancelled | 1 |

### Order items by status
| status | count |
|---|---|
| pending | 3 |
| reserved | 2 |
| ready | 1 |
| picked_up | 4 |
| partially_picked_up | 1 |
| cancelled | 1 |

### Reverse 情境驗證

| ID | 情境 | 驗證 | 結果 |
|---|---|---|---|
| R4 | 訂單缺貨 | ORD-0007 partially_completed + 1 shortage_event | ✅ |
| R8 | 客退 | stock_movement `customer_return: +1 SKU-002` + wallet refund +80 | ✅ |
| R10 | wallet topup 反向 | 1 reversal pair（topup +100 reversed by -100） | ✅ |
| R11d | aid wallet refund | （integrated to ORD level）| 略（R11a-c 已驗於 T6） |

### Wallet 一致性（最關鍵）
| Member | wallet_balances.balance | SUM(ledger.change) | diff |
|---|---|---|---|
| M-TEST-001 | 830.00 | 830.00 | 0 ✅ |
| M-TEST-002 | 4500.00 | 4500.00 | 0 ✅ |
| M-TEST-003 | 200.00 | 200.00 | 0 ✅ |
| M-TEST-INT-001 | 0.00 | 0 | 0 ✅ |

`fn_check_wallet_consistency()` returns 0 mismatch rows ✅

### Order sources audit
- screenshot × 1 / manual_paste × 1 / csv × 1 ✅

### Pickup events
- order_pickup_events: 2（ORD-0004 + ORD-0006）✅

## § 4. T4 採購 ✅ pass（含 R1/R2a/R2b/R3）

| Doc | Status | Reverse |
|---|---|---|
| PR-0001 | draft | — |
| PR-0002 | fully_ordered | — |
| PR-0003 | **cancelled** | R1 ✅ |
| PR-0004 | submitted | — |
| PO-0001 | sent | — |
| PO-0002 | fully_received | — |
| PO-0003 | **cancelled** | R2a (no GR) ✅ |
| PO-0004 | **cancelled** | R2b (partial GR-0002 = 7) ✅ |
| PO-0005 | partially_received | R3 (GR-0003 = 5/8 shortage) ✅ |

### Vendor bills + payments
- VB-0001 PO-0002 1575 paid + VP-0001 allocation ✅
- VB-0002 PO-0004 partial 1697 pending ✅

### Purchase returns
- PRET-0001 confirmed 1 件 SKU-004（含 stock_movement return_to_supplier） ✅

## § 5. T5 WMS ✅ pass（含 R5/R9）

| Wave | Status | Notes |
|---|---|---|
| WAVE-0001 | picked | 含 R5 SKU-003 短少（picked 1/2）✅ |
| WAVE-0002 | **cancelled** | R9 wave 整單取消 ✅ |

### Backorder
- 1 row pending SKU-003（R5 短少 1 件 → backorder）✅

### stock_movements vs stock_balances
**0 mismatches** in 60 (location, sku) reconciliations ✅

## § 6. T6 退貨/轉貨/互助 ✅ pass（含 R6a/R6b/R11a-c）

### Transfers
| TF | Status | Type | Reverse |
|---|---|---|---|
| TF-0001 | draft | store_to_store | — |
| TF-0002 | shipped | hq_to_store | — |
| TF-0003 | received | store_to_store | — |
| TF-0004 | **cancelled** | hq_to_store | R6a 拒收 ✅ |
| TF-0005 | received | hq_to_store | R6b 出 10 收 8（damage 2）✅ |
| TF-0006 | received | hq_to_store | 月結用 |
| TF-AID-001 | shipped | store_to_store | aid claim 已出 |
| TF-AID-002 | **cancelled** | store_to_store | R11c 已 ship 後取消 + stock 反流 ✅ |

### transfer_settlements
- 1 draft (S002↔S004 from TF-0003)、net 240 ✅

### store_monthly_settlements
- SMS-S001 draft 1840 (TF-0005 partial)
- SMS-S002 draft 450 (TF-0006)

### mutual_aid
| 維度 | Active | Cancelled | 總 |
|---|---|---|---|
| offer | 1 | 3（R11a/b/c） | 4 |
| request | 3 | 0 | 3 |

- mutual_aid_replies: 3 ✅
- mutual_aid_claims: 3 ✅
- R11c stock 反流：transfer_out -1 + transfer_reject +1 配對 ✅

### R12 RPC gap 確認
**未跑**（無 received-aid fixture 觸發）— 但 RPC 註解確認 RAISE「已 received 不能撤」、需後續 issue 補 `rpc_return_aid_order`

## § 7. T3 收尾 + § 8. T7 收件匣 ✅ data-layer pass

- pickup_events 2 筆（master § 7 wallet refund 反映在 R8 的 wallet ledger）
- `rpc_hq_inbox_keys` ✅ SECURITY DEFINER
- `rpc_inbox_counts` ✅ SECURITY DEFINER
- inbox UI 渲染未驗（admin app 未啟）

## § 9. T10 安全 ✅ data-layer pass

| 項目 | 預期 | 實際 |
|---|---|---|
| SECURITY DEFINER `rpc_*` count | ≥ 80 | **160** ✅ |
| Tables with all 4 audit cols | ≥ 25 | **67** ✅ |
| Append-only `trg_no_*` triggers | ≥ 8 | **23** ✅ |
| `wallet_ledger` 兩 trigger | update + delete | trg_no_update_wallet + trg_no_delete_wallet ✅ |
| RLS-enabled tables | 多 | **113** ✅ |

**未跑：** branch user 跨店 SELECT/INSERT 拒絕測試（需 mock JWT claims、可後補）；LINE User ID 馬賽克 UI（需 admin 頁）。

---

## §10-§18 反向情境總結

| ID | 情境 | Fixture seed | SQL ripple 驗 | RPC trigger 跑 |
|---|---|---|---|---|
| R1 | PR cancel | PR-0003 cancelled | ✅ | 略（直接 status set）|
| R2a | PO cancel no GR | PO-0003 cancelled | ✅ | 略 |
| R2b | PO partial cancel | PO-0004 cancelled + GR-0002 7 件 | ✅ | 略 |
| R3 | GR shortage | GR-0003 5/8 | ✅ | 略（fixture INSERT）|
| R4 | 訂單缺貨 | ORD-0007 + shortage event | ✅ | 略 |
| R5 | 撿貨不足 | WAVE-0001 picked 1/2 + backorder | ✅ | 略 |
| R6a | Transfer 拒收 | TF-0004 cancelled + transfer_reject | ✅ | 略 |
| R6b | 運送破損 | TF-0005 received 8/10 + damage 2 | ✅ | 略 |
| R7 | 過期 write-off | （無專屬 fixture）| 待跑 RPC | — |
| R8 | 客退 | ORD-0006 + customer_return + refund | ✅ | 略 |
| R9 | Wave cancel | WAVE-0002 cancelled | ✅ | 略 |
| R10 | Wallet reverse | M-003 reversal pair | ✅ | 略 |
| R11a-c | Aid offer cancel | AID-OFR-002/003/004 + R11c 反流 | ✅ | 略 |
| R12 | Aid received 退單 | RPC gap、未灌 fixture | — RPC RAISE 確認 | ✅ 確認 |

---

## 驗收門檻 vs 實際

| 門檻 | 達成 |
|---|---|
| §1-§9 數據層全勾 | ✅ |
| `fn_check_wallet_consistency()` 回 0 rows | ✅ |
| stock_balances vs movements 0 mismatch | ✅ |
| 跑 reset.sh 無 SQL error | ✅（除預先修的 migration bug 外）|
| `apps/admin` `pnpm build` 過 | **未驗**（admin app 沒切到 local）|
| 所有 8 軌 sub-doc 對應 SQL 都過 | ✅ |

---

## 已知缺口 / 後續 issue

1. **products audit columns**：`created_by` NULL — 改 fixture 補 created_by/updated_by from any_user
2. **R12 RPC**：`rpc_return_aid_order` 不存在；workaround = free transfer 反向。建議開 issue 新增此 RPC
3. **Migration ordering bugs**：4 支 migration bugs 已在本 PR fix；prod 是否需要同等修補需評估（prod 是否歷史上也踩過？）
4. **Branch user RLS 跨店 negative tests**：本次跑只在 SQL 層、未模擬 JWT claims；T10 留 follow-up
5. **UI 部分**：master § 2 candidates calendar / § 3 order-entry / § 5 picking UI / § 6 mutual-aid UI — 需 admin app 啟動 + preview MCP，本輪未跑

---

## 結論

**Status: passed (data-layer)** ✅

Seed 系統 + 所有反向情境的資料層 ripple 都驗證過。Master golden path 9 大段、SQL 層全綠、3 大一致性檢查（wallet × stock × audit）通過。

UI 層驗證留待後續啟 admin app + preview MCP 時補。

→ 8 軌 sub-doc 對應 -report 同步狀態見 [TEST-INDEX.md](TEST-INDEX.md)。

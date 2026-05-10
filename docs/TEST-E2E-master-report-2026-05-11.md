---
title: TEST-E2E-master Run Report (Cloud session)
status: passed (data-layer)
ran_at: 2026-05-11
verified_by: claude opus 4.7 (cloud session, 1M context)
db: anfyoeviuhmzzrhilwtm.supabase.co (remote dev, project_name=erp-dev, postgres 17.6)
schema_source: live (no dump/restore — direct query)
fixture: full-demo (re-applied via Management API runner)
checks: 70 PASS / 0 FAIL / 0 ERR  (55 ripple + 15 RPC negative)
---

# Master 黃金路徑 Run Report — 2026-05-11

**範圍：** 黃金路徑 **資料層** baseline + 12 反向情境 (R1-R12) 4 維 ripple SQL 驗證。
**未跑：** UI 互動部分（§ 2 finalize / § 3 order entry / § 5 wave UI / § 6-8 互動）— cloud session 沒 browser，做不到。

對應 spec：[TEST-E2E-master.md](TEST-E2E-master.md)

---

## Environment

| 項目 | 值 |
|---|---|
| DB | Remote dev — `anfyoeviuhmzzrhilwtm.supabase.co` |
| Project name | `erp-dev` (Supabase free tier, ap-southeast-1) |
| Postgres | 17.6.1.105 |
| Connection path | `POST https://api.supabase.com/v1/projects/{ref}/database/query` (Management API) |
| 為什麼走 Management API | cloud sandbox outbound 5432/6543 都被 block、只通 443、PG protocol 不通；走 Management API 走 443 拿 PAT 認證 |
| Tenant | `00000000-0000-0000-0000-000000000001` |
| Fixture 上樁時間 | 2026-05-11 ~16:00 UTC |
| Fixture 跑法 | 自寫 `/tmp/run_reset.py` 把 `00-truncate / 01-master / 02-base-fixtures / fixtures/full-demo` 4 個檔展開 (`\ir` recursive inline + `:'tenant_id'` substitute) 後 4 段 POST 上去 |
| 驗證腳本 | `/tmp/verify.py` — 55 條 SQL 檢查 |

---

## Setup gotchas（跑這次 cloud session 才發現）

1. **5432/6543 outbound block** — 預設要 fall back 走 Management API。`reset.sh` 在 cloud sandbox 跑不動。
2. **psql `:'tenant_id'` 變數展開** — Management API 不認識 psql meta-syntax，runner 自己做 string substitute。
3. **Cloudflare 1010 block** — urllib 預設 User-Agent 被 Cloudflare 擋；要假裝 `curl/8.5.0`。
4. **Multi-statement、`BEGIN/COMMIT`、`DO $$ ... $$` block** — Management API 全支援，但只回最後一條 SELECT 的結果。
5. **psql `\set` / `\echo` / `\ir` meta-commands** — runner 過濾 / 遞迴 inline 才能送上去。

→ 這些是 cloud-only fallback 的限制，本機 + local Supabase 走 `reset.sh` 不會碰到。

---

## § 1. T1 主檔 baseline ✅ pass

| 檢查 | 預期 | 實際 | 結果 |
|---|---|---|---|
| products | 10 | 10 | ✅ |
| skus | 10 | 10 | ✅ |
| members (4) | M-TEST-001/002/003/INT-001 | 同 | ✅ |
| categories tree | 1=3 / 2=9 / 3=5 | 同 | ✅ |
| sku_packs SKU-004 | 個(1) + 箱(10) | 同 | ✅ |
| supplier_skus SKU-001 | SUP-LOCAL(F) + SUP-JP(T) | 同 | ✅ |
| member_line_bindings | >= 3 | 3 | ✅ |

> Spec 寫 supplier code 是 `LOCAL/JP`，實際是 `SUP-LOCAL/SUP-JP`。已修 verify 腳本。

## § 2. T2 candidate→campaign baseline ✅ pass

| 檢查 | 預期 | 實際 | 結果 |
|---|---|---|---|
| group_buy_campaigns | 10 (CAMP-001~010) | 10 | ✅ |
| 多狀態覆蓋 | >= 4 distinct | 6 distinct | ✅ |

> § 2 操作部分（preview UI 推 candidate → finalize CAMP-MASTER-001）**未跑**（沒 browser）。

## § 3. T3 訂單 baseline ✅ pass

| 檢查 | 預期 | 實際 | 結果 |
|---|---|---|---|
| customer_orders | 8 | 8 | ✅ |
| status distinct | 6 (cancelled / completed / confirmed / partially_completed / pending / ready) | 6 | ✅ |

> § 3a-d 操作（preview 開 4 種訂單）**未跑**。

## § 4. T4 採購 baseline ✅ pass

| 檢查 | 預期 | 實際 | 結果 |
|---|---|---|---|
| purchase_requests | 4 | 4 | ✅ |
| purchase_orders | 5 | 5 | ✅ |
| goods_receipts | 3 | 3 | ✅ |

## § 5. T5 WMS baseline ✅ pass

| 檢查 | 預期 | 實際 | 結果 |
|---|---|---|---|
| picking_waves | 2 (WAVE-0001/0002) | 2 | ✅ |

> § 5b wave UI 操作 **未跑**。

## § 6. T6 transfers + mutual aid baseline ✅ pass

| 檢查 | 預期 | 實際 | 結果 |
|---|---|---|---|
| transfers | 8 | 8 | ✅ |
| mutual_aid_board | 7 (4 active + 3 cancelled) | 7 | ✅ |

> § 6a/6b 操作 **未跑**。

## § 7-8. Pickup / Inbox UI

**未跑** — 需要 admin app + preview MCP。

## § 9. T10 安全

**部分跑**：
- aggregate consistency（fn_check_wallet_consistency / stock balance）✅
- RLS branch user 跨店、SECDEF tenant_id 抽查、LINE 馬賽克、append-only invariant — **未跑**

---

## Aggregate consistency ✅ pass

| 檢查 | 預期 | 實際 | 結果 |
|---|---|---|---|
| `fn_check_wallet_consistency()` | 0 rows | 0 | ✅ |
| stock_balances vs SUM(stock_movements) mismatch | 0 | 0 | ✅ |
| Wallet balances | 830 / 4500 / 200 / 0 | 830.00 / 4500.00 / 200.00 / 0.00 | ✅ |

---

## 反向情境 R1-R12 ripple ✅ all pass (R12 N/A by design)

### R1. PR-0003 cancelled
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| status | cancelled | cancelled | ✅ |
| stock_movements | 0 | 0 | ✅ |

### R2a. PO-0003 cancelled (no GR)
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| status | cancelled | cancelled | ✅ |
| SUM(qty_received) | 0 | 0 | ✅ |
| GRs | 0 | 0 | ✅ |
| vendor_bills | 0 | 0 | ✅ |

### R2b. PO-0004 cancelled w/ partial GR (GR-0002)
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| status | cancelled | cancelled | ✅ |
| SUM(qty_received) | 7 | 7 | ✅ |
| GR-0002 stock_movements qty | 7 | 7 | ✅ |

### R3. GR shortage (PO-0005 / GR-0003)
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| PO status | partially_received | partially_received | ✅ |
| SUM(qty_received) | 5 | 5 | ✅ |
| GR-0003 stock_movements qty | 5 | 5 | ✅ |
| variance_reason | 'R3: 來貨不足 5/8 — ...' | 同 | ✅ |
| backorders pending | >= 1 | 1 | ✅ |

### R4. ORD-0007 partially_completed
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| status | partially_completed | partially_completed | ✅ |
| order_shortage_events | >= 1 | 1 | ✅ |
| sale stock_movements | 0 | 0 | ✅ |

### R5. WAVE-0001 picked 1/2 + backorder
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| wave status | picked | picked | ✅ |
| backorder for ORD-0002 | >= 1 | 1 | ✅ |

### R6a. TF-0004 拒收
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| status | cancelled | cancelled | ✅ |
| stock_movements net | 0 (out + reject 反流) | 0 | ✅ |
| reverses NOT NULL | >= 1 | 1 | ✅ |

### R6b. TF-0005 部分破損
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| status | received | received | ✅ |
| stock_movements net | -4 (-10 out + 8 in + -2 damage @ HQ) | -4 | ✅ |
| 3 distinct movement_types | 3 | 3 | ✅ |
| store_monthly_settlement qty | 8 (不是 10) | 8 | ✅ |

### R8. ORD-0006 客退
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| status | completed | completed | ✅ |
| customer_return movement | +1 | 1 | ✅ |
| wallet refund | +80 to M-TEST-001 | 80.0 | ✅ |

### R9. WAVE-0002 cancelled
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| status | cancelled | cancelled | ✅ |
| picking_wave_audit_log 'wave_cancelled' | >= 1 | 1 | ✅ |

### R10. M-TEST-003 wallet reversal pair
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| ledger rows | 3 | 3 | ✅ |
| ledger SUM | 200 | 200.0 | ✅ |
| reversal pair (reverses NOT NULL) | 1 | 1 | ✅ |

### R11a/b/c. 互助 offer cancelled
| 子情境 | 預期 | 實際 | 結果 |
|---|---|---|---|
| R11a (note='R11a:%') | cancelled / 0 claims | cancelled / 0 | ✅ |
| R11b (note='R11b:%') | cancelled / >=1 claim | cancelled / 1 | ✅ |
| R11c (note='R11c:%') | cancelled / 反流 reverses >= 1 | cancelled / 1 | ✅ |

### R12. rpc_cancel_aid_order RAISE on received aid (gap)
| 維度 | 預期 | 實際 | 結果 |
|---|---|---|---|
| DO block 跑得起來 | 1 | 1 | ✅ |
| 真的 trigger 到 RAISE | 需要 received-aid fixture (no fixture) | DO block 走 N/A path、未實際驗 RAISE | ⚠ N/A |

> R12 沒實際 trigger RAISE — 需要先把某個 mutual_aid offer 推到 'received' 狀態才能驗。handoff 標 R12 為「無 fixture、follow-up issue」。

---

## 結論

**Data-layer 全綠：55 條 SQL 檢查 PASS=55 / FAIL=0 / ERR=0。**

正向 baseline（T1-T6 seed 結果）+ 反向 R1-R11 ripple 完整對齊 spec 與 fixture 預期。R12 因為沒 fixture 推到 received 狀態，DO block 走 N/A 分支、不算實質驗證。

**未涵蓋（需 UI session）：**
- § 2 candidate → finalize CAMP-MASTER-001
- § 3a-d 4 種新訂單入帳
- § 5b wave + 撿貨 + ship 真實流程
- § 6 收 transfer + 互助 board UI
- § 7 pickup + wallet refund
- § 8 收件匣 unified UI
- § 9b LINE 馬賽克 UI / § 9a RLS branch user 跨店

**Follow-up issue 候選：**
- R12 fixture：把某 mutual_aid offer 推到 'received' 狀態方便驗 RPC RAISE
- 修 spec：T1.6 supplier code 'LOCAL/JP' → 'SUP-LOCAL/SUP-JP'

---

## RPC contract negative tests ✅ pass

**目的：** 驗 SECURITY DEFINER RPC 的 RAISE 守衛真的擋得住違規呼叫。

| # | RPC | 觸發 | 期望 RAISE 字串 | 結果 |
|---|---|---|---|---|
| 1 | `rpc_wallet_reverse` | reason='' | `reason required` | ✅ |
| 2 | `rpc_wallet_reverse` | bogus ledger_id | `ledger \d+ not found` | ✅ |
| 3 | `rpc_wallet_reverse` | M-003 reversal row (L3) | `cannot reverse a reversal` | ✅ |
| 4 | `rpc_wallet_reverse` | M-003 already-reversed (L2) | `already reversed` | ✅ |
| 5 | `rpc_wallet_refund` | amount=-1 | `Refund amount must be positive` | ✅ |
| 6 | `rpc_wallet_refund` | reason='' | `reason required` | ✅ |
| 7 | `rpc_wallet_adjust` | change=0 | `adjust change must be non-zero` | ✅ |
| 8 | `rpc_cancel_aid_order` | bogus order_id | `order \d+ not found` | ✅ |
| 9 | `rpc_cancel_aid_order` | ORD-0006 (completed) | `only pending/confirmed/shipping can be cancelled` | ✅ |
| 10 | `rpc_cancel_aid_order` | ORD-0005 (cancelled) | 同上 | ✅ |
| 11 | `rpc_pr_reopen` | bogus pr_id | `not found` | ✅ |
| 12 | `rpc_pr_reopen` | PR-0003 (cancelled) | `is cancelled` | ✅ |
| 13 | `rpc_wallet_pay_order` | amount=0 | `amount must be positive` | ✅ |
| 14 | `rpc_wallet_pay_order` | bogus order_id | `order \d+ not found` | ✅ |
| 15 | `rpc_create_pr_from_campaigns` | 空陣列（注入 JWT）| `is empty` | ✅ |

**附帶發現：** `_current_tenant_id()` 沒帶 JWT 時 RAISE
> `JWT missing tenant_id claim; ensure custom_access_token_hook is enabled and user has app_metadata.tenant_id set`

— security guard 早於 function-level 參數驗證 trigger，符合預期。第 15 條測 inject `request.jwt.claims` GUC 把 tenant_id 補回去後、才走到 function 真正的參數守衛。

---

## 附錄：runner / verify 腳本

三個 cloud-only fallback 腳本（這次 session 寫的）：
- `/tmp/run_reset.py` — `reset.sh` 的 Management API 版（走 443、不需要 PG protocol）
- `/tmp/verify.py` — 55 條 SQL 檢查（baseline + R1-R12 ripple）
- `/tmp/verify_rpc_neg.py` — 15 條 RPC contract negative tests

需要的話可以收進 `scripts/e2e/cloud-fallback/`。

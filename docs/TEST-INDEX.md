# TEST-INDEX — 全套 E2E 測試入口

> **目的：** 把現有 31 份 TEST 文件 + 8 軌 E2E sub-doc + 1 主黃金路徑串成可重複跑的回歸測試套件。
> **執行模式（決策已鎖）：** master + 子文件 / 半手動（SQL/RPC 驗 + preview UI）/ 跳過 LIFF & PWA push。
> **規劃文件：** `C:\Users\Alex\.claude\plans\q1-c-q2-b-expressive-emerson.md`

---

## 怎麼跑

### 前置：seed
1. 確認 `scripts/e2e/.env.e2e` 設定（`E2E_EXPECTED_HOST` 防呆）
2. `bash scripts/e2e/reset.sh full-demo --yes`
3. 抓尾段 row count 表當 baseline，貼進 `TEST-E2E-master.md` § Prerequisites

### 主黃金路徑
跑 `docs/TEST-E2E-master.md` 全 13 步、產 `TEST-E2E-master-report.md`

### 各軌道（依序或挑跑）
1. `reset.sh full-demo --yes`（每軌前都 reset 一次乾淨）
2. 跑該軌道既有 docs（`run-feature-tests` skill）
3. 跑該軌道 sub-doc 的 gap addendum
4. 跑 master 對應 sections
5. 結 sub-doc rolling `-report.md`、勾回此表

### ⚠ 安全提醒
**永遠別把 `reset.sh` 跑到 prod connection。** `.env.e2e` `E2E_EXPECTED_HOST` 防呆只擋換 project、不擋 prod 自殺。

---

## 軌道（8 in scope）

> **2026-05-10 首輪 SQL-layer pass**：local Supabase + prod schema dump + reset.sh full-demo。資料層全綠、UI 層未跑（admin app 沒切到 local）。詳見 [TEST-E2E-master-report.md](TEST-E2E-master-report.md)。

| Track | 主文件 | 範圍 | 狀態 | 最近驗證 | Report |
|---|---|---|---|---|---|
| T1 主檔 | [TEST-E2E-T1-master-data.md](TEST-E2E-T1-master-data.md) | 商品/SKU/規格/加盟店/會員/員工/audit cols | 🟢 (SQL) | 2026-05-10 | master § 1 |
| T2 候選→開團 | [TEST-E2E-T2-campaign.md](TEST-E2E-T2-campaign.md) | 候選週曆/campaign/finalize/auto-PR | 🟡 (SQL data) | 2026-05-10 | master § 2（UI 未跑） |
| T3 訂單+wallet | [TEST-E2E-T3-orders-wallet.md](TEST-E2E-T3-orders-wallet.md) | admin 加單/轉手/88折/soft-cancel/負數/wallet a-d/R4 R8 R10 | 🟢 (SQL) | 2026-05-10 | master § 3 |
| T4 採購 | [TEST-E2E-T4-purchase.md](TEST-E2E-T4-purchase.md) | PR/PO/GR + R1 R2a R2b R3 + vendor_bills + purchase_returns | 🟢 (SQL) | 2026-05-10 | master § 4 |
| T5 WMS 出貨 | [TEST-E2E-T5-wms-shipping.md](TEST-E2E-T5-wms-shipping.md) | Wave/Pick/Ship/Receive/逆轉 + R5 R9 + 異常處理 | 🟢 (SQL) | 2026-05-10 | master § 5 |
| T6 退貨/轉貨 | [TEST-E2E-T6-returns-transfers.md](TEST-E2E-T6-returns-transfers.md) | free transfer/store→HQ/aid + R6a R6b R7 R11a-d R12 | 🟢 (SQL) | 2026-05-10 | master § 6（R12 是 RPC gap）|
| T7 收件匣 | [TEST-E2E-T7-inbox.md](TEST-E2E-T7-inbox.md) | HQ inbox + restock + counts RPC | 🟡 (SQL data) | 2026-05-10 | master § 8（UI 未跑）|
| T10 安全 RLS | [TEST-E2E-T10-security-rls.md](TEST-E2E-T10-security-rls.md) | RLS 矩陣/SECURITY DEFINER/LINE 馬賽克/audit 4 欄位 | 🟡 (SQL data) | 2026-05-10 | master § 9（branch user negative tests + LINE mask UI 未跑）|

### 主黃金路徑
| 文件 | 說明 | 狀態 | Report |
|---|---|---|---|
| [TEST-E2E-master.md](TEST-E2E-master.md) | 13 步串全鏈黃金路徑（候選→開團→訂單→採購→撿貨→派貨→收貨→退貨→月結）| 🟢 (data-layer) | [report](TEST-E2E-master-report.md) |

**Legend：** 🟢 (SQL) 資料層全驗 / 🟡 (SQL data) 資料齊但 UI 未跑 / 🆕 全新未跑 / 🔴 失敗

---

## 既有 31 份 TEST 文件分類（P1 triage 結果）

> **規則：** 🟢 GREEN（有 -report.md status: passed）/ 🟡 YELLOW（無 report、跑前 refresh 或直接跑）/ 🔴 RED（migration/RPC/path 已不存在、需 rewrite）/ ⚪ SKIP（不在範圍）

| 文件 | 軌 | 等級 | 動作 |
|---|---|---|---|
| TEST-B3-products-ext.md | T1 | 🟢 | relink、有 -report |
| TEST-core-modules.md | T1 | 🟢 | relink、有 -report |
| TEST-member-merge-ux.md | T1 | 🟡 | 跑 |
| TEST-member-tabs-notifications.md | T1 | 🟡 | 跑 |
| TEST-member-type-guest.md | T1 | 🟡 | 跑 |
| TEST-candidate-to-draft-and-pricing.md | T2 | 🟡 | 跑 |
| TEST-campaign-finalize.md | T2 | 🟡 | 跑 |
| TEST-campaign-to-purchase.md | T2 | 🟡 | 跑 |
| TEST-close-campaign-auto-new-pr.md | T2 | 🟡 | 跑 |
| TEST-order-entry-mvp0.md | T3 | 🟡 | 跑 |
| TEST-order-entry-store-internal.md | T3 | 🟢 | relink、有 -report |
| TEST-order-transfer.md | T3 | 🟢 | relink、有 -report |
| TEST-order-transfer-button.md | T3 | 🟡 | 跑 |
| TEST-orders-edit.md | T3 | 🟡 | 跑 |
| TEST-訂單刪除與負數訂單.md | T3 | 🟡 | 跑 |
| TEST-order-expiry-events.md | T3 | 🟡 | 跑 |
| TEST-order-shortage-events.md | T3 | 🟡 | 跑 |
| TEST-wallet-phase-a.md | T3 | 🟡 | 跑 |
| TEST-wallet-phase-b.md | T3 | 🟡 | 跑 |
| TEST-wallet-phase-c.md | T3 | 🟡 | 跑 |
| TEST-wallet-phase-d.md | T3 | 🟡 | 跑 |
| TEST-pr-manual-creation.md | T4 | 🟡 | 跑 |
| TEST-picking-require-po.md | T4/T5 | 🟡 | 跑 |
| TEST-arrive-and-distribute.md | T5 | 🟡 | 跑 |
| TEST-hq-dispatch-ui.md | T5 | 🟢 | relink、有 -report |
| TEST-rpc-receive-transfer.md | T6 | 🟡 | 跑 |
| TEST-transfer-hq-dispatch.md | T6 | 🟢 | relink、有 -report |
| TEST-mutual-aid-board.md | T6 | 🟢 | relink、有 -report |
| TEST-store-self-service.md | T7 | 🟡 | 跑（部分 cover）|
| TEST-LIFF-overview-orders-settlements.md | — | ⚪ | LIFF、本次跳過 |
| TEST-deploy-admin.md | — | ⚪ | infra deploy、不算 feature |

**統計：** 6 GREEN + 22 YELLOW + 2 SKIP + 1 跨軌 (picking-require-po)

---

## 排除（不在 8 軌）

- LIFF 真機（TEST-LIFF-*.md）— 真機 / Safari / LINE in-app 環境難自動化
- PWA push 真機 — iOS PWA Web Push 訂閱 timeout / SW 重加主畫面踩雷
- TEST-deploy-admin — 部署 infra
- POS / 銷售 / pos_sales / customers — 與團購流程平行、本次不測

---

## 慣例

- 既有 31 份 docs：保留 5 段格式（Schema/Migration → RPC 行為 → UI 行為 → Regression → 驗收門檻）
- 新 sub-doc：用 meta + gap addendum（軌道 ≥2 既有 docs）或 inline checklist（T7/T10 沒既有 docs）
- 各 sub-doc 跑完一輪 → 寫 rolling `TEST-E2E-T{n}-*-report.md`、回填此 INDEX
- 主黃金路徑跑完 → `TEST-E2E-master-report.md`
- 反向情境（R1-R12）對應 fixture 在 `scripts/e2e/fixtures/` 已備好

---

## 反向情境清冊（在哪測）

| # | 反向情境 | 對應軌道 | Fixture 種子位置 |
|---|---|---|---|
| R1 | PR 取消 | T4 | with-pr-po.sql / PR-0003 |
| R2a | PO 取消（無 GR）| T4 | with-pr-po.sql / PO-0003 |
| R2b | PO 取消（部分 GR）| T4 | with-pr-po.sql / PO-0004 + GR-0002 |
| R3 | GR 來貨不足 | T4 | with-pr-po.sql / PO-0005 + GR-0003 |
| R4 | 訂單缺貨 | T3 | with-orders.sql / ORD-0007 + order_shortage_events |
| R5 | 撿貨不足量 | T5 | with-picking-wave.sql / WAVE-0001 + backorder |
| R6a | Transfer 拒收 | T6 | with-transfers.sql / TF-0004 + transfer_reject |
| R6b | 運送遺失/破損 | T6 | with-transfers.sql / TF-0005 + damage |
| R7 | 店家發現過期 | T6/T5 | （走 R6b 同 RPC `rpc_register_damage`）|
| R8 | 顧客取貨後反悔 | T3 | with-orders.sql / ORD-0006 + customer_return movement + wallet refund |
| R9 | Wave 整單取消 | T5 | with-picking-wave.sql / WAVE-0002 |
| R10 | Wallet topup 反向 | T3 | with-wallet-history.sql / M-TEST-003 reversal |
| R11a | 互助 offer 取消（無 claim）| T6 | with-mutual-aid.sql / AID-OFR-002 |
| R11b | 互助 offer 取消（有 cancelled claim）| T6 | with-mutual-aid.sql / AID-OFR-003 |
| R11c | 互助 offer 取消（已 ship）| T6 | with-mutual-aid.sql / AID-OFR-004 + TF-AID-002 |
| R12 | 互助 received 後對方退單 | T6 | **RPC gap** — 用 free transfer 反向 workaround |

---

## 跑法 cheatsheet

```bash
# 黃金路徑（master）
bash scripts/e2e/reset.sh full-demo --yes
# → 開 admin、依 TEST-E2E-master.md § 1 ~ § 13 逐步跑、寫 report

# 個別軌道
bash scripts/e2e/reset.sh full-demo --yes
# → 用 run-feature-tests skill 跑該軌道既有 docs
# → 跑 sub-doc gap addendum
# → 寫 rolling report

# 全套（big-bang）
# Day 1: P0+P1+master+T3
# Day 2: T1/T2/T4
# Day 3: T5/T6/T7
# Day 4: T10
# Day 5: master rerun
```

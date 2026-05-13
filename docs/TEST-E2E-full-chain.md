---
title: E2E 完整鏈路測試 — 建商品 → 取貨 (Spec + Runbook)
module: Cross-module / E2E
status: passed
created: 2026-05-14
last_run: 2026-05-14
verified_by: alex.chen + claude
db: anfyoeviuhmzzrhilwtm (dev)
marker: E2E-CHAIN-260514
runbook: scripts/e2e/full_chain/run_all.cjs
---

# E2E 完整鏈路測試

## 目的

驗證 ERP「建商品 → 顧客取貨」這條主鏈路在資料層完整跑得通：每個 RPC 串接正確、stock / wallet / order 三條 ledger 都對得上、schema invariants 全綠。

## 覆蓋範圍

| 模組 | 涵蓋的 RPC / Flow |
|---|---|
| Products | 建 product + SKU + prices (retail/branch/cost) + supplier_skus |
| Campaigns | 建 campaign + campaign_item + close → auto PR (trigger 同步 join 表) |
| Orders | 建 customer_orders + items (3 張 / 3 店 / 30 件) |
| Purchase | submit / approve / split PR → PO / send PO / GR / confirm |
| WMS | rpc_create_wave_from_po / confirm_picked / generate_transfer / mark_shipping |
| Transfer | rpc_receive_transfer × 3 |
| Pickup | wallet pay / cash settle / rpc_record_pickup (含 stock_movement 扣帳) |

## 12 步流程

```
1. setup        建 product / SKU / prices / supplier_skus
2. (併 1)       建 campaign + campaign_item
3. orders       3 顧客訂單 (松山 15 / 萬華 10 / 四號 5)
4. close        rpc_close_campaign → auto-create PR (close_date)
5. pr_po_gr     submit PR → approve → split PO → send → GR confirm
6. (併 5)       GR confirmed → stock +30 @ HQ
7. wave         create wave from PO → confirm picked → generate transfer × 3
8. receive      rpc_receive_transfer × 3 → stock 進各分店
9. pickup       顧客取貨 → wallet/cash 結帳 → stock 扣分店 → order completed
10. invariants  fn_check_* × 4 + state assertions
```

## 一鍵執行

```bash
node scripts/e2e/full_chain/run_all.cjs
```

預期約 5-10 秒、最後一行：
```
✅ All steps done in Xs
```

## 個別執行（debug 用）

| Script | 對應 Step |
|---|---|
| `scripts/e2e/full_chain/01_setup.cjs` | Step 1+2 (Products + Campaign) |
| `scripts/e2e/full_chain/03_orders.cjs` | Step 3 (Orders) |
| `scripts/e2e/full_chain/04_close.cjs` | Step 4 (Close campaign) |
| `scripts/e2e/full_chain/05_pr_po_gr.cjs` | Step 5+6 (PR/PO/GR) |
| `scripts/e2e/full_chain/07_wave.cjs` | Step 7 (Wave + Transfer) |
| `scripts/e2e/full_chain/08_receive.cjs` | Step 8 (Receive transfers) |
| `scripts/e2e/full_chain/09_pickup.cjs` | Step 9 (Pickup SQL fallback) |
| `scripts/e2e/full_chain/10_invariants.cjs` | Step 10 (Final invariants) |

每個 script 都 idempotent — reuse 既有 marker 資料、重跑安全。

## UI 互動點（C 路徑混合）

完整 user-facing UX 建議至少手動跑一次：

1. **`/wms/picking`** — 看派貨工作台顯示 E2E SKU、按「自動分配」+「建立撿貨單」
2. **`/pickup?q=M-TEST-002`** — 搜會員、點 `✅ 取貨`、用儲值金結帳、看 modal 流程

UI 跑完後重跑 Step 7-10 SQL script 補完其餘訂單。

## Marker 隔離

所有 test 資料用 `E2E-CHAIN-260514` 開頭：
- Product: `R-E2E-CHAIN-260514-001 / E2E-CHAIN-260514 蜂蜜茶`
- SKU: `SKU-E2E-CHAIN-260514-001`
- Campaign: `GB-E2E-CHAIN-260514-001 / E2E-CHAIN-260514 蜂蜜茶 #1`
- Orders: `E2E-CHAIN-260514-O1/2/3`
- GR: `E2E-CHAIN-260514-GR-17`

事後識別 / cleanup 可用 `WHERE ... LIKE 'E2E-CHAIN-260514%'`。

## 預期最終狀態

```
fn_check_pr_campaigns_consistency      : 0 ✓
fn_check_pickup_movements_consistency  : 0 ✓
fn_check_wallet_consistency             : 0 ✓
stock_balances vs Σ movements          : 0 ✓

Campaign 18           : closed
PR 13                 : fully_ordered
PO 17                 : fully_received
Wave 13               : shipped (or closed)
Transfers (WAVE-13-S*): 3/3 received
Orders                : 3/3 completed (status / payment_status='paid')

SKU 16 stock:
  HQ:        0  (+30 -5 -10 -15)
  松山店倉:  0  (+15 -15)
  萬華店倉:  0  (+10 -10)
  四號店倉:  0  (+5  -5)
```

## 沿途發現的 bug + 修復

跑這條鏈路 2026-05-14 第一次跑出 2 個 critical bug、已在同一輪修復：

### Bug 1: PR ↔ Campaigns 不同步 (PO 撿不到貨)

`rpc_create_pr_from_close_date` + `rpc_append_campaign_to_pr` 漏寫 `purchase_request_campaigns` join 表、`v_picking_demand_by_po` 因此找不到 demand。

| Migration | 角色 |
|---|---|
| [20260614000010_fix_pr_campaigns_sync.sql](../supabase/migrations/20260614000010_fix_pr_campaigns_sync.sql) | view fallback + 2 RPC 補寫 + backfill |
| [20260614000020_pr_campaigns_invariant_trigger.sql](../supabase/migrations/20260614000020_pr_campaigns_invariant_trigger.sql) | AFTER INSERT/UPDATE trigger auto-sync + `fn_check_pr_campaigns_consistency()` + migration self-check |

Spec: [TEST-pr-campaigns-invariant.md](TEST-pr-campaigns-invariant.md)

### Bug 2: 取貨後分店 stock 沒扣

`rpc_record_pickup` 漏寫 `stock_movements` (type='sale')、漏回填 `customer_order_items.pickup_movement_id`、所有歷史取貨分店帳面庫存膨脹。

| Migration | 角色 |
|---|---|
| [20260614000030_fix_pickup_stock_movement.sql](../supabase/migrations/20260614000030_fix_pickup_stock_movement.sql) | RPC 修 + backfill 歷史 + `fn_check_pickup_movements_consistency()` + self-check |

Spec: [TEST-pickup-stock-invariant.md](TEST-pickup-stock-invariant.md)

## Troubleshooting

| 症狀 | 原因 | 解法 |
|---|---|---|
| `JWT missing tenant_id claim` | SECURITY DEFINER RPC 需要 JWT、pg client 沒帶 | `_db.cjs` 的 `setJwt()` 在 transaction 內注入 |
| `分店 X 未設定倉庫位置` | store.location_id 是 NULL | `INSERT INTO locations` + `UPDATE stores SET location_id=...` |
| `PR X already submitted` | 重跑、PR 已 advance status | scripts 已 idempotent、會 skip / reuse |
| `分配 X 超過可分配量 0`（wave）| wave 已建過 | scripts 已 idempotent、reuse 既有 wave |
| `member status=merged cannot be charged` | member 是 merged 會員 (M-TEST-003 已 merge) | Step 9 fallback 用 cash 結帳 |

## 不該做

- ❌ 跑 cleanup script 後重跑前、別在 prod 跑（會刪商品 / campaign）
- ❌ 直接跑這 chain 在有真實顧客資料的 DB；只跑 dev (anfyoeviuhmzzrhilwtm)
- ❌ 修改 marker 後再跑（會建第二批、混淆）

## 未來擴充

| 想加 | 怎麼加 |
|---|---|
| 反向情境 (R1-R12) | 在 Step 10 之後加 `11_reverse.cjs`、跑取消訂單 / 退貨 / 派貨 cancel |
| 全 UI 跑 | 把 03/07/09 改成 preview tool 操作 (慢、有 UI bug 抓到) |
| 多商品 / 多 campaign | 修改 `MARKER` + 用環境變數參數化 |
| Cleanup script | trigger 擋 DELETE products/skus、需 cascade UPDATE status='discontinued' 並反向 stock_movements |

## 相關文件

- [TEST-E2E-full-chain-report-2026-05-14.md](TEST-E2E-full-chain-report-2026-05-14.md) — 2026-05-14 首次執行 audit 報告
- [TEST-pr-campaigns-invariant.md](TEST-pr-campaigns-invariant.md) — Bug 1 invariant spec
- [TEST-pickup-stock-invariant.md](TEST-pickup-stock-invariant.md) — Bug 2 invariant spec
- [TEST-E2E-master.md](TEST-E2E-master.md) — 既有 E2E 黃金路徑 spec

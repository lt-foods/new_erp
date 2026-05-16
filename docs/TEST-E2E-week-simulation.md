---
title: E2E 一週混亂模擬 — 真實大規模壓測
module: Cross-module / E2E
status: in_progress
created: 2026-05-14
db: anfyoeviuhmzzrhilwtm (dev)
marker: E2E-WEEK-260514
runbook: scripts/e2e/week_simulation/run.cjs
---

# E2E 一週混亂模擬

## 目的

模擬「總倉很混亂」的真實 7 天日常：
- 每天開 20 團
- 每團 1-3 個 SKU、覆蓋 5-15 店、每店 10-50 訂單
- PR / 採購 / 收貨 / 撿貨 / 派貨 / 取貨 全部 **隨機交叉時間**
  - 禮拜一下的單可能禮拜三才到貨
  - 禮拜二的團可能禮拜五才撿貨
- 全現金結帳、無取消、無缺貨
- **每張訂單必須走真實 RPC 鏈、留完整 audit trail**

## 規模預估

| 維度 | 範圍 | 預估總量 |
|---|---|---|
| 天數 | 7 | — |
| 每日開團 | 20 | 140 團 |
| 每團 SKU | 1-3 (uniform) | 平均 2 |
| 每團覆蓋店家 | 5-15 (uniform) / 23 stores | 平均 10 |
| 每團每店訂單 | 10-50 (uniform) | 平均 30 |
| 每訂單 qty | 1-5 (uniform) | 平均 3 |
| **總訂單** | — | **~42,000** |
| **總 order items** | — | **~84,000** |
| **總件數** | — | **~250,000** |
| **stock_movements** | — | **~500,000** |

## 不可妥協原則

### 1. 完整 RPC chain — 不繞過 trigger / FK

每張訂單必須真實走過：

```
campaign_items
  ↓ campaign_item_id (FK)
customer_order_items
  ↓ order_id (FK)
customer_orders
  ↓ campaign_id (FK)
group_buy_campaigns
  ↓ rpc_close_campaign
purchase_requests + purchase_request_campaigns (trigger auto-sync)
  ↓ rpc_submit_pr → rpc_split_pr_to_pos
purchase_orders + purchase_order_items
  ↓ rpc_send_purchase_order
PO sent
  ↓ INSERT goods_receipts + items → rpc_confirm_gr
stock_movement (purchase_receipt @ HQ)
  ↓ rpc_create_wave_from_po → rpc_confirm_picked → generate_transfer_from_wave
picking_waves + items + transfers
  ↓ rpc_receive_transfer
stock_movement (transfer_out @ HQ, transfer_in @ store)
  ↓ UPDATE customer_orders payment_status='paid' (cash)
  ↓ rpc_record_pickup
stock_movement (sale @ store, 含 pickup_movement_id 回填)
```

### 2. Audit trail 完整

每個 day-tick 把所有「建立 / 連結」事件寫進
`scripts/e2e/week_simulation/audit/day_N.json`，含：
- 開團 → campaign_id / name / SKU list
- 訂單 → order_id / order_no / campaign_id / member_id / store_id / SKU+qty
- PR → pr_id / pr_no / 對應 campaigns / SKU 聚合量
- PO → po_id / po_no / supplier / 對應 PR / SKU+qty
- GR → gr_id / gr_no / 對應 PO / SKU+收貨量
- Wave → wave_id / wave_code / 對應 PO / 各店 alloc
- Transfer → transfer_id / transfer_no / 對應 wave / store / SKU+qty
- Pickup → event_id / 對應 order / movement_id

跑完 `verify.cjs` 隨機抽 30 張訂單回溯整條 chain、驗證每一節點存在 + FK 對齊。

### 3. Marker 隔離

`E2E-WEEK-260514` 前綴所有資料：
- Campaign: `GB-WEEK-D{day}-{seq}` (1-20 per day)
- Order: `WK-D{day}-{seq}` (auto seq)
- PR: 自動編號（系統的 `rpc_next_pr_no`）— 但 source_type='campaign' 用既有 campaign_id 對應
- PO: 自動編號
- GR: `WK-GR-D{day}-{po_id}`
- Wave: 系統自動編號

事後 cleanup 用 `marker = name LIKE 'E2E-WEEK-260514%'` 串入既有 `99_cleanup.cjs`。

## 隨機混亂模型

### 時間軸事件池

每天 (Day N) 跑：

```
1. 開新團 (20 張)
2. 顧客下單到「open 中的所有團」(包含 N-1, N-2 等之前的團)
3. 關掉「end_at <= today」的團 → auto-create PR
4. 從「PR 等候池」隨機抽 0-15 張 → submit + split PO + send
5. 從「sent PO 等候池」隨機抽 0-20 張 → 建 GR + confirm (但可能不是同天的 PO)
6. 從「fully_received PO 等候池」隨機抽 0-10 張 → 建 wave + 派貨
7. 從「shipped transfer 等候池」隨機抽 0-30 張 → 各店收貨
8. 從「ready customer order 等候池」隨機抽 0-200 張 → 取貨 + 現金結帳
```

關鍵：**池子是跨天累積的**、不是「當天事件當天處理完」。Day 1 的 PR 可能 Day 3 才拆 PO、Day 5 的 PO 可能 Day 7 才收貨。

### 機率分布

| 行為 | 機率 |
|---|---|
| 顧客下單到某團 | 開團當天 50%、後續每天 25% 遞減 |
| PR 拆 PO 延遲 | 0 天 30% / 1 天 40% / 2 天 20% / 3+ 天 10% |
| GR 收貨延遲 | 1 天 20% / 2 天 40% / 3 天 25% / 4-5 天 15% |
| Wave 建立延遲 | 0 天 40% / 1 天 35% / 2 天 25% |
| Transfer 分店收貨延遲 | 0 天 50% / 1 天 30% / 2 天 20% |
| 取貨延遲 | 0 天 40% / 1 天 25% / 2-3 天 25% / 4-7 天 10% |

### Seed deterministic

`SEED` 環境變數固定隨機 seed、同 seed 跑出同結果。Default seed = `'week-260514'`。

```bash
SEED=foo node scripts/e2e/week_simulation/run.cjs
```

## 預設參數（可改）

| 參數 | Default | 說明 |
|---|---|---|
| `DAYS` | 7 | 跑幾天 |
| `CAMPAIGNS_PER_DAY` | 20 | 每日開團數 |
| `SKUS_PER_CAMPAIGN` | [1, 3] | uniform |
| `STORES_PER_CAMPAIGN` | [5, 15] | uniform |
| `ORDERS_PER_STORE` | [10, 50] | uniform |
| `QTY_PER_ITEM` | [1, 5] | uniform |
| `START_DATE` | today (TPE) | 模擬 Day 1 |
| `SEED` | 'week-260514' | RNG seed |

## 跑完後驗證

```bash
node scripts/e2e/week_simulation/verify.cjs
```

驗證：
1. **4 個 invariants** 全 0：
   - `fn_check_pr_campaigns_consistency`
   - `fn_check_pickup_movements_consistency`
   - `fn_check_wallet_consistency` (0、因為全現金沒 wallet 動)
   - `stock_balances vs Σ movements`

2. **Chain traceability 抽樣**：隨機抽 30 張 completed orders、回溯：
   - order → campaign → campaign_item ✓
   - order → PR (via campaign) → PO → GR ✓
   - PR → wave → transfer ✓
   - transfer → received → stock_in @ store ✓
   - order → pickup_event → stock_sale @ store ✓
   - 訂單金額 = pickup 後的 wallet/cash 結算 ✓

3. **聚合驗證**：
   - sum(orders qty) == sum(PO qty_ordered) — 假設無缺貨
   - sum(GR qty_received) == sum(PO qty_ordered)
   - sum(wave allocated) == sum(GR qty_received)
   - sum(transfer received) == sum(wave allocated)
   - sum(pickup qty) == sum(order qty)
   - sum(stock_movements per location per sku) == stock_balances on_hand

4. **每日報表**：
   - 開了幾團、收了多少訂單、貨在哪
   - 各天各店的 backlog（pending wave / pending pickup）

## 預期最終狀態

跑完 Day 7 + 等所有 pending 都處理完（隔幾天再跑剩餘 tick）：

- 140 campaigns 全 closed
- ~42K orders 大部分 completed (少數 still pending 因為時間還沒到)
- All POs fully_received
- All transfers received
- 各分店 stock 接近 0（全取走了）
- 4 invariants 全 0

## Cleanup

把 `MARKERS` 加進 [99_cleanup.cjs](../scripts/e2e/full_chain/99_cleanup.cjs):

```js
const MARKERS = [
  'E2E-CHAIN-260514',
  'E2E-WEEK-260514',  // ← 新加
];
```

跑 `node scripts/e2e/full_chain/99_cleanup.cjs --yes` 全清。

## 預估執行時間

42K orders × 多步 RPC = 約 **30-60 分鐘**
（單個 transaction 慢、要 batch）

Optimization 策略：
- Batch INSERT 用 multi-row VALUES (一次塞 100-500 筆)
- RPC 只在「狀態轉換」呼叫、不是每筆 RPC
- 隨機池操作用 Map/Set 不 query DB

## 相關

- [TEST-E2E-full-chain.md](TEST-E2E-full-chain.md) — single chain 驗證
- [TEST-pr-campaigns-invariant.md](TEST-pr-campaigns-invariant.md)
- [TEST-pickup-stock-invariant.md](TEST-pickup-stock-invariant.md)

# order-return-entry 測試項目 — 已收貨單一鍵導向退貨回總倉

**對應 migration:** 無（沿用既有 `rpc_create_order_return`，`OrderReturnCreateModal` 已上線）
**對應 UI 變更:** `apps/admin/src/app/(protected)/orders/page.tsx`、`apps/admin/src/app/(protected)/pickup/page.tsx`
**對應 PRD:** `docs/PRD-LIFF前端.md`（銷售/退貨）

> 背景：使用者反映 `GB20260511-C000003-0001` 這類**已收貨/已到貨**團購單「為什麼不能取消」。取消規則刻意不開放已收貨單（避免取消已派/已取貨）；正解是走既有「退貨回總倉」。本功能**不改取消規則**，只在訂單頁/取貨頁對這類單顯示原因並一鍵帶到既有 `OrderReturnCreateModal`（prefill 該單）。

## 1. Schema / Migration 層

- [ ] 無新增 migration（`git diff origin/main...HEAD -- supabase/migrations/` 為空）
- [ ] 無新增 / 變更 RPC（沿用 `rpc_create_order_return`）

## 2. RPC 行為（沿用既有，僅複核）

> 不新增 RPC。複核 `OrderReturnCreateModal` 仍以 prefill 的 order/store 正常呼叫 `rpc_create_order_return`：

### 2.1 prefill 帶入
**情境：** 從訂單頁/取貨頁某 `ready` 單按「↩ 退貨」。
**預期：** modal 開啟即定在該單（跳過 store/order picker），SKU 表顯示 delivered / already_returned / returnable。

### 2.2 既有 guardrail 不變
**情境：** 送出退貨。
**預期：** 沿用 `rpc_create_order_return` 既有限制（status ∈ shipping/ready/partially_completed/completed/expired；qty ≤ delivered − already_returned），錯誤照舊經 `translateRpcError` 顯示。

## 3. UI 行為（preview 互動）

### 3.1 訂單頁 — ↩ 退貨 鈕 gating
- [ ] `ready` / `partially_completed` 單：操作欄出現「↩ 退貨」鈕（與「去取貨」並存）
- [ ] `completed` 單：「已完成」灰標旁出現「↩ 退貨」
- [ ] `expired` 單：「已逾期」灰標旁出現「↩ 退貨」
- [ ] `pending` / `confirmed` / `shipping`：**不出現**「↩ 退貨」（這些走「取消」）
- [ ] `cancelled` / `transferred_out`：**不出現**「↩ 退貨」（不可退）
- [ ] 「↩ 退貨」鈕 hover tooltip 明確說明：已收貨/已取貨，無法取消，點此退貨回總倉

### 3.2 訂單頁 — 一鍵開 modal
- [ ] 按「↩ 退貨」→ `OrderReturnCreateModal` 開啟且 prefill 該 `orderId` + `pickup_store_id`
- [ ] modal 內成功送出退貨 → modal 關閉、訂單列表 reload
- [ ] modal「取消/關閉」→ 不送出、回列表，原訂單狀態不變

### 3.3 取貨頁 — ↩ 退貨 鈕
- [ ] `ready` / `partially_completed` 單：在「🔔 通知 / ✅ 取貨」旁出現「↩ 退貨」
- [ ] `pending` / `confirmed` / `reserved` / `partially_ready` / `shipping`：**不出現**「↩ 退貨」
- [ ] 按下 → prefill 該單開 modal；成功送出 → reload 搜尋

### 3.4 GB20260511-C000003-0001 情境
- [ ] 該團購單若為 ready/partially_completed/completed/expired → 訂單頁搜尋後可見「↩ 退貨」，一鍵進退貨流程（不再「卡住無路可走」）

## 4. Regression
- [ ] 取消規則**完全未動**：`rpc_cancel_aid_order` 與訂單頁/取貨頁既有「取消」鈕 gating（pending/confirmed/shipping）行為不變
- [ ] `OrderDetail` 內既有「↩ 退訂單」鈕、其 `OrderReturnCreateModal`（prefill）行為不變
- [ ] 訂單頁：搜尋(若 #257 已併)、開團/取貨店 filter、明細 Modal、分頁、去取貨、KPI 卡不受影響
- [ ] 取貨頁：搜尋、常用顧客、通知、PickupDialog 取貨、一次全取、列印不受影響
- [ ] `wms/transfers` 頁的退貨入口不受影響（共用同一 modal 元件）

## 5. 驗收門檻

全部 §3-§4 勾完、**無 console error**、**build + type-check 過** 才可標 done。（無 migration / 新 RPC，§1-§2 僅複核。）

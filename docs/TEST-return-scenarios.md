# 退回總倉 5 情境測試項目 — Return Scenarios

涵蓋：退貨 / 缺貨 / 少領 / 損壞 / 過期。對應 PR #202 + 後續修補。

---

## 0. 機制總覽

| 情境 | 訂單 status | 走哪條 | movement_type | 已實作 |
|------|------------|-------|--------------|-------|
| A 退貨（客戶取後反悔） | completed | rpc_create_order_return | customer_return | 半套（要先 inbound 才能 outbound）|
| B 缺貨（總倉沒貨） | pending/confirmed | rpc_handle_shortage_order | — | ✅ |
| C 少領（部分取貨剩餘） | partially_completed | rpc_create_order_return | customer_return | ✅ |
| D 損壞（店收到破損） | shipping/ready/completed | rpc_create_order_return | customer_return（reason 標破損）| ⚠️ movement 不分 |
| E 過期（沒取） | expired | rpc_create_order_return | customer_return | ❌ canReturn 漏含 expired |

**TODO 修補**：
1. **E**：把 `'expired'` 加到 `canReturn` + RPC 允許 status
2. **D**：rpc_create_order_return 加 `p_movement_type` 參數（`customer_return` / `damage` / `expired_return`）；UI 加類型選單
3. **A**：客戶退貨需先 `rpc_inbound(movement_type='customer_return')` 把貨放回店端、再走 return_to_hq；目前流程要店員自己手動 inbound

---

## A. 退貨（客戶取貨後反悔）

### 前置
- 訂單 X：客戶已取 5 個 SKU-009、訂單 status = `completed`
- 店端 SKU-009 庫存：0（因為已 picked_up 了）

### 測試
- [ ] **A.1**：客戶把 2 個 SKU-009 拿回店、店員先做 `rpc_inbound(movement_type='customer_return', source_doc='customer_order', source_doc_id=X)` 把店端庫存 +2
- [ ] **A.2**：店端開 OrderDetail popup → `↩ 退訂單` → 退 2 → 成功
- [ ] **A.3**：驗證 stock_movements：店端 +2 (customer_return inbound) + -2 (customer_return outbound to HQ)
- [ ] **A.4**：驗證 transfer：return_to_hq, qty_shipped=2, customer_order_id=X
- [ ] **A.5**：HQ 收貨後 stock_balances HQ +2

### 邊界
- [ ] **A.6**：跳過 A.1（沒先 inbound）→ 直接 A.2 → 應 fail with `Insufficient stock`
- [ ] **A.7**：A.2 重做（再退 2 個）→ 第二次跑前要再 inbound、否則 Insufficient stock
- [ ] **A.8**：超量退（A.2 退 6 但訂單只訂了 5）→ fail with `qty exceeds returnable`

---

## B. 缺貨（總倉沒貨可配給店）

⚠️ **不是退回總倉**，貨從來沒派出去過。但仍是「客戶訂了拿不到」的處理流程。

### 前置
- 客戶訂 10 個 SKU-X
- 總倉 + 在途 SKU-X 加總只有 6
- 訂單 status = `confirmed`、出現在 `v_order_shortage`

### 測試
- [ ] **B.1**：HQ inbox `短少訂單` 分頁可看到此訂單
- [ ] **B.2**：客服選 `notified` → `customer_orders.shortage_resolution = 'notified'`、推播給客戶
- [ ] **B.3**：客服選 `cancelled` → `rpc_cancel_aid_order` 連動退錢包
- [ ] **B.4**：客服選 `waiting_next_po` → 留訂單在 shortage、暫不處理
- [ ] **B.5**：客服選 `reallocated` → 從別店改派（產 transfer）

### 邊界
- [ ] **B.6**：缺貨數量歸零（總倉補貨進來）後，再次計算 `v_order_shortage` 會把此單剔除
- [ ] **B.7**：訂單部分缺、部分有（10 訂、4 有）→ 4 派出去 + 6 留 shortage

---

## C. 少領（partially_completed 剩餘退回）

### 前置
- 訂單 X：訂 10 個 SKU-009、客戶已取 7 個、訂單 status = `partially_completed`
- 店端 SKU-009 庫存：3（剩餘）

### 測試
- [ ] **C.1**：店端 OrderDetail popup → `↩ 退訂單`（出現按鈕、status=partially_completed 在 canReturn 內）
- [ ] **C.2**：modal 顯示 SKU-009 訂單量=10、已退=0、可退=10（注意：UI 並沒扣掉 picked_up 的 7）
- [ ] **C.3**：輸入退 3 → 成功（rpc_outbound 從店端 3 個庫存扣掉）
- [ ] **C.4**：輸入退 4 → fail with `Insufficient stock` (店端只有 3)
- [ ] **C.5**：退完後再開 → 已退=3、可退=7；輸入退 1 → 必 fail with Insufficient stock（店端 0）

### 邊界
- [ ] **C.6**：UX 改善建議——「可退」應顯示 `min(訂單量 - 已退量, 店端實際庫存)` 而非僅 `訂單量 - 已退量`，避免使用者輸入後才被擋

---

## D. 損壞（破損退回）

### 前置
- 訂單 X 派到店、ready 狀態
- 店員開箱發現 SKU-007 有 1 個破損

### 目前能做（將就版）
- [ ] **D.1**：OrderDetail popup → `↩ 退訂單` → 退 1 個 SKU-007、reason 填「破損」
- [ ] **D.2**：成功；但 stock_movements.movement_type = `customer_return`（不是 `damage`）
- [ ] **D.3**：transfers.notes 包含 `[order return: 破損]`
- [ ] **D.4**：HQ 收到後可從 transfers.notes 看出是破損

### 應該做（待補）
- [ ] **D.5**：rpc_create_order_return 加 `p_movement_type` 參數，預設 `customer_return`、可選 `damage`
- [ ] **D.6**：UI modal 加「退貨類型」radio：一般退貨 / 破損 / 過期
- [ ] **D.7**：選破損 → movement_type=damage、會計可以從 ledger 直接區分

### 邊界
- [ ] **D.8**：破損 + 數量錯誤（訂 5 收到 4 個 + 1 破損）→ 走「進貨短少」exception 流程、不是退貨

---

## E. 過期（過期未取退回）

### 前置
- 訂單 X：訂 5 個 SKU-009、過了 pickup_deadline、status = `expired`
- 店端 SKU-009 庫存：5（沒人取）

### 目前狀態 ❌
- [ ] **E.1**：OrderDetail popup → 沒有 `↩ 退訂單` 按鈕（canReturn 漏含 expired）
- [ ] **E.2**：直接呼叫 RPC → fail with `cannot be returned (must be shipping/ready/partially_completed/completed)`

### 修補後應通過
- [ ] **E.3**：把 `'expired'` 加到 canReturn 列表（OrderDetail.tsx）
- [ ] **E.4**：把 `'expired'` 加到 RPC 允許 status
- [ ] **E.5**：expired 訂單 popup 出現 `↩ 退訂單` 按鈕
- [ ] **E.6**：退 5 個 → 成功、店端 -5、transfers.return_to_hq qty=5

### 邊界
- [ ] **E.7**：expired 後又退完 → 訂單仍 expired（不應改 status）
- [ ] **E.8**：expired 訂單錢的處理（已付儲值金）— 退貨**不**自動退錢；錢退要走 `rpc_wallet_partial_refund`

---

## F. 跨情境

- [ ] **F.1**：同一訂單先少領 (C) 再退 (A) — 累積已退量正確
- [ ] **F.2**：退完後 transfer 到 HQ、HQ 拒收 → `rpc_reject_transfer` 應正確逆轉
- [ ] **F.3**：退完後 HQ 收貨 (rpc_receive_transfer) → HQ stock_balances 增加
- [ ] **F.4**：跨 tenant 退（A tenant 訂單、B tenant 操作員）→ fail with `not in tenant`
- [ ] **F.5**：店員 role 退別店訂單 → fail with `store role can only return orders for own store`

---

## 修補優先序

1. **P0 — E 過期支援**：1 行 code、users 會立刻碰到（過期訂單沒退路徑）
2. **P1 — D 破損 movement_type**：會計區分用，可延後
3. **P2 — A 客戶退貨先 inbound**：可手動兩步、先觀察使用頻率再考慮 RPC 整合
4. **P2 — C 可退量加店端庫存上限**：UX 改善、不擋功能

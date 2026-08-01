# 全數退貨自動收尾 — 測試項目

對應 migration `20260801000000_full_return_closes_order.sql` + 取貨頁退貨感知。
回報案例：湖口店 GRP-20260615-017-0013 全數退回總倉後仍留在取貨頁「未取訂單」、顯示「1 項可取」。

---

## A. 全數退貨收尾（rpc_create_order_return）

### 前置
- 訂單 X：ready、1 個 SKU × 2、無已取貨品項

### 測試
- [ ] **A.1**：店端退 2（未取退貨）→ RPC 成功、result 帶 `order_closed_as='cancelled'`
- [ ] **A.2**：訂單 status = `cancelled`、cancelled_at 有值；品項行狀態**不變**（仍 pending/ready）
- [ ] **A.3**：取貨頁重新搜尋 → 訂單從未取清單消失（不在 ACTIVE_STATUSES）
- [ ] **A.4**：OrderDetail / LIFF 應收（v_customer_order_summary.payable_amount）＝$0（退貨扣減不受收尾影響）
- [ ] **A.5**：部分退（退 1 留 1）→ `order_closed_as=null`、訂單仍 ready、清單顯示「↩ 已退 1」且金額扣半

### 已取過的單
- [ ] **A.6**：訂 5 取 3（partially_completed）→ 退剩餘 2 → `order_closed_as='completed'`、completed_at 有值
- [ ] **A.7**：completed 單做「取貨後退回」→ status 不變（仍 completed）
- [ ] **A.8**：expired 單全退 → status 不變（仍 expired，E.7）

## B. 退貨單拒收復原（rpc_reject_transfer）

- [ ] **B.1**：A.1 的單被 HQ「退訂單取消」（拒收）→ 訂單從 cancelled 復原為 `ready`、cancelled_at 清空、result 帶 `restored_co_id`/`restored_status`
- [ ] **B.2**：復原後取貨頁重新搜尋 → 訂單重新出現、可取（拒收的 transfer 已 cancelled、不再計已退量）
- [ ] **B.3**：A.6 的單退貨被拒收 → completed 復原為 `partially_completed`、completed_at 清空
- [ ] **B.4**：正常 ready 單的部分退貨被拒收 → 訂單狀態不動（**不再**被誤設 cancelled — 30709 事故防呆）
- [ ] **B.5**：互助單（非 return_to_hq）拒收 → 沿用舊行為（customer_order 取消、source order 還原）

## C. 取貨端收尾（rpc_record_pickup）

- [ ] **C.1**：訂 5、退 2、取貨頁「✅ 取貨」→ 自動只取 3（p_item_qtys）、成功
- [ ] **C.2**：C.1 之後訂單 status = `completed`（殘行 2 已被退貨覆蓋，不再卡 partially_completed）、active_remaining=0
- [ ] **C.3**：兩 SKU 單：SKU-A 全退、SKU-B 未退 → 取 SKU-B 全部 → completed（SKU-A 殘行不擋）

## D. 取貨頁 UI（退貨感知）

- [ ] **D.1**：部分退貨的品項行顯示「↩ 已退 N」、金額已扣除已退量
- [ ] **D.2**：全退但尚未收尾的單（理論上只剩 race window）顯示「↩ 已全數退回總倉，無可取貨項目」、取貨/✏️/🔔 全部 disabled
- [ ] **D.3**：「N 項可取」分母不含被退光的品項行
- [ ] **D.4**：退貨 modal 全退成功 → alert 提示「訂單已自動取消/結案」

## E. 資料治理（一次性，已於 2026-08-01 執行）

- [x] **E.1**：GRP-20260611-020-0031 / GRP-20260615-017-0013 / GRP-20260615-017-0027（皆湖口、全退未取）→ cancelled ✅
- [x] **E.2**：除上述 3 張外無其他訂單被動到（dry-run SELECT 先驗過名單）✅

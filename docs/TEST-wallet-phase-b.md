# wallet-phase-b 測試項目 — 訂單抵扣

**對應 migration:**
- `supabase/migrations/20260606000010_customer_orders_wallet_paid.sql`（新欄位）
- `supabase/migrations/20260606000011_v_customer_order_summary_balance_due.sql`（view 加 balance_due）
- `supabase/migrations/20260606000012_rpc_wallet_pay_order.sql`（新 RPC）

**對應 UI 變更:**
- `apps/admin/src/components/OrderDetail.tsx`（加付款摘要 + 用儲值金結帳按鈕）
- `apps/admin/src/components/WalletPayOrderModal.tsx`（新 modal）

**對應 plan:** `C:\Users\Alex\.claude\plans\session-db-federated-thunder.md` (Phase B)

---

## 1. Schema / Migration 層

### 1.1 customer_orders.wallet_paid_amount 欄位
- [ ] 欄位存在、`NUMERIC(18,2) NOT NULL DEFAULT 0`
  ```sql
  SELECT column_name, data_type, numeric_precision, numeric_scale, column_default, is_nullable
    FROM information_schema.columns
   WHERE table_name='customer_orders' AND column_name='wallet_paid_amount';
  -- expect: numeric, 18, 2, 0, NO
  ```
- [ ] CHECK constraint `wallet_paid_amount >= 0` 存在
- [ ] index `idx_corders_wallet_paid` 存在（partial index where > 0）
- [ ] 既有 row 全填 0（migration 不破壞現有資料）

### 1.2 v_customer_order_summary 新加 balance_due
- [ ] view 多兩欄：`wallet_paid_amount`, `balance_due`
- [ ] `balance_due = payable_amount - wallet_paid_amount`
- [ ] 既有欄位都還在（payable_amount / items / chips / settlement_no...）
- [ ] LIFF Edge function 取出來無 schema mismatch

### 1.3 rpc_wallet_pay_order
- [ ] 函式存在、SECURITY DEFINER、回傳 JSONB（含新 ledger_id + new wallet_paid_amount + new balance_due + payment_status）
- [ ] `GRANT EXECUTE TO authenticated`

---

## 2. RPC 行為（SQL / curl 直測）

### 2.1 happy path（部分付）
**情境：** 訂單 #X，payable=500、wallet_paid_amount=0；會員餘額 1000；payment_status='unpaid'
**操作：** `rpc_wallet_pay_order(X, 200, op)`
**預期：**
- ledger 多一筆 type='spend'、change=-200、source_type='customer_order'、source_id=X
- 會員餘額 = 800
- `customer_orders.wallet_paid_amount` = 200
- `payment_status` 仍 'unpaid'（balance_due > 0）
- 回傳 JSONB `{ ledger_id, wallet_paid_amount: 200, balance_due: 300, payment_status: 'unpaid' }`

### 2.2 happy path（剛好付清）
**情境：** payable=500、wallet_paid_amount=200、餘額 800
**操作：** `rpc_wallet_pay_order(X, 300, op)`
**預期：**
- 餘額 = 500
- `wallet_paid_amount` = 500
- **`payment_status` = 'paid'**, **`paid_at` 設 NOW()**
- balance_due = 0

### 2.3 餘額不足
**情境：** payable=500、wallet_paid_amount=0；會員餘額 100
**操作：** `rpc_wallet_pay_order(X, 200, op)`
**預期：** RAISE `Insufficient wallet`（從 rpc_wallet_spend 冒泡）；訂單 column 沒動

### 2.4 超付防護
**情境：** payable=500、wallet_paid_amount=400
**操作：** `rpc_wallet_pay_order(X, 200, op)`（總和 > 500）
**預期：** RAISE `wallet pay exceeds balance_due`；無 ledger 寫入

### 2.5 訂單狀態擋
- [ ] `status='pending'` → 通過
- [ ] `status='confirmed'` → 通過
- [ ] `status='cancelled'` → RAISE
- [ ] `status='completed'` → RAISE（已完成不能再付）
- [ ] `status='shipping'` → 視 PRD 決定（目前讓過，之後若有問題再加擋）

### 2.6 跨 tenant
- [ ] 用 tenant1 的 JWT 試付 tenant2 的訂單 → RAISE `order not found`

### 2.7 並發（兩個 session 同時 pay 同訂單）
**情境：** 同訂單同時兩個 session 付 300、300（payable=500）
**預期：** 第二個等第一個 commit；其中一個會 RAISE 超付；最終 `wallet_paid_amount <= payable`

### 2.8 amount <= 0 拒絕
- [ ] `p_amount = 0` → RAISE
- [ ] `p_amount = -10` → RAISE

### 2.9 member.status 擋
- [ ] order.member 是 'merged' → RAISE（不能對已合併的會員扣）

---

## 3. UI 行為（preview 互動）

### 3.1 OrderDetail — 付款摘要
**前置：** 訂單 status='pending'、payable=500、wallet_paid_amount=0
- [ ] 應收區塊顯示：`= 應收 $500`
- [ ] 若 wallet_paid_amount > 0：多一行 `− 已用儲值金 $X`
- [ ] 若 balance_due > 0：多一行 `= 應付剩餘 $Y`
- [ ] 顯示「💳 用儲值金結帳」按鈕（可點）

### 3.2 已付清訂單
**前置：** wallet_paid_amount = payable
- [ ] 顯示綠色「✅ 已付清（儲值金 $X）」chip
- [ ] 「用儲值金結帳」按鈕 disabled / 隱藏

### 3.3 取消／完成訂單
- [ ] status='cancelled' / 'completed' → 按鈕 disabled、tooltip 解釋

### 3.4 WalletPayOrderModal
**操作：** 點「💳 用儲值金結帳」
- [ ] modal 開啟，顯示：
  - 訂單號 / 應付剩餘 $X
  - 會員目前儲值餘額 $Y（從 wallet_balances 即時撈）
  - 金額 input（預設 = min(balance_due, wallet_balance)、max=balance_due）
- [ ] 若會員餘額 = 0 → 顯示警告「會員餘額不足，請先加值」、確認鈕 disabled
- [ ] 送出後 modal 關、訂單 reload、wallet_paid_amount 更新
- [ ] 若全付清，自動更新 payment_status='paid'

### 3.5 錯誤處理
- [ ] RPC 各種 RAISE（Insufficient wallet / exceeds / not found）→ 經 `translateRpcError` alert

### 3.6 跨權限
- [ ] HQ admin 看自店 / 他店訂單 → 都能用儲值金結帳
- [ ] 店家帳號看自店訂單 → 可結帳；他店訂單 → 按鈕 disabled / 不顯示

---

## 4. Regression

- [ ] Phase A 的 4 顆按鈕 + reverse 全部正常
- [ ] 既有訂單 audit 顯示沒壞
- [ ] LIFF `/orders/:id` 顧客端的 `payable_amount` 仍對（balance_due 在 view 裡是新增欄）
- [ ] LIFF `OrderCard` / `SettlementCard` UI 沒破
- [ ] `rpc_cancel_aid_order` 還能執行（Phase C 才會改它）— 現在取消後 `wallet_paid_amount` 留著，之後 Phase C auto-refund
- [ ] `rpc_record_pickup` 不受影響
- [ ] `pnpm build` 過、type-check 過

---

## 5. 驗收門檻

§1-§4 全勾、無 console error、Supabase push 成功、跑 `fn_check_wallet_consistency()` 回 0 rows、build 過 才能標 done。

PR merge 後同步 GitHub Issues + Wiki。

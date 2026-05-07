# wallet-phase-c 測試項目 — 取消訂單自動退儲值金

**對應 migration:**
- `supabase/migrations/20260606000040_rpc_cancel_aid_order_wallet_refund.sql`
- `supabase/migrations/20260606000041_rpc_wallet_partial_refund.sql`

**對應 UI 變更:**
- `apps/admin/src/components/OrderDetail.tsx`（cancel 按鈕旁顯示「將退回 $X 儲值金」提示）

**對應 plan:** `C:\Users\Alex\.claude\plans\session-db-federated-thunder.md` (Phase C)

**前置：** Phase A (PR #188) + Phase B (PR #190) 已 landed。

---

## 1. Schema / Migration 層

### 1.1 rpc_cancel_aid_order 已加 wallet refund 邏輯
- [ ] 函式 source 含 `IF v_order.wallet_paid_amount > 0` 區塊
  ```sql
  SELECT pg_get_functiondef('rpc_cancel_aid_order(bigint,text,uuid)'::regprocedure);
  ```
- [ ] 仍然 GRANT EXECUTE TO authenticated

### 1.2 rpc_wallet_partial_refund 存在
- [ ] 函式存在、SECURITY DEFINER、回傳 BIGINT
- [ ] GRANT EXECUTE TO authenticated
- [ ] reason 必填 ≥ 4 chars

---

## 2. RPC 行為（curl / SQL 直測）

### 2.1 cancel — 0 wallet 訂單
**前置：** 訂單 status='pending' / 'confirmed'，wallet_paid_amount=0
**操作：** `rpc_cancel_aid_order(order_id, 'test', op)`
**預期：**
- 訂單 status='cancelled', cancelled_at=NOW()
- **無**新 wallet ledger 紀錄（不該 refund $0）
- 回傳 `{order_id, cancelled_transfer_ids, source_order_reverted, wallet_refunded: 0}`

### 2.2 cancel — 部分 wallet pay 訂單
**前置：** 訂單 payable=500, wallet_paid_amount=300, balance_due=200
**操作：** cancel
**預期：**
- 訂單 status='cancelled'
- ledger 多一筆 `type='refund', change=+300, source_type='customer_order', source_id=<order>, reason='order_cancelled: test'`
- 會員 wallet_balances.balance += 300（補回去）
- `wallet_paid_amount` **保持 300**（歷史紀錄；ledger refund 才是 source of truth）
- 回傳含 `wallet_refunded: 300`

### 2.3 cancel — 全付清訂單（payment_status='paid'）
**前置：** wallet_paid=500=payable, payment_status='paid'
**操作：** cancel
**預期：**
- ledger 多 refund $500
- 訂單 cancelled
- payment_status 不變（cancelled 後 status 才是真實狀態）

### 2.4 cancel — shipping 階段（含 transfer chain）
**前置：** 訂單 status='shipping', wallet_paid=200, transfer chain 含 shipped legs
**操作：** cancel
**預期：**
- transfer chain 反向（既有邏輯）
- wallet refund $200 同 transaction 完成
- 兩者都成功才訂單 cancelled

### 2.5 cancel — already received transfer 拒絕
**前置：** 訂單 shipping，transfer chain 有一段 status='received'
**預期：** RAISE `transfer X already received...`，**訂單 + wallet 都不動**（transaction roll back）

### 2.6 cancel — completed/cancelled/expired 訂單拒絕
- [ ] status='completed' → RAISE
- [ ] status='cancelled' → RAISE  
- [ ] status='expired' → RAISE
- [ ] status='transferred_out' → RAISE（既有邏輯）

### 2.7 partial_refund — happy path
**前置：** 訂單 wallet_paid=300, status='ready'（未取貨、可退）
**操作：** `rpc_wallet_partial_refund(order_id, 100, '補退一半', op)`
**預期：**
- ledger refund +100
- 訂單 wallet_paid_amount: 300 → 200
- 餘額 += 100
- 回傳 `{ledger_id, wallet_paid_amount: 200, ...}`

### 2.8 partial_refund — 超退拒絕
**前置：** wallet_paid=200
**操作：** `rpc_wallet_partial_refund(order_id, 300, ...)`
**預期：** RAISE `partial refund exceeds wallet_paid_amount`

### 2.9 partial_refund — reason 必填
- [ ] NULL → RAISE
- [ ] '' / 短於 4 chars → RAISE

### 2.10 partial_refund — amount <= 0 拒絕
- [ ] 0 → RAISE
- [ ] -10 → RAISE

### 2.11 partial_refund — terminal 訂單拒絕
- [ ] status='cancelled' → RAISE（已退完了）
- [ ] status='completed' → 視 PRD 決定（先放行，可重複部分退）

### 2.12 一致性
**前置：** 跑完上面所有測試
- [ ] `SELECT * FROM fn_check_wallet_consistency()` 回 0 rows
- [ ] 對任一退過的訂單：`SUM(wallet_ledger.change WHERE source_id=X AND type IN ('spend','refund')) >= 0`

---

## 3. UI 行為

### 3.1 OrderDetail — cancel 按鈕提示
**前置：** 訂單 wallet_paid_amount=300
- [ ] cancel 按鈕旁（或 confirm dialog）顯示「將自動退回 $300 儲值金」
- [ ] 按下 cancel → confirm dialog 包含這條訊息
- [ ] 確認後 alert 顯示「訂單已取消，已退回 $300 儲值金」
- [ ] reload 後訂單 status='cancelled'，會員餘額已更新

### 3.2 OrderDetail — 0 wallet 訂單
- [ ] cancel 按鈕無「將退回」提示（因為沒得退）
- [ ] 行為跟舊版一樣

### 3.3 取消後 audit trail
- [ ] 會員詳細頁 wallet ledger tab 多一筆 `refund` row
- [ ] reason 顯示「order_cancelled: ...」
- [ ] source 連結到取消的訂單

---

## 4. Regression

- [ ] Phase A 5 個 button + reverse 全部正常
- [ ] Phase B `rpc_wallet_pay_order` 行為不變
- [ ] 既有 `rpc_cancel_aid_order` 對 0-wallet 訂單行為完全沒變（transfer chain 反向、source order 回 confirmed）
- [ ] LIFF 顧客端訂單列表不破
- [ ] `fn_check_wallet_consistency()` 0 rows

---

## 5. 驗收門檻

§1-§4 全勾、無 console error、Supabase push 成功、tsc + build 過。

PR merge 後同步 GitHub Issues #191 (close) + Wiki（會員模組頁加 Phase C ✅）。

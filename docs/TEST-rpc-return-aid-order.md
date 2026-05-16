# rpc-return-aid-order 測試項目 — 已收貨互助單退單（修 #234 / R12）

**對應 migration:** `supabase/migrations/20260615000050_rpc_return_aid_order.sql`
**對應 UI 變更:** `apps/admin/src/components/OrderDetail.tsx`、`apps/admin/src/lib/rpcError.ts`
**對應 issue:** [#234](https://github.com/lt-foods/new_erp/issues/234)（R12 gap，已 code-level 確認真實）
**性質:** 補既有反向缺口；mirror `rpc_cancel_aid_order` + `rpc_reject_transfer` Leg-3 模式

> 缺口：互助單 received 後 `rpc_cancel_aid_order`（限 pending/confirmed/shipping）與 `rpc_reject_transfer`（限 transfer=shipped）皆 RAISE，無正規退單。
> 範圍刻意對齊 sibling：**不動** `mutual_aid_board` qty / `store_monthly_settlement`（cancel/reject 也都沒動）。

---

## 1. Schema / Migration 層

### 1.1 RPC signature
- [ ] `rpc_return_aid_order(BIGINT, TEXT, UUID)` 存在、`prosecdef=true`、RETURNS jsonb
  ```sql
  SELECT proname, prosecdef, pg_get_function_identity_arguments(oid)
    FROM pg_proc WHERE proname='rpc_return_aid_order';
  ```
- [ ] `GRANT EXECUTE ... TO authenticated`、有 `COMMENT ON FUNCTION`
- [ ] 不改動 `rpc_cancel_aid_order` / `rpc_reject_transfer` / `rpc_create_order_return` 既有 signature

### 1.2 不破壞既有約束
- [ ] 反向用既有 `rpc_outbound`/`rpc_inbound` + `transfers`/`transfer_items`；無新表/欄位；append-only `stock_movements` 不被 UPDATE

---

## 2. RPC 行為（SQL 直測，admin auth）

### 2.1 已收貨 aid 單完整退單（空中轉，is_air_transfer=true）
**情境：** 一張 aid 單已 ship→receive（transfer=received、order=ready）；dest 店該 SKU on_hand 含這批量
**預期：**
- dest_location 該 SKU 扣回本批量（transfer_out movement）
- source 店 location 加回本批量（transfer_in movement）
- 新增 1 張退貨 transfer（store_to_store、status=received、customer_order_id NULL、notes 含 `[aid return: …]`）含對應 transfer_items；原 received transfer `next_transfer_id` 指向它
- aid `customer_order` → `cancelled`、`cancelled_at` 有值
- 來源單（transferred_from_order_id）原 `transferred_out` → `confirmed`、`transferred_to_order_id` = NULL
- 回傳 JSON 含 return_transfer_id / source_order_reverted=true

### 2.2 經總倉 aid 單（is_air_transfer=false）退單
**情境：** 2-leg chain（source→HQ→dest），dest 已 received、order=ready
**預期：** 同 2.1 — 退貨直接 dest_location → 原 source 店 location（一次反向、status=received），不需重走 HQ；stock 三方對得上（dest 扣、source 加）

### 2.3 wallet 退款
**情境：** 退單的 aid 單 `wallet_paid_amount > 0` 且有 member
**預期：** 觸發 `rpc_wallet_refund`，會員餘額 +該金額、ledger 有 refund row；`wallet_paid_amount` 欄保留歷史值（不清零）；回傳含 wallet_refunded / wallet_refund_ledger_id

### 2.4 completed 明確拒絕（範圍邊界）
**情境：** aid 單已 `completed`（顧客已取貨、貨已不在 dest 店）
**預期：** RAISE 並提示：completed 屬「客退 + 解互助」糾纏案、需先處理客退，本 RPC 僅處理 received 未取貨（status='ready'）。不誤產負庫存

### 2.5 非 aid 單拒絕
**情境：** 一般顧客訂單（無 transferred_from_order_id / 無 aid_transfer item）呼叫
**預期：** RAISE `order % is not an aid order`（不誤動一般單；一般單退貨走 `rpc_create_order_return`）

### 2.6 狀態未到 received 拒絕並提示
**情境：** aid 單 status = pending / confirmed / shipping
**預期：** RAISE，訊息提示改用 `rpc_cancel_aid_order`；無任何 transfer/movement/狀態變更

### 2.7 order 不存在
**情境：** 不存在的 p_order_id
**預期：** RAISE `order % not found`

### 2.8 idempotent / 重入
**情境：** 對已退（已 cancelled）的單再呼叫一次
**預期：** RAISE（status 不在 ready/completed）；不重複產 movement / 不重複 refund

### 2.9 一致性
**情境：** 2.1–2.3 跑完
**預期：** `fn_check_wallet_consistency()` 0 rows；`stock_balances` vs `SUM(stock_movements)` 0 mismatch（dest 扣 + source 加 淨額正確）

---

## 3. UI 行為（preview 互動）

掛載：`OrderDetail`（訂單 popup）。

### 3.1 退單按鈕顯示條件
- [ ] aid 單（有 aid_transfer item / transferred_from_order_id）且 status = `ready`（已收貨未取）→ 顯示「退單（已收貨）」
- [ ] aid 單 status = pending/confirmed/shipping/completed → **不**顯示此鈕（前三者走既有取消/拒收；completed 走客退）
- [ ] 一般顧客訂單 → 不顯示此鈕（仍顯示既有 `↩ 退訂單` = `rpc_create_order_return`，兩者不混淆）

### 3.2 退單流程
- [ ] 點「退單（已收貨）」→ prompt 輸入原因 → 確認後呼叫 `rpc_return_aid_order`
- [ ] 成功 → popup reload，單 status 顯示為已取消；無 console error
- [ ] 後端 RAISE（非 aid / 狀態不符）→ 經 `translateRpcError` 顯示可讀中文

### 3.3 rpcError 中文化
- [ ] `order % is not an aid order` → 中文
- [ ] 「請改用 rpc_cancel_aid_order」類訊息 → 中文（提示使用者此單尚未收貨、走取消）

---

## 4. Regression
- [ ] `rpc_cancel_aid_order` 未改：pending/confirmed/shipping 仍可取消、shipping 反向 chain + wallet refund 行為不變
- [ ] `rpc_reject_transfer` 未改：transfer=shipped 仍可拒收 + Leg-3 行為不變
- [ ] `rpc_create_order_return`（一般顧客訂單退回總倉，含上次 P1/P2）不受影響
- [ ] OrderDetail 既有按鈕（轉出 / 取消 / 去取貨 / ↩退訂單）邏輯與顯示條件不破
- [ ] 一般訂單列表 / `/orders` 不受影響
- [ ] tsc / build 不破其他共用（rpcError、OrderDetail import）

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功（migration applied）**、**`pnpm build` + type-check 過** 才可標 done。

# wallet-phase-d 測試項目 — LIFF 顧客端餘額顯示

**對應 edge function:**
- `supabase/functions/liff-api/index.ts` — 加 `get_wallet` + `list_wallet_ledger` 兩個 actions

**對應 LIFF UI:**
- `apps/member/src/app/overview/page.tsx`（加儲值金卡片）
- `apps/member/src/app/wallet/page.tsx`（新頁，完整 ledger）

**對應 plan:** `C:\Users\Alex\.claude\plans\session-db-federated-thunder.md` (Phase D)

---

## 1. Edge function 行為（curl 直測）

### 1.1 get_wallet — 有餘額會員
**前置：** member 1659 (M-SEED-01628 何佩珊) 餘額 > 0
**操作：** POST /functions/v1/liff-api `{action:"get_wallet"}` 帶有效 LIFF token
**預期：**
```json
{ "balance": 800, "version": 2, "last_movement_at": "2026-05-07T12:41:38.440745+00:00", "updated_at": "..." }
```

### 1.2 get_wallet — 從未動過的會員
**前置：** 一個從未 topup 過的會員（無 wallet_balances row）
**預期：** `{balance:0, version:0, last_movement_at:null, updated_at:null}` — 不報錯

### 1.3 list_wallet_ledger — 預設 30 筆
**操作：** POST `{action:"list_wallet_ledger"}`
**預期：**
- 回傳 `{ledger: [...], has_more: bool}`
- 按 `id desc` 排序（最新在最上）
- 每筆含 id / change / balance_after / type / source_type / source_id / payment_method / reverses / reason / created_at

### 1.4 list_wallet_ledger — 分頁
- [ ] 第一頁 `limit=10` → 回 10 筆 + has_more=true
- [ ] 第二頁 `before_id=<上頁最後一筆.id>` → 回下 10 筆
- [ ] 最後一頁 `has_more=false`

### 1.5 limit 邊界
- [ ] `limit=0` → 用最小 1
- [ ] `limit=999` → 上限 100
- [ ] `limit=null/undefined` → 預設 30

### 1.6 跨 tenant / 跨會員
- [ ] tenant1 token 試問 tenant2 member → RLS 把關，回 0 rows（不該有 leak）
- [ ] member A token 不應拿到 member B 的 ledger（filter by token claim memberId）

### 1.7 無 memberId token
- [ ] 401 `{error: "no member_id"}`

---

## 2. LIFF UI 行為

### 2.1 Overview 頁 — 儲值金卡片
**路徑：** /overview
- [ ] 載入後看到「💰 儲值金餘額」卡片
- [ ] 餘額金額大字顯示 + 千分位逗號
- [ ] 「查看儲值流水 ›」按鈕 → 點擊跳轉 /wallet
- [ ] 提示文字：「儲值金不可退現；可在門市加值或結帳時抵扣」
- [ ] 既有「未結單金額」「逛商品」「賣場介紹」卡都還在

### 2.2 Wallet 頁 — /wallet
**路徑：** /wallet
- [ ] 進頁載入順暢、無 console error
- [ ] 上方「目前餘額」卡片（同 overview 樣式）
- [ ] 下方「交易紀錄」list
- [ ] 每筆顯示：類型（中文：加值/扣款/退款/調整/反向）+ 付款方式（現金/信用卡/轉帳，topup 才有）+ 訂單關聯（source=customer_order 顯示「訂單 #X」）+ 時間 + reason + 變動金額（綠色 +N / 紅色 -N）+ 餘額
- [ ] 加值類型 = 綠色 +N
- [ ] 扣款類型 = 紅色 -N
- [ ] 退款類型 = 綠色 +N
- [ ] 反向類型 = 對應原方向相反

### 2.3 Wallet 頁 — 載入更多
- [ ] 30+ 筆紀錄會出現「載入更多」按鈕
- [ ] 點擊載入下 30 筆、追加到列表底部
- [ ] 最後一頁 has_more=false → 按鈕消失

### 2.4 Wallet 頁 — 空狀態
- [ ] 餘額 0 + 0 ledger → 顯示「尚無紀錄」訊息

### 2.5 未登入 / 過期 token
- [ ] /wallet 直接訪問且無 session → router.replace("/")

---

## 3. 整合測試（端到端流程）

### 3.1 Admin 加值 → LIFF 立即看到
1. Admin: 對 member X 加值 $500
2. LIFF: member X 開 /overview → 餘額卡顯示 $500
3. /wallet 看到 topup +500 row、payment_method 顯示中文「現金」
4. ✅ 整鏈通

### 3.2 取貨用儲值金 → LIFF ledger 有 spend
1. Admin: member 取貨用 $300 儲值金
2. LIFF /wallet → 多一筆 spend −300、source 顯示「訂單 #X」
3. 餘額減 300

### 3.3 訂單取消 → LIFF 看到 refund
1. Admin: 取消已 wallet pay 的訂單
2. LIFF /wallet → 多一筆 refund +X
3. 餘額補回去

---

## 4. Regression

- [ ] Overview 既有功能完全不破：未結單金額、進行中訂單按鈕、賣場介紹、PushNotificationManager
- [ ] /orders / /settlements / /shop 不受影響
- [ ] LIFF auth 流程不變

---

## 5. 驗收門檻

§1-§4 全勾、無 console error、edge fn deploy 成功、`tsc --noEmit` 過。

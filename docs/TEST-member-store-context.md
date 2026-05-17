# 測試項目 — apps/member 會員端跨店一致性修正

**問題回報：**
1. 登入時選了取貨店，會員中心仍一律顯示註冊店「平鎮」。
2. 訂單的取貨店 ≠ 登入店時，「未結單金額 / 進行中訂單筆數」顯示 0（看不到數字），但點進「我的訂單」每張單都看得到。

**對應變更：**
- `supabase/functions/liff-api/index.ts` — `getOverview` 的未結金額 / 進行中筆數移除 `store_id` 過濾（改為會員級，與 `listMyOrders` 一致）。
- `apps/member/src/app/me/page.tsx` — 頭像旁門市 chip 改顯示目前門市（`overview.store.name`），不再用永不更新的 `me.home_store_name`。

---

## 1. 根因確認（程式碼層）

- [ ] `v_customer_order_summary.store_id` 等於 `customer_orders.pickup_store_id`
      （migration `20260606000011_v_customer_order_summary_balance_due.sql` 第 16 行）
- [ ] 修正前 `listMyOrders` 無 `store_id` 過濾（跨店、會員級）
- [ ] 修正前 `getOverview` 有 `.eq("store_id", storeId)` → 與列表不一致（本次修掉）
- [ ] 修正前 `/me` chip 綁 `me.home_store_name`（= `members.home_store_id`，LIFF 永不更新）

## 2. Bug 2 — 未結金額 / 進行中筆數（DB 驗證）

前置：找一個會員，其 `customer_orders.pickup_store_id` 與登入 JWT `store_id` 不同，且有未付款訂單。

**驗證 SQL（會員級總額，應等於修正後 overview 回傳值）：**
```sql
-- 未結單金額（會員級，不分店）
SELECT COALESCE(SUM(payable_amount),0) AS receivable
  FROM v_customer_order_summary
 WHERE tenant_id = :tenant AND member_id = :member
   AND payment_status = 'unpaid'
   AND status NOT IN ('cancelled','expired');

-- 進行中訂單筆數（會員級，不分店）
SELECT COUNT(*) AS active_cnt
  FROM v_customer_order_summary
 WHERE tenant_id = :tenant AND member_id = :member
   AND status NOT IN ('completed','cancelled','expired');
```

- [ ] `get_overview` 回傳的 `receivable_amount` == 上面 receivable（跨店加總，> 0）
- [ ] `get_overview` 回傳的 `active_orders_count` == 上面 active_cnt
- [ ] `list_my_orders`（active）筆數 ≥ overview 的 active_orders_count（列表為 6 個月窗、overview 不設窗，方向一致即可）
- [ ] 回歸：同店訂單情境，數字與修正前一致（未引入回歸）

## 3. Bug 1 — 門市 chip 顯示目前門市（UI / 行為）

- [ ] 登入店 = A、註冊店（home_store）= 平鎮：`/me` 頭像旁 chip 顯示「📍 A」而非「平鎮」
- [ ] `get_overview` 失敗（catch → null）時，chip 回退顯示 `home_store_name`（不空白、不報錯）
- [ ] `/overview` 頁標題與 `/me` chip 顯示同一家店（一致）
- [ ] LIFF 回頭客（`liff-session` 將 JWT store 鎖定為 binding store）行為不在本次調整範圍 —
      已知限制：此情境 chip = binding store（非本次選店）。記錄於 PR，不視為回歸。

## 4. 驗證限制

- [ ] `/me` preview 需 liff-api 已 serve + 有效 member session（記憶提示本地預設 503）；
      若無法 preview，至少完成 §1、§2 的 SQL/程式碼層驗證並於 PR 說明。

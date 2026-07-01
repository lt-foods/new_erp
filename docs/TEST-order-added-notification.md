# TEST — 會員被加單時發通知

功能：後台「小幫手加單」(`campaigns/order-entry`) 於 **customer 模式**成功建立/更新訂單後，
自動通知每一位被加單的會員（in-app notification + web push），沿用既有 `admin-notify` edge function。

改動範圍：純前端 `apps/admin/src/app/(protected)/campaigns/order-entry/page.tsx`
（新增 `fanoutOrderAddedNotifications` + 在 `handleSubmit` customer 分支呼叫）。
**不需 migration、不需改 edge function**（`admin-notify` 單人模式已會寫 `notifications` 表並推 web push）。

---

## 1. 觸發正確性

- [ ] **customer 模式加單成功 → 該會員收到通知**
  - 加單頁選一個真實會員 + 商品，送出成功後：
    - `notifications` 表新增一列：`member_id` = 該會員、`category = 'order_added'`、
      `title = '您有一筆新訂單'`、`body` 含團名與件數、`url = '/orders'`。
    - 若該會員有 `push_subscriptions` → 裝置收到 web push。
- [ ] **多會員一次送出 → 每位各收一則**（依 member_id 去重/彙總，不重複轟炸）。
- [ ] **同一會員多列 → 合併成一則**，件數為各列加總。
- [ ] **通知 body 件數正確**：等於該會員本次送出所有 items 的 qty 總和。

## 2. 不該觸發的情境

- [ ] **internal 模式（分店叫貨）不發通知** — 對象是合成的 `store_internal` member，非真人。
- [ ] **offset 模式（庫存抵減單）不發通知** — 純庫存調整。
- [ ] **送出失敗（RPC error）不發通知** — 只有 `rpc_create_customer_orders` 成功後才 fanout。
- [ ] **沒有有效訂單列（rows 為空）不發** — 提早 return，helper 不被呼叫。

## 3. 韌性 / 不影響主流程

- [ ] **推播失敗不影響訂單建立** — 訂單已建立、toast 正常顯示、表單已重置；
      admin-notify 掛掉只在 console.warn，不 setError、不 rollback。
- [ ] **會員無 push 訂閱** → 仍寫入 in-app notification（admin-notify 既有行為），
      會員端 `/notifications` 頁看得到。
- [ ] **fanout 不 await** → 表單重置與 toast 不被推播延遲卡住。

## 4. 會員端顯示

- [ ] 會員端 `/notifications` 出現該通知，點擊導到 `/orders`。
- [ ] `NotificationCard` 對 `order_added` category 正常渲染（不依 category 分流，無需改）。
- [ ] 未讀紅點 (`useUnreadNotifications`) +1。

## 5. Regression

- [ ] 加單三模式（customer / internal / offset）主流程皆正常送出。
- [ ] 既有取貨/轉運/美食列車推播不受影響（共用 admin-notify，未改該 fn）。
- [ ] `tsc --noEmit`：order-entry/page.tsx 無新增型別錯誤。

---

### 驗證備註
- Admin live preview 從沙箱被網路阻擋（連不到本地 Supabase），登入流程跑不完 →
  觸發面驗證交由使用者在自己的環境自審；程式面以 tsc + code review 為準。
- 快速 DB 檢核：加單後對 prod/本機查
  `select category,title,body,url from notifications order by created_at desc limit 5;`

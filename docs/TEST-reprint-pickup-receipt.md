# 測試項目 — 取貨後補印收據（訂單明細「補印收據」鈕）

**範圍:** 純前端 UI。取貨當下自動印的那張 80mm 熱感收據（`/pickup/print?event_ids=`）原本只在取貨的那一瞬間印得到，事後沒有任何入口；本次在 `OrderDetail` 加一顆「補印收據」，用 `order_pickup_events` 的 id 把當時那張收據找回來重印。無 schema / RPC 變更。

**為什麼不是「補印小白單」:** `/pickup/print-list`（小白單）只列 `status ∈ {pending, reserved, ready}` 的品項，取貨後品項變 `picked_up`，硬開網址會印出空單、合計 $0。取貨後有意義的是**收據**，資料在 append-only 的 `order_pickup_events`。

**對應變更:**
- `apps/admin/src/components/OrderDetail.tsx`
  - 主載入 `Promise.all` 加一支 `order_pickup_events` 查詢（`picked_up` / `partial_pickup` / `pickup_undone`，依 id 升冪）。
  - `undonePickupEventIds()`：撤銷取貨不刪原事件，而是補一筆 `pickup_undone`、notes 為 `撤銷取貨事件 #<id>…`（`rpc_undo_pickup`，20260704000010）。解析出被撤銷的 id 並濾掉 — 撤銷掉的那次不給補印。
  - `canReprintReceipt = pickupEvents.length > 0` → 動作列多一顆「補印收據」，一次帶上該訂單所有有效取貨事件（`?event_ids=a,b`，列印頁本來就支援多筆、逐張印）。多次取貨時鈕上顯示次數、title 列出每次的時間。
  - `canPrintSlip` 加入 `partially_completed`（對齊 `/orders` 列表；先前列表印得到、進明細反而沒有鈕）。
- 列印頁 `/pickup/print`、`/pickup/print-list` **不動**。

**驗證方式:** `tsc --noEmit` + eslint（該檔 0 error，2 個既有 warning 未增加）+ Playwright fixture 驗證（`apps/admin/.claude/skills/verify`，攔 `rest/v1` 回假資料，不碰線上 DB）。

---

## 1. 顯示條件（已用 fixture 實測）

- [x] `completed` + 2 筆取貨事件（`partial_pickup` + `picked_up`）→ 鈕顯示為「補印收據（2）」，title 列出兩次時間
- [x] `partially_completed` + 1 筆 `partial_pickup` → 「補印收據」與「列印」（小白單）兩顆並存
- [x] `picked_up` 事件已被 `pickup_undone` 撤銷 → 鈕**不顯示**（不會印出已作廢的收據）
- [x] `ready`（無取貨事件）→ 只有原本的「列印」小白單鈕，無「補印收據」

## 2. 列印行為（已用 fixture 實測）

- [x] 點「補印收據」→ 走 `printViaIframe`（不跳新分頁），載入 `/pickup/print?event_ids=555,556`
- [x] 單筆事件 → `?event_ids=555`
- [ ] **使用者本機自審:** 實際印出的內容＝當時那張 80mm 收據（品項＝該事件的 `item_ids`、數量與部分取貨拆行一致）

## 3. 已知限制（設計如此，非 bug）

- 收據上的**折扣 / 儲值金 / 應收金額是即時從 `customer_orders` 讀的**，不是取貨當下的快照。取貨後若又改過折扣，補印出來的金額會是改後的值。要「印出當時原樣」需另存快照，本次不做。
- 撤銷判定靠 `pickup_undone` 的 notes 格式（`撤銷取貨事件 #<id>`）。若日後改 `rpc_undo_pickup` 的 notes 文字，這裡的正則要一起改。

## 4. 回歸 / 品質

- [x] `tsc --noEmit` 0 error
- [x] `OrderDetail.tsx` 無新增 eslint error/warning
- [x] 取貨 / 撤銷取貨後 `reloadTick` 會重抓事件，鈕即時出現或消失

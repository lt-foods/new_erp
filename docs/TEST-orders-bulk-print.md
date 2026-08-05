# 測試項目 — 訂單頁批量列印（勾選 → 依會員分組送印）

**範圍:** 純前端 UI。訂單頁（`/orders`）加勾選欄與批量列印工具列：依目前篩選結果勾選多張訂單，一次「補印收據」或「列印小白單」。無 schema / RPC 變更；列印頁 `/pickup/print`、`/pickup/print-list` 不動。

**對應變更:**
- 新增 `apps/admin/src/lib/pickupReceipt.ts` — 補印收據的共用邏輯（原本寫在 `OrderDetail`，訂單頁批量也要用，抽出避免兩份各修各的）：
  - `fetchReprintableEvents(orderIds)` → `order_id → 有效取貨事件[]`（一次查多張單，已濾掉被 `pickup_undone` 撤銷的）
  - `undonePickupEventIds()` / `pickupEventLabel()`
  - `OrderDetail.tsx` 改用這支，行為不變。
- `apps/admin/src/app/(protected)/orders/page.tsx`
  - `applyOrderFilters(q, filters)`：把「開團 / tab 狀態 / 取貨店 / 日期區間 / 關鍵字」的條件抽成一支，**列表分頁查詢與「選全部符合篩選」共用** — 保證「勾到的」＝「看到的」。
  - `selected: Set<orderId>`：桌機表格與手機卡片各一顆勾選框、表頭 / 工具列「選本頁」全選；篩選或 tab 一變就清空（避免印到已看不見的單）。勾選可跨分頁累加。
  - 「選全部 N 筆」：用同一組條件另撈 id，不受目前 50 筆分頁限制，上限 `SELECT_ALL_MAX = 500`（超過會提示只選到最新 500 筆）。
  - `bulkPrint("receipt" | "slip")`：補撈 `id, member_id, status` → **依會員分組** → 每組一次 `printViaIframe`。
    - `receipt` → `/pickup/print?event_ids=…`（該會員所有選取單的有效取貨事件）
    - `slip` → `/pickup/print-list?order_ids=…`（只收 `SLIP_STATUSES`＝未取貨 + 部分取貨）
    - 不合格的單自動略過並顯示張數；全部不合格時只顯示原因、不送印。
    - 分組後超過 `BULK_PRINT_CONFIRM = 20` 張先 `confirm`。

**為什麼一定要依會員分組:** 兩支列印頁都假設「一次進來的是同一個會員」（`print-list/page.tsx:157` 註解寫明；收據頁同樣取 `receipts[0].order.member`），表頭與合計都取第一張單的會員。整批倒進同一個 URL 會印出**別人名字的表頭與加總**。

**驗證方式:** `tsc --noEmit` + eslint（無新增 error/warning，維持既有 4 error 1 warning）+ Playwright fixture（`apps/admin/.claude/skills/verify`，攔 `rest/v1` 回假資料，不碰線上 DB），桌機 1440×900 與手機 390×844 各跑一次。

---

## 1. 勾選 UI（已實測）

- [x] 桌機表格每列一顆勾選框、表頭一顆「選取本頁全部」
- [x] 手機卡片每張一顆勾選框（會員列左側）
- [x] 工具列顯示「選本頁（N）」「已選 N 筆」「清除」，手機視窗會換行不擠爆
- [x] 全選本頁 → 「已選 3 筆」
- [ ] **本機自審:** 換 tab / 改篩選 → 勾選清空；換頁後勾選保留（同一組篩選內累加）
- [ ] **本機自審:** 「選全部 N 筆」只在 `total > 本頁筆數` 時出現；超過 500 筆會提示

## 2. 批量補印收據（已實測）

- [x] 同一會員兩張已完成單（事件 901 / 902+903）→ **合印一張** `/pickup/print?event_ids=901,902,903`
- [x] 跨會員（會員5 事件 901、會員6 事件 904）→ **分成兩張依序送印**（`event_ids=901` → `event_ids=904`），由 `printViaIframe` 串行，前一張列印對話框關掉才印下一張
- [x] 取貨已被 `pickup_undone` 撤銷的單 → 略過，提示「另有 1 張略過（還沒取貨或取貨已撤銷）」
- [x] 選取的單全都沒有可補印事件 → 不送印，提示「選取的 N 張都沒有可補印的收據」

## 3. 批量列印小白單（已實測）

- [x] 全部是 `completed` → 不送印，提示「選取的 N 張都不能印小白單（已取貨 / 已取消的單印出來會是空單）」
- [x] 混合（1 張 ready + 2 張 completed）→ 只印 ready 那張，提示「已送印 1 張；另有 2 張略過」
- [ ] **本機自審:** 同會員多張未取單合印一張，表頭姓名 / 取貨店 / 合計正確

## 4. 已知限制

- 一次最多選 500 筆（`SELECT_ALL_MAX`）。列印是 client 端逐張跑，再多會拖垮瀏覽器。
- 分組後每一張都會跳一次瀏覽器列印對話框（`printViaIframe` 刻意串行，避免對話框互蓋），超過 20 張會先 `confirm`。
- 收據金額是即時從 `customer_orders` 讀的，不是取貨當下的快照（同 `TEST-reprint-pickup-receipt.md`）。

## 5. 回歸 / 品質

- [x] `tsc --noEmit` 0 error
- [x] `orders/page.tsx` eslint 問題數與改動前相同（皆為既有 `set-state-in-effect` / 未使用元件）
- [x] `applyOrderFilters` 重構後列表查詢條件與原本逐條 `q.eq/in/gte/lt/or` 等價（tab / 開團 / 店 / 日期 / 關鍵字）
- [x] 表格 `colSpan` 由 9 改 10（多一欄勾選），載入中 / 無資料列不跑版

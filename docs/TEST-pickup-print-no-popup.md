# 測試項目 — 取貨列印不跳新分頁（隱藏 iframe 直接列印）

**範圍:** 純前端 UI 行為。取貨相關列印（大張取貨單 + 熱感小白單）原本 `window.open(..., "_blank")` 開新分頁再自動 `window.print()`，改成用隱藏 iframe 載入既有列印頁、直接叫出瀏覽器列印對話框,不再跳出新分頁/視窗。

**對應變更:**
- 新增 `apps/admin/src/lib/printIframe.ts` — `printViaIframe(url)`：建立隱藏 iframe 載入同源列印頁；列印頁本身（`/pickup/print`、`/pickup/print-list`）資料載入後自會 `window.print()`，在 iframe 內即印 iframe 內容。多筆列印用 promise chain 串行（避免兩個列印對話框互相蓋掉）。`afterprint` + 保險 timeout 清掉 iframe。
- `apps/admin/src/app/(protected)/pickup/page.tsx`：3 處 `window.open` → `printViaIframe`（L222 大張取貨單 / L224 小白單 / L648 modal「列印小白單」）
- `apps/admin/src/components/PickupDialog.tsx`：3 處 `window.open` → `printViaIframe`（L164 列印小白單預覽 / L205 取貨單收據 / L208 部分取貨清單）
- **列印頁本身（`pickup/print/page.tsx`、`pickup/print-list/page.tsx`）不動** —— 完整重用既有資料抓取與排版。

**驗證方式（無 schema / RPC；admin live preview 受沙箱阻擋無法跑登入/列印,照 reference_admin_preview_sandbox_block 走）:** `tsc --noEmit` + `next build` + 碼審；**列印對話框實際行為需使用者本機自審**（沙箱無印表機、無法驅動列印對話框）。

---

## 1. printIframe helper（碼審）

- [ ] `printViaIframe(url)` 建立的 iframe 為離屏隱藏（`position:fixed; width/height:0; visibility:hidden; border:0`）、`aria-hidden`
- [ ] iframe 同源（指向 `withBasePath('/pickup/print*')`）→ 可存取 `contentWindow` 掛 `afterprint`
- [ ] 多次呼叫串行（promise chain）：前一張 `afterprint`（或保險 timeout）後才載入下一張，不會兩個列印對話框同時彈
- [ ] `afterprint` 後延遲移除 iframe（確保列印工作已送出）；錯誤/未列印有保險 timeout 收尾,不會永久卡住 chain
- [ ] SSR/prerender 安全：`document` 僅在函式內存取(client 事件觸發),有 `typeof document === "undefined"` 保護
- [ ] 單一錯誤不會 reject 卡住整條 chain（`.catch` 吞掉續跑）

## 2. 呼叫點全數轉換（碼審 — grep 無殘留）

- [ ] `apps/admin` 內 `window.open(` + `pickup/print` 已無殘留（全部走 `printViaIframe`）
- [ ] `pickup/page.tsx` `bulkPickAllConfirmed`：大張取貨單 + 小白單兩張依序印（不跳分頁）
- [ ] `pickup/page.tsx` bulkConfirm modal「🖨️ 列印小白單」：不跳分頁直接印
- [ ] `PickupDialog.tsx` `printSlip()`：含 `wallet_preview` / 折扣存檔後印小白單,不跳分頁
- [ ] `PickupDialog.tsx` `submit()`：取貨單一定印；`active_remaining > 0` 才追加取貨清單；兩張依序、不跳分頁
- [ ] `withBasePath` 保留（GH Pages basePath 正確）；移除多餘 `"_blank"`

## 3. 使用者本機自審（沙箱無法驗，列清單交付）

- [ ] 單筆取貨 → 只彈一次列印對話框、無新分頁；列印內容＝取貨單收據
- [ ] 部分取貨 → 依序彈兩次（取貨單 → 取貨清單）、皆無新分頁
- [ ] 一次全取（bulk）→ 依序彈兩次（大張取貨單 → 熱感小白單 80mm）、皆無新分頁
- [ ] 列印對話框按「取消」→ 不殘留隱藏 iframe、不卡住下一張
- [ ] 熱感小白單 80mm 版面、折扣/儲值金/預覽金額顯示與改版前一致
- [ ] 列印完頁面停留在原取貨頁（搜尋結果/常用顧客不變）

## 4. 回歸 / 品質

- [ ] `tsc --noEmit` 0 error
- [ ] `next build`（admin, static export）成功
- [ ] 無新增 `eslint` error
- [ ] 列印頁 `/pickup/print`、`/pickup/print-list` 直接開網址仍可用（未破壞既有路由 / 自動列印）

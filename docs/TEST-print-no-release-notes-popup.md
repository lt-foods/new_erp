# 測試項目 — 列印不再印出「更新公告」popup

**範圍:** 純前端 UI 行為。修正使用者回報「新系統的列印出現這個不是商品 / 列印有時候會出現公告的 popup」。

**根因:** 取貨單、調撥單等列印頁都掛在 `(protected)/layout.tsx` 底下，layout 用 `<ReleaseNotesProvider>` 包住所有頁面。`printViaIframe()` 以隱藏 iframe 載入列印頁時，會把整個 `(protected)` layout（含 `ReleaseNotesProvider`）一起掛進 iframe；Provider 的 `useEffect` 看到有「尚未不再顯示」的最新公告就自動 `setIsOpen(true)`，而公告 modal 的 overlay（`fixed inset-0 z-50`）**沒有 `print:hidden`**，於是列印頁在 iframe 內 `window.print()` 時，公告 popup 被一起印在取貨單上。只有「有新公告且該瀏覽器尚未按過不再顯示」時才會發生，故為「有時候」。

**對應變更（`apps/admin/src/components/ReleaseNotes.tsx`）:**
- `ReleaseNotesProvider` 載入 effect：自動跳公告前先判斷 `window.self !== window.top`，**在 iframe 內一律不自動跳公告**（列印 iframe 即屬此情況；跨來源存取 `window.top` 會 throw，視為在 frame 內、同樣不跳）。
- 公告 modal overlay 加上 `print:hidden` 作為第二道防線：即使在頂層分頁直接開列印頁並列印，公告也不會印出來。

**驗證方式（沙箱無印表機、無法驅動列印對話框，碼審 + build/typecheck；實際列印對話框行為交使用者本機自審）:** `tsc --noEmit` 0 error、`next build`（static export）成功。

---

## 1. 碼審

- [ ] iframe 內（`window.self !== window.top`）不會自動跳出更新公告
- [ ] overlay div 有 `print:hidden`（`@media print` 下 `display:none`）
- [ ] 既有行為不變：頂層分頁、有未讀公告時仍自動跳；鈴鐺紅點（`hasUnread`）、手動 `open()`、「不再顯示」記憶（localStorage）皆不受影響
- [ ] `window.top` 存取以 try/catch 包裹，例外時保守視為在 frame 內

## 2. 使用者本機自審

- [ ] 取貨列印（單筆 / 部分 / bulk）→ 印出內容只有取貨單，**不再夾帶更新公告 popup**
- [ ] 調撥單 / 請購單 / 應收等其他列印頁同樣不夾帶公告
- [ ] 正常進系統（頂層分頁）有新公告時，仍會自動跳出更新公告
- [ ] 直接開列印頁網址（頂層分頁）按列印 → 公告不會印出來（`print:hidden` 生效）

## 3. 回歸 / 品質

- [ ] `tsc --noEmit` 0 error
- [ ] `next build`（admin, static export）成功
- [ ] 無新增 eslint error（既有 `react-hooks/set-state-in-effect` 警告為本次變更前既有，未新增）

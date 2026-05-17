# 測試項目 — member App 全站 spin loading 畫面

**範圍:** 純前端 UI。把 `apps/member` 各頁裸文字「載入中…」換成 iOS 風 spinner 載入畫面，並在 async 動作按鈕加 inline spinner，讓 App 更像原生。

**對應變更:**
- 新增 `apps/member/src/components/Spinner.tsx`（`Spinner` + `LoadingScreen`）
- `apps/member/src/components/PullToRefresh.tsx`（改用共用 Spinner）
- 11 頁 page-level loader + 5 個 async 按鈕 inline spinner

**驗證方式（無 schema / RPC，照 reference_member_preview_verify 走輕量驗證）:** `tsc --noEmit` + `next build` + grep 全站無殘留裸 loader + 逐頁 code review。

---

## 1. 共用元件

- [ ] `Spinner` 預設 20px、淡灰底環 `#7676801f` + 品牌色 `--brand-strong` 弧、`animate-spin`
- [ ] `Spinner` `onColor` 變體 = 白弧 + 半透明白底環（給品牌漸層 / 藍 / LINE 綠等彩色鈕用）
- [ ] `Spinner` 有 `role="status"` + `aria-label="載入中"`（無障礙）
- [ ] `LoadingScreen` = 置中 30px spinner，預設無文字；可選 `label`、可覆寫 `className`（預設 `min-h-[55vh]`）
- [ ] `PullToRefresh` 旋轉態改用共用 `Spinner`，下拉箭頭態邏輯不變

## 2. Page-level loader（裸「載入中…」→ `<LoadingScreen />`）

- [ ] `/orders` 載入中顯示置中 spinner（非文字）
- [ ] `/overview` 同上
- [ ] `/notifications` 同上
- [ ] `/settlements` 同上
- [ ] `/wallet` 同上
- [ ] `/shop/flash` 同上
- [ ] `/shop/c/[id]` 同上
- [ ] `/me` 首次載入整頁 spinner（仍包在 PageShell；`!me` 錯誤態文案不變）
- [ ] `/`（landing）`status==="loading"` → 純 spinner；`status==="liff_auth"` → 純 spinner（無文字）
- [ ] `/register` `!ready` 載入 → spinner（`error` 分支文案不變）
- [ ] `/install` `env==="loading"` → spinner
- [ ] `/shop` 維持既有 skeleton（內容網格的原生佔位模式，刻意不換 spinner）

## 3. Async 按鈕 busy 態 = 純 spinner（無文字）

> 使用者回饋「不要用載入中那個方式」：busy 時**只轉圈、不顯示任何「…中」文字**；
> idle 標籤維持原樣。

- [ ] `/shop/c/[id]` BuySheet 送出鈕：`submitting` → 只白 spinner（無「送出中…」）；idle = 請先選擇商品 / 送出訂單
- [ ] `/me` 儲存鈕：`saving` → 只白 spinner；idle =「儲存」
- [ ] `/me` PWA 碼鈕：`generating` → 只白 spinner；idle =「PWA 碼」
- [ ] `/`（landing）驗證鈕：`syncing` → 只白 spinner；idle =「驗證」
- [ ] `/wallet` 載入更多：`loadingMore` → 只 spinner；idle =「載入更多」
- [ ] `/register` 送出鈕：`submitting` → 只白 spinner；idle = 確認綁定 / 建立會員
- [ ] 全站無可見「載入中 / 驗證中 / 送出中 / 儲存中 / 處理中」文字（`Spinner` 的 `aria-label="載入中"` 為螢幕報讀、不可見，保留）

## 4. 回歸 / 品質

- [ ] `grep` 全 `apps/member/src`：無殘留裸 page-level「載入中…」`<p>`（只剩按鈕標籤 + Spinner aria/doc）
- [ ] `tsc --noEmit` 0 error
- [ ] `next build` 成功（static export，全頁 prerender 不報錯）
- [ ] 彩色鈕上 spinner 對比足夠（onColor 白弧），淺底 spinner 用品牌玫瑰弧
- [ ] 無新增 `eslint` error

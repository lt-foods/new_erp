# campaign-list-layout-fix 測試項目 — 開團列表欄位斷行修正

**對應 UI 變更:** `apps/admin/src/app/(protected)/campaigns/page.tsx`（list 視圖：非名稱欄加 `whitespace-nowrap`、名稱欄 `min-w-[14rem]`）
**對應後端 / migration / RPC:** 無（純 CSS class）

> 症狀：auto table-layout 下，動作（編輯/加單/結單）、更新時間、表頭等中文被壓成「逐字直排」。改為非名稱欄不換行 + 名稱欄保底寬度 → 超寬時由既有 `overflow-x-auto` 水平捲動，不再擠壓斷字。

## 1. Schema / Migration / RPC
- [ ] N/A — 無變更

## 2. UI 行為（preview / 使用者實機）
- [ ] `/campaigns` 列表載入無 console error
- [ ] 動作欄「編輯 / 加單 / 結單 / 結算」單列水平排列，**不再逐字直排**
- [ ] 「更新」時間單行顯示（不折成兩行）
- [ ] 表頭「狀態/收單/開團-收單/取貨截止/商品數/下單總數/更新」不逐字斷行
- [ ] 「開團/收單」「取貨截止」日期單行
- [ ] 名稱欄維持可換行（長品名多行 OK），但欄寬不被壓到過窄（min 14rem）
- [ ] 視窗較窄時整表水平捲動（`overflow-x-auto`），不出現直排擠壓
- [ ] 縮圖（#255/#261）、勾選/批次列、點列進編輯、加單連結、分頁 行為不變

## 3. Regression
- [ ] 週/月曆視圖不受影響（未改）
- [ ] 其他用 DataTable 的頁面不受影響（只改本頁 cell className，未動共用 `DataTable` 元件）

## 4. 驗收門檻
§2-§3 勾完、無 console error、build + type-check 過 才可標 done。（無 migration）

---

## 驗證結果（2026-05-18）
- [x] **Type-check** `tsc --noEmit` apps/admin → exit 0
- [x] **Build** `npm run build` apps/admin → exit 0
- [x] **路由執行期** dev server `GET /campaigns/ 200`、server/console 零錯誤（class 變更無語法/執行期問題）
- [x] **碼審** 僅本頁 `<Th>/<Td>` className 加 `whitespace-nowrap` / `min-w-[14rem]`；未動共用 `DataTable`、未動邏輯/資料/縮圖；`overflow-x-auto` 為既有 → 超寬改水平捲動而非斷字
- [ ] ⏸ 真實資料目視（斷行消失、捲動）— Claude 沙箱連不到後端登入（見 reference_admin_preview_sandbox_block）；**使用者實機回報的就是此頁，reload 即可自審**

**Verdict:** 可 SHIP — 純 CSS、零失敗、自動化全綠；視覺由回報者本機 reload 確認。

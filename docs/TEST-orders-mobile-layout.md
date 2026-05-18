# orders-mobile-layout 測試項目 — 訂單頁手機版面修正

**對應 migration:** 無（純前端 className）
**對應 UI 變更:** `apps/admin/src/app/(protected)/orders/page.tsx`
**對應 PRD:** —（沿用 #265 開團列表手機修正同一 pattern）

> 問題：訂單頁在手機寬度下，表格欄位被 `auto` table-layout 壓成逐字直排（商品名「雙貓眼／人體感／應壁燈」一字一行）、表頭中文直排；KPI 卡因 sparkline 擠壓，數字/標籤糊在一起。
> 作法（對齊 #265）：表格非名稱欄 `whitespace-nowrap`、開團（名稱）欄 `min-w-[14rem]`，超寬交給既有 `overflow-x-auto` 水平捲動；KPI 卡的 sparkline 在 `< sm` 隱藏，手機只顯示標籤＋大數字。桌機完全不變。

## 1. Schema / RPC
- [ ] 無 migration / 無 RPC 變更（`git diff origin/main...HEAD` 僅 `orders/page.tsx` + 本測試文件）

## 2. 桌機回歸（≥ sm，1280）
- [ ] 表格八欄與改動前視覺一致（開團/會員/取貨店/項數/總數量/總金額/日期/操作）
- [ ] KPI 四卡含 sparkline、版面與改動前一致
- [ ] 篩選列（開團 picker / 取貨店 / 搜尋 bar）一列三欄如舊
- [ ] 排序/分頁/明細 Modal/取消/去取貨/↩退貨 行為不變

## 3. 手機版面（375 寬）
- [ ] 表格**不再逐字直排**：商品名在 ≥14rem 欄寬內正常折行（非一字一行）
- [ ] 其餘欄（會員/取貨店/數字/日期/操作）`whitespace-nowrap`，整表靠 `overflow-x-auto` **水平捲動**而非壓縮
- [ ] 表頭中文不直排
- [ ] KPI 卡：手機隱藏 sparkline，僅標籤＋大數字＋副字，數字不被截到看不到、不重疊
- [ ] 篩選列在窄寬堆疊（單欄），搜尋框可用、🔍/✕ 不脫版
- [ ] 頁面整體無破版、可正常上下捲動

## 4. 量測驗證（沙箱無法登入 admin，依 reference_admin_preview_sandbox_block 走 inject + getComputedStyle/Rect）
- [ ] `preview_resize` 375 → 注入表格列實際 markup（用改後 class）→ 量開團 cell `getBoundingClientRect().width ≥ 224px(14rem)`、非名稱 cell `white-space: nowrap`
- [ ] 注入 KPI 卡 markup → 375 下 sparkline `display:none`、數字元素 rect 可見且未 0 寬
- [ ] `preview_resize` 1280 → 同元件 sparkline `display` 非 none（桌機保留）

## 5. 驗收門檻
§2-§4 勾完、**無 console error**、**`next build` exit 0**。無 migration/RPC，§1 僅確認無變更。

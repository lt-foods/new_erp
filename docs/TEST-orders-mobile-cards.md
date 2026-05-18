# orders-mobile-cards 測試項目 — 訂單列表手機改卡片版

**對應 migration:** 無（純前端）
**對應 UI 變更:** `apps/admin/src/app/(protected)/orders/page.tsx`

> #267 已讓手機表格可水平捲動（救破版）；本次再進一步：手機（`< sm`）改成**每筆訂單一張卡片**（資訊直向堆疊），桌機（`≥ sm`）維持原表格。共用同一份 `rows` 與同一組操作按鈕（抽成 `orderActions(r,m)` 一處維護）。

## 1. Schema / RPC
- [ ] 無 migration / RPC 變更（`git diff origin/main...HEAD` 僅 `orders/page.tsx` + 本文件）

## 2. 行為共用性
- [ ] 操作按鈕邏輯抽成單一 `orderActions(r, m)`，桌機表格與手機卡片**共用**（去取貨 / 取消 / ↩退貨 / 已取消·已逾期·已完成·已轉出 狀態鈕，gate 與改動前完全相同）
- [ ] 卡片點商品區 → 開既有訂單明細 Modal（同表格 開團 cell 行為）

## 3. 桌機回歸（≥ sm，1280）
- [ ] 顯示原 8 欄表格、卡片清單 `display:none`
- [ ] 表頭/欄位/排序/分頁/明細 Modal/KPI/篩選與改動前一致
- [ ] 去取貨 / 取消 / ↩退貨 行為不變（沿用抽出的 `orderActions`）

## 4. 手機版面（375）
- [ ] 表格容器 `display:none`，**卡片清單顯示**
- [ ] 每張卡：商品（封面縮圖＋開團名＋品名×數量）、會員（頭像＋姓名＋電話／暱稱）、meta（取貨店·項數·總數量·**總金額**醒目）、日期、操作鈕
- [ ] 卡片底色依狀態：cancelled 紅 / expired 琥珀 / transferred_out 灰 / 其餘白
- [ ] 操作鈕在窄寬可 wrap、可點；點商品區開明細 Modal
- [ ] 無逐字直排、無破版、整頁可正常上下捲動
- [ ] 載入中 / 無資料 兩態在卡片版也有對應顯示（非空白）

## 5. 量測驗證（沙箱無法登入 admin，依 reference_admin_preview_sandbox_block：inject + getComputedStyle/Rect + resize）
- [ ] 375：注入「卡片容器 + 表格容器」兩 wrapper（用改後 class）→ 卡片 wrapper `display` 非 none、表格 wrapper `display:none`
- [ ] 1280：表格 wrapper `display:block`、卡片 wrapper `display:none`
- [ ] 注入單張卡 markup → 量總金額元素可見、操作鈕容器 `flex-wrap: wrap`、卡寬 ≤ viewport（不溢出橫捲）

## 6. 驗收門檻
§2-§5 勾完、**無 console error**、**`next build` exit 0**。無 migration/RPC，§1 僅確認無變更。

# campaigns-mobile-cards 測試項目 — 開團列表手機改卡片版

**對應 migration:** 無（純前端）
**對應 UI 變更:** `apps/admin/src/app/(protected)/campaigns/page.tsx`

> 同 #269（訂單列表手機卡片版）的處理，套到開團列表「列表」view：手機 `< sm` 每筆開團一張卡片，桌機 `≥ sm` 維持原 DataTable。操作鈕（編輯/加單/結單/結算）抽成共用 `campaignActions(r)` 單一維護點。「未來 7 天 / 月曆」view 不動。

## 1. Schema / RPC
- [ ] 無 migration / RPC 變更（`git diff origin/main...HEAD` 僅 `campaigns/page.tsx` + 本文件）

## 2. 行為共用性
- [ ] 操作鈕抽成單一 `campaignActions(r)`，桌機表格與手機卡片共用；gate 與改動前完全相同（編輯一律有；加單/結單僅 open；結算僅 closed/ordered/receiving/ready；結單中/結算中 disable 文案不變）
- [ ] 卡片點空白處 → `openEdit(r.id)`（同表格 Tr onClick）；checkbox / 操作鈕 / 下單 Link `stopPropagation` 不誤觸編輯

## 3. 桌機回歸（≥ sm，1280）
- [ ] 「列表」view 顯示原 DataTable（11 欄）、卡片清單 `display:none`
- [ ] 表頭/欄位/勾選全選/排序/分頁/批次/新增開團/編輯 Modal 與改動前一致
- [ ] 編輯/加單/結單/結算 行為不變（沿用 `campaignActions`）
- [ ] 「未來 7 天」「月曆」view 完全不受影響

## 4. 手機版面（375）
- [ ] 「列表」view：DataTable 容器 `display:none`，**卡片清單顯示**
- [ ] 每張卡：checkbox＋封面縮圖＋開團名（粗體）＋狀態 badge＋團型 badge；日期（開團→收單、取貨截止）、商品數、下單數（含抵減）、更新日；操作鈕列
- [ ] 卡片可點開編輯；勾選卡片 highlight；操作鈕可 wrap、可點且不誤觸卡片點擊
- [ ] 載入中 / 無資料 兩態在卡片版也有對應顯示
- [ ] 無逐字直排、卡寬不溢出、整頁可上下捲動

## 5. 量測驗證（沙箱無法登入 admin，依 reference_admin_preview_sandbox_block：inject + getComputedStyle/Rect + resize）
- [ ] 375：卡片 wrapper（`space-y-2 sm:hidden`）`display` 非 none、Table wrapper（`hidden sm:block`）`display:none`；卡寬 ≤ viewport
- [ ] 1280：Table wrapper `display:block`、卡片 wrapper `display:none`
- [ ] 操作鈕容器 `flex-wrap: wrap`

## 6. 驗收門檻
§2-§5 勾完、**無 console error**、**`next build` exit 0**。無 migration/RPC，§1 僅確認無變更。

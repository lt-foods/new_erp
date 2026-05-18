# campaign-list-thumbnail 測試項目 — 開團列表隱藏團號改顯示商品圖

**對應 UI 變更:** `apps/admin/src/app/(protected)/campaigns/page.tsx`（list 視圖：移除「團號」欄，新增商品縮圖欄；list query select 加 `cover_image_url` + `campaign_items` 嵌入取圖）
**對應後端:** 無變更 — 圖片回退鏈沿用 `supabase/functions/liff-api/index.ts` `listActiveCampaigns` 既有邏輯（campaign.cover_image_url > 第一個 campaign_item（sort_order 最小）的 sku.product.images[0]，products bucket public URL）
**對應 migration / RPC:** 無（純前端呈現 + 既有欄位）

## 1. Schema / Migration 層
- [ ] N/A — 本功能無 schema / migration 變更（`group_buy_campaigns.cover_image_url`、`products.images` 皆既有欄位）

## 2. RPC 行為（SQL 直測）
- [ ] N/A — 無 RPC 變更；圖片解析在前端，回退鏈與 liff-api 一致

## 3. UI 行為（preview 互動）

### 3.1 開團列表「列表」視圖載入（`/campaigns`，view=list）
- [ ] 頁面載入無 console error
- [ ] 表頭「團號」欄已移除，原位置改為商品縮圖欄；其餘欄（名稱 / 狀態 / 收單 / 開團/收單 / 取貨截止 / 商品數 / 下單總數 / 更新 / 動作）順序與內容不變
- [ ] 多選 checkbox 欄仍在最左、全選 / 單選 / indeterminate 行為不變
- [ ] 表格欄位總數不變（colSpan=11 的 LoadingRow / EmptyRow 不破版）

### 3.2 縮圖資料來源（回退鏈）
- [ ] 有 `cover_image_url` 的團：縮圖顯示該封面圖（products bucket public URL）
- [ ] 無 cover、但第一個 campaign_item（sort_order 最小）對應 sku.product.images 有圖：縮圖顯示該商品第一張圖
- [ ] cover 與 product.images 皆無：顯示 fallback 佔位（不破版、不出現破圖 alt）
- [ ] `images[0]` 為字串或 `{url}` 兩種型別都能正確取出路徑（與 liff-api 同邏輯）
- [ ] 已是絕對 http(s) URL 的路徑不被重複加 storage 前綴（直接採用）

### 3.3 列互動維持不變
- [ ] 點整列（含縮圖）開啟「編輯開團」modal（原 onClick openEdit 不變）
- [ ] 「名稱」仍可視、點列可進編輯；移除團號 cell 不影響進入編輯的途徑
- [ ] 狀態為 open 的列仍有「加單」連結 → `/campaigns/order-entry?id=`，可正常進入加單頁
- [ ] 「編輯 / 結單 / 結算」列動作行為不變
- [ ] 批次（開團 / 結單 / 取消）工具列與選取列高亮不受影響

### 3.4 搜尋與分頁
- [ ] 搜尋框輸入「團號」關鍵字仍能查到對應團（後端 `.or(name/campaign_no ilike)` 未改，雖然欄位不顯示）
- [ ] 搜尋框輸入「名稱」關鍵字仍能查到
- [ ] 分頁切換後縮圖隨該頁資料正確載入、無殘留上一頁圖

## 4. Regression
- [ ] 「未來 7 天 / 月曆」視圖（CalendarView / CampaignCard）不受影響、仍顯示 campaign_no（不在本次範圍）
- [ ] 編輯 modal 標題仍為 `編輯開團 #{campaign_no}｜{name}`（campaign_no 仍可由資料取得）
- [ ] 商品數 / 下單總數 的既有 chunked fetch 聚合數字不變（新增的嵌入 select 不影響該獨立查詢）
- [ ] 內部 sentinel 活動（`__INTERNAL_RESTOCK__`）仍被 `.neq` 濾掉、不出現在列表
- [ ] 會員端 `/shop` 卡片封面圖不受影響（後端未動）

## 5. 驗收門檻

全部 §3-§4 勾完、**無 console error**、**build + type-check 過** 才可標 done.（本功能無 migration，故 dev push 門檻不適用）

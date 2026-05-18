# order-entry-thumbnail 測試項目 — 加單頁隱藏團號改顯示商品圖（+ 共用元件、補回 64px）

**對應 UI 變更:**
- 新增 `apps/admin/src/lib/campaignCover.ts`（`publicProductUrl` / `campaignCoverUrl(coverUrl, items)` / `CampaignCoverItem`）
- 新增 `apps/admin/src/components/CampaignThumb.tsx`（64px 共用縮圖）
- `apps/admin/src/app/(protected)/campaigns/order-entry/page.tsx`：header 移除團號 `<span font-mono>{campaign_no}</span>`，改在標題左側放商品縮圖；Campaign type + load select 加 `cover_image_url` + `campaign_items` 嵌入
- `apps/admin/src/app/(protected)/campaigns/page.tsx`：移除本地重複的 helper/型別/元件，改 import 共用；欄寬 `w-14` → `w-20`（**補回 #255 漏掉的 44→64px**）

**對應後端:** 無 — 圖片回退鏈沿用 liff-api `listActiveCampaigns`（既上線）
**對應 migration / RPC:** 無

> 註：#255 squash 只含第一個 commit（44px），尺寸放大 commit 未進 main。本 PR 經共用元件一併補回使用者已核可的 64px。

## 1. Schema / Migration 層
- [ ] N/A — 無 schema 變更（`group_buy_campaigns.cover_image_url`、`products.images` 既有）

## 2. RPC 行為（SQL 直測）
- [ ] N/A — 無 RPC；回退鏈在前端，與 liff-api 一致

## 3. UI 行為（preview 互動）

### 3.1 加單頁 header（`/campaigns/order-entry?id=<open campaign>`）
- [ ] 頁面載入無 console error
- [ ] header **不再顯示團號**（`GBxxxxxxxx-Cxxxxxx` 不出現）
- [ ] 標題「小幫手加單」左側顯示**商品縮圖 64px**；右側 `Alt+N / Ctrl+S` 提示不變
- [ ] 縮圖回退鏈：有 cover 顯示 cover；無 cover 有商品圖顯示 sort_order 最小 item 的 product.images[0]；皆無顯示 fallback 佔位框
- [ ] 商品名稱 · 狀態 badge · 取貨截止（若有）仍正確顯示
- [ ] `campaign` 載入中（null）時只顯示「小幫手加單 / 載入中…」、不顯示破圖、載入後縮圖補上
- [ ] 客戶下單 / 為分店叫貨 / 庫存抵減 三模式切換、送出流程不受 header 變更影響（回歸）

### 3.2 開團列表（`/campaigns` list 視圖，回歸 + 補回尺寸）
- [ ] 縮圖以共用元件渲染、尺寸為 **64px**（h-16 w-16），欄寬 `w-20` 不破版
- [ ] 團號欄仍隱藏；點列 / 名稱仍進編輯；加單/結單/結算/批次/搜尋/分頁不變
- [ ] 欄位總數不變（colSpan=11 的 Loading/Empty 不破版）
- [ ] 有圖 / 無圖（fallback）兩種皆正確（共用元件行為與 #255 一致）

### 3.3 共用模組一致性
- [ ] 列表與加單頁取得的縮圖 URL 對同一開團一致（同一 `campaignCoverUrl`）
- [ ] `images[0]` 字串 / `{url}` 兩型別、絕對 URL 短路 行為與 liff-api 對齊

## 4. Regression
- [ ] 加單頁：draft 載回 / autosave / 快速鍵 / SKU 下拉 / 送出（customer/internal/offset）皆不受 header 與 select 變更影響
- [ ] 列表頁：商品數 / 下單總數 chunked 聚合數字不變；`__INTERNAL_RESTOCK__` 仍濾除
- [ ] 加單頁 select 新增 `campaign_items` 嵌入不影響既有 `rpc_search_skus_for_campaign` 抓 SKU 邏輯
- [ ] 編輯 modal 標題 `編輯開團 #{campaign_no}｜{name}`（列表頁）仍正確（campaign_no 仍在資料中）
- [ ] 會員端 `/shop` 後端未動、不受影響

## 5. 驗收門檻
全部 §3-§4 勾完、**無 console error**、**build + type-check 過** 才可標 done.（無 migration，dev push 門檻不適用）

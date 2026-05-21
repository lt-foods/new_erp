# TEST — 開團清單多選批次發 FB

## 範圍
- 後台 `/campaigns` 列表 view：勾選多個開團 → bulk toolbar 上「批次發 FB (N)」按鈕
- 點按鈕開 `FbBulkPublishModal`：
  - 載入所有選中 campaigns 詳情（name、cover、items→skus→products.images）
  - 統一選粉絲團（fb_pages 啟用中的）
  - 每個 campaign 預覽：標題、shop link、自動產生文案、所有圖片縮圖
  - 「發送 N campaigns × M pages」按鈕 → 逐個 campaign 呼叫 `campaign-publish-facebook`
  - 每個 (campaign × page) 結果即時顯示（pending / success / failed + error_message + permalink）
- 共用既有 edge function `campaign-publish-facebook`、`campaign_fb_posts` 表寫紀錄

## UI 行為
- [ ] 沒勾選任何 campaign → toolbar 不顯示「批次發 FB」按鈕
- [ ] 勾 1 個以上 → 顯示「批次發 FB (N)」按鈕（admin/owner/hq_manager 才可見，沿用 `showAdminActions`）
- [ ] 點按鈕 → modal 開啟、自動載入所有勾選 campaigns 詳情
- [ ] modal 顯示每個 campaign 一塊區域，包含 name、shop link、auto-message 預覽、image thumbs
- [ ] 粉絲團多選 chip（沿用 single modal 樣式）
- [ ] 「發送」按鈕在 `selectedPageIds.size === 0` 時 disabled
- [ ] 進度區即時顯示每個 (campaign, page) pair 狀態（pending → success / failed）
- [ ] 全部完成後顯示總結：N campaigns × M pages → X success / Y failed
- [ ] 關閉 modal 後勾選自動清空、列表 reload

## 資料正確性
- [ ] 對單一 campaign 來說：bulk 跑出來的 `campaign_fb_posts` row 與 single modal 跑的格式一致
- [ ] 自動文案 = `【開團】<name>\n\n<description plain text>\n\n👉 立即下單：<MEMBER_APP_URL>/shop/c/<id>`
- [ ] image_urls = `[cover_image_url, ...campaign_items.sku.product.images]`（dedupe + resolve PublicUrl）
- [ ] 含 cover_image_url 為 null 的情境：只發 items 圖片
- [ ] 含完全無圖的 campaign：純文字發文（imageUrls = []，走 `/feed`）

## 錯誤處理
- [ ] 任一 campaign 失敗不影響其他 campaign 繼續發送（不是 fail-fast）
- [ ] 同個 page 對同個 campaign 失敗時：error_message 顯示在進度區
- [ ] FB token 整體過期：每個 (campaign × page) 都會失敗、各自顯示錯誤
- [ ] 沒啟用粉絲團（fb_pages 全 inactive）→ modal 顯示警示、按鈕 disabled

## 角色 / 權限
- [ ] 一般 store_owner / staff 看不到「批次發 FB」（同 row level「發 FB」邏輯）
- [ ] owner / admin / hq_manager 看得到
- [ ] edge function 後端 role check 仍會擋（雙保險）

## 回歸
- [ ] 既有 single「發 FB」按鈕仍可用、modal 沒被影響
- [ ] 既有「批次開團 / 批次結單 / 批次取消 / 批次設定收單時間」仍可用
- [ ] 勾選操作（單行 checkbox / 全選 checkbox / 跨頁清除）正常

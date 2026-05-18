# product-detail-campaigns Test Run — 2026-05-18

對應測試文件：`docs/TEST-product-detail-campaigns.md`
變更檔：`apps/admin/src/components/ProductCampaignsPanel.tsx`（新）、`apps/admin/src/app/(protected)/products/page.tsx`（編輯 modal 掛入面板）

### Summary
- Total: 約 26 項
- Passed: 11（自動化 + 路由執行期 + 程式碼／RPC 語意審查）
- Blocked: 15（需登入的真實資料 live preview — Claude 沙箱連不到 127.0.0.1:54321，見 reference_admin_preview_sandbox_block）
- Failed: 0

### §1
- ✅ N/A — 無 schema / migration 變更

### §2 RPC 語意（複用既有 `rpc_bulk_set_campaign_status`，已讀 migration 20260514000012 逐條核對）
- ✅ 合法轉換僅 `draft→open`（需 campaign_items）/ `open→closed`（+ →cancelled / draft→cancelled / closed→cancelled）；**無 open→draft / closed→open** → 面板據此把 closed/cancelled/已採購狀態 switch 設為 disabled，UI 不會送出會被 RPC 跳過的請求
- ✅ RPC 回傳「實際變更筆數」；面板對 `changed===0`（如 draft 無 items）顯示提示、不誤報成功
- ✅ RPC error 透傳 `err.message` 顯示（不吞錯、非 [object Object]）
- ⏸ §2 各情境 SQL 直測（draft→open 有/無 items、open→closed、closed→open 跳過、跨 tenant）— Blocked：沙箱無 DB 連線；語意已由 migration 原始碼逐條確認，UI 僅送 open/closed 兩值

### §3 UI
- ✅ **§3.1 路由執行期** — dev server（Next 16.2.4 Turbopack）`GET /products/ 200`（application-code 149ms），server log / browser console **零錯誤**；證明新 `ProductCampaignsPanel` import、modal 結構改寫（ProductForm + 面板包進 `space-y-6`）執行期可編譯不丟例外。隨後無 session 轉址 `/login`（預期）
- ✅ **設計符合慣例（碼審）** — 載入態為純 spinner 無「載入中」文字（依 `feedback_loading_spinner_no_text`）；switch 用既有 `SpinButton`（async onClick 自動 spinner、disable 防重複點）；切換前 `window.confirm`（與 campaigns 頁狀態變更一致）；收單方向明示「不可逆」
- ✅ **關聯查詢正確（碼審）** — skus(product_id)→ids → campaign_items(sku_id in ids)→campaign_id 去重 → group_buy_campaigns（排除 `__INTERNAL_RESTOCK__`、start_at desc）；多 SKU 對應同團去重
- ⏸ §3.1/§3.2/§3.3 真實資料互動（面板出現、關聯列表、switch 三狀態、confirm、refetch）— Blocked：protected route 需登入，沙箱不可達後端。**使用者本機可自審**

### §4 Regression（碼審）
- ✅ ProductForm 本體（欄位/上架驗證/儲存/SKU 區/圖片/進階）未動；面板加在 ProductForm **之外**、edit 且 id!=null 才掛、new 模式不掛
- ✅ 商品列表搜尋/篩選/排序/分頁/批次/開團 modal 未動
- ✅ 與 `/campaigns` 共用同一 `rpc_bulk_set_campaign_status`、不改其行為；會員端後端未動

### Gate status
- Type-check（`tsc --noEmit` apps/admin）：✅ exit 0
- Build（`npm run build` apps/admin）：✅ exit 0
- Supabase push：N/A（無 migration）
- Console / server errors during `/products` route run：0

### Verdict
**可 SHIP（自動化全綠 + RPC 語意逐條核對 + 路由執行期 200）** — 0 失敗。switch 嚴格對齊既有單向狀態機（不做會被後端默默跳過的假雙向）。唯需登入的真實資料互動被沙箱網路阻擋（非程式問題），使用者本機可即時自審 §3.1–§3.3。

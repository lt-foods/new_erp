# campaign-list-thumbnail Test Run — 2026-05-18

對應測試文件：`docs/TEST-campaign-list-thumbnail.md`
變更：`apps/admin/src/app/(protected)/campaigns/page.tsx`（list 視圖移除「團號」欄、改商品縮圖；list query select 加 `cover_image_url` + `campaign_items` 嵌入；新增 `publicProductUrl` / `campaignCoverUrl` / `CampaignThumb`）

### Summary
- Total: 24 項
- Passed: 9（自動化 + 程式碼審查 + 路由執行期）
- Blocked: 15（live data preview — 本地 Supabase/Docker 未啟動，admin 登入失敗無法進 `/campaigns`）
- Failed: 0

### §1 / §2
- ✅ N/A — 無 schema / migration / RPC 變更（`group_buy_campaigns.cover_image_url`、`products.images` 皆既有欄位；圖片解析全在前端）

### §3 UI（preview）
- ✅ **§3.1 路由執行期** — dev server（Next 16.2.4 Turbopack）`GET /campaigns/ 200`，application-code 83ms，server log / browser console **零錯誤**；證明新欄位 JSX、嵌入 select 型別斷言、`CampaignThumb` 元件在執行期可編譯且不丟例外（非僅 `next build` 靜態分析）。隨後因無 session client 端轉址 `/login`（預期行為）。
- ⏸ **§3.1（資料渲染）/ §3.2 / §3.3 / §3.4 全項 — Blocked** — `/campaigns` 為 protected route，需 Supabase Auth 登入。本地 `NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321` 不通（REST 探測回 `000`，Docker Desktop Linux engine 未啟動 → 本地 Supabase 全停）。以 `.env.local` 內 admin 帳密實測登入：表單提交後**停留登入頁、未轉址**（auth 網路層失敗）。故無法載入真實開團資料來目視縮圖渲染 / 回退 / fallback 佔位 / 點列進編輯 / 搜尋分頁。**未採取**：啟動 Docker + `supabase start` + 補含商品圖的 seed，對一個加法式純前端欄位變更不成比例且有動到使用者本地 dev 環境的風險（比照 `docs/TEST-member-card-ordered-qty.md` 既有先例的環境阻擋處置）。

### §4 Regression（程式碼審查）
- ✅ 欄位總數不變（移除「團號」+ 新增縮圖欄 = 仍 11 欄），`LoadingRow/EmptyRow colSpan={11}` 未動、不破版
- ✅ 整列 `<Tr onClick={openEdit}>` 未動 → 點縮圖/列仍進編輯；「名稱 / 狀態 / 加單 / 結單 / 結算 / 批次工具列 / 選取高亮」JSX 皆未改
- ✅ 後端搜尋 `.or(name/campaign_no ilike)` 未改 → 仍可用團號關鍵字搜尋（僅欄位不顯示）
- ✅ 週/月曆 `CalendarView`/`CampaignCard` 完全未改，仍顯示 campaign_no（不在範圍）
- ✅ 商品數 / 下單總數的獨立 chunked fetch 未動；新增嵌入只在主分頁 query（每頁 20 筆，輕量）
- ✅ `__INTERNAL_RESTOCK__` `.neq` 濾除未動；會員端 `/shop` 後端未動
- ✅ 圖片回退鏈為 `supabase/functions/liff-api/index.ts` `listActiveCampaigns`（line 353-362）已上線邏輯之忠實移植；`publicProductUrl` 的 `storage.from("products").getPublicUrl()` 與既上線 `ProductImagesField.tsx:20` 同一呼叫；字串/`{url}` 雙型別、絕對 URL 短路皆對齊

### Gate status
- Type-check（`tsc --noEmit` apps/admin）：✅ exit 0
- Build（`npm run build` apps/admin）：✅ exit 0，全 route 產出
- Supabase push：N/A（無 migration）
- Console errors / server errors during `/campaigns` route run：0

### 追加（2026-05-18 使用者環境實證 + 尺寸調整）
- ✅ **§3.1 / §3.2 由使用者實機畫面證實** — 使用者於自身環境（本地 Supabase 正常、Claude 沙箱無法連 127.0.0.1:54321）截圖：`/campaigns` 列表「團號」欄已移除、縮圖以**真實資料**正確渲染（秘魯即食紅藜麥片 / 韓國 Oriox / ττ義大利 Malizia / 玻璃清潔劑 / 雙面漁夫帽 …，與第一張截圖 campaign_no 對應），名稱/狀態/收單/開團-收單/取貨截止/商品數/下單總數 欄位順序與資料完好、未破版 → §3.1、§3.2「有圖顯示縮圖」獲真實資料佐證
- ✅ **尺寸調整** — 依使用者要求縮圖加大：`h-11 w-11`(44px) → `h-16 w-16`(64px)，欄寬 `w-14` → `w-20`，fallback svg `h-5` → `h-7`；tsc / build 重跑綠
- ⏸ 仍未由 Claude 直接跑：§3.3 點列進編輯 / §3.4 搜尋分頁的 live 互動（Claude 沙箱連不到後端；使用者端可即時自審）

### Verdict
**可 SHIP（自動化全綠 + 使用者實機佐證核心呈現）**

（原始判定保留如下）
**NOT DONE（條件式）** — 0 失敗；自動化門檻（type-check / build）全綠、`/campaigns` 路由執行期 200 無錯、回退鏈為已上線邏輯忠實移植，視覺風險低。唯 §3 真實資料目視驗證被本地 Supabase（Docker）停機阻擋、非程式問題。可 ship；待有 active 開團 + 商品圖的環境（或啟動本地 Supabase 並補 seed）時補跑 §3.1 資料渲染 / §3.2 / §3.3 / §3.4 即可全綠。

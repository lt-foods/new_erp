# order-entry-thumbnail Test Run — 2026-05-18

對應測試文件：`docs/TEST-order-entry-thumbnail.md`
變更檔：`apps/admin/src/lib/campaignCover.ts`（新）、`apps/admin/src/components/CampaignThumb.tsx`（新）、`apps/admin/src/app/(protected)/campaigns/order-entry/page.tsx`、`apps/admin/src/app/(protected)/campaigns/page.tsx`

### Summary
- Total: 約 24 項
- Passed: 11（自動化 + 路由執行期 + 程式碼審查；含使用者先前對列表縮圖的實機佐證可延伸到共用元件）
- Blocked: 13（live data preview — Claude 沙箱連不到 127.0.0.1:54321，需登入的資料渲染無法跑）
- Failed: 0

### §1 / §2
- ✅ N/A — 無 schema / migration / RPC 變更

### §3 UI（preview）
- ✅ **§3.1 / §3.2 路由執行期** — dev server（Next 16.2.4 Turbopack）`GET /campaigns/order-entry/?id=1 200`（application-code 51ms），server log / browser console **零錯誤**；證明新增的共用 import（`@/lib/campaignCover`、`@/components/CampaignThumb`）、Campaign type 擴充、嵌入 select、header JSX 改寫在執行期可編譯且不丟例外。隨後無 session client 端轉址 `/login`（預期）。
- ✅ **§3.2 / §3.3（佐證）** — `CampaignThumb` 與 `campaignCoverUrl` 為使用者已於實機畫面確認可用之同一邏輯（#255 列表縮圖；使用者 2026-05-18 截圖證實真實資料正確渲染）原樣抽出為共用模組、邏輯逐行等價（僅尺寸由 44→64px，亦為使用者已核可值），加單頁複用同元件 → 視覺風險極低
- ⏸ **§3.1 加單頁 header 真實縮圖 / §3.2 列表 64px 目視 / §3.3 兩處 URL 一致 / §4 互動 — Blocked** — protected route 需 Supabase 登入；`NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321` 從 Claude 沙箱不可達（REST/auth 探測 `000`），登入無法完成。**使用者本機環境正常**（其截圖為證），可即時自審。**未採取**：在沙箱啟 Docker+Supabase+seed，對複用既驗證元件的加法式變更不成比例。

### §4 Regression（程式碼審查）
- ✅ 列表頁：移除本地重複 helper/型別/元件改 import 共用，`Row.campaign_items` 改用 `CampaignCoverItem`，call site 改 `campaignCoverUrl(r.cover_image_url, r.campaign_items)`；欄位數不變（仍 11 欄、colSpan=11）；團號隱藏 / 點列進編輯 / 加單 / 結單 / 結算 / 批次 / 搜尋 / 分頁 JSX 皆未動
- ✅ 加單頁：僅 header 區塊改寫（縮圖 + 移除團號 span，保留名稱/狀態/取貨截止）；下單/內部/抵減三模式、draft/autosave/快速鍵/SKU 下拉/送出 邏輯完全未動；新增 `campaign_items` 嵌入只在 campaign 載入 select，不影響 `rpc_search_skus_for_campaign`
- ✅ `campaign_no` 仍在兩頁 type/select（列表編輯 modal 標題仍可用）；`__INTERNAL_RESTOCK__` 濾除、商品數/下單總數 chunked 聚合 未動
- ✅ 回退鏈 / 型別斷言（to-one 嵌入經 `as unknown as`）與 #255 等價；`publicProductUrl` 同 `ProductImagesField` 既上線 `storage.getPublicUrl`

### Gate status
- Type-check（`tsc --noEmit` apps/admin）：✅ exit 0
- Build（`npm run build` apps/admin）：✅ exit 0
- Supabase push：N/A（無 migration）
- Console / server errors during `/campaigns/order-entry` route run：0

### Verdict
**可 SHIP（自動化全綠 + 複用使用者已實機佐證之元件）** — 0 失敗；唯需登入的真實資料目視被 Claude 沙箱網路阻擋（非程式問題），使用者本機可即時自審。加單頁與列表共用同一已驗證縮圖元件、邏輯逐行等價，視覺風險極低。

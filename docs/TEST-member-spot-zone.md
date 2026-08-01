# TEST — 會員端「現貨專區」：中間 tab、跨店金額隱藏、LINE 詢問

## 目標
驗證店家在互助交流板按「我有庫存可提供」發的貼文（`mutual_aid_board.post_type='offer'`）
會出現在會員 App 的「現貨專區」；**只有會員所在店家釋出的商品才看得到金額**，
跨店的金額被隱藏（含 LINE 詢問訊息內也不能帶）。

## 涵蓋範圍
- Edge Function `liff-api` action：`list_spot_products`
- Migration `20260801000020_rpc_upsert_store_line_oa.sql`（`rpc_upsert_store` 加 `p_line_oa_basic_id`）
- 會員端：底部 tab bar 中央凸起鍵、`/spot`（`/shop` 的現貨導流區塊已移除，見 T6）
- 元件：`SpotProductCard.tsx`、`lib/lineInquiry.ts`
- admin：`/stores` 的「LINE@ ID」欄位

## 前置條件
- Migration 已 apply：`SELECT oid::regprocedure FROM pg_proc WHERE proname='rpc_upsert_store';`
  → **只能有一筆**，且簽章是 9 個參數（`...,text,text)`）。兩筆 = DROP 沒生效，具名呼叫會炸 not unique
- Edge Function `liff-api` 已部署（含 `list_spot_products`）
  - 驗證：無 auth `POST {"action":"list_spot_products"}` 回 `401 {"error":"missing authorization"}`
    （回 `{"code":"NOT_FOUND"}` 或 `unknown action` = 沒部署到）
- 環境變數 `NEXT_PUBLIC_LINE_OA_ID` 已設（租戶層預設 LINE@），或 A 店已在 admin 填好 LINE@ ID
- 已知兩間店 A / B（A = 測試會員 M 的 `members.home_store_id`）
- A、B 各至少 1 筆 `status='pending'` 的 `customer_orders` 可拿去釋出
- 會員 M 的 LIFF JWT（`store_id` claim = A）

---

## T0 — admin：門市 LINE@ 欄位

| # | 步驟 | 預期 |
|---|------|------|
| T0-1 | admin 進 `/stores` 編輯 A 店 | 表單有「LINE@ ID」欄位，placeholder `@example（留空 = 用租戶預設）` |
| T0-2 | 填 `@abc1234` 存檔 | 存檔成功；`SELECT line_oa_basic_id FROM stores WHERE id=<A>` = `@abc1234` |
| T0-3 | 清空該欄位再存檔 | DB 是 `NULL`（不是空字串 —— RPC 內 `NULLIF(btrim(...),'')`） |
| T0-4 | 填 `  @abc1234  `（前後空白）存檔 | DB 存 `@abc1234`，空白被 trim |
| T0-5 | 新增一間門市不填 LINE@ | 建立成功，`line_oa_basic_id` 為 `NULL`（參數有 DEFAULT，不是必填） |
| T0-6 | 迴歸：改門市名稱 / 取貨窗 / 付款方式 / 停用 | 全部照舊可存（`rpc_upsert_store` 其餘邏輯一字未改） |

## T1 — 資料前置：兩間店各發一則 offer

| # | 步驟 | 預期 |
|---|------|------|
| T1-1 | admin 用 A 店帳號進 `/inventory/mutual-aid` →「我有庫存可提供」→ 選 A 店訂單 + 品項 + 數量 | 貼文成立，列表出現「釋出 / 進行中 / A店」 |
| T1-2 | 同上用 B 店再發一則（挑不同 SKU 好辨識） | 貼文成立 |
| T1-3 | `SELECT id, post_type, status, offering_store_id, sku_id, qty_remaining, expires_at FROM mutual_aid_board WHERE post_type='offer' AND status='active';` | 兩筆，`expires_at` 在未來、`qty_remaining > 0` |

## T2 — Edge Function `list_spot_products`

| # | 步驟 | 預期 |
|---|------|------|
| T2-1 | `curl POST /functions/v1/liff-api {"action":"list_spot_products"}` 帶會員 M 的 token | 200，回 `{items, my_store_id, my_store_name, my_store_line_oa_id}` |
| T2-2 | `my_store_id` | = M 的 `members.home_store_id`（= A） |
| T2-3 | `my_store_line_oa_id` | = A 店的 `line_oa_basic_id`；**response 裡不能出現 B 店的 LINE@** |
| T2-4 | items 筆數 | = 2 |
| T2-5 | A 店那筆 | `is_my_store=true`，`unit_price` 是數字，= 來源訂單該 SKU 的 `customer_order_items.unit_price` |
| T2-6 | **B 店那筆（重點）** | `is_my_store=false`，**`unit_price` 為 `null`** —— 看 raw response 也拿不到金額 |
| T2-7 | 排序 | `is_my_store=true` 的排前面 |
| T2-8 | 每筆欄位 | `id, sku_id, sku_code, product_name, variant_name, unit, image_url, store_id, store_name, qty_remaining, expires_at, is_my_store, unit_price` |
| T2-9 | response 不含 `note` | 板上備註是店對店內部訊息，不外流 |
| T2-10 | 把 A 店那筆改 `status='cancelled'` 後重打 | 只剩 1 筆（B 店） |
| T2-11 | 把 B 店那筆 `expires_at` 改成過去後重打 | 0 筆 |
| T2-12 | 把某筆 `qty_remaining` 改 0 後重打 | 該筆消失 |
| T2-13 | 板上另發一則「我要求助」（`post_type='request'`）後重打 | items 不含它 |
| T2-14 | 板上 0 則 offer 時打 | `items: []`，但 `my_store_name` / `my_store_line_oa_id` 仍正確回傳 |

## T3 — 底部 tab bar（中央凸起鍵）

| # | 步驟 | 預期 |
|---|------|------|
| T3-1 | 開 App 任一頁 | tab bar 共 5 格：商品 / 訂單 / **現貨專區** / 通知 / 我 |
| T3-2 | 中間那格 | 品牌漸層圓鈕（56px）往上凸出 bar 上緣約 14px，白色外圈；下方有「現貨專區」小字 |
| T3-3 | 五格文字基線 | 對齊（圓鈕是 absolute 溢出，不吃版位） |
| T3-4 | 點中間鍵 | 進 `/spot`，**只有現貨專區亮**，「商品」不能跟著亮（`/spot` 是頂層路由，不在 `/shop` 底下） |
| T3-5 | 在 `/shop` / `/orders` / `/notifications` / `/me` | 各自 tab 亮，現貨專區不亮 |
| T3-6 | **每一頁捲到最底** | 最後一列內容不被凸起圓鈕蓋住（`PageShell` paddingBottom 已從 92px 加到 104px） |
| T3-7 | 進 `/shop/c/[id]` 商品詳情 | tab bar 整條隱藏（既有行為），sticky 下單 bar 不被干擾 |
| T3-8 | 通知未讀 badge | 仍正常顯示在「通知」上（凸起鍵不吃 badge 邏輯） |

## T4 — `/spot` 頁面

| # | 步驟 | 預期 |
|---|------|------|
| T4-1 | 進 `/spot` | 標題「現貨專區」，**沒有返回鍵**（已列入 `TOP_LEVEL_PATHS`），tab bar 在 |
| T4-2 | segmented control | 「全部 (N)」/「〈A店名〉 (M)」，數字正確 |
| T4-3 | 切到「〈A店名〉」 | 只剩 `is_my_store=true` 的卡，全部有金額 |
| T4-4 | 切回「全部」 | 跨店卡回來，仍然沒有金額 |
| T4-5 | 說明文字 | 有一行「〈A店名〉的才看得到金額，其他分店的商品金額不顯示」 |
| T4-6 | A 店卡片 | 左上紫紅「本店釋出」；價格是品牌漸層大字 `$xxx` |
| T4-7 | **B 店卡片（重點）** | 左上深色「B店 釋出」；價格位置是灰色鎖頭膠囊「跨店 · 金額不顯示」，畫面上沒有任何金額 |
| T4-8 | 每張卡 | 有「可提供 N〈單位〉」綠膠囊 + 到期倒數膠囊 |
| T4-9 | 沒有商品圖的 SKU | 暖色品牌底 + 箱子圖示，不是灰底破圖 |
| T4-10 | 空狀態 | 全部分頁「目前沒有店家釋出現貨」；我的店分頁「你的店目前沒有現貨」 |
| T4-11 | 下拉重新整理 | 重抓 |
| T4-12 | 未登入 / session 過期直接開 | redirect 回 `/` |

## T5 — LINE 詢問（金額隱藏第二道關卡）

| # | 步驟 | 預期 |
|---|------|------|
| T5-1 | 卡片可點區域 | **只有底部綠色「LINE 詢問」按鈕**可點；整張卡不是連結（避免捲動誤觸彈出 App） |
| T5-2 | 點 A 店卡的 LINE 詢問 | 開啟 LINE 與 A 店 LINE@ 的對話，輸入框已預填 |
| T5-3 | A 店訊息內容 | `您好，我想詢問今日現貨` / `「〈品名〉／〈規格〉」` / `金額：$149` / `請問店家目前還有貨嗎？` |
| T5-4 | **點 B 店卡的 LINE 詢問** | 同樣開 **A 店（會員自己的店）** 的 LINE@ 對話 —— 不是 B 店 |
| T5-5 | **B 店訊息內容（重點）** | `「〈品名〉」（B店釋出）` + `請問可以幫我調貨嗎？`，**整則訊息不含任何金額** |
| T5-6 | A 店有填 LINE@ | 用 A 店自己的 `line_oa_basic_id` |
| T5-7 | A 店沒填 LINE@、有 `NEXT_PUBLIC_LINE_OA_ID` | 用租戶層預設 |
| T5-8 | 兩者都沒有 | **CTA 按鈕整顆不出現**（不是點了跳空白） |
| T5-9 | 填的 ID 沒有 `@` 開頭（例 `abc1234`） | 連結仍正確（`buildLineOaMessageUrl` 會自動補 `@`） |
| T5-10 | 在 LINE 內建瀏覽器 / 外部瀏覽器 / PWA standalone 各試一次 | 三種都能開到 LINE 對話 |

## T6 — `/shop` 不該再有現貨區塊（2026-08-01 移除）

有了中間 tab 之後那塊是重複入口，整塊拿掉，`/shop` 回到只管團購。

| # | 步驟 | 預期 |
|---|------|------|
| T6-1 | 進 `/shop` | **沒有**「現貨專區 📦」區塊、沒有「去現貨專區 ›」連結 |
| T6-2 | 開 devtools Network 看 `/shop` 的請求 | **只打 `list_active_campaigns` 一支**，不再打 `list_spot_products` |
| T6-3 | banner 輪播與「團購商品」標題之間 | 直接相接，沒有多餘空白或殘留分隔 |
| T6-4 | 要看現貨 | 只有底部中間 tab 一個入口 |

## T7 — 迴歸

| # | 步驟 | 預期 |
|---|------|------|
| T7-1 | `/shop` 團購列表、banner 輪播、排序 tab | 照舊 |
| T7-2 | 暫時讓 `list_spot_products` 失敗（改 action 名） | `/shop` 完全不受影響（它已經不呼叫這支）；`/spot` 顯示錯誤訊息 |
| T7-3 | admin `/inventory/mutual-aid` 認領 / 取消 / 留言 | 不受影響（沒動互助板任何 RPC） |
| T7-4 | offer 被別店認領到 `qty_remaining=0`（`exhausted`） | 會員端該筆自動消失 |
| T7-5 | offer 到期（cron `purge-expired-aid-board`） | 會員端該筆自動消失 |
| T7-6 | admin `/stores` 建立 / 編輯 / 刪除 / 還原門市 | 照舊 |

---

## 備註
- 金額隱藏是**後端**做的（`listSpotProducts` 只查自己店那幾筆來源訂單的單價），
  前端只負責畫「跨店 · 金額不顯示」。改動時別把它退化成前端過濾。
- LINE 訊息範本集中在 `apps/member/src/lib/lineInquiry.ts`，本店 / 跨店是兩套，
  **別合併** —— 合併就等於讓跨店訊息帶到金額。
- 本次唯一的 DB 異動是 `rpc_upsert_store` 加一個有 default 的參數；
  互助板相關的 RPC / view 完全沒動。

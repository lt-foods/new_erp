# TEST — 會員端「店家釋出商品」＋跨店金額隱藏

## 目標
驗證店家在互助交流板按「我有庫存可提供」發的貼文（`mutual_aid_board.post_type='offer'`）
會出現在會員 App，且**只有會員所在店家釋出的商品才看得到金額**，跨店的金額被隱藏。

## 涵蓋範圍
- Edge Function `liff-api` 新 action：`list_released_products`
- 會員端頁面：`/shop`（「店家釋出 📦」橫向區塊）、`/shop/released`（專區全列表）
- 元件：`apps/member/src/components/ReleasedProductCard.tsx`

## 前置條件
- Edge Function `liff-api` 已部署（含 `list_released_products` case）
  - 驗證：`POST /functions/v1/liff-api {"action":"list_released_products"}` 無 auth 回 `401 {"error":"missing authorization"}`
    （若回 `{"code":"NOT_FOUND"}` 或 `unknown action` = 沒部署到）
- 已知兩間店 A / B（A = 測試會員的 `members.home_store_id`）
- A、B 各至少 1 筆 `status='pending'` 的 `customer_orders`，可拿去釋出
- 測試會員 M 的 LIFF JWT（`store_id` claim = A）

---

## T1 — 資料前置：兩間店各發一則 offer

| # | 步驟 | 預期 |
|---|------|------|
| T1-1 | admin 用 A 店帳號進 `/inventory/mutual-aid` → 「我有庫存可提供」→ 選 A 店的訂單 + 品項 + 數量 | 貼文成立，列表出現「釋出 / 進行中 / A店」 |
| T1-2 | 同上用 B 店再發一則（不同 SKU 較好辨識） | 貼文成立 |
| T1-3 | `SELECT id, post_type, status, offering_store_id, sku_id, qty_remaining, expires_at FROM mutual_aid_board WHERE post_type='offer' AND status='active';` | 兩筆，`expires_at` 都在未來、`qty_remaining > 0` |

## T2 — Edge Function `list_released_products`

| # | 步驟 | 預期 |
|---|------|------|
| T2-1 | `curl POST /functions/v1/liff-api {"action":"list_released_products"}` 帶會員 M 的 token | 200，回 `{items:[...], my_store_id, my_store_name}` |
| T2-2 | `my_store_id` | = M 的 `members.home_store_id`（= A），不是 JWT 的 store_id 也要一致 |
| T2-3 | items 筆數 | = 2（T1 兩筆都在） |
| T2-4 | A 店那筆 | `is_my_store=true`，`unit_price` 是數字，= 來源訂單該 SKU 的 `customer_order_items.unit_price` |
| T2-5 | **B 店那筆（重點）** | `is_my_store=false`，**`unit_price` 為 `null`** — 直接看 raw response 也拿不到金額 |
| T2-6 | 排序 | `is_my_store=true` 的排在前面 |
| T2-7 | 每筆欄位 | `id, sku_id, sku_code, product_name, variant_name, unit, image_url, store_id, store_name, qty_remaining, expires_at, is_my_store, unit_price` |
| T2-8 | response 不含 `note` | 板上備註是店對店內部訊息，不外流給會員 |
| T2-9 | 把 A 店那筆改 `status='cancelled'` 後重打 | 只剩 1 筆（B 店） |
| T2-10 | 把 B 店那筆 `expires_at` 改成過去時間後重打 | 0 筆 |
| T2-11 | 把某筆 `qty_remaining` 改 0 後重打 | 該筆消失 |
| T2-12 | 板上另外發一則「我要求助」（`post_type='request'`）後重打 | items 不含它（求助不是可買的貨） |

## T3 — 會員 App `/shop` 首頁區塊

| # | 步驟 | 預期 |
|---|------|------|
| T3-1 | 會員 M 開 `/shop` | 團購商品區塊上方出現「店家釋出 📦」＋右上「全部 N 件 ›」 |
| T3-2 | 橫向左右滑 | 卡片可橫滑，最多露 6 張（`RELEASED_PREVIEW_COUNT`） |
| T3-3 | A 店卡片 | 左上角紫紅色「本店釋出」標籤；價格用品牌漸層大字 `$xxx` |
| T3-4 | **B 店卡片（重點）** | 左上角深色「B店 釋出」標籤；價格位置是灰色鎖頭膠囊「跨店 · 金額不顯示」，畫面上沒有任何金額 |
| T3-5 | 每張卡 | 有「可提供 N〈單位〉」綠膠囊 + 到期倒數膠囊 |
| T3-6 | 沒有商品圖的 SKU | 顯示暖色品牌底 + 箱子圖示，不是灰底破圖 |
| T3-7 | 板上 0 則 active offer | 整個「店家釋出」區塊不出現（不留空殼標題） |
| T3-8 | 下拉 pull-to-refresh | 釋出區塊一起更新 |
| T3-9 | 點「全部 N 件 ›」→ 返回 | 回到 `/shop` 且捲動位置、排序都還原（走既有 `shopCache`） |

## T4 — 會員 App `/shop/released` 專區

| # | 步驟 | 預期 |
|---|------|------|
| T4-1 | 進 `/shop/released` | 標題「店家釋出」、左上有返回鍵、底部 tab bar 在 |
| T4-2 | 上方 segmented control | 「全部 (N)」/「〈A店名〉 (M)」兩個分頁，數字正確 |
| T4-3 | 切到「〈A店名〉」 | 只剩 `is_my_store=true` 的卡片，全部都有金額 |
| T4-4 | 切回「全部」 | 跨店卡片回來，且仍然沒有金額 |
| T4-5 | 說明文字 | 有一行說明「〈A店名〉釋出的才看得到金額，其他分店的商品金額不顯示」 |
| T4-6 | 板上 0 則時 | 空狀態 📦「目前沒有店家釋出商品」 |
| T4-7 | 「我的店」分頁 0 筆時 | 空狀態文案是「你的店目前沒有釋出商品」 |
| T4-8 | 未登入 / session 過期直接開此頁 | redirect 回 `/` |

## T5 — 迴歸

| # | 步驟 | 預期 |
|---|------|------|
| T5-1 | `/shop` 團購列表、banner 輪播、排序 tab | 全部照舊 |
| T5-2 | 暫時把 `list_released_products` 打成會失敗（例如改 action 名） | `/shop` 團購列表仍正常顯示，只是沒有釋出區塊（前端各自 catch，不連坐） |
| T5-3 | admin `/inventory/mutual-aid` 認領 / 取消 / 留言流程 | 不受影響（本次沒動任何 RPC / migration） |
| T5-4 | offer 被別店認領到 `qty_remaining=0`（`status='exhausted'`） | 會員端該筆自動消失 |

---

## 備註
- 本次**沒有** migration、沒有動任何 RPC：只加了一個唯讀的 `liff-api` action + 會員端 UI。
- 金額隱藏是**後端**做的（`listReleasedProducts` 只查自己店那幾筆來源訂單的單價），
  前端只負責畫「跨店 · 金額不顯示」。改動時別把它退化成前端過濾。

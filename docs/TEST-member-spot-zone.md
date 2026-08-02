# TEST — 會員端「現貨專區」：中間 tab、跨店金額隱藏、LINE 詢問

## 目標
驗證店家在互助交流板按「我有庫存可提供」發的貼文（`mutual_aid_board.post_type='offer'`）
會出現在會員 App 的「現貨專區」；**只有會員所在店家釋出的商品才看得到金額**，
跨店的金額被隱藏（含 LINE 詢問訊息內也不能帶）。

## 涵蓋範圍
- Edge Function `liff-api` actions：`list_spot_products`、`get_spot_product`
- Migration `20260801000020_rpc_upsert_store_line_oa.sql`（`rpc_upsert_store` 加 `p_line_oa_basic_id`）
- Migration `20260802000000_aid_board_spot_price_description.sql`（互助板 offer 可自訂釋出單價與商品說明）
- Migration `20260802000030_aid_board_spot_title.sql`（互助板 offer 可自訂商品標題，上架時填、發佈後可改）
- Migration `20260802000040_manual_spot_listing.sql`（手動新增現貨：免訂單、可手打商品、可傳圖）
- Migration `20260802000050_spot_cross_store_visibility.sql`（手動現貨可設成只給本店會員看）
- Migration `20260802000060_aid_board_hidden_posts_rls.sql`（不公開的貼文後台也只有該店看得到，含管理員）
- 會員端：底部 tab bar 中央凸起鍵、`/spot` 列表、`/spot/[id]` 詳情（`/shop` 的現貨導流區塊已移除，見 T6）
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
| T1-4 | 選了品項後看「釋出單價」與「商品說明」欄位 | 單價預填來源訂單原價（欄位下方顯示「原價 $X」）；說明預填商品主檔原文的**純文字**（無 HTML 標籤），皆可改 |
| T1-5 | 把單價改低於原價 | 欄位下方出現綠色提示「低於原價 ~~$X~~ — App 會用刪除線顯示原價」 |
| T1-6 | 單價填 0 / 負數 | 擋下「釋出單價需 > 0（留空 = 沿用原價）」 |
| T1-7 | 單價留空 or 沒動、說明沒動 | 送出後 `mutual_aid_board.spot_price` / `spot_description` 為 `NULL`（= 沿用原值，不是存一份複本） |
| T1-8 | SQL 直呼 `rpc_post_aid_board` 用 `p_post_type='request'` 帶 `p_spot_price` | 炸 `spot_price is only valid for offer posts` |
| T1-9 | **發佈後編輯**：點開自己店的 offer 貼文 → 「✏️ 修改內容」 | 出現編輯區：**商品標題**（帶改寫版或 SKU 組出的預設）＋單價（帶目前值或空 = 沿用原價，含原價提示）＋**到期時間**（帶目前值）＋商品說明（帶改寫版或原文）；標頭顯示目前單價與到期時間 |
| T1-10 | 改單價存檔 → 會員 App 重新整理 | App 立刻顯示新價（讀取端每次現查，不用重發貼文）；標頭單價同步更新 |
| T1-11 | 把單價清空存檔 | `spot_price` 回 `NULL` = 沿用原價；App 回到顯示原價、無刪除線 |
| T1-12 | 對已結束（cancelled / expired / exhausted）的貼文 | 沒有「修改內容」按鈕；SQL 直呼 `rpc_update_aid_board_listing` 會炸 `only active posts can be edited` |
| T1-13 | **改到期時間**（延長或縮短）存檔 | 標頭「到期」即時更新；會員端 `/spot` 該筆的下架時間跟著變 |
| T1-14 | 到期時間設到**過去** | 擋下「到期時間需在未來（要立刻下架請用「結束此貼」）」；SQL 直呼也會炸 `expires_at must be in the future` |
| T1-15 | 只改單價、不動到期 | 到期時間維持原值（前端一律帶值；SQL 層 `p_expires_at=NULL` 也是不動該欄） |
| T1-16 | 選了品項後看「商品標題」欄位 | 預填 `商品名稱／規格`（全形／，不含 SKU code），和 App 沒改時顯示的字串一模一樣 |
| T1-17 | 標題沒動就送出 | `mutual_aid_board.spot_title` 為 `NULL`（= 沿用 SKU 組出的標題；商品主檔之後改名會自動跟上） |
| T1-18 | 標題改成別的字（例「今日現貨・梅花豬」）送出 | `spot_title` 存改寫值；會員 App 的 `/spot` 卡片、`/spot/[id]` 詳情、LINE 詢問文字三處都用新標題 |
| T1-19 | **發佈後改標題**：ThreadModal →「✏️ 修改內容」→ 改「商品標題」存檔 | 標頭出現藍色「App 標題：◯◯」標記；App 重新整理即時生效 |
| T1-20 | 把標題清空（或改回預填值）存檔 | `spot_title` 回 `NULL`，App 回到 SKU 組出的標題 |
| T1-21 | SQL 直呼 `rpc_post_aid_board` 用 `p_post_type='request'` 帶 `p_spot_title` | 炸 `spot_title is only valid for offer posts` |

## T1M — 手動新增現貨（免訂單）

| # | 步驟 | 預期 |
|---|------|------|
| T1M-1 | admin `/inventory/mutual-aid` →「➕ 手動新增現貨」 | 開出 modal，最上面有綠色提示說明「不需要來源訂單、別的分店不能認領」 |
| T1M-2 | **不選 SKU**、標題留空就送出 | 擋下「沒有從商品庫選品項時，商品標題必填」 |
| T1M-3 | **不選 SKU**、標題打「今日現滷拼盤」＋數量 8＋單位「份」＋金額 180＋上傳 2 張圖 | 上架成功；`mutual_aid_board` 該列 `sku_id IS NULL`、`source_customer_order_id IS NULL`、`spot_images` 是 2 個路徑的陣列 |
| T1M-4 | 從商品庫選 SKU | 「商品標題」自動帶入 `商品名稱／規格`；已經手打過的標題**不會**被覆蓋 |
| T1M-5 | 選了 SKU 後按「清除選擇，改成手打」 | SKU 清掉，但已經打好的標題保留（打過的字不憑空消失） |
| T1M-6 | 選了 SKU、圖片留空 | 會員端 fallback 顯示商品主檔的圖 |
| T1M-7 | 金額留空 | 上架成功，`spot_price IS NULL`；會員端本店看到的價格位置是「—」 |
| T1M-8 | 金額填 0 / 負數 | 擋下「金額需 > 0（留空 = 不顯示金額）」 |
| T1M-9 | 到期時間設到過去 | 擋下「到期時間需在未來」 |
| T1M-10 | 手動貼文在列表 | 品名旁有綠色「手動」badge |
| T1M-11 | 點開手動貼文 | **沒有「✋ 我要認領」按鈕**，改顯示「手動現貨・只給會員看，不開放跨店認領」 |
| T1M-12 | 手動貼文 →「✏️ 修改內容」 | 編輯區比訂單來源的多出 **數量** 與 **單位** 兩欄，最下面有 **商品圖片** 上傳區 |
| T1M-13 | 改數量存檔 | 標頭「可釋」即時更新；`qty_available` 與 `qty_remaining` 一起被覆寫 |
| T1M-14 | **訂單來源**的貼文 →「✏️ 修改內容」 | **沒有**數量欄（qty 和認領扣量的帳綁在一起）；SQL 直呼帶 `p_qty_available` 會炸 `qty of an order-sourced listing cannot be edited` |
| T1M-15 | 手打（無 SKU）貼文把標題清空存檔 | 擋下「這則是手打的商品、沒有商品主檔可沿用，標題不能留空」；SQL 直呼也會炸 `this listing has no sku — spot_title cannot be cleared` |
| T1M-16 | 編輯區把圖片全刪掉存檔 | `spot_images` 回 `NULL`；有 SKU 的話 App 回到顯示主檔圖，手打的話變成品牌底placeholder |
| T1M-17 | 會員 App `/spot` | 手動現貨和訂單現貨混在同一個列表，本店的一樣排前面、一樣看得到金額；跨店一樣鎖頭 |
| T1M-18 | 手打商品的 `/spot/[id]` | 標題是 `spot_title`、圖是 `spot_images`、**沒有「商品編號」那一列**（沒有 SKU） |
| T1M-19 | SQL 直呼 `rpc_post_manual_spot` 帶 `p_spot_images => '{"a":1}'::jsonb` | 炸 `spot_images must be a JSON array of storage paths` |
| T1M-20 | SQL 直接 INSERT 一列 `post_type='request'` 且 `sku_id IS NULL` | 撞 CHECK `chk_aid_board_request_needs_sku`（求助一定要有 SKU 才轉得了單） |
| T1M-21 | SQL 直呼 `rpc_post_aid_board` 用 `p_post_type='offer'` 但 `p_source_customer_order_id => NULL` | 仍炸 `offer post requires p_source_customer_order_id`（放寬 CHECK 沒有替訂單釋出路徑開洞） |

## T1V — 跨店可見性開關（手動現貨）

前提：A 店（測試會員 M 的所在店）與 B 店各有一則手動現貨。

| # | 步驟 | 預期 |
|---|------|------|
| T1V-1 | 開「➕ 手動新增現貨」看開關 | 「其他分店的會員也看得到」**預設打勾**；說明文字是「所有會員都看得到這項商品；跨店的金額照舊隱藏（顯示鎖頭）」 |
| T1V-2 | 把勾取消 | 說明文字改成「只有「〈選定的店〉」的會員看得到，其他分店的會員完全查不到這一筆」 |
| T1V-3 | 取消勾選後上架 | `mutual_aid_board.spot_visible_to_other_stores = false` |
| T1V-4 | 不動開關上架 | 該欄為 `true`（維持既有行為） |
| T1V-5 | **B 店關掉開關** → 會員 M（A 店）看 `/spot` | **完全看不到那一筆**（不是有卡片但鎖金額 —— 是整筆消失） |
| T1V-6 | 會員 M 直接打 `/spot/<那筆 id>` | **404「已經不在架上」**；`curl {"action":"get_spot_product","id":<該筆>}` 回 404，不是回商品內容 |
| T1V-7 | B 店自己的會員看 | 照常看得到，而且有金額 |
| T1V-8 | **A 店關掉開關**（自己店的商品）→ 會員 M 看 | 照常看得到、照常有金額（開關只擋別店會員） |
| T1V-9 | 列表與 ThreadModal 標頭 | 關掉的貼文有橘色「🔒 限本店會員」badge |
| T1V-10 | ThreadModal →「✏️ 修改內容」 | 手動現貨的編輯區最下面有同一顆開關，帶目前狀態 |
| T1V-11 | 發佈後把開關關掉存檔 | 標頭立刻出現「🔒 限本店會員」；別店會員重新整理後該筆消失 |
| T1V-12 | 再打開存檔 | badge 消失；別店會員重新整理後又看得到（金額仍鎖） |
| T1V-13 | **訂單來源**的貼文 →「✏️ 修改內容」 | **沒有**這顆開關（只對手動現貨開放）；存檔後 `spot_visible_to_other_stores` 維持 `true` 不被動到 |
| T1V-14 | SQL 直呼 `rpc_update_aid_board_listing` 只送 9 個具名參數（不帶 `p_visible_to_other_stores`） | 可見性**不變**（NULL = 不動，不是重設成 true） |

### T1V-B — 不公開的貼文，**後台**也只有該店看得到

前提：用 B 店（例：松山店）的手動現貨，把開關關掉。

| # | 步驟 | 預期 |
|---|------|------|
| T1V-B1 | 用 **B 店店長**帳號進 `/inventory/mutual-aid` | 看得到那則，標橘色「🔒 限本店會員」 |
| T1V-B2 | 用 **admin（總倉）**帳號進同一頁 | **看不到那一則**（不是灰掉，是列表裡沒有） |
| T1V-B3 | 用 **hq_manager** 帳號 | 同樣看不到；頁面正常載入不報錯（該帳號 `app_metadata.stores` 是 `null`） |
| T1V-B4 | 用 **C 店（別的分店）**店長帳號 | 看不到 |
| T1V-B5 | 多店店長（`stores` 含 B 店） | 看得到 |
| T1V-B6 | admin 直接打 PostgREST `GET /mutual_aid_board?id=eq.<該筆>` | 回 `[]`（RLS 擋掉，不是靠前端過濾） |
| T1V-B7 | admin 直接打 `GET /mutual_aid_replies?board_id=eq.<該筆>` | 回 `[]`（貼文看不到，留言也不能撈） |
| T1V-B8 | 分店側欄「互助交流板」badge | 數字**不含**別店的不公開貼文，和列表筆數對得起來 |
| T1V-B9 | 公開貼文（絕大多數） | 所有帳號行為完全不變 |
| T1V-B10 | 把開關打開後重看 | admin 立刻又看得到 |
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
| T2-8 | 每筆欄位 | `id, sku_id, sku_code, product_name, variant_name, unit, image_url, store_id, store_name, qty_remaining, expires_at, is_my_store, unit_price, original_price` |
| T2-15 | **改價後的 A 店貼文（原價 199、釋出價 149）** | `unit_price=149`、`original_price=199` |
| T2-16 | 改價**高於**原價（例 249） | `unit_price=249`、`original_price=null`（漲價不畫刪除線） |
| T2-17 | 沒改價 | `unit_price=原價`、`original_price=null` |
| T2-18 | **跨店 + 有改價** | `unit_price` 與 `original_price` **都是 `null`** —— 折扣資訊也是金額，不外流 |
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
| T4-2 | segmented control | **左邊是「〈A店名〉 (M)」、右邊才是「全部 (N)」**（2026-08-02 對調），數字正確 |
| T4-2b | **一進頁面時預設選中哪一個** | **左邊的「〈A店名〉」**（不是「全部」）；列表直接是本店的貨、都有金額 |
| T4-3 | 切到「〈A店名〉」 | 只剩 `is_my_store=true` 的卡，全部有金額 |
| T4-4 | 切回「全部」 | 跨店卡回來，仍然沒有金額 |
| T4-15 | **本店 0 筆、其他分店有貨**時進頁面 | 停在「〈A店名〉」的空狀態，並且多一顆「看看其他分店的現貨（N）」；點了切到「全部」 |
| T4-16 | 本店 0 筆、其他分店也 0 筆 | 空狀態沒有那顆按鈕（沒東西可跳） |
| T4-5 | 說明文字 | **沒有**說明段落（2026-08-01 拿掉）；分頁下面直接接卡片 |
| T4-6 | A 店卡片 | 左上紫紅「本店釋出」；價格是品牌漸層大字 `$xxx` |
| T4-14 | A 店卡片（釋出價低於原價） | 大字 `$149` 旁有灰色刪除線 `~~$199~~` |
| T4-7 | **B 店卡片（重點）** | 左上深色「B店 釋出」；價格位置是灰色鎖頭膠囊「跨店 · 金額不顯示」，畫面上沒有任何金額 |
| T4-8 | 每張卡 | 有「可提供 N〈單位〉」綠膠囊；**沒有到期倒數**（2026-08-01 從卡片拿掉，剩餘時間只在詳情頁） |
| T4-9 | 沒有商品圖的 SKU | 暖色品牌底 + 箱子圖示，不是灰底破圖 |
| T4-10 | 空狀態 | 全部分頁「目前沒有店家釋出現貨」；我的店分頁「你的店目前沒有現貨」 |
| T4-11 | 下拉重新整理 | 重抓 |
| T4-13 | 點任一張卡 | 整張卡可點，進 `/spot/<該筆 id>` 詳情頁；卡片上**不該再有** LINE 詢問按鈕 |
| T4-12 | 未登入 / session 過期直接開 | redirect 回 `/` |

## T5 — LINE 詢問（在詳情頁，金額隱藏第二道關卡）

| # | 步驟 | 預期 |
|---|------|------|
| T5-1 | CTA 位置 | 在 `/spot/[id]` 詳情頁底部常駐一條綠色「用 LINE 詢問店家」；列表卡片上沒有 CTA |
| T5-2 | 開 A 店商品詳情、點詢問 | 開啟 LINE 與 A 店 LINE@ 的對話，輸入框已預填 |
| T5-3 | A 店訊息內容 | `您好，我想詢問今日現貨` / `「〈品名〉／〈規格〉」` / `金額：$149` / `請問店家目前還有貨嗎？` |
| T5-4 | **開 B 店商品詳情、點詢問** | 同樣開 **A 店（會員自己的店）** 的 LINE@ 對話 —— 不是 B 店 |
| T5-5 | **B 店訊息內容（重點）** | `「〈品名〉」（B店釋出）` + `請問可以幫我調貨嗎？`，**整則訊息不含任何金額** |
| T5-6 | A 店有填 LINE@ | 用 A 店自己的 `line_oa_basic_id` |
| T5-7 | A 店沒填 LINE@、有 `NEXT_PUBLIC_LINE_OA_ID` | 用租戶層預設 |
| T5-8 | 兩者都沒有 | 按鈕**仍要出現**；點下去把訊息複製到剪貼簿，顯示「已複製詢問訊息 / 貼到 LINE 傳給店家」。**不能整顆按鈕消失** |
| T5-9 | 填的 ID 沒有 `@` 開頭（例 `abc1234`） | 連結仍正確（`buildLineOaMessageUrl` 會自動補 `@`） |
| T5-10 | 在外部瀏覽器 / PWA standalone | 跳去 LINE 開對話並預填文字 |

### T5b — 兩種跑法（PWA vs LIFF）

App 有 PWA 與 LIFF 兩種載入型態，送訊息的路不同，**兩種都要測**。

LIFF 直送要三件事同時成立：`NEXT_PUBLIC_LIFF_ID` 有設（Vercel）、LIFF app 開了
`chat_message.write` scope（2026-08-01 已確認開啟）、使用者從聊天室 / 圖文選單進來。
任一不成立都會自動退到 universal link。

| # | 步驟 | 預期 |
|---|------|------|
| T5b-1 | **在 LINE 裡開 App**（從 OA 聊天室 / 圖文選單進 LIFF）→ 進現貨詳情 → 按詢問 | 文字**直接進 LINE 對話**（不是放進輸入框等使用者按送出），人留在 App 裡；跳出置中 popup「✅ 已發送詢問」，按「好」關閉後按鈕位置變「已送出詢問訊息」 |
| T5b-2 | 回 LINE 對話看 | 有一則以會員身分送出的文字，內容同 T5-3 / T5-5 的範本 |
| T5b-3 | LIFF 但 **`chat_message.write` scope 沒開**（2026-08-01 現況：已開，此列是退路驗證） | 自動退到 universal link（跳 LINE 開對話預填），功能不壞、只是多一步 |
| T5b-4 | LIFF 但**沒有 chat context**（不是從聊天室進來） | 同上，退到 universal link |
| T5b-5 | **LIFF 且 LINE@ 都沒設定** | 詢問按鈕仍要出現且直送成功（sendMessages 不需要 LINE@ id） |
| T5b-9 | **PWA 且 LINE@ 都沒設定** | 按鈕仍要出現 → 複製訊息到剪貼簿（第三條退路） |
| T5b-6 | **PWA standalone** 按詢問 | 交棒給 LINE app 開對話並預填；PWA 自己留在原地 |
| T5b-7 | 一般手機瀏覽器按詢問 | 同 T5b-6 |
| T5b-8 | 送出失敗（三條路都不通，例如剪貼簿被擋） | 按鈕下方出現紅字「送不出去，請直接私訊店家」，不是靜默無反應 |

## T6 — `/shop` 不該再有現貨區塊（2026-08-01 移除）

有了中間 tab 之後那塊是重複入口，整塊拿掉，`/shop` 回到只管團購。

| # | 步驟 | 預期 |
|---|------|------|
| T6-1 | 進 `/shop` | **沒有**「現貨專區 📦」區塊、沒有「去現貨專區 ›」連結 |
| T6-2 | 開 devtools Network 看 `/shop` 的請求 | **只打 `list_active_campaigns` 一支**，不再打 `list_spot_products` |
| T6-3 | banner 輪播與「團購商品」標題之間 | 直接相接，沒有多餘空白或殘留分隔 |
| T6-4 | 要看現貨 | 只有底部中間 tab 一個入口 |

## T7 — `/spot/[id]` 詳情頁

| # | 步驟 | 預期 |
|---|------|------|
| T7-1 | 從列表點進本店商品 | 圖片、品名、`本店釋出` 標籤、`$金額`、可提供數量、釋出分店、剩餘時間倒數、商品編號 |
| T7-2 | **點進跨店商品（重點）** | 同上但價格位置是「跨店 · 金額不顯示」鎖頭，**畫面與 raw response 都沒有金額** |
| T7-3 | `curl POST {"action":"get_spot_product","id":<跨店那筆>}` | `item.unit_price` 為 `null`、`is_my_store=false` |
| T7-4 | `my_store_line_oa_id` | 只回會員自己店那一間；**不能出現釋出店的 LINE@** |
| T7-5 | 商品有多張圖 | 可左右滑，底部有頁碼點 |
| T7-6 | 商品沒有圖 | 品牌底 + 線稿箱子，不是破圖 |
| T7-7 | 商品有說明 | 顯示「商品說明」區塊：上架時有改寫 → 顯示改寫版（`spot_description`）；沒改 → fallback 商品主檔原文；兩者皆無 → 整塊不出現 |
| T7-17 | 詳情頁價格（釋出價低於原價） | 大字 `$149` 旁有刪除線 `~~$199~~`；LINE 詢問訊息帶的金額是 **149**（釋出價） |
| T7-18 | 上架時改過商品標題的品項 | 詳情頁標題、列表卡片、LINE 詢問訊息的「今日現貨『◯◯』」三處都是改寫後的標題（`spot_title`）；沒改則是 `商品名稱／規格` |
| T7-16 | **商品說明的排版（重點）** | 後台 TipTap 存的是 HTML。畫面上**不能出現 `<p>` `<br>` `</p>` 這種標籤字樣**，段落要正常換行（走 `cleanCampaignText`，同 `/shop/c/[id]`） |
| T7-8 | 底部提示文字 | 本店寫「數量有限，先問先得」；跨店寫「由店家幫你調貨」 |
| T7-9 | tab bar | 詳情頁**隱藏** tab bar（底部是詢問列，會打架）；回到 `/spot` 列表後 tab bar 回來 |
| T7-10 | 標題列 | 有返回鍵（`/spot/[id]` 不在 `TOP_LEVEL_PATHS`） |
| T7-11 | 捲到最底 | 最後一行字不被底部詢問列蓋住 |
| T7-15 | 「剩餘時間」列 | 顯示倒數（**只有列表卡片拿掉倒數，詳情頁保留**） |
| T7-12 | **直接用網址開已下架的 id**（cancelled / 過期 / `qty_remaining=0` / 別租戶的 id） | API 回 404，頁面顯示「這個現貨已經不在架上了」+「回現貨專區」按鈕。**不能因為知道 id 就看到列表看不到的東西** |
| T7-13 | 網址塞非數字（`/spot/abc`） | 同上空狀態，且**不發 API 請求** |
| T7-14 | 未登入 / session 過期直接開詳情頁 | redirect 回 `/` |

## T8 — 迴歸

| # | 步驟 | 預期 |
|---|------|------|
| T8-1 | `/shop` 團購列表、banner 輪播、排序 tab | 照舊 |
| T8-2 | 暫時讓 `list_spot_products` 失敗（改 action 名） | `/shop` 完全不受影響（它已經不呼叫這支）；`/spot` 顯示錯誤訊息 |
| T8-7 | `/shop/c/[id]` 團購詳情頁 | tab bar 仍隱藏、sticky 下單 bar 正常（改動只多加 `/spot/` 這條判斷） |
| T8-3 | admin `/inventory/mutual-aid` 認領 / 取消 / 留言 | 不受影響（沒動互助板任何 RPC） |
| T8-4 | offer 被別店認領到 `qty_remaining=0`（`exhausted`） | 會員端該筆自動消失 |
| T8-5 | offer 到期（cron `purge-expired-aid-board`） | 會員端該筆自動消失 |
| T8-6 | admin `/stores` 建立 / 編輯 / 刪除 / 還原門市 | 照舊 |

---

## 備註
- 金額隱藏是**後端**做的（`listSpotProducts` 只查自己店那幾筆來源訂單的單價），
  前端只負責畫「跨店 · 金額不顯示」。改動時別把它退化成前端過濾。
- LINE 訊息範本集中在 `apps/member/src/lib/lineInquiry.ts`，本店 / 跨店是兩套，
  **別合併** —— 合併就等於讓跨店訊息帶到金額。
- 本次唯一的 DB 異動是 `rpc_upsert_store` 加一個有 default 的參數；
  互助板相關的 RPC / view 完全沒動。

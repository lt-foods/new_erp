# TEST — LIFF 顧客端：總覽 / 我的訂單 / 我的結單

## 目標
驗證 `apps/member/` 三個顧客可見頁面 + 對應 `liff-api` Edge Function actions + supporting schema 全鏈路正確。

## 前置條件
- Migrations 已 apply：
  - `stores_liff_overview_columns.sql`（5 個 column）
  - `customer_orders_payment_shipping_columns.sql`（12 個 column）
  - `v_customer_order_summary.sql`
- Edge Function `liff-api` 已部署（含 3 個新 case：`get_overview` / `list_my_orders` / `list_my_settlements`）
- 測試 tenant_id / store_id / member_id / 對應 LIFF JWT 已知（test fixture 在 `apps/admin/.env.local`）
- 至少 1 筆 customer_orders（含 order_items）對該 member 存在，狀態橫跨 pending / shipping / completed
- 至少 2 個 store 的訂單同時存在（驗跨店隔離）

---

## T1 — Schema 欄位存在確認

| # | 步驟 | 預期 |
|---|------|------|
| T1-1 | `\d stores` | 含 `banner_url TEXT`, `description TEXT`, `payment_methods_text TEXT`, `shipping_methods_text TEXT`, `store_short_code TEXT` |
| T1-2 | `\d customer_orders` | 含 `payment_method`, `payment_status` (NOT NULL DEFAULT 'unpaid' CHECK), `paid_at`, `remit_amount`, `remit_at`, `remit_note`, `shipping_method`, `shipping_address`, `shipping_phone`, `shipping_note`, `shipping_fee`, `discount_amount` |
| T1-3 | `SELECT payment_status, count(*) FROM customer_orders GROUP BY 1` | 全部 = `'unpaid'`（既有資料 backfill） |
| T1-4 | `SELECT store_short_code, count(*) FROM stores GROUP BY 1` | 每筆都有值（migration 內 backfill 為 `upper(left(code,2))`） |

## T2 — v_customer_order_summary view

| # | 步驟 | 預期 |
|---|------|------|
| T2-1 | `SELECT * FROM v_customer_order_summary LIMIT 1` | 不報錯，欄位含：id, order_no, member_id, store_id, status, payment_status, items_total, payable_amount, all_arrived, all_completed, settlement_no, items |
| T2-2 | 挑 1 筆已知訂單，比對 `payable_amount = items_total + shipping_fee - discount_amount` | 數字相符 |
| T2-3 | 挑 1 筆所有 items.status = 'picked_up' 的訂單 | `all_arrived=true`, `all_completed=true` |
| T2-4 | 挑 1 筆所有 items.status = 'pending' 的訂單 | `all_arrived=false`, `all_completed=false` |
| T2-5 | settlement_no 格式 | `S-<8位數字>-<2字大寫>`，例：`S-00000123-SK` |

## T3 — Edge Function `get_overview`

| # | 步驟 | 預期 |
|---|------|------|
| T3-1 | `curl POST /functions/v1/liff-api { action: "get_overview" }` 用會員 A、A 店 token | 200，回 `{store: {...}, receivable_amount, active_orders_count}` |
| T3-2 | T3-1 回應的 store.id | = JWT 中的 store_id |
| T3-3 | T3-1 回應的 store 必含欄位 | id, code, name, banner_url, description, payment_methods_text, shipping_methods_text |
| T3-4 | T3-1 回應的 receivable_amount | = SUM(payable_amount) WHERE payment_status='unpaid' AND status NOT IN ('cancelled','expired') for that member+store |
| T3-5 | active_orders_count | = COUNT(*) WHERE status NOT IN ('completed','cancelled','expired') |
| T3-6 | 不帶 Authorization | 401 missing authorization |
| T3-7 | 帶過期 / 偽造 JWT | 401 invalid token |

## T4 — Edge Function `list_my_orders`

| # | 步驟 | 預期 |
|---|------|------|
| T4-1 | `{ action: "list_my_orders", tab: "active" }` | 200，`{orders: [...]}` 含未完成訂單 |
| T4-2 | T4-1 中 orders 的 status | 全部 NOT IN ('completed','cancelled','expired') |
| T4-3 | `{ action: "list_my_orders", tab: "history" }` | 200，全部 status='completed' |
| T4-4 | 不傳 tab 或 tab 為其他值 | 400 invalid tab |
| T4-5 | 訂單列表過濾 6 個月 | created_at >= NOW() - INTERVAL '6 months' |
| T4-6 | ORDER BY created_at DESC | 第一筆是最新訂單 |
| T4-7 | 跨店隔離：A 店 token 看 B 店 member 的訂單 | 不會出現（store_id 過濾） |
| T4-8 | 訂單 items 結構 | 每筆訂單帶 items array（含 sku_id, qty, unit_price, status） |

## T5 — Edge Function `list_my_settlements`

| # | 步驟 | 預期 |
|---|------|------|
| T5-1 | `{ action: "list_my_settlements", tab: "unpaid" }` | 200，`{settlements: [...]}` 全部 payment_status='unpaid' |
| T5-2 | `{ action: "list_my_settlements", tab: "shipped" }` | 200，全部 status IN ('shipping','completed') |
| T5-3 | settlement 結構含 settlement_no | 格式 `S-xxxxxxxx-XX` |
| T5-4 | 金額分解欄位 | items_total, shipping_fee, discount_amount, payable_amount 全部存在 |
| T5-5 | 跨店隔離 | 同 T4-7 |
| T5-6 | 付款資訊欄位 | payment_method, paid_at, remit_amount, remit_at, remit_note 在 unpaid tab 可為 null/0 |
| T5-7 | 出貨資訊欄位 | shipping_method, shipping_address, shipping_phone, shipping_note 在卡片內可顯示 |

## T6 — UI: /overview 頁

| # | 步驟 | 預期 |
|---|------|------|
| T6-1 | 未登入直接訪問 /overview | redirect 回 / |
| T6-2 | 已登入訪問 | 載入後顯示店名、店家描述（若有）、付款方式、出貨方式、未結金額大字塊、進行中訂單 chip |
| T6-3 | banner_url 為空 | fallback 顯示純色背景 + 店名（不破版） |
| T6-4 | receivable_amount = 0 | 顯示「0 元」不出錯 |
| T6-5 | 點擊「進行中訂單 (N)」chip | 跳到 /orders 並停在 active sub-tab |
| T6-6 | 頂部 TabBar 含 4 個 tab | 總覽 / 我的訂單 / 我的結單 / 我，當前 tab 高亮 |

## T7 — UI: /orders 頁

| # | 步驟 | 預期 |
|---|------|------|
| T7-1 | 預設停在「未完成」sub-tab | 顯示 active 訂單 |
| T7-2 | 切換到「訂單紀錄」sub-tab | 顯示 history 訂單 |
| T7-3 | sub-tab 切換重新打 list_my_orders | 看 network panel 確認 |
| T7-4 | 訂單卡片內容 | 商品名 + 截止日 + 數量 + 金額 + 狀態 chips |
| T7-5 | 狀態 chips 邏輯 | items 全部 picked_up → 「全到 全結」；否則 「!未到 !未結 !未付 !未寄」（依 all_arrived / all_completed / payment_status / status 判斷） |
| T7-6 | empty state（無訂單） | 顯示「目前沒有未完成訂單」/「目前沒有已完成訂單」 |
| T7-7 | API 失敗 | 顯示錯誤 banner，不破版 |

## T8 — UI: /settlements 頁

| # | 步驟 | 預期 |
|---|------|------|
| T8-1 | 預設停在「待付款」sub-tab | 顯示 unpaid 結單 |
| T8-2 | 切換到「已寄出」sub-tab | 顯示 shipping/completed 結單 |
| T8-3 | 結單卡片頂部 | 顯示 `# 結單編號 S-xxxxxxxx-XX` 字樣 |
| T8-4 | 卡片狀態列 | 「未付款 / 未出貨」或「已付款 / 已寄出」依資料 |
| T8-5 | 付款方式區 | payment_method, 匯款金額 (remit_amount), 匯款時間 (remit_at), 匯款備註 (remit_note) — 缺值顯示 "-" 或 "0" |
| T8-6 | 出貨方式區 | shipping_method + 收件人/電話/備註（從 shipping_address/phone/note） |
| T8-7 | 金額分解 | 總金額 / 運費 / 促銷活動 / 應付金額 4 列數字 |
| T8-8 | empty state | 顯示「目前沒有待付款結單」/「目前沒有已寄出結單」 |

## T9 — 跨店隔離 / 安全

| # | 步驟 | 預期 |
|---|------|------|
| T9-1 | 偽造 JWT 把 store_id 改成另一店 | Edge Function 驗 JWT 簽章失敗 → 401 |
| T9-2 | 用 A 店合法 token 跑三個 action | 結果只含 pickup_store_id = A 的資料 |
| T9-3 | 用未綁會員 token（無 member_id）跑 list_my_orders | 401 no member_id in token |

## T10 — 已知限制（不在本次 scope）

| # | 項目 | 說明 |
|---|------|------|
| T10-1 | admin 端寫入新欄位 UI | payment_status / shipping_* / remit_* 等 12 個新欄位的 admin 編輯 UI 留 P1 |
| T10-2 | 「個人賣場」/「我的發票」tab | 留 P1，不在本次實作 |
| T10-3 | 結單合併（多 order → 1 settlement） | 結單 1:1 從 order 衍生，未來真合併再升級 |
| T10-4 | 訂單 / 結單分頁 | v1 限制最近 6 個月，無分頁 UI |

---

## 通過條件
- T1~T9 全部 pass
- T10 條目於最終 PR description 標明為「已知限制」
- 所有 SQL / API / UI 證據（query result, curl response, screenshot）保留於 `docs/TEST-LIFF-overview-orders-settlements-report.md`

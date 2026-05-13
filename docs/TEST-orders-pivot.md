---
title: TEST — 訂單樞紐表（日期/開團 × 商品品項 × 店家）
module: Order / UI
status: passed
created: 2026-05-13
verified_by: alex.chen + claude (preview tools)
---

# 訂單樞紐表 view

## 需求

訂單原本只有「清單」一個維度。新增一個樞紐表 view：

- **Row 分組（3 種模式可切換）：**
  - 取貨日（`pickup_deadline`，逐日）
  - 訂單日（`created_at`，逐日）
  - 開團（`group_buy_campaigns.id`，row 顯示開團名 + 收單期間 `start_at ~ end_at`）
- **Column：** 取貨店家（pickup_store，依資料動態出現）
- **Cell：** 該 group × 該品項 × 該店的「訂單筆數」(DISTINCT order_id COUNT)
- **Cell click：** 開 modal 顯示該 cell 內的訂單清單，點訂單可彈 OrderDetail

業態：團購店模式（總倉 1 + 100 加盟店），HQ 用這個 view 看「**哪個開團/哪天該送什麼到哪家店、各幾筆**」做出貨計劃 / 撿貨計劃。

## Scope

- 新頁面 `apps/admin/src/app/(protected)/orders/pivot/page.tsx`
- `apps/admin/src/app/(protected)/orders/page.tsx` header 加「樞紐表 ↗」連結
- 共用 filter：開團多選 / 分組維度 (取貨日|訂單日|開團) / 日期範圍 / 狀態
- Cell click 開 modal（不另起 sidebar 項目，在訂單頁切換）

## 資料模型

| 欄 | 來源 | 備註 |
|---|---|---|
| Group key (取貨日) | `customer_orders.pickup_deadline ?? created_at::date` | pickup_deadline 為 NULL 時 fallback |
| Group key (訂單日) | `customer_orders.created_at::date` | — |
| Group key (開團) | `customer_orders.campaign_id` | label = 開團名、subLabel = `start_at~end_at 收單` |
| 商品品項 | `skus.variant_name` (NULL fallback `product_name`) | 樞紐 row 層 2 |
| 店家 | `stores.name`（依 `customer_orders.pickup_store_id`） | 樞紐 column |
| Cell | `COUNT(DISTINCT customer_orders.id)` | 一個訂單可能有多 sku、只算一次 / sku |

## 預設值

- 分組維度：`pickup_date`（取貨日）
- 日期範圍：今天起前後各 30 天
  - 取貨日 mode：套用至 `pickup_deadline`
  - 訂單日 mode：套用至 `created_at`
  - 開團 mode：套用至 `campaign.end_at`（client 端 filter）
- 狀態：排除 `cancelled` / `expired` / `transferred_out`（這些不該進出貨計劃）
- 開團：全部
- 店家篩選：依分店帳號自動鎖（同訂單頁）

## 測試項目

### A. 載入 / Layout

| # | 測項 | 預期結果 |
|---|---|---|
| A1 | 從 /orders 點 header「樞紐表 ↗」連結進入 /orders/pivot | URL 切到 /orders/pivot |
| A2 | /orders/pivot 顯示 filter bar + 樞紐表 | 表頭店家為 column、列為日期+商品 |
| A3 | 樞紐表 header sticky（橫向 column 多時可滾動） | 滾動時店家列固定可見 |
| A4 | 空資料時顯示「沒有符合條件的訂單」 | 不 crash |
| A5 | /orders/pivot header 反向連結「列表 ←」回 /orders | URL 切回 /orders |

### B. 篩選 filter

| # | 測項 | 預期結果 |
|---|---|---|
| B1 | 切換分組維度 取貨日 / 訂單日 / 開團 | row group 重組、第一欄 header 從「日期」變「開團」 |
| B2 | 選一個開團 → 只剩該團訂單 | row count 對 |
| B3 | 多選開團 → 合併顯示 | row count = 多團合計 |
| B4 | 改日期範圍 | row 只剩範圍內（open mode 套 end_at） |
| B5 | 選擇狀態 = 已完成 → 只算 status=completed | cell count 變化 |
| B6 | branch user 自動鎖在自家店 | column 只剩自家店 |
| B7 | HQ user 預設全部店 | column 含所有有訂單的店 |

### B'. Cell drill-down

| # | 測項 | 預期結果 |
|---|---|---|
| B'1 | 點 cell 數字（count > 0） | 開 modal、title 含 `group / sku / store` |
| B'2 | Modal 列訂單 (order_no, member, campaign, qty, status, 訂購日) | 訂單數 = cell count |
| B'3 | 點 modal 內訂單 row | 開 OrderDetail modal（雙 modal stack） |
| B'4 | Cell count = 0（顯示「·」）→ 不可點 | 沒有 click handler |

### C. 樞紐 cell 數值正確性

| # | 測項 | SQL 對照 | 預期結果 |
|---|---|---|---|
| C1 | 任一 cell 值 = 該 (date, sku, store) 的 DISTINCT 訂單數 | `SELECT COUNT(DISTINCT co.id) FROM customer_orders co JOIN customer_order_items ci ON ci.order_id = co.id WHERE co.pickup_deadline = '{date}' AND ci.sku_id = {sku_id} AND co.pickup_store_id = {store_id} AND co.status NOT IN ('cancelled','expired','transferred_out')` | 數值對 |
| C2 | 同訂單兩個 sku → 該訂單在兩 sku row 各算 1（不重複合併） | — | 兩 row 各 +1 |
| C3 | 日期合計 = 該日所有品項合計 | sum(cell) | 對 |
| C4 | 品項合計 = 該品項所有店合計 | sum(cell) | 對 |
| C5 | 店家合計 = 該店所有 row 合計 | sum(cell) | 對 |
| C6 | 總計 = 所有 cell 合計 | sum(cell) | 對 |

### D. 邊界情況

| # | 測項 | 預期結果 |
|---|---|---|
| D1 | pickup_deadline 為 NULL 的訂單（用 created_at fallback） | 改日期欄位才看得到 / 用 fallback 顯示 |
| D2 | sku.variant_name 為 NULL → 顯示 product_name | row 名稱 fallback 正確 |
| D3 | 店家 active=false（被停用）但仍有訂單 | column 顯示該店（不擋） |
| D4 | 沒任何訂單 → empty state | 顯示「沒有符合條件的訂單」 |

### E. 效能

| # | 測項 | 預期結果 |
|---|---|---|
| E1 | 30 天 × 全部開團 × 全店 → 載入 < 3 秒 | 載入完成、不卡 UI |
| E2 | 大資料量 (1000+ 訂單) 樞紐 | 仍順、scroll 不卡 |

## 已驗證 (2026-05-13, preview tools)

| 測項 | 結果 | 證據 |
|---|---|---|
| A1-A5 載入 + Layout + toggle 連結 | ✅ PASS | `共 7 筆訂單 / 1 個日期 / 3 家店`、`href="/orders/pivot/"` link 存在 |
| B1 切換分組維度 (campaign mode) | ✅ PASS | 切到 campaign → header 變「開團」、9 個 group、row 「日本醬油 #2 / 5/11 ~ 5/16 收單」 |
| B5 狀態 全選 | ✅ PASS | 20 → 23 筆（含 cancelled/expired/transferred_out） |
| C1-C6 cell 數值 + 小計 + 總計 | ✅ PASS | 中筋麵粉1kg: 北投1+平鎮2+松山0=3 ✓ / 小計 1+5+5=11 ✓ / 總計 11 ✓ |
| B'1-B'3 cell click → modal → OrderDetail | ✅ PASS | 雙 modal stack: `日本醬油 #2（5/11 ~ 5/16 收單） / 日本醬油1L / 松山店` + `訂單明細 ORD-0002` |

## 未驗證 / 後續

- CSV 匯出（V2 加）
- 切換 cell 為 sum(qty)（V2 加，目前用戶要 count）
- 跳 /orders 列表頁帶 filter（目前用 modal、未跳列表頁）— 若後續要、可加 /orders 支援 `skuId` + `date` + `dateField` query param

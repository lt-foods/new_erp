---
title: TEST — rpc_orders_pivot returns jsonb（避開 PostgREST max_rows=1000 截斷）
module: admin / orders / pivot
status: pending
ran_at: 2026-05-21
verified_by: alex.chen
---

# Bug: 樞紐表選「全部店」時、某些開團整個從表內消失

## 症狀

`/admin/orders/pivot`：

| 操作 | 結果 |
|---|---|
| 取貨店 filter = 「松山店」 | 開團 `GRP-20260521-001` 出現、cell 數量正確 |
| 取貨店 filter = 「全部取貨店」 | 開團 `GRP-20260521-001` 整筆從表內消失 |

選「全部店」反而比選單店看到的少（單店是全部的子集，理應出現）— 顯然某些 row 被丟掉。

## 根因

`supabase/config.toml` `max_rows = 1000` 是 PostgREST 對所有 GET / RPC `setof` 結果的硬上限。

[`rpc_orders_pivot`](../supabase/migrations/20260621000020_rpc_orders_pivot_closed_filter.sql) 雖是 server-side aggregate（PR #318 引入避免 client 撈 items 時被截斷），但它本身回的是 `RETURNS TABLE(...)`（setof rows），**這個 setof 一樣被 max_rows cap 在 1000**。

- 每一筆 RPC row = `(group × sku × pickup_store)` 一個 cell
- 選單一店時 cell 數 = 團 × SKU，通常 < 1000 → 不截
- 選全部店時 cell 數 = 團 × SKU × 店，輕鬆爆 1000 → 截斷
- RPC 內沒 `ORDER BY`，被砍掉的是哪幾筆是 DB 隨機決定 → 任何開團都可能消失

## 修法

新 migration `supabase/migrations/20260621000030_rpc_orders_pivot_jsonb.sql`：

- DROP 舊的 `rpc_orders_pivot(text, date, date, bigint[], bigint, text[], boolean)` setof 版
- CREATE 新版 `RETURNS jsonb`，內部用 `jsonb_agg(to_jsonb(t))` 包成單 row
- 單 row 不受 `max_rows = 1000` 限制（PostgREST cap 算 row 數、不算 jsonb array 內元素）

Client 端 [`apps/admin/src/app/(protected)/orders/pivot/page.tsx`](../apps/admin/src/app/(protected)/orders/pivot/page.tsx)：

- `sb.rpc("rpc_orders_pivot", ...)` 回值改為 `jsonb` （在 supabase-js 中就是 JS array/object）
- `setPivotRows(data ?? [])` 改 cast 為 `PivotRow[]`（jsonb array 解出來就是 PivotRow array）

## 驗證

### Schema 層

| 測項 | 期待 |
|---|---|
| 新 migration 內有 `DROP FUNCTION IF EXISTS rpc_orders_pivot(...)`（舊 signature） | ✓ |
| 新 migration `CREATE OR REPLACE FUNCTION rpc_orders_pivot(...) RETURNS jsonb` | ✓ |
| `GRANT EXECUTE` 給 `authenticated` | ✓ |
| Migration `\i` 進 local DB 後 `\df rpc_orders_pivot` 顯示 return type = `jsonb` | ✓ |

### RPC 層

prod 部署後（user 貼 Studio）：

| 測項 | 期待 |
|---|---|
| `SELECT rpc_orders_pivot('campaign', '2026-05-01'::date, '2026-06-01'::date, NULL, NULL, ARRAY['confirmed','submitted','pending'], NULL)` 回 jsonb array | ✓ |
| array length（用 `SELECT jsonb_array_length(rpc_orders_pivot(...))`）符合預期 group×sku×store cell 數 | ✓ |
| 該 jsonb 內含 `group_id = <GRP-20260521-001 的 id>` 的元素 | ✓ |

### UI 層

| 測項 | 期待 |
|---|---|
| `/admin/orders/pivot` 取貨店 = 「松山店」 → `GRP-20260521-001` row 出現 | ✓ |
| 同上 = 「全部取貨店」 → **`GRP-20260521-001` row 仍出現**（修前消失） | ✓ |
| 同上、cell 數量加總（松山店欄）等於修前單選松山店時看到的數量 | ✓ |
| 切「品項數 / 訂單金額」、月份範圍、closed_only filter 全正常 | ✓ |
| 點 cell 跳 drill-down modal 訂單清單正常 | ✓ |
| Console 零 error | ✓ |

### Regression

| 測項 | 期待 |
|---|---|
| 樞紐表內其他既有開團 row 數量／金額不變 | ✓ |
| `/orders` 列表不受影響（沒共用 RPC） | ✓ |
| `tsc` / `npm run lint` 全綠 | ✓ |

## 邊界 / 後續

- jsonb 單 row 大小理論上 1 GB cap，但 PG 實務 toast 後 10 MB 就會變慢；目前 cell 數預估 < 100K（30 團 × 30 SKU × 100 店），單 jsonb < 5 MB，OK
- 若未來 cell 數爆增、可考慮 RPC 加 `LIMIT` + `OFFSET` 參數做分頁；不過 cell 數真到 100K UI 也吃不下，要先 redesign
- 不動 `config.toml` 的 `max_rows = 1000`（全域改動風險大，個別 RPC 自己處理較乾淨）

# 總倉退回貨處理：本機整合測試設計

日期：2026-09-07  
角色：阿審，並行驗收準備  
限制：只設計本機測試，不連 GitHub/Supabase，不讀 `.env`，不跑現有可能連線腳本，不碰阿寫的 `tests/return-disposition/fixture.sql` 或 `test.sql`。

---

## 一、測試目標

這組測試不是要複製整套正式系統，而是用最小假資料跑「真正最新版函式」：

- `apply_movement_to_balance` / `trg_apply_movement`
- `rpc_outbound`
- `rpc_receive_transfer`
- `rpc_create_store_return`
- `rpc_resolve_transfer_item_shortage`
- `rpc_undo_transfer_item_shortage`
- `rpc_adjust_received_transfer`
- `rpc_unreceive_transfer`
- 阿寫新增的總倉退回貨待處理 migration

不能把核心函式抄成簡化版測試，否則只是在測自己寫的假世界。

---

## 二、最小本機庫載入方式

本機 PostgreSQL 18 預計位置：

```powershell
psql -h 127.0.0.1 -p 56427 -U returnlocal -d return_disposition_review
```

建議建立兩種資料庫：

- `return_disposition_review_fixture`：阿寫 fixture/test 用。
- `return_disposition_review_check`：阿審可重跑審查斷言用。

最低限度要載入這幾類東西：

1. 基礎 schema，不要手刻假表：
   - `supabase/migrations/20260422120001_product_schema.sql`：`products` / `skus` / `prices`
   - `supabase/migrations/20260422120003_inventory_schema.sql`：`locations` / `stock_balances` / `stock_movements` / `transfers` / `transfer_items` / trigger
   - `supabase/migrations/20260423120000_stores_order_schema.sql`：`stores` / `customer_orders` / `customer_order_items`
   - `supabase/migrations/20260423120002_picking_waves.sql`：`picking_waves` / `picking_wave_items`
   - `supabase/migrations/20260512000009_store_monthly_settlement.sql`：鎖月表
   - `supabase/migrations/20260515000001_restock_requests_schema.sql`：補貨申請表
2. 會被最新版函式引用的欄位追加 migration。不要只靠最早建表檔，因為後面有追加欄位：
   - `transfer_type`、`customer_order_id`、`next_transfer_id`
   - `transfer_items.description`、`estimated_amount`
   - `shortage_resolution`、`shortage_restock_movement_id`、`shortage_redispatch_wave_id`、`shortage_return_transfer_id`、`shortage_prev_qty_received`
   - `stock_movements` 的最新 movement type、`source_doc_line_id`、`reverses`
3. 真正最新版函式按最後 CREATE 載入：
   - `rpc_outbound`：`20260705000000_dispatch_price_guard.sql:121`
   - `rpc_receive_transfer`：`20260904020010_accept_store_return_deducts_stock.sql:101`
   - `rpc_create_store_return`：`20260904020000_store_return_create_no_stock.sql:157`
   - `rpc_resolve_transfer_item_shortage`：`20260903000200_shortage_resolution_undo.sql:111`
   - `rpc_undo_transfer_item_shortage`：`20260903000200_shortage_resolution_undo.sql:429`
   - `rpc_adjust_received_transfer`：`20260904010000_adjust_received_syncs_stock.sql:194`
   - `rpc_unreceive_transfer`：`20260903000010_unreceive_reverse_inbound_regardless_of_qty.sql:26`
4. 阿寫新增 migration 最後載入。

如果完整 migration 串太重，允許做「最小 schema 載入檔」，但限制是：

- 表、欄位、CHECK、trigger 必須照真 schema。
- 上面列的函式必須從正式 migration 原文載入，不可在 fixture 內重寫簡版。
- 可以 stub 掉本測試完全不會走到的通知、報表、外部整合，但 stub 名稱要集中列在 fixture 檔頭。

---

## 三、真 schema 錨點

本輪已讀到的真 schema／真定義錨點：

- `stock_balances.reserved` 欄位存在於 `20260422120003_inventory_schema.sql:34`。
- `stock_movements` movement type 最初清單在 `20260422120003_inventory_schema.sql:54`，後續有 migration 擴充，不能只拿最早清單。
- `transfers` / `transfer_items` 基礎表在 `20260422120003_inventory_schema.sql:84`、`:107`。
- `trg_apply_movement` 在 `20260422120003_inventory_schema.sql:254`。
- `rpc_outbound` 最新版在 `20260705000000_dispatch_price_guard.sql:121`，`SELECT on_hand - reserved` 在 `:144`，`p_allow_negative` 判斷在 `:157`。
- `rpc_receive_transfer` 最新版在 `20260904020010_accept_store_return_deducts_stock.sql:101`。
- `rpc_create_store_return` 最新版在 `20260904020000_store_return_create_no_stock.sql:157`。
- `rpc_resolve_transfer_item_shortage` 最新版在 `20260903000200_shortage_resolution_undo.sql:111`。
- `rpc_undo_transfer_item_shortage` 最新版在 `20260903000200_shortage_resolution_undo.sql:429`。
- `rpc_adjust_received_transfer` 最新版在 `20260904010000_adjust_received_syncs_stock.sql:194`。
- `rpc_unreceive_transfer` 最新版在 `20260903000010_unreceive_reverse_inbound_regardless_of_qty.sql:26`。

---

## 四、最小 fixture 必備角色

假資料至少要有：

- 1 個 tenant。
- 1 個總倉 location。
- 2 個店 location：A 店、B 店。
- 2 個 store：A、B，分別連到 location。
- 2 個 SKU：
  - SKU-GOOD：一般商品，用來測完好/破損/遺失/待確認。
  - SKU-OTHER：同商品或不同商品皆可，用來證明同商品好貨照派、不整個商品鎖死。
- HQ `stock_balances`：
  - SKU-GOOD 在庫 20，好貨已確認。
  - 另有 3 件待確認來源，測試後可派應是 20，不是 23。
- A 店 `stock_balances`：
  - SKU-GOOD 在庫足夠送退貨，能測 `rpc_create_store_return` → `rpc_receive_transfer`。
- 一筆 `hq_to_store` 已收但短收的 transfer，用來測 `restock_hq` / `redispatch`。
- 一筆鎖月 `store_monthly_settlements`，用來測跨月/已鎖月份不可靜默改錢。
- 至少一筆直接負異動嘗試，用來驗 trigger 或同等保護是否擋住繞過 `rpc_outbound`。

---

## 五、必要測試情境

### A. 店家退貨同意後形成待確認

1. A 店送退貨 3 件，送出時不扣庫存。
2. 總倉手動同意。
3. 預期：
   - transfer 變 `received`。
   - HQ on_hand 增加 3。
   - 新待處理明細出現 3。
   - HQ reserved 或同等保護增加 3。
   - 可派量仍只算原本好貨，不把這 3 件算進去。

### B. 48 小時自動同意也要一樣

1. 建一張超過 48 小時的店家退貨。
2. 呼叫真正的自動同意函式，或用阿寫測試鉤子只處理該單。
3. 預期和手動同意一致，且處理紀錄標示系統自動、時間、原單。

### C. 同商品好貨照派，不整個 SKU 鎖死

1. HQ SKU-GOOD on_hand 23，其中 3 待確認、20 是好貨。
2. 對 B 店派 20 應成功。
3. 派第 21 件應失敗。
4. 不能出現「因有 3 件待確認，所以整個 SKU 都不能派」。

### D. 同批部分處理

1. 同一批 10 件待確認。
2. 先處理 4 完好。
3. 再處理 2 破損、1 遺失。
4. 預期：
   - 完好 4 從待確認轉可派。
   - 破損/遺失扣總倉數量且留成本依據。
   - 待確認剩 3。
   - 完好 + 破損 + 遺失 + 未處理 = 10。

### E. 重複提交與兩連線併發

1. 同一筆待確認，連續按兩次處理，第二次不能再扣。
2. 雙 session 同時處理同一批：
   - session A 開交易後鎖住同一批。
   - session B 應等待或失敗。
   - 最終合計不能超過原數量。
3. 同時派貨與處理破損：
   - 派貨不能把待確認量吃掉。
   - 破損扣減不能把 on_hand 扣成負數。

### F. `p_allow_negative` 與直接負異動旁路

1. 呼叫 `rpc_outbound(..., p_allow_negative => false)` 應被 `reserved` 或同等可用量擋住。
2. 呼叫 `rpc_outbound(..., p_allow_negative => true)` 不應能繞過本案「待確認不可派」規則；若本案選擇用 trigger，應由 trigger 擋。
3. 直接 `INSERT stock_movements` 寫負數也應被 trigger 或同等共用保護擋住。

這三條是用來防 fixture 太簡化：只測一般 `rpc_outbound` 不夠。

### G. 短少路徑

1. `restock_hq` 真回帳：`transfer_cancel` 回到出貨端的那批實物/貨帳，必須建立一次待處理來源。
2. `redispatch` 真回帳：同上，且不能因為重派再建第二批待處理。
3. `[短收沖帳]` 純記帳 `return_to_hq` 單不能進實物待驗。
4. 同一短少已處理過，再送一般少收退貨，應防重複扣/加/退款。

### H. 修改實收與退回收貨配單

1. 已有待處理的 `return_to_hq` 單，走 `rpc_adjust_received_transfer`：
   - 要嘛後端擋。
   - 要嘛同步調整待處理量與保留量。
2. 走 `rpc_unreceive_transfer`：
   - 待處理明細與保留量要撤回。
   - 不能留下幽靈 reserved。

### I. 錢與鎖月

1. 店家帳單沖回只發生一次。
2. 總倉內部破損/遺失不自動再向店家收款或退款。
3. 已鎖月份不准被原單更正或後續處理靜默重算。
4. 成本依據至少能追到原出庫/入庫 movement 或候選規則明確標記成本未知。

---

## 六、審查用跑法

阿寫完成後，建議 CEO 在本機新 cluster 依序跑：

```powershell
psql -h 127.0.0.1 -p 56427 -U returnlocal -d return_disposition_review -v ON_ERROR_STOP=1 -f .\tests\return-disposition\fixture.sql
psql -h 127.0.0.1 -p 56427 -U returnlocal -d return_disposition_review -v ON_ERROR_STOP=1 -f .\tests\return-disposition\test.sql
psql -h 127.0.0.1 -p 56427 -U returnlocal -d return_disposition_review -v ON_ERROR_STOP=1 -f .\tests\return-disposition-review\review_assertions.sql
```

雙 session 併發測試不能只靠單一 SQL 檔證明。若阿寫沒有提供兩連線腳本，阿審要手動用兩個 psql 視窗驗一次：

```sql
-- session A
BEGIN;
-- 呼叫阿寫的處理函式，故意先不 COMMIT。

-- session B
BEGIN;
-- 對同一批呼叫處理或派貨，應等待或失敗，不能成功吃掉同一批。

-- session A
COMMIT;

-- session B
-- 若等待後繼續，必須重讀新狀態並拒絕超量。
```

---

## 七、阿審正式審查時的判準

- 測試有跑真正最新版函式，不是 fixture 裡另寫簡版。
- 測試能抓出只改畫面、沒改共用後端保護的錯。
- 測試能抓出只靠 `reserved`、卻漏掉 `p_allow_negative` 或直接負 movement 的錯。
- 測試能抓出短少 `transfer_cancel` 真回帳未建待處理的錯。
- 測試能抓出 `[短收沖帳]` 純記帳單被誤抓進實物待驗的錯。
- 測試能抓出 `adjust` / `unreceive` 讓保留量脫鉤的錯。
- 測試能抓出鎖月、重複提交、兩連線併發缺測。

沒有上述證據，就不能只憑「測試綠」放行。

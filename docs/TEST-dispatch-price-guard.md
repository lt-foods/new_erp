# dispatch-price-guard 測試項目 — 出貨價格防呆：成本/分店價未設定不能出倉

**對應 migration:** `supabase/migrations/20260705000000_dispatch_price_guard.sql`
**對應 UI 變更:** `apps/admin/src/app/(protected)/wms/picking/page.tsx`
**背景:** 採購單 0 成本 0 分店價建單 → 收貨 avg_cost=0 → 一鍵派貨無人發現 → 月結 `qty × 0` 元。
楊小胖 2026-06-11 回報：「派車出倉沒有可以修改金額的地方」「0 分店價不可出」。

## 1. Schema / Migration 層

### 1.1 守衛 helper
- [ ] `_missing_dispatch_prices(uuid, bigint[])` 存在、回傳 TEXT
  ```sql
  SELECT proname, pg_get_function_arguments(oid) FROM pg_proc
   WHERE proname = '_missing_dispatch_prices';
  ```

### 1.2 rpc_outbound 簽名替換（9 → 10 參數）
- [ ] 舊 9 參數版已 DROP、只剩一個 10 參數版（`p_fallback_unit_cost NUMERIC DEFAULT NULL`）
  ```sql
  SELECT pronargs, pg_get_function_arguments(oid) FROM pg_proc WHERE proname = 'rpc_outbound';
  -- 預期：恰好 1 列、pronargs = 10、最後一個參數 p_fallback_unit_cost numeric DEFAULT NULL
  ```
- [ ] GRANT EXECUTE 仍在（authenticated）

### 1.3 三支出倉 RPC 重建 + 守衛
- [ ] `generate_transfer_from_wave` / `rpc_ship_restock_pr_received` / `rpc_transfer_distribute_batch` 的 prosrc 都含 `_missing_dispatch_prices`
  ```sql
  SELECT proname FROM pg_proc
   WHERE prosrc LIKE '%_missing_dispatch_prices%' AND proname <> '_missing_dispatch_prices';
  ```
- [ ] 三支 GRANT 不變；`generate_transfer_from_wave` 保留 20260511000002 全部行為（picked_qty NULL 自動補 qty、全 0 中文錯誤、advisory lock、store location 檢查、so_generated audit、張數核對）

## 2. RPC 行為（SQL 直測）

### 2.1 wave 派貨 — 缺成本價擋下
**情境：** SKU 無現行 cost 價（無 row 或 effective_to 已收掉），有 branch 價；wave status=picked。
**預期：** `generate_transfer_from_wave` RAISE 中文錯誤、訊息含該 sku_code 與「缺成本價」；不建 transfers、不寫 stock_movements、wave 仍 picked。

### 2.2 wave 派貨 — 缺分店價擋下
**情境：** SKU 有 cost 價、無現行 branch 價。
**預期：** 錯誤訊息含「缺分店價」；其餘同 2.1。

### 2.3 wave 派貨 — 價格 = 0 視同缺
**情境：** prices 有現行 row 但 price = 0（cost 或 branch）。
**預期：** 一樣擋下（守衛條件 price > 0）。

### 2.4 wave 派貨 — 兩價齊全放行 + avg_cost 正常計價
**情境：** SKU avg_cost > 0、cost/branch 價齊全。
**預期：** transfer 建立、出庫 movement.unit_cost = avg_cost（行為與改前完全一致）。

### 2.5 wave 派貨 — avg_cost=0 時用現行成本價計費（fallback）
**情境：** SKU 以 0 成本收貨（HQ avg_cost = 0），事後補 cost 價 = 50、branch 價 = 60，再派貨。
**預期：** 出庫 movement.unit_cost = 50（非 0）；transfer 照常 shipped。

### 2.6 月結金額不再 0 元（end-to-end）
**情境：** 接 2.5，分店收貨後跑 `rpc_generate_hq_to_store_settlement(當月)`。
**預期：** 該店月結 line：unit_cost = 50、line_amount = qty × 50；payable_amount 非 0。

### 2.7 restock PR 到貨直派 — 守衛同樣生效
**情境：** restock_requests status=approved_pr，行內 SKU 缺 branch 價，呼叫 `rpc_ship_restock_pr_received`。
**預期：** 中文缺價錯誤、不建 transfer、request 狀態不變。

### 2.8 待派發批次 — 只擋 hq_to_store
**情境：** 兩張 draft transfer 一起 `rpc_transfer_distribute_batch`：A = hq_to_store 含缺價 SKU、B = 店↔店（free）同樣缺價。
**預期：** A 進 failed[]、reason 為中文缺價訊息；B 照常 shipped（店間轉貨不檢查）。

### 2.9 虛擬 SKU 跳過
**情境：** hq_to_store transfer 內含 products.is_virtual=TRUE 的 SKU（無任何價格）。
**預期：** 不因虛擬 SKU 被擋；出庫照 20260515000006 邏輯跳過 movement。

### 2.10 rpc_outbound 既有呼叫端回歸（9 具名參數 → 單一函式 + default）
**情境：** 各跑一次會觸發 rpc_outbound 的既有流程：訂單退貨回總倉（rpc_create_order_return）、互助單派貨（rpc_ship_aid_order）、取貨跨店 leg2（rpc_pickup 鏈）。
**預期：** 全部正常、無「function is not unique」、movement.unit_cost 行為同舊（avg_cost）。

### 2.11 守衛訊息一次列出全部缺價 SKU
**情境：** wave 內 3 個 SKU 缺價（兩個缺成本、一個缺兩種）。
**預期：** 一次 exception 列出 3 個 sku_code 與各自缺的價別（頓號分隔），不是只報第一個。

## 3. UI 行為（/wms/picking 派貨工作台）

- [ ] 頁面載入無 console error；矩陣/依分店/補貨 section 外觀與原本一致
- [ ] 缺成本價的 SKU 列顯示紅字 pill「缺成本」；缺分店價顯示「缺分店價」；兩者都缺同時顯示（文字 pill、無 icon/emoji）
- [ ] 價格齊全的 SKU 不顯示任何 pill
- [ ] 點 pill → inline 輸入框；輸入 50 儲存 → 呼叫對應 rpc_set_cost_price / rpc_set_branch_price → pill 消失（價格重抓）
- [ ] 儲存中為純 spinner、無「儲存中」文字
- [ ] 輸入 0 / 空白 → 不送出（防呆，分店價 0 不可出的源頭就是這個）
- [ ] 非 HQ 價格權限 role（無法讀 cost/branch prices 的 role）不顯示 pills（避免 RLS 讀不到誤判缺價）

## 4. Regression

- [ ] hq/inbox 撿貨單批次「派貨」：全有價 wave 照常成功；含缺價 wave 失敗訊息逐張顯示、其他 wave 不受牽連
- [ ] 自由轉貨 店↔店：建單 → 派發 → 收貨 全程不受守衛影響
- [ ] 訂單退貨回總倉（rpc_create_order_return）照常
- [ ] 取貨（同店 / 跨店互助 leg）照常
- [ ] e2e seed：seed 資料若缺 cost/branch 價，黃金路徑派貨步驟會被新守衛擋 — seed 腳本需同步補價（檢查 `supabase/seed*` / `scripts/`）
- [ ] /wms/picking 原矩陣分配、⚖ 平均、FIFO 多 PO 切單、勾選品項建單、補貨 amber section 全部照舊

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**migration 套用成功（本機 docker 或 prod via Management API）**、**admin build + type-check 過** 才可標 done。

> Prod 部署前置：先探測線上缺價覆蓋率（active SKU 缺 cost/branch 價的數量、HQ 在庫 avg_cost=0 清單），
> 若大面積缺價，需先告知使用者並提供補價 SQL，避免守衛上線當下全倉派貨被擋死。

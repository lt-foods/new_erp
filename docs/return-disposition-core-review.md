# 阿審審查報告：總倉退回貨處理 A 核心

日期：2026-09-07  
範圍：只審 A 段 `supabase/migrations/20260907010000_hq_return_disposition_core.sql` 與 `docs/return-disposition-core-contract.md`。  
不審 B/C 尚未接的來源接線、撤回、月鎖；不連 GitHub / Supabase / API；沒有執行正式庫 db push。

CEO 已回報 SQL parser：34 statements / 4 funcs 通過。以下是邏輯審查，不是正式資料庫驗收。

## 結論

A 目前不建議直接交給 B/C 往下接，先修 P0/P1 比較安全。

最重的問題不是語法，而是「核心保護層本身還沒把來源、凍結量、併發與權限鎖死」。如果 B 段照預期接對，很多問題不一定立刻爆；但 A 是共用底座，應該要防 B 接錯，而不是相信 B 永遠接對。

## P0

### P0-1：`_hq_hold_return` 沒驗來源 movement 真的屬於這個總倉、這個品項批次，且 `p_qty` 可異於來源數量

位置：`supabase/migrations/20260907010000_hq_return_disposition_core.sql:245-317`

目前有驗：

- source movement 存在：`:245-253`
- tenant 相同：`:255-257`
- quantity > 0：`:259-261`
- sku 相同：`:263-265`
- 傳入 location 是總倉：`:267-278`

但還少三道核心防線：

- 沒驗 `v_mov.location_id = p_location_id`。也就是「來源 movement」可能其實不是這個總倉的入庫，A 仍會在總倉建立待處理批次並加 reserved。
- 沒驗 `p_qty` 必須等於來源 movement 的 quantity。`source_movement_id` 又是唯一鍵 `:72-73`，如果 `p_qty` 小於來源 movement，剩下那段永遠不能再建第二批；如果大於來源 movement，會凍結出超過實際來源的待處理量。
- 沒驗 `p_source_transfer_item_id` 跟來源 movement 的關係。B 之後會傳 `transfer_items.in_movement_id` / `shortage_restock_movement_id`，但 A 本身沒驗 item 是否真的指向這筆 movement、同 SKU、同 tenant。

白話風險：

- 做了現在這版：B 只要傳錯一個 movement id，就可能在總倉帳上生出一批「看起來待處理、其實來源不對」的貨。
- 不修：後面 UI、報表、補貨保護都會相信這批 reserved，錯會一路擴散。

最小修法：

- 在 `_hq_hold_return` 內補：
  - `v_mov.location_id = p_location_id`
  - `v_hold_qty = v_mov.quantity`，不要只檢查 `> 0`
  - 若 `p_source_transfer_item_id IS NOT NULL`，查 `transfer_items`，確認同 SKU，且 `in_movement_id = p_source_movement_id OR shortage_restock_movement_id = p_source_movement_id`
- 介面簽名可不改。

### P0-2：負異動 guard 先算 pending、沒 pending 就直接放行；遇到同 SKU 新增 hold 的併發會漏看

位置：`supabase/migrations/20260907010000_hq_return_disposition_core.sql:581-632`

目前流程：

1. 負 movement 進來。
2. 先 `SUM(hq_return_batches pending)`：`:592-600`
3. 如果當下看起來 pending = 0，就直接 `RETURN NEW`：`:602-605`
4. 有 pending 才鎖 `stock_balances`：`:607-616`

問題是：A 的任務就是保護「剛回總倉、還待確認的那批不能被派走」。如果另一個交易正在對同一個總倉/SKU 建 hold，這支 guard 可能在 hold 完成前先看到 pending = 0，於是直接放行負出庫。

白話風險：

- 做了現在這版：剛回來、正要被凍結的那批貨，遇到同時間出庫，有機會被先派掉。
- 不修：後面即使 B 有正確呼叫 `_hq_hold_return`，共用保護仍不是穩的。

最小修法：

- 對負 movement，先鎖同一筆 `stock_balances`，再重讀 pending；不要在鎖 balance 前因 pending = 0 直接 return。
- `_hq_hold_return` 建 hold / 加 reserved 也要走同一個鎖序，避免跟 guard 互相錯過。
- guard function 建議補 `SECURITY DEFINER SET search_path = public, pg_temp`；現在是一般 trigger function，後續若 RLS/權限收緊，或 search_path 不乾淨，讀 pending 可能失準。

## P1

### P1-1：RLS / GRANT / 契約三者不一致；修 GRANT 時還會變成分店可看成本

位置：

- RLS policy：`supabase/migrations/20260907010000_hq_return_disposition_core.sql:185-196`
- view：`supabase/migrations/20260907010000_hq_return_disposition_core.sql:645-673`
- 契約：`docs/return-disposition-core-contract.md`

目前 migration 只建了同 tenant SELECT policy，沒有 `GRANT SELECT` 給 `authenticated`。照 Postgres 權限，policy 不是 grant；沒有表/視圖權限時，前端不一定讀得到。這跟契約「同 tenant 可讀」不一致。

但如果只是補 `GRANT SELECT`，又會變成同 tenant 的分店帳號也可查 `unit_cost`、全部總倉待處理批次與事件，因為 policy 只有 tenant，沒有 role 白名單。

白話風險：

- 做了現在這版：UI 可能讀不到。
- 只補 GRANT 不補 role：分店可能看得到不該看的成本與總倉內部處理資料。

最小修法：

- 決定 A 的讀取對象：若這是總倉處理頁，SELECT policy 與 view 都應限制 `owner/admin/hq_manager`。
- 補對應的 `GRANT SELECT ON ... TO authenticated`，但要跟 role policy 同刀完成。
- 若分店日後也要看自己的進度，另開低敏 view，不要把 `unit_cost` 與全部 batch 直接放給同 tenant 所有人。

### P1-2：`request_id` 冪等沒有 tenant 範圍、payload 比對不完整，併發重試也可能不是冪等

位置：`supabase/migrations/20260907010000_hq_return_disposition_core.sql:418-437`

目前有做：

- 同 `request_id` 查既有 event。
- 比對 `batch_id / qty_good / qty_damaged / qty_lost`。
- 相同就回 `idempotent = true`。

還缺：

- 查 existing event 時沒有加 `tenant_id = v_tenant`，而且發生在 batch tenant 驗證之前。雖然 UUID 猜中機率低，但這是 SECURITY DEFINER RPC，不應跨 tenant 回別人的 event/batch id。
- payload 沒比 `damage_reason / loss_reason / goods_confirmed / notes`。同 request id 換原因或備註，現在會被當成同一筆重試放過。
- 兩個完全同時的相同 request，可能都先查不到 existing，最後靠 unique constraint 擋第二筆；第二筆會噴錯，不會回 idempotent。
- `p_request_id IS NULL` 沒先擋，會一路做到最後 INSERT 才撞 NOT NULL，錯誤點太晚。

白話風險：

- 做了現在這版：重送按鈕的「同一包」定義不完整；真的網路重試或雙擊，還是可能讓使用者看到錯誤。
- 不修：稽核備註/原因可能被靜默忽略，跨 tenant 的安全邊界也不夠乾淨。

最小修法：

- existing 查詢加 `tenant_id = v_tenant`。
- 一開始擋 `p_request_id IS NULL`。
- payload 比對補齊 reason、notes、goods_confirmed；文字欄位用同一個空白/null 規則。
- INSERT event 遇到 `unique_violation` 時，重新 SELECT existing 並跑同一套 payload 比對後回 idempotent。

### P1-3：NUMERIC 會被 `NUMERIC(18,3)` 靜默四捨五入，可能讓 pending / reserved / event 數字不照使用者輸入

位置：

- batch qty 欄：`supabase/migrations/20260907010000_hq_return_disposition_core.sql:55-64`
- event qty 欄：`:122-124`
- `v_this_total NUMERIC(18,3)`：`:367-392`

目前有擋負數、NaN、Infinity，但沒有明確拒絕超過 3 位小數。Postgres 寫入 `NUMERIC(18,3)` 會四捨五入，不是拒絕。

白話風險：

- 做了現在這版：如果前端或未來 RPC 傳 `0.0005`，資料庫可能記成 `0.001`，使用者輸入跟帳上留痕不同。
- 不修：部分處理的 pending、reserved、事件紀錄會出現很難追的零碎差異。

最小修法：

- 在 `_hq_hold_return` 與 `rpc_dispose_hq_return` 對所有數量輸入補共同檢查：`value = ROUND(value, 3)`。
- 對 `p_qty_good / p_qty_damaged / p_qty_lost / p_qty` 都要逐欄檢查，不要只檢查總和。

### P1-4：`reserved` 直接扣，沒確認這批凍結量還在，可能把共用 reserved 扣成負數或吃到別人的 reserved

位置：`supabase/migrations/20260907010000_hq_return_disposition_core.sql:465-480`

`rpc_dispose_hq_return` 先鎖 balance，再直接：

```sql
reserved = reserved - v_this_total
```

但沒有檢查目前 `reserved >= v_this_total`。既有 `stock_balances` 本身也沒有 `reserved >= 0` 的 CHECK，見 `supabase/migrations/20260422120003_inventory_schema.sql:29-41`。

白話風險：

- 做了現在這版：只要前面曾經漏加、被手動改、或未來別的機制共用 reserved，這裡就可能把 reserved 扣成負數，讓「可派貨」看起來比實物更多。
- 不修：A 的「待確認這批不能派」保護會變得不好對帳。

最小修法：

- 鎖 balance 後讀 `reserved`，若 `reserved < v_this_total` 直接 raise。
- 不要用 `GREATEST(reserved - v_this_total, 0)` 靜默吞錯；那會把錯帳藏起來。

### P1-5：新增 `hq_return_damage` / `hq_return_loss` 不必要，會把全域 CHECK 變成本案負擔

位置：

- CHECK 重建：`supabase/migrations/20260907010000_hq_return_disposition_core.sql:16-38`
- 寫 movement：`:498-523`

本機 grep 到最後一次正式重建 `stock_movements_movement_type_check` 是 `20260713000000_stock_movements_allow_transfer_cancel.sql:25-41`；A 目前沒有漏掉本機主線已合法的 type。

但依 ponytail，這兩個新 type 不值得。既有合法 type 已有：

- `damage`
- `manual_adjust`
- `stocktake_loss`

而且 `stock_movements` 本來就有 `source_doc_type / source_doc_id / reason / notes` 可以標明這是 `hq_return_batch`。

白話風險：

- 做了現在這版：每次有人加 movement_type，都要重建同一個全域 CHECK；未來別的分支也動這裡時，很容易互蓋。
- 不修：不是今天一定壞，但會把一個局部功能變成全系統庫存型別維護成本。

最小修法：

- 破損用既有 `damage`，搭配 `source_doc_type='hq_return_batch'`、`source_doc_id=p_batch_id`、`reason=p_damage_reason`。
- 遺失若不是盤點，不要硬用 `stocktake_loss`；可用 `manual_adjust` 搭配 `source_doc_type='hq_return_batch'`、`reason='退回總倉遺失：...'`。
- 移除本檔 movement_type CHECK 重建。

## 已看但不列為 A 缺陷

- `rpc_dispose_hq_return` 有 `auth.uid()` 必填與 role 白名單，見 `:363-383`。這段方向正確。
- `qty_good > 0` 時要求 `p_goods_confirmed = true`，見 `:413-416`。這段符合「好貨要實物確認」。
- `p_allow_negative=true` 與直接 insert 負 movement 的旁路，A 有放在同一個 stock_movements BEFORE trigger 保護，方向正確；問題在 P0-2 的鎖序/競態，而不是「完全沒 guard」。
- A 文件明列 B/C 尚未包含來源接線、撤回、月鎖；本報告未把這些刻意未做的範圍當缺陷。

## 建議修正順序

1. 先修 P0-1：把 `_hq_hold_return` 變成可信入口。
2. 再修 P0-2：讓負異動 guard 在併發下也看得到待處理量。
3. 接著修 P1-1 / P1-2：權限與冪等。
4. 最後修 P1-3 / P1-4 / P1-5：數字、reserved、movement_type 瘦身。

---

## 2026-09-07 Codex GPT-5.5 阿審正式複審（A 修版，靜態）

範圍：只複審 A 段 `supabase/migrations/20260907010000_hq_return_disposition_core.sql` 與 `docs/return-disposition-core-contract.md`。未審 B/F/E/C 作者包；未連 GitHub / Supabase / 正式資料；未讀 `.env`；未改功能碼；本段尚未在 `return_disposition_test_core_a_fix` 跑 runtime。

### 複審結論

靜態看 A 修版，首審列的 A 自身 P0/P1 已有對應修補；目前未新增 A 自身 P0/P1。這只代表 SQL 邏輯文字審查通過到「可交假庫 runtime 驗」這一步，不是正式功能驗收。

P0：0

P1：0

P2：0

runtime：新假庫 `return_disposition_test_core_a_fix` 已由阿審獨立執行 16 群，16/16 PASS、exit 0。C 的撤回/更正/月鎖不在 A 範圍，不能因 A 通過就視為整包已完成。

A 載入 SHA256：`3B007711260B8D255F9B7574BD38865B25644534BB9F722BB709265C93CC4FC7`

B 載入 SHA256：`3D0FE235F04913DE67088495DAF28A8EED02A2F28F0B5C2E98A1C55EFA681042`

### 已核對的 A 邊界

- 來源防偽已收緊：`_hq_hold_return` 現在要求 `p_source_transfer_item_id` 必填，並檢查 movement tenant / location / sku / qty / source_doc 與 transfer item、父單位置、來源種類一致，見 `supabase/migrations/20260907010000_hq_return_disposition_core.sql:233-384`。其中 `source_doc_line_id` 可為 NULL；有值時才要求等於 item id，見 `:354-360`，符合真收貨既有路徑。
- 真收貨不因父單當下仍是 `shipped` 被 A 擋：A 的 store_return 驗證看 `transfer_type='return_to_hq'`、dest/source location、`in_movement_id`、`qty_received`、movement type，見 `:362-370`，沒有要求父單已改成 received。B 的 operator 取值時序若仍誤標 system，是 B 缺陷，不列 A。
- hold 冪等已改成鎖 balance 後重讀既有 batch，且比對 tenant、location、sku、source item、source_kind、source_reason、total_qty、unit_cost、auto_flag、created_by，見 `:386-415`。同 source movement 不同 payload 不會靜默當重試。
- 權限已補到表與 view：表 RLS 限同 tenant 且 role 為 owner/admin/hq_manager，見 `:164-178`；底表有 `GRANT SELECT`，見 `:180-182`；view 用 `security_invoker` 並 grant 給 authenticated，見 `:858-885`。前端處理 RPC 也要求 `auth.uid()` 與同三個 HQ 角色，見 `:500-508`。
- request_id 冪等已改成同 tenant/request advisory lock，且完整比對 batch、三個數量、兩個原因、goods_confirmed、notes；重播回第一次 event 的原 `new_status`，見 `:572-603`。
- 數字已逐欄拒絕 NULL、NaN、Infinity、負數、超界、超過 3 位小數，見 `:517-545`；hold 量也同樣逐項檢查，見 `:246-257`。
- reserved / pending 一致性已補：dispose 先鎖 balance 再鎖 batch，鎖後重讀本批 pending、同 SKU 全部 pending，並要求 `reserved >= total_pending`，見 `:606-665`。這可擋先前人為破壞 reserved 後仍處理的缺口。
- 破損/遺失 movement 已瘦身回既有類型：破損用 `damage`，遺失用 `manual_adjust` 搭配 `source_doc_type='hq_return_batch'`，見 `:697-722`；A 修版沒有再新增 `hq_return_damage` / `hq_return_loss` 全域 movement type。
- 負異動 guard 已改為先建立/鎖同一筆 balance，再重讀全部 pending，見 `:797-817`；`pending=0` 的放行點已移到鎖後，見 `:819-822`，方向符合首審要求。

### runtime 證據

命令：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_a_fix --case all
```

結果：exit 0，16/16 PASS。

補驗包含：

- 原 13 群：NULL line 正向來源、source_validation 四個單點負例、reserved_corruption、race_same_request、race_hold_negative。
- 新增 3 群：同 UUID 跨 tenant 不干擾、hold 同來源完整 payload 重送、同 SKU 多批 pending 的 reserved/available 總額保護。

本輪 race 留存：

- `race_same_request` tenant：`dbfd3cb1-43ca-4af6-9881-9afe7560322d`
- `race_hold_negative` tenant：`8e57b58e-c946-4a7d-b8ef-94812560ab8c`

連線收尾：`other_open_connections=0`。

### 仍未覆蓋

- C：原單更正 / 撤回 / 月鎖。
- E/F：前端與可派量包。
- 正式資料庫：本輪只跑本機假庫，不代表正式資料已驗收。

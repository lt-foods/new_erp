# 阿審審查報告：總倉退回貨處理 B 來源接線

日期：2026-09-07  
範圍：只審 B 段 `supabase/migrations/20260907020000_hq_return_disposition_sources.sql` 與 `docs/return-disposition-source-contract.md`。  
不審 A 已知退修項，不把 C 尚未接的撤回、原單更正、月鎖完整實作算成 B 自身缺陷；不連 GitHub / Supabase / API；沒有執行正式庫 db push。

## 結論

B 的大方向正確：用 `transfer_items.in_movement_id` 接「退回總倉真入庫」，用 `transfer_items.shortage_restock_movement_id` 接「短少沖回總倉」，欄位名稱也對。

按目前 patch 實際缺陷計：

- B 自身 P0：0
- B 自身 P1：2
- B 自身 P2：1

另外有 2 個「整包交付前置條件」：A helper 必須先修完來源防偽；C 必須接撤回/改實收，不然整包不能放行。這兩項不重複計入 B 自身 P1。

## B 自身 P0

無。

## B 自身 P1

### P1-1：人工退回總倉會被誤標成 system，處理人也會變全零

位置：

- B 讀父單 `received_by`：`supabase/migrations/20260907020000_hq_return_disposition_sources.sql:49-53`
- B 用 `received_by` 判斷 system/manual：`:109-115`
- B 傳給 A helper：`:120-131`
- 最新 `rpc_receive_transfer` 先寫 item `in_movement_id`：`supabase/migrations/20260904020010_accept_store_return_deducts_stock.sql:380-384`
- 最新 `rpc_receive_transfer` 後面才寫父單 `received_by = p_operator`：`:397-400`

實際時序：

1. `rpc_receive_transfer` 對每個 item 先呼叫 `rpc_inbound` 建正向入庫 movement。
2. 同一圈立刻 `UPDATE transfer_items SET in_movement_id = v_in_mov_id`。
3. B 的 AFTER UPDATE trigger 此時被觸發。
4. B 去讀 parent `transfers.received_by`，但父單還沒更新，所以很可能是 NULL。
5. B 把 NULL coalesce 成全零 UUID，再把 `auto_flag` 記成 `system`。
6. 迴圈跑完後，`rpc_receive_transfer` 才 `UPDATE transfers SET received_by = p_operator`。

白話風險：

- 做了現在這版：店員或總倉人員明明手動同意收回，待處理批次卻會寫成「系統自動」，處理人變全零。
- 不修：後面查誰同意、48 小時自動同意、人工責任歸屬會混在一起。這是稽核錯，但尚未證實會造成不可恢復大量資料或全系統破壞，所以列 P1，不升 P0。

最小修法：

- return 路不要讀父單 `received_by` 當 operator。
- 直接從 `stock_movements.operator_id` 取操作者；B 的 `v_mov` SELECT 補 `operator_id`。
- `auto_flag` 用 `v_mov.operator_id = '00000000-0000-0000-0000-000000000000'::uuid` 判 system，其餘 manual。

### P1-2：B 沒核對 movement 的 `source_doc_type/source_doc_id`，來源防偽少一層

位置：

- return movement 查詢只取 id/tenant/location/sku/quantity/type：`supabase/migrations/20260907020000_hq_return_disposition_sources.sql:58-63`
- shortage movement 查詢只取 id/tenant/location/sku/quantity/type：`:148-153`
- 最新 receive 建入庫時 source 是 `transfer / p_transfer_id`：`supabase/migrations/20260904020010_accept_store_return_deducts_stock.sql:368-378`
- 最新 shortage restock/redispatch 建回帳 movement 時 source 是 `transfer / v_item.transfer_id`：`supabase/migrations/20260903000200_shortage_resolution_undo.sql:229-239`、`:271-281`
- 既有 `rpc_adjust_received_transfer` 對 `in_movement_id` 也會核 `movement_type='transfer_in' AND source_doc_type='transfer' AND source_doc_id=p_transfer_id`：`supabase/migrations/20260904010000_adjust_received_syncs_stock.sql:437-449`

目前 B 有核：

- tenant
- sku
- location
- movement_type
- quantity > 0

但沒核：

- `source_doc_type = 'transfer'`
- `source_doc_id = NEW.transfer_id`

白話風險：

- 做了現在這版：如果 `in_movement_id` 或 `shortage_restock_movement_id` 被接到同倉同品項、但不是這張調撥單的 movement，B 仍會建總倉待處理批次。
- 不修：A 即使後續加強 helper，B 這層還是沒有把「這筆異動就是這張原單」說清楚，出錯時比較難定位。

最小修法：

- B 查 `stock_movements` 時補取 `source_doc_type, source_doc_id, operator_id`。
- return / shortage 兩條都加：
  - `v_mov.source_doc_type = 'transfer'`
  - `v_mov.source_doc_id = NEW.transfer_id`

## B 自身 P2

### P2-1：return 原因只取父單 notes，而且是在父單收貨 notes 合併前讀；這可以接受但文件要講清楚

位置：

- B 取 `v_transfer.notes`：`supabase/migrations/20260907020000_hq_return_disposition_sources.sql:49-53`
- B 設 `v_source_reason := LEFT(v_transfer.notes, 200)`：`:117-118`
- 最新 `rpc_receive_transfer` 是最後才把 `p_notes` 合併回父單 notes：`supabase/migrations/20260904020010_accept_store_return_deducts_stock.sql:397-405`

這不擋 B，因為退貨原因通常在建退貨單時已在父單 notes；收貨當下補的 notes 不一定需要當 source_reason。  
但契約若寫成「收貨備註也會進 source_reason」就不成立。

最小修法：

- source contract 補一句：return `source_reason` 只取觸發當下父單既有 notes，不含本次收貨 `p_notes`。

## 整包交付前置條件（不算 B 自身缺陷）

### 前置條件 1：A helper 必須先修完來源防偽，B 才可放行

位置：

- B 呼叫 A helper：`supabase/migrations/20260907020000_hq_return_disposition_sources.sql:120-131`、`:205-216`
- A 前審已指出 `_hq_hold_return` 尚需補 source movement location、qty、transfer_item 關係防偽。

這不是 B 單獨缺陷；但整包交付要明列：B 只有在 A helper 已經防偽完成後，才算安全入口。

### 前置條件 2：C 必須接撤回與原單更正，否則 B 建出的 pending 會留下假量

位置：

- B 觸發條件：`supabase/migrations/20260907020000_hq_return_disposition_sources.sql:45-47`、`:139-140`
- `rpc_adjust_received_transfer` 會把 `in_movement_id` 指到新 movement：`supabase/migrations/20260904010000_adjust_received_syncs_stock.sql:692-696`
- `rpc_unreceive_transfer` 會先寫 reversal，再清 `in_movement_id`：`supabase/migrations/20260903000010_unreceive_reverse_inbound_regardless_of_qty.sql:185-207`
- `rpc_undo_transfer_item_shortage` 會 reversal `shortage_restock_movement_id`，再清短少欄位：`supabase/migrations/20260903000200_shortage_resolution_undo.sql:565-590`、`:636-646`

這不是 B 自身 P1，因為 B 本來只負責「建批」，C 負責「拆批/撤回」。但整包不能漏。

## C 最小接法獨立評估

結論：用 `stock_movements.reverses` hook 比重抄三支大 RPC 小，也比較不容易漏，方向可採；但不能只做一個 stock_movement hook，還要補 transfer_items 清 ID 守門，防止「不寫 reversal、只清欄位」繞過。

### 建議形狀

1. 新增 `_hq_revoke_return(p_source_movement_id, p_operator_id, p_reason)` 或等價 helper。
   - 找 `hq_return_batches.source_movement_id = p_source_movement_id`。
   - 只允許未處理批次撤回：`status='pending'` 且 `qty_good = qty_damaged = qty_lost = 0`。
   - 撤回時扣回 `stock_balances.reserved`、標 `status='revoked'`，並留事件或欄位紀錄。
   - partial / completed 一律 raise，讓外層 RPC 整筆 rollback。

2. 新增 `stock_movements BEFORE INSERT` hook，專門處理 reversal。
   - 條件：`NEW.reverses IS NOT NULL`，且被 reverses 的原 movement 有 hq_return batch。
   - 在負異動 guard 前先呼叫 `_hq_revoke_return`。
   - trigger 名稱要排在 `trg_guard_hq_pending` 前面，否則舊入庫 movement 被 reversal 時，負異動 guard 會先看到 pending 還在而擋掉。

3. 新增 `transfer_items BEFORE UPDATE OF in_movement_id, shortage_restock_movement_id` 守門。
   - 如果 OLD movement 有 hq_return batch，NEW 清成 NULL 或換成別筆 movement，必須確認舊 batch 已撤回，或同交易中已有對 OLD movement 的 reversal。
   - 若沒有，就 raise。這是防「清 ID 不寫 reversal」旁路。

### 為什麼比重抄三支大 RPC 小

- `rpc_unreceive_transfer` 已經先寫 reversal，再清 `in_movement_id`，行號 `supabase/migrations/20260903000010_unreceive_reverse_inbound_regardless_of_qty.sql:185-207`。
- `rpc_undo_transfer_item_shortage` 已經先 reversal `shortage_restock_movement_id`，再清欄位，行號 `supabase/migrations/20260903000200_shortage_resolution_undo.sql:565-590`、`:636-646`。
- `rpc_adjust_received_transfer` 是先立新、再沖舊、最後把 `in_movement_id` 換成新 movement，行號 `supabase/migrations/20260904010000_adjust_received_syncs_stock.sql:591-610`、`:692-696`。

所以 C 可以貼在共同的 movement reversal 與 transfer_items 欄位變更點，不必把三支 RPC 各自重抄一段 hq_return 邏輯。

### 需要注意的邊界

- 月鎖：現有大 RPC 內已有月鎖/狀態守衛；C hook 不應假裝替代月鎖。若有人繞過大 RPC 直接寫 reversal，transfer_items 清 ID 守門仍要擋住狀態不一致。
- 先立新後沖舊：`rpc_adjust_received_transfer` 會先寫新入庫 movement，再 reversal 舊 movement，最後更新 item 指向新 movement。C 應在舊 reversal 時撤舊 batch，讓 B 在 item 換新 id 時建新 batch。
- partial 拒絕：只要舊 batch 已有 good/damaged/lost 任何處理，C 必須 raise，讓外層整筆 rollback，不能自動拆。
- 清 ID 不 reversal 旁路：只靠 stock_movement hook 抓不到「直接把 `in_movement_id` 清 NULL」；所以 transfer_items 欄位守門是必要配套。

### C 必測

- `rpc_unreceive_transfer`：pending return batch 可隨 reversal 撤回；partial batch 會擋，整張取消收貨 rollback。
- `rpc_undo_transfer_item_shortage`：pending shortage batch 可隨 reversal 撤回；partial batch 會擋，撤銷短少 rollback。
- `rpc_adjust_received_transfer`：先立新後沖舊時，舊 batch 被撤，新 movement 經 B 建新 batch；partial 舊 batch 擋下。
- 直接 UPDATE `transfer_items.in_movement_id = NULL` 或清 `shortage_restock_movement_id`、但沒有 reversal：必須被 transfer_items 守門擋。

## 已核實正確 / 不列問題

- 短少欄位名是真的：`shortage_resolution`、`shortage_resolution_at`、`shortage_resolution_by`、`shortage_resolution_notes`、`shortage_restock_movement_id` 都由最新版 `rpc_resolve_transfer_item_shortage` 寫入，見 `supabase/migrations/20260903000200_shortage_resolution_undo.sql:399-405`。
- shortage 的 operator 用 `NEW.shortage_resolution_by` 是合理的，因為 resolve 同一個 UPDATE 會同時寫 `shortage_resolution_by = p_operator` 與 `shortage_restock_movement_id`，見 `supabase/migrations/20260903000200_shortage_resolution_undo.sql:399-405`。
- shortage restock/redispatch 的回帳 movement type 是 `transfer_cancel`，B 檢查 `transfer_cancel` 方向正確，見 `supabase/migrations/20260903000200_shortage_resolution_undo.sql:229-239`、`:271-281`。
- return path 檢查 `transfer_type='return_to_hq'`、movement type `transfer_in`、movement location = dest、dest 是 central_warehouse，方向正確。
- B trigger 是 `SECURITY DEFINER SET search_path = public, pg_temp`，且 revoke PUBLIC/anon/authenticated；作為 trigger 內部函式，不直接開給前端，方向正確。

## 建議修正順序

1. B 先修人工/系統來源：return operator 改取 movement.operator_id。
2. B 再補 source_doc 防偽：兩條來源都核 `source_doc_type/source_doc_id`。
3. source contract 補 return notes 時序與 A 前置條件。
4. C 採 reversal hook + transfer_items 清 ID 守門，不重抄三支大 RPC。

---

## 修版複審（2026-09-07，Codex GPT-5.5 阿審）

結論：B 最新版本輪沒有 P0/P1/P2 阻擋。首審兩個 P1 已補上，P2 文件邊界也已在 contract 說清楚。這只代表 B 來源建批這一段可交下一段整包驗收；不代表 C 撤回／原單更正已完成，也不代表正式系統驗收。

### 本輪範圍

- 檔案：`supabase/migrations/20260907020000_hq_return_disposition_sources.sql`
- 契約：`docs/return-disposition-source-contract.md`
- 對照原始路徑：
  - `rpc_receive_transfer` 最新定義：`supabase/migrations/20260904020010_accept_store_return_deducts_stock.sql:101`，入庫 movement 與 `transfer_items.in_movement_id` 先寫，父單 `received_by` 後寫。
  - `rpc_resolve_transfer_item_shortage` 最新定義：`supabase/migrations/20260903000200_shortage_resolution_undo.sql:111`，少收回總倉與 redispatch 回帳 movement 都用 `source_doc_type='transfer'`、`source_doc_id=transfer_id`。

### P0

- 0。

### P1

- 0。

首審 P1-1 已修：return 路現在從 `stock_movements.operator_id` 取操作者，位置 `supabase/migrations/20260907020000_hq_return_disposition_sources.sql:59`、`:117-124`，不再在 trigger 時讀尚未更新的父單 `received_by`。

首審 P1-2 已修：return 與 shortage 都補核 `source_doc_type='transfer'`、`source_doc_id=NEW.transfer_id`，位置 `:109-113`、`:203-208`。白話講，就是待處理批次只能由「這張原單自己的回帳異動」建立，不能把同品項同倉但別張單的異動接進來。

### P2

- 0。

首審 P2-1 已收斂：contract 已寫明 return 的 `source_reason` 取觸發當下父單既有 notes，不承諾包含收貨當下新輸入的 `p_notes`。實碼位置 `:124`。

### 本機實跑

命令：

```powershell
node tests\return-disposition-review\source-available-runtime.cjs --db-name return_disposition_test_core_a_fix --case b_store_return,b_shortage
```

結果：exit 0。

- `b_store_return` PASS：退貨回總倉只建一批；人工 operator 記 manual；全零 operator 記 system；錯 source_doc 原單會拒絕。
- `b_shortage` PASS：少收 `restock_hq` 回帳只建一批；重複更新不重建；錯 source_doc 原單會拒絕。

### 交付前置條件（不算 B 自身缺陷）

- C 撤回／原單更正仍要接上。B 只負責「來源正確時建批」，不負責「原收貨撤回、改實收、撤銷少收時把舊批撤掉」。
- 整包最後仍要在包含 A/B/C/F 的同一假庫跑 flow 與核心回歸；本段不是正式系統驗收。

# 總倉退回貨 C：原單更正／撤回保護審查

審查時間：2026-09-07

審查身分：Codex GPT-5.5 阿審，獨立審查。

範圍：只審 C 這包「原單更正／撤回保護」：

- `supabase/migrations/20260907030000_hq_return_disposition_reversals.sql`
- `docs/return-disposition-reversal-contract.md`
- 對照真正既有流程：`rpc_adjust_received_transfer`、`rpc_unreceive_transfer`、`rpc_undo_transfer_item_shortage`、店家月結產生／確認流程

禁止事項遵守：未連 GitHub、未連 Supabase、未碰正式資料、未讀 `.env`、未改功能碼、未 commit。

首審讀到的 C 檔案 SHA256：

- C SQL：`09C1B31D48E6C9F97C235EC185D3804EF89A6A5126B640B34A9DF49853EF748D`
- C contract：`19B150CD8740E1A470B83B26F66BCC164BEBABD9FD41A2DE71E537598D11494C`

## 結論

首審 C 不可直接放行：審查有 1 個 P1，集中在「月份鎖」的併發保護說法和真月結流程不一致；這點已用本機假庫補測重現。

其他主線目前靜態看起來方向正確：C 有把真 reversal、操作者、租戶、來源 movement、原 item、未處理批次、reserved 釋放綁在同一個後端守門點；也有擋掉不走 reversal 就清來源 ID、直接改 item 數量、partial 批次撤回、缺 `auth.uid()` 或 operator 冒用。

注意：這份是 C 的需求／程式審查，不是完整系統驗收。阿審已在本機假庫獨立跑 C flow-smoke 與 1 個月結鎖反例；仍未代表正式系統已驗收。

## P0

目前未發現 C 自身 P0。

## P1

### P1-1：C 的「月結 advisory lock」沒有跟真正店家月結產生器共用，帳單尚未存在時仍可能競跑

依據：

- C `_hq_assert_return_month_open` 在 `20260907030000_hq_return_disposition_reversals.sql:46` 建立，`78-80` 拿 `hashtext('settlement:' || tenant || ':' || month)` advisory lock，`82-88` 再鎖 `store_monthly_settlements` row，`90` 開始拒絕 confirmed/settled/remitted。
- C contract 寫「每個月份先取得既有月結 advisory lock」，C SQL 註解也寫「advisory lock 仍與既有月結生成器序列化」。
- 但真正最新店家月結產生器是 `20260901000000_settlement_dispatch_basis.sql:74` 的 `rpc_generate_hq_to_store_settlement`；實查此函式內沒有 `pg_advisory_xact_lock`。同檔 `148-152` 只是在已存在 row 時檢查 locked status，`348-369` upsert draft/sent/disputed。
- 全 migrations 目前同 key `pg_advisory_xact_lock(hashtext('settlement:'...))` 只查到舊 `20260423120001_inventory_v02_demand_aid_settlement.sql:483` 與 C；不是最新店家月結產生器共用的鎖。
- 店家月結確認流程在 `20260715000120_settlement_estatement_flow.sql:542`；確認時會 `WHERE id = p_settlement_id FOR UPDATE`，但這只能鎖已存在的 row，不能保護「C 檢查時 row 還不存在、月結另一邊同時建立」的空窗。

白話風險：

如果某店某月帳單還沒建出來，C 會先拿一把「自己以為大家都會拿」的鎖，看到沒有已鎖帳單就放行；但真正產生店家月結的流程沒有拿這把鎖，可能同時把同一月份帳單生出來、甚至被送出或確認。結果就是退回貨撤回／更正已經改了貨和待處理數，帳單那邊卻可能用舊狀態結算，後面只能人工對帳。

本機反例：

- 新增阿審測試 `tests/return-disposition-review/reversal-runtime.cjs`。
- 命令：`node tests\return-disposition-review\reversal-runtime.cjs --db-name return_disposition_test_full_v1`
- 結果：FAIL，訊息為「月結產生器沒有等待 C 使用的 settlement advisory lock；finished=true result=completed」。
- 意義：連線 A 已先拿住 C 使用的同一個 settlement advisory lock；連線 B 在交易中跑真正 `rpc_generate_hq_to_store_settlement`，測試用 `pg_locks` / `pg_stat_activity` 觀察 B 是否真的在等 advisory lock。如果真共用鎖，B 應先進入 advisory lock wait，等 A 放鎖後才完成；實際 B 直接完成，證明最新月結產生器沒有被這把鎖序列化。
- 測試沒有載入或手刻 generator；`return_disposition_test_full_v1` 內的月結函式、helper、view、schema 是 CEO 建庫時載入的真本機 SQL。阿審本支只呼叫已安裝的 `rpc_generate_hq_to_store_settlement`。若 fresh full_v2 缺少月結函式依賴，這支會報出實際缺物件／缺欄位，而不是假通過。

最小修法：

- 讓真正 `rpc_generate_hq_to_store_settlement` 在處理每個店家月份前，拿與 C 完全相同的 advisory lock key；相關「送出／確認／結清」若會改同一張 `store_monthly_settlements`，也要確認鎖序一致，至少不能在 C 檢查空窗內完成狀態切換。
- 或者 C 改用真正月結流程已經會拿的同一把鎖；但目前實碼沒有看到最新店家月結產生器拿這把鎖，所以不能只改文件。
- 補一個雙連線測試：連線 A 在 C 月份檢查處持鎖未提交，連線 B 同月同店跑月結產生／確認，必須能觀察到等待或被安全拒絕；不能兩邊各做各的。

## P2

目前未列 C 自身 P2。C contract 的「既有月結 advisory lock」文字若 P1 採用修程式解掉，就一起修正；若不修程式，文件必須降級成限制說明，但那不建議當作放行方案。

## 已靜態核對且暫未發現阻擋的點

### 真 reversal 與操作者

- `20260907030000_hq_return_disposition_reversals.sql:123-124` 對正向 movement 直接 return，所以自動同意／正常收貨這類不是 reversal 的路徑不會被 C 誤擋。
- `171-180` 要求 `auth.uid()` 非空、`NEW.operator_id = auth.uid()`，並用 `_current_tenant_id()` 比對 batch tenant。這符合「撤回一定要真人，不能把缺 JWT 當特權」的契約。
- 既有 `rpc_adjust_received_transfer`、`rpc_unreceive_transfer`、`rpc_undo_transfer_item_shortage` 都會建立 `movement_type='reversal'` 且帶 `operator_id=p_operator`；C 在真正碰到總倉退回批次時補上後端核對。

### 來源鏈與 `source_doc_line_id`

- C 對 reversal row 要求 `source_doc_type='transfer'`、`source_doc_id` 等於父單、`source_doc_line_id` 等於 item id、數量／成本／位置／SKU 全部對齊（`184-193`）。
- C 對原正向 movement 的檢查允許 `v_orig.source_doc_line_id IS NULL`，只有原 movement 有 line id 時才要求等於 item id（`197-201`）。這點有對上真收貨來源：真 `rpc_receive_transfer`／shortage restock 可能只在 movement 寫原單 id，反向指標主要在 `transfer_items.in_movement_id` 或 `shortage_restock_movement_id`。
- 既有更正／撤回／短收撤銷三支 reversal，實查都會把 reversal 自己的 `source_doc_line_id` 寫成 item id，所以 C 要求 reversal line id 不會擋住真路徑。

### 未處理批次才能撤回

- C 先鎖 `stock_balances` 再鎖 `hq_return_batches`（`253-268`），與 A 的核心鎖序一致。
- `270-280` 要求 batch 仍是 pending，且 good/damaged/lost/revoked 都是 0、沒有 event。也就是總倉一旦已部分處理，就不允許原單更正悄悄把整批沖掉。
- `282-295` 在釋放 reserved 前檢查同 tenant/location/SKU 全部 pending/partial 的總 reserved 仍足夠，能擋住 reserved 已被其他路徑破壞後繼續扣成負數。
- `326-357` 的 AFTER hook 會在 reversal row 真落表後，把 `revoked_by_movement_id` 補回 batch；失敗會讓同交易 rollback。

### item/header 守門

- `381` 開始的 item guard 會擋刪除、改 item/transfer/SKU 歷史歸屬，且舊 `in_movement_id` 或 `shortage_restock_movement_id` 被清／換前，對應 batch 必須已經由真 reversal 完整撤回。
- `551-554` 是 deferred final-state constraint trigger，交易最後才檢查 item 仍掛來源 movement 時，店退 `qty_received` 或短收 `qty_shipped - qty_received` 必須等於 batch 總量。這適合既有 unreceive 先歸零再撤短收的暫態。
- `563-659` 的 header guard 會擋有 batch 的 return transfer 被刪除、改 tenant/type/location；有 active pending/partial 時不能直接離開 received/closed，也不能清空 `received_at`。
- 真 `rpc_adjust_received_transfer` 實查順序是先寫新入庫、再寫舊 reversal、最後更新 item pointer；C 的 hook 先撤舊 batch，B 再按新 pointer 建新 batch，順序合理。
- 真 `rpc_unreceive_transfer` 實查順序是逐 item 寫 reversal、清 item pointer，最後才把單頭改回 shipped；C 會在 active batch 被撤完後才允許 header 離開 received/closed。
- 真 `rpc_undo_transfer_item_shortage` 實查會先 reversal `shortage_restock_movement_id`，再清短收欄位；C 的 deferred final-state 可避免把同交易合法暫態誤判為錯。

## 待補 runtime 驗證

阿審已獨立完成：

- `node --check tests\return-disposition\flow-smoke.cjs`：exit 0。
- `node tests\return-disposition\flow-smoke.cjs --db-name return_disposition_test_full_v1`：13/13 PASS，全部交易 rollback。
- `node tests\return-disposition\flow-smoke.cjs --db-name return_disposition_test_no_c_baseline`：1/13 PASS、12/13 FAIL；同一支測試能抓到沒有 C 時的舊洞，不是只檢查 trigger 存在。
- `node --check tests\return-disposition-review\reversal-runtime.cjs`：exit 0。
- `node tests\return-disposition-review\reversal-runtime.cjs --db-name return_disposition_test_full_v1`：exit 1，打中 P1 月結鎖未共用。
- 殘留連線查核：`return_disposition_test_full_v1` 的 `returnlocal` 其他連線數為 0。

仍待 C 修版後重跑：

- P1 的月結併發：同店同月 C 月份檢查與月結產生／確認必須共用鎖，不能各自通過。
- C 修版後需重跑 flow-smoke 13 群與 no-C baseline 對照，確認不是為了修月結鎖而破壞正常更正／撤收／短少撤銷。

## 2026-09-07 C P1 修版複審

C 修版 SQL SHA256：`F486AA6A5141973AEBA65F58D1267DF11D6D0FBF12B9A76EC5D2183F6E7D767B`

資料庫：`return_disposition_test_full_v2`

修版重點：

- `_hq_assert_return_month_open` 改用 `pg_try_advisory_xact_lock`（C SQL `:82`），月鎖忙時快速拒絕，不讓舊 RPC 已拿住庫存／單據鎖後再反向等月結鎖。
- 同一支 C migration 後段重建真正 `rpc_generate_hq_to_store_settlement`（C SQL `:685`），在確認 tenant 後、任何算帳前拿同一把 blocking 月結鎖。
- 作者回報剝除新增鎖與 comment 後，generator 真定義 SHA 為 `CA5E84E9E9F037E7A7AF791E3E4A2958B89BD2A0F277EA0797F7D1713C12736D`；本輪阿審沒有重寫 generator，也沒有改財務算法。

阿審獨立實跑：

```powershell
node --check tests\return-disposition-review\reversal-runtime.cjs
node tests\return-disposition-review\reversal-runtime.cjs --db-name return_disposition_test_full_v2
node tests\return-disposition\flow-smoke.cjs --db-name return_disposition_test_full_v2
```

結果：

- `node --check`：exit 0。
- `reversal-runtime`：4/4 PASS。
  - `settlement_generator_shares_c_advisory_lock`：連線 A 拿 C 月結鎖；連線 B 跑真 generator，已用 `pg_locks` / `pg_stat_activity` 看到 B 等 advisory lock；放鎖後真 generator 完成。
  - `settlement_generator_completes_twice`：交易內把假 prices 的 `effective_from` 前移 30 天，真 generator 連跑兩次；第一次有真明細，第二次 draft 重建沒有被舊 immutable trigger 擋住，也沒有重複膨脹。
  - `busy_month_rejects_c_without_side_effects`：另一連線持有同月鎖時，真 `rpc_adjust_received_transfer` 走到 C 後快速業務拒絕，不是拖到 statement timeout；庫存、批次、item 快照不變。
  - `trylock_reentrant_multi_item`：同一交易兩個 SKU 更正，C helper 同 session 重入同月鎖不誤拒；兩個舊 batch revoked、兩個新 batch pending。
- `flow-smoke`：13/13 PASS，全部交易 rollback。

複審結論：

- 首審 P1「C 月結 advisory lock 未與真正店家月結產生器共用」已關閉。
- C 修版目前未發現新 P0/P1/P2。
- C 仍不是整包正式驗收；它不涵蓋 D fixture 完整 ERP、F-UI、正式資料，也不代表已上線。

本輪 C 判定：

- P0：0。
- P1：0。
- P2：0。

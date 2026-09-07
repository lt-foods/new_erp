# 總倉退回貨處理 — 阿審核心 runtime 驗收器報告

日期：2026-09-07

角色：Codex 側 GPT-5.5 阿審（獨立驗收準備 / 初版假庫實測）
限制：只改測試碼與本報告；未改 A/B/E 功能碼；未連 GitHub / Supabase；未讀 `.env`。本輪只在本機假庫 `return_disposition_test_core_initial` 收集初版 A/B 的真結果，不代表 A 修版或 D 最終 fixture 已驗收。

## 測試器

檔案：

- `tests/return-disposition-review/core-runtime.cjs`

安全邊界：

- 固定連 `127.0.0.1:56427`
- 固定 user `returnlocal`
- 不讀 password / `.env`
- DB 名稱不符合 `^return_disposition_test_[A-Za-z0-9_]+$` 直接拒絕
- 預設跑全部 16 組；也可用 `--case` 指定單組或 `--case all`

用法：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_<name> [--case case_name]
```

可列 case：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial --case list
```

目前 case：`dispose_split`、`source_validation`、`source_line_null_positive`、`idempotency`、`idempotency_replay_after_complete`、`idempotency_payload_fields`、`request_id_tenant_scoped`、`hold_full_payload_replay`、`bad_numbers`、`multi_batch_reserved_total`、`reserved_corruption`、`pending_guard`、`role_edges`、`rls_roles`、`race_same_request`、`race_hold_negative`。

## 最小檢查

命令：

```powershell
node --check tests/return-disposition-review/core-runtime.cjs
```

結果：exit 0。這只代表測試器語法可解析，不代表資料庫整合已通過。

## 20:46 後實跑結果（核心初版假庫，保留紅燈歷史）

### 1. 當時全 13 組

命令：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial --case all
```

結果：exit 1。當時 13 組中 4 組 PASS、9 組 FAIL。這是初版 A/B 的紅燈結果，不是修版驗收；本段保留歷史，不用它覆蓋 A 修版結果。

逐組結果：

| 測試組 | 結果 | 真結果 |
|---|---:|---|
| `dispose_split` | PASS | 10 件分次處理成 7 好、2 破、1 失；reserved 歸 0；on_hand 剩 7。 |
| `source_validation` | FAIL | 已修正測試資料：備料時短暫停用已查證的 B trigger `trg_hq_return_source`、把正確 `transfer_items.in_movement_id` 掛好、再恢復 trigger 後才跑斷言。目前實測數量不符、同租戶別總倉地點不符、原單行不符都未擋；品項不符有被擋。 |
| `source_line_null_positive` | PASS | 真收貨 movement 沒有 `source_doc_line_id`、但 `transfer_items.in_movement_id` 指回該 movement 時，由 B trigger 自動建批成功；batch 數量、成本與凍結數都對齊來源。這條是防止 A 修版把真收貨擋死的回歸保護。 |
| `idempotency` | FAIL | 同 request id、同數量但不同 reason/notes 未被拒絕。 |
| `idempotency_replay_after_complete` | FAIL | 第一包 partial、第二包結案後，重送第一包沒有回第一包原本的 partial 結果，實測 `new_status` 變成 `undefined`。 |
| `idempotency_payload_fields` | FAIL | 同 request id 改 notes、damage_reason、loss_reason 仍被接受；改 goods_confirmed 這筆有被既有檢查擋下。 |
| `bad_numbers` | FAIL | `NULL` 三欄、`NaN`、`Infinity` 未報失敗；但 `1.0001` 四位小數被接受，代表初版沒有逐欄拒絕超過 3 位小數。 |
| `reserved_corruption` | FAIL | 交易內人為把 reserved 改成小於同 SKU 全部 pending 後，dispose 仍成功；代表初版沒有在處理前檢查「凍結數不能小於待處理數」。 |
| `pending_guard` | PASS | 既有好貨 20 可派；第 21 件、`p_allow_negative=true`、直接負 movement 都被擋。 |
| `role_edges` | PASS | `hq_accountant`、空 role、缺 `auth.uid()` 都被拒絕。 |
| `rls_roles` | FAIL | HQ 正向讀 `v_hq_return_batches_list` 失敗：`permission denied for view v_hq_return_batches_list`。店家、跨租戶、匿名限制未報失敗。 |
| `race_same_request` | FAIL | 第二個連線等第一個交易完成後，沒有重新吃到同 request 的冪等事件，反而回 `rpc_dispose_hq_return: batch 120 already completed`。不會直接多扣，但會讓安全重試失敗。保留追查 tenant：`7300f39c-1942-4678-89dd-d5f4d1b490f7`。 |
| `race_hold_negative` | FAIL | hold 建立中遇到直接負異動，第二連線沒有被拒絕，錯在「應回錯誤物件」但實際不是 Error。符合先查 pending、後等 balance lock、commit 後未重讀 pending 的競態疑慮。保留追查 tenant：`66a7d81e-5f08-465b-8e3d-500bd8c5dbd9`。 |

另單跑真收貨 NULL line 正向案例：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial --case source_line_null_positive
```

結果：exit 0。這表示測試器已補上「真 `rpc_receive_transfer` / shortage 入庫 movement 可能沒有 line id」的實際路徑；A 修版不得無條件要求 movement.line_id 非 NULL。

### 2. 本輪忠實度修正

本輪重點不是多加功能測，而是修正測試是否真的打到要害：

- `source_line_null_positive` 原本先讓 B trigger 自動建批，再手動呼叫 `_hq_hold_return(... source_reason='review fixture', auto_flag='manual')`。未來若 A 做完整 payload 去重，第二次手動 hold 可能應該被拒；所以已改成只驗 B 自動建出的批次，不再多呼叫一次 hold。
- `source_validation` 原本用 `inboundMovement()` 更新 `transfer_items.in_movement_id`，也會先觸發 B 建批；後面的負例容易撞到「同 source_movement 已存在」早退，沒有忠實測來源防偽。現在改成備料階段短暫停用 `trg_hq_return_source`，把正確 `in_movement_id` 掛好後立刻恢復；assertion 開始時 trigger 已正常，且合法來源 control 先證明全對時可建批，再逐項測錯數量、錯地點、錯品項、錯原單行。

來源證據：

- `supabase/migrations/20260904020010_accept_store_return_deducts_stock.sql:368` 呼叫 `rpc_inbound`，`:376` 只傳 `p_source_doc_id => p_transfer_id`，沒有傳 `source_doc_line_id`；`:380` 才把 `transfer_items.in_movement_id` 指回該 movement。
- `supabase/migrations/20260903000200_shortage_resolution_undo.sql:229`、`:271` 的短少回總倉也呼叫 `rpc_inbound`，`:237`、`:279` 只傳 `p_source_doc_id => v_item.transfer_id`，沒有傳 line id；`:404` 才寫 `shortage_restock_movement_id`。
- `supabase/migrations/20260907020000_hq_return_disposition_sources.sql:242` 掛載的 trigger 名稱是 `trg_hq_return_source`；`:126`、`:210` 是 B trigger 把 `NEW.id` 作為 `p_source_transfer_item_id` 交給 A helper。

另單跑本輪新增 4 組：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial --case idempotency_replay_after_complete,idempotency_payload_fields,reserved_corruption,role_edges
```

結果：exit 1。`role_edges` PASS；另外 3 組 FAIL，與全驗結果一致。

另單跑 `bad_numbers` 的確認命令：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial --case bad_numbers
```

結果：exit 1，實際失敗為：

```text
FAIL bad_numbers: 四位小數拒絕: 四位小數拒絕 應該拒絕，但實際成功
```

連線收尾確認：

```powershell
node -e 'const {Client}=require("pg");(async()=>{const c=new Client({host:"127.0.0.1",port:56427,user:"returnlocal",database:"return_disposition_test_core_initial"});await c.connect();const r=await c.query("select count(*)::int as n from pg_stat_activity where datname=$1 and pid<>pg_backend_pid()",["return_disposition_test_core_initial"]);console.log("other_open_connections="+r.rows[0].n);await c.end();})().catch(e=>{console.error(e.stack||e.message);process.exit(1);})'
```

結果：`other_open_connections=0`，測試器沒有留下開著的連線。

## A 修版實跑結果（新假庫）

DB：`return_disposition_test_core_a_fix`

A 載入 SHA256：`3B007711260B8D255F9B7574BD38865B25644534BB9F722BB709265C93CC4FC7`

B 載入 SHA256：`3D0FE235F04913DE67088495DAF28A8EED02A2F28F0B5C2E98A1C55EFA681042`

阿審獨立實跑：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_a_fix --case all
```

結果：exit 0。16/16 PASS。

新增 3 組補驗：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_a_fix --case request_id_tenant_scoped,hold_full_payload_replay,multi_batch_reserved_total
```

結果：exit 0。3/3 PASS。

新增補驗重點：

- `request_id_tenant_scoped`：同一個 UUID 在不同 tenant 各自可成立，且各自重送只回自己的事件。
- `hold_full_payload_replay`：同來源 movement 重送完整 payload 一致才回既有批次；改 reason / auto_flag / operator 會拒絕且無副作用。
- `multi_batch_reserved_total`：同 SKU 兩批 pending 共 12 時，既有好貨 20 可出；多出到只剩 11 會被 guard 擋。

本輪 race 留存：

- `race_same_request` tenant：`dbfd3cb1-43ca-4af6-9881-9afe7560322d`
- `race_hold_negative` tenant：`8e57b58e-c946-4a7d-b8ef-94812560ab8c`

連線收尾確認：

```powershell
node -e 'const {Client}=require("pg");(async()=>{const c=new Client({host:"127.0.0.1",port:56427,user:"returnlocal",database:"return_disposition_test_core_a_fix"});await c.connect();const r=await c.query("select count(*)::int as n from pg_stat_activity where datname=$1 and pid<>pg_backend_pid()",["return_disposition_test_core_a_fix"]);console.log("other_open_connections="+r.rows[0].n);await c.end();})().catch(e=>{console.error(e.stack||e.message);process.exit(1);})'
```

結果：`other_open_connections=0`。

## 覆蓋重點

這支測試器目前抓以下幾類：

1. `10 = 7 好 + 2 破 + 1 失`，含分次處理。
2. 來源防偽：來源數量、地點、品項、原單行不符必須拒絕。這組現在備料時先掛好合法來源指標，並有合法來源正向 control，避免只測到「未掛來源」或既有 batch 早退。
3. 真收貨相容：movement 的 `source_doc_line_id` 可為 NULL；此時必須靠 `transfer_items.in_movement_id` / `shortage_restock_movement_id` 反向指標、原單、位置、品項、數量來驗，不可把真收貨擋死。
4. 重複提交：同 request 同 payload 要冪等；第一包 partial 後續被重送時要回第一包原結果；同 request 不同 goods_confirmed / reason / notes 要拒絕。
5. 同 UUID 跨 tenant 不互相干擾。
6. hold 同來源完整 payload 重送才冪等；payload 不同要拒絕。
7. 壞數字：`NULL`、`NaN`、`Infinity`、超過 3 位小數不能默默收下。
8. 待確認保護：正常資料下既有好貨可派，但不能派到吃掉待確認量；另外故意破壞 reserved 小於 pending 時，dispose 必須拒絕。
9. 同 SKU 多批 pending 要用總額保護 available。
10. `p_allow_negative=true` 與直接寫負庫存都不能繞過待確認保護。
11. 權限：HQ manager 應能讀；同 tenant 店家、跨 tenant、匿名、`hq_accountant`、空 role、缺 `auth.uid()` 不能讀或處理總倉批次。
12. 兩連線併發：
   - 同 request 同時送，不可多扣或變成 `already completed`。
   - hold 建立中遇到直接負異動，不可因為先查 pending 後鎖 balance 而吃掉待確認量。

## 覆蓋限制

- 初版紅燈歷史只代表 `return_disposition_test_core_initial`；A 修版綠燈代表 `return_disposition_test_core_a_fix` 本機假庫，不代表正式資料庫。
- 一般案例用交易 `ROLLBACK` 清假資料；兩連線 race 因為兩個連線必須互相看得到資料，使用專屬 tenant 造資料並保留 tenant id 供追查，不關 trigger、不硬刪 append-only 表、不自稱已清乾淨。
- 錯誤檢查不是「任意 error 算過」：每個負案例都有指定錯誤訊息關鍵字，並比對狀態快照。
- RLS 讀取不是「看不到就算安全」：測試器先驗 HQ 角色確實讀得到 view，再驗店家/跨租戶/匿名讀不到或被 42501 權限錯擋。
- 併發測試不是只睡一下：測試器會用 `pg_stat_activity` 看到第二連線正在等 Lock，才繼續放行第一個交易。
- RLS/GRANT 使用 `SET LOCAL ROLE authenticated/anon` 與 fixture 的 `request.jwt.*` stub；若 D fixture 改 auth stub 名稱，需同步調整 `setAuth()`。
- 本支不測瀏覽器畫面、不測 C 撤回/更正完整流程、不測月鎖結帳金額；那些要等 B/C/D 全包完成後另跑整合驗收。

## 初版判斷（保留歷史）

P0：3 類

- 來源防偽不足：數量不符、同租戶別總倉地點不符、原單行不符未拒絕。
- reserved 一致性不足：人為破壞 reserved 小於 pending 後仍可 dispose。
- 併發 hold vs 直接負異動未拒絕，可能吃掉待確認量。

P1：3 類

- 冪等 / 安全重試不足：同 request 不同 reason/notes 未拒絕；第一包 partial 後重送沒有回原結果；併發同 request 變 `already completed`。
- 4 位小數未精準拒絕。
- HQ manager 無法讀 view。

P2：0

已通過但仍需修版後重跑確認：分次 7/2/1、真收貨 NULL line 但 item 反向指標正確時可建待處理、正常資料下既有好貨可派且 pending 不可被一般出庫 / allow_negative / 直接負 movement 吃掉、`hq_accountant` / 空 role / 缺 auth.uid 的越權處理被拒絕。

## A 修版目前判斷

P0：0

P1：0

P2：0

A 修版已通過本機假庫 16 群 runtime。仍未覆蓋 C：原單更正 / 撤回 / 月鎖；也未代表 E/F 前端或可派量包已通過。

# 總倉退回貨處理 — 阿審核心 runtime 驗收器報告

日期：2026-09-07

角色：阿審（獨立驗收準備 / 初版假庫實測）
限制：只改測試碼與本報告；未改 A/B/E 功能碼；未連 GitHub / Supabase；未讀 `.env`。本輪只在本機假庫 `return_disposition_test_core_initial` 收集初版 A/B 的真結果，不代表 A 修版或 D 最終 fixture 已驗收。

## 測試器

檔案：

- `tests/return-disposition-review/core-runtime.cjs`

安全邊界：

- 固定連 `127.0.0.1:56427`
- 固定 user `returnlocal`
- 不讀 password / `.env`
- DB 名稱不符合 `^return_disposition_test_[A-Za-z0-9_]+$` 直接拒絕
- 預設跑全部 8 組；也可用 `--case` 指定單組或 `--case all`

用法：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_<name> [--case case_name]
```

可列 case：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial --case list
```

目前 case：`dispose_split`、`source_validation`、`idempotency`、`bad_numbers`、`pending_guard`、`rls_roles`、`race_same_request`、`race_hold_negative`。

## 最小檢查

命令：

```powershell
node --check tests/return-disposition-review/core-runtime.cjs
```

結果：exit 0。這只代表測試器語法可解析，不代表資料庫整合已通過。

## 20:46 後實跑結果（核心初版假庫）

### 1. 全 8 組

命令：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial
```

結果：exit 1。此命令目前等同全驗；也可明確寫 `--case all`。8 組中 2 組 PASS、6 組 FAIL。

逐組結果：

| 測試組 | 結果 | 真結果 |
|---|---:|---|
| `dispose_split` | PASS | 10 件分次處理成 7 好、2 破、1 失；reserved 歸 0；on_hand 剩 7。 |
| `source_validation` | FAIL | 數量不符未擋：同來源已建 10 件後，11 件的不一致 hold 請求仍成功；原單行不符也未擋。地點不符、品項不符有被擋。 |
| `idempotency` | FAIL | 同 request id、同數量但不同 reason/notes 未被拒絕。 |
| `bad_numbers` | FAIL | `NULL` 三欄、`NaN`、`Infinity` 未報失敗；但 `1.0001` 四位小數被接受，代表初版沒有逐欄拒絕超過 3 位小數。 |
| `pending_guard` | PASS | 既有好貨 20 可派；第 21 件、`p_allow_negative=true`、直接負 movement 都被擋。 |
| `rls_roles` | FAIL | HQ 正向讀 `v_hq_return_batches_list` 失敗：`permission denied for view v_hq_return_batches_list`。店家、跨租戶、匿名限制未報失敗。 |
| `race_same_request` | FAIL | 第二個連線等第一個交易完成後，沒有重新吃到同 request 的冪等事件，反而回 `rpc_dispose_hq_return: batch 28 already completed`。不會直接多扣，但會讓安全重試失敗。保留追查 tenant：`0a9fd33b-d5d5-47e9-9d88-2269ff1050b8`。 |
| `race_hold_negative` | FAIL | hold 建立中遇到直接負異動，第二連線沒有被拒絕，錯在「應回錯誤物件」但實際不是 Error。符合先查 pending、後等 balance lock、commit 後未重讀 pending 的競態疑慮。保留追查 tenant：`4288326c-ca13-46c6-9bab-fa43749cf1ae`。 |

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
node -e '...pg_stat_activity...'
```

結果：`other_open_connections=0`，測試器沒有留下開著的連線。

## 覆蓋重點

這支測試器目前抓以下幾類：

1. `10 = 7 好 + 2 破 + 1 失`，含分次處理。
2. 來源防偽：來源數量、地點、品項、原單行不符必須拒絕。
3. 重複提交：同 request 同 payload 要冪等；同 request 不同 reason / notes 要拒絕。
4. 壞數字：`NULL`、`NaN`、`Infinity`、超過 3 位小數不能默默收下。
5. 待確認保護：`reserved >= pending`，既有好貨可派，但不能派到吃掉待確認量。
6. `p_allow_negative=true` 與直接寫負庫存都不能繞過待確認保護。
7. 權限：HQ 應能讀；同 tenant 店家、跨 tenant、匿名不能讀或處理總倉批次。
8. 兩連線併發：
   - 同 request 同時送，不可多扣或變成 `already completed`。
   - hold 建立中遇到直接負異動，不可因為先查 pending 後鎖 balance 而吃掉待確認量。

## 覆蓋限制

- 目前只在 `return_disposition_test_core_initial` 初版假庫跑過；還沒在 D 最終 fixture / A 修版上完整跑完，不能當成「已驗收通過」。
- 一般案例用交易 `ROLLBACK` 清假資料；兩連線 race 因為兩個連線必須互相看得到資料，使用專屬 tenant 造資料並保留 tenant id 供追查，不關 trigger、不硬刪 append-only 表、不自稱已清乾淨。
- 錯誤檢查不是「任意 error 算過」：每個負案例都有指定錯誤訊息關鍵字，並比對狀態快照。
- RLS 讀取不是「看不到就算安全」：測試器先驗 HQ 角色確實讀得到 view，再驗店家/跨租戶/匿名讀不到或被 42501 權限錯擋。
- 併發測試不是只睡一下：測試器會用 `pg_stat_activity` 看到第二連線正在等 Lock，才繼續放行第一個交易。
- RLS/GRANT 使用 `SET LOCAL ROLE authenticated/anon` 與 fixture 的 `request.jwt.*` stub；若 D fixture 改 auth stub 名稱，需同步調整 `setAuth()`。
- 本支不測瀏覽器畫面、不測 C 撤回/更正完整流程、不測月鎖結帳金額；那些要等 B/C/D 全包完成後另跑整合驗收。

## 目前判斷

P0：2（初版假庫已抓到來源防偽不足：數量不符、原單行不符未拒絕；併發 hold vs 直接負異動也未拒絕）

P1：3（冪等/安全重試不足：同 request 不同 reason/notes 未拒絕，且併發同 request 變 already completed；4 位小數未精準拒絕；HQ 角色無法讀 view）
P2：0

已通過但仍需修版後重跑確認：分次 7/2/1、既有好貨可派且 pending 不可被一般出庫/allow_negative/直接負 movement 吃掉。

交付前置條件：等 D fixture 修版與 A 修版載入後，重新執行本測試器；若測試失敗，再依錯誤回報 A/B/C 實際缺口。

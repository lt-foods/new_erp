# 總倉退回貨處理 — 阿審核心 runtime 驗收器報告

日期：2026-09-07  
角色：阿審（獨立驗收準備）  
限制：只新增測試碼與本報告；未改功能碼；未連 GitHub / Supabase；未讀 `.env`；目前 D fixture 修版尚未完成，所以本輪只做「可執行測試準備」，不宣稱測試已綠。

本輪最小檢查：

```powershell
node --check D:\1人公司\_本機工地\new_erp_return_disposition_20260907\tests\return-disposition-review\core-runtime.cjs
```

結果：exit 0。這只代表測試器語法可解析，不代表資料庫整合已通過。

2026-09-07 追加初版假庫反例：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial
```

結果：exit 1，測試器先通過「10 件分 7 好 2 破 1 失、含分次處理」，接著在來源防偽案例停止：

```text
AssertionError [ERR_ASSERTION]: hold qty 大於來源 movement 應該拒絕，但實際成功
```

白話解讀：這證明驗收器不是空測；這次流程是先由 `inboundMovement` 讓 B 依同一筆來源 movement 建出 10 件 batch，再用同來源呼叫 `_hq_hold_return(... p_qty=11)`。初版 A 把這個「同來源、不同數量」的請求當成可接受的冪等回傳，沒有拒絕。這次反例沒有證明真的又多凍結 11 件，但已證明 A 來源防偽/冪等 payload 檢查不足；需等 A 修版後再重跑。

## 本輪新增

- `tests/return-disposition-review/core-runtime.cjs`

用途：在老闆指定的本機 PostgreSQL 測試庫跑 A/B 核心驗收。它只接受：

```powershell
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_<name>
```

安全邊界：

- 固定連 `127.0.0.1:56427`
- 固定 user `returnlocal`
- 不讀 password / `.env`
- DB 名稱不符合 `^return_disposition_test_[A-Za-z0-9_]+$` 直接拒絕
- D fixture 未通知 ready 前，不應執行

## 覆蓋重點

這支測試器準備抓以下幾類錯：

1. `10 = 7 好 + 2 破 + 1 失`，含分次處理。
2. 來源防偽：來源數量、地點、品項、原單行不符必須拒絕。
3. 重複提交：同 request 同 payload 要冪等；同 request 不同 reason / notes 要拒絕。
4. 壞數字：`NULL`、`NaN`、`Infinity`、超過 3 位小數不能默默收下。
5. 待確認保護：`reserved >= pending`，既有好貨可派，但不能派到吃掉待確認量。
6. `p_allow_negative=true` 與直接寫負庫存都不能繞過待確認保護。
7. 權限：同 tenant 店家、跨 tenant、匿名都不能讀或處理總倉批次。
8. 兩連線併發：
   - 同 request 同時送，不可多扣或變成 `already completed`。
   - hold 建立中遇到直接負異動，不可因為先查 pending 後鎖 balance 而吃掉待確認量。

## 覆蓋限制

- 這是 runtime 驗收器；目前只在 `return_disposition_test_core_initial` 初版假庫跑到第一個反例，還沒在 D 最終 fixture / A 修版上完整跑完，不能當成「已驗收通過」。
- 一般案例用交易 `ROLLBACK` 清假資料；兩連線 race 因為兩個連線必須互相看得到資料，使用專屬 tenant 造資料並保留 tenant id 供追查，不關 trigger、不硬刪 append-only 表、不自稱已清乾淨。
- 錯誤檢查不是「任意 error 算過」：每個負案例都有指定錯誤訊息關鍵字，並比對狀態快照。
- RLS 讀取不是「看不到就算安全」：測試器先驗 HQ 角色確實讀得到 view，再驗店家/跨租戶/匿名讀不到或被 42501 權限錯擋。
- 併發測試不是只睡一下：測試器會用 `pg_stat_activity` 看到第二連線正在等 Lock，才繼續放行第一個交易。
- RLS/GRANT 使用 `SET LOCAL ROLE authenticated/anon` 與 fixture 的 `request.jwt.*` stub；若 D fixture 改 auth stub 名稱，需同步調整 `setAuth()`。
- 本支不測瀏覽器畫面、不測 C 撤回/更正完整流程、不測月鎖結帳金額；那些要等 B/C/D 全包完成後另跑整合驗收。

## 目前判斷

P0：1（初版假庫反例已抓到：同來源已建 10 件後，11 件的不一致 hold 請求未被拒絕；這是 A 功能已知問題，不是測試器問題）  
P1：0（測試器語法檢查通過；完整 D fixture / A 修版 ready 後才會有完整功能結果）  
P2：0

交付前置條件：等 D fixture 修版載入真正 schema/RPC 後，執行本測試器；若測試失敗，再依錯誤回報 A/B/C 實際缺口。

## 目前不可執行整合的原因

CEO 目前回報的 D2 狀態是：已載入基底 DDL，但尚無 A/B，且 `_current_tenant_id` 漏載；A 修版、B/F、E、C 都尚未交到可驗收 patch。因此現在若硬跑 `core-runtime.cjs`，會只得到「缺核心函式 / 缺租戶 helper」這類前置環境錯，不是功能驗收結果。

等可以跑時，最低條件是：

- 測試 DB 名稱符合 `return_disposition_test_...`
- D fixture 已載入 `_current_tenant_id`、`auth.uid()`、`auth.jwt()` 的本機 stub
- A 核心已載入 `_hq_hold_return`、`rpc_dispose_hq_return`、`trg_guard_hq_pending`、`v_hq_return_batches_list`
- B 來源接線若要驗自動建批，需載入；本測試器主體仍可用 helper 直接建待處理批次驗 A 核心
- `authenticated` / `anon` 角色存在，且能用 `SET LOCAL ROLE` 真測 RLS/GRANT

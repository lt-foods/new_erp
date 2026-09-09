# 總倉退回貨處理：F 可派量／一般退貨複審

審查者：Codex GPT-5.5 阿審
日期：2026-09-07
範圍：只審 F 最新版 `supabase/migrations/20260907040000_hq_return_disposition_available.sql` 與 `docs/return-disposition-available-contract.md`。不審 C 撤回／原單更正，不碰功能碼，不連 GitHub / Supabase / 正式資料。

結論：F 補貨「只能吃已確認好貨」主線已守住；但一般店家退貨 RPC 仍接受四位小數數量，列 P1，建議退修後再放行整包。

## P0

- 0。

## P1

### P1-1：一般店家退貨仍接受四位小數數量

位置：

- `supabase/migrations/20260907040000_hq_return_disposition_available.sql:88-92`

實碼目前在通用退貨 `rpc_create_store_return` 裡直接做：

```sql
v_qty := (v_line ->> 'qty')::NUMERIC;
```

這和同一支 F 裡補貨建單的寫法不同。補貨建單已先用文字規則擋有限正數與最多 3 位小數，位置 `:359-384`；一般退貨沒有同等檢查。

本機實測：

```powershell
node tests\return-disposition-review\source-available-runtime.cjs --db-name return_disposition_test_bf_review --case f_restock_available,f_restock_inputs,f_old_restock_available_baseline,f_restock_balance_race,f_store_return
```

結果：exit 1。

- `f_store_return` FAIL：`qty='1.0001'` 應拒絕但實際成功。
- 同組測試中 `NaN`、`Infinity` 沒出現在失敗清單，表示本次未觀察到它們被接受；目前紅點是四位小數已確定可送過。

白話風險：

- 做了現在這版：店家退貨數量可以送 `1.0001` 這種系統不該接受的數字，後面進 `numeric(18,3)` 或 transfer line 時可能被四捨五入或用不一致的數量記帳。
- 不修：補貨那邊已經要求「最多 3 位小數」，一般退貨卻比較鬆，之後對帳時會出現「使用者送的數字」和「系統留下的數字」不完全一致。

最小修法：

- `rpc_create_store_return` 也改成和 `rpc_create_wave_from_restock` 一樣，先保留原始文字 `qty_text`。
- 用同等規則拒絕空值、NaN、Infinity、負數、0、超過 3 位小數，再 cast 成 numeric。
- 不要靠 numeric 欄位或後段 insert 自動幫忙修正。

## P2

- 0。

## 已核實正確 / 不列問題

- 一般退貨「少收」已被擋在通用退貨入口，位置 `supabase/migrations/20260907040000_hq_return_disposition_available.sql:45`；本機 `f_store_return` 也驗到「少收」會拒絕。
- 一般退貨的三個合法原因 `破損`、`過期`、`客人退` 仍可建單，且結果 `stock_moved=false`，沒有回到舊版直接搬庫存的行為。
- 補貨需求 view 已把總倉供給改成 `on_hand - reserved`，位置 `:258`，並有 `GRANT SELECT` 給 authenticated，位置 `:304`。
- 補貨建 wave 前會鎖補貨申請與總倉 balance，位置 `:336`、`:409-420`，再用 `on_hand - reserved` 後端守門，位置 `:451-462`。
- 補貨分配已驗 raw qty：有限正數、最多 3 位小數，位置 `:359-384`。
- 建 draft wave 不會先加 reserved；本機 `f_restock_available` 驗證建 10 件 draft 後 `stock_balances.reserved` 不變。

## 本機實跑證據

### B/F 測試器語法

```powershell
node --check tests\return-disposition-review\source-available-runtime.cjs
```

結果：exit 0。

### F 主測群

資料庫：`return_disposition_test_bf_review`，由 `return_disposition_test_flow_base1` 複製，已套本輪 F 與真 `20260612000060` 前置。只是假庫。

```powershell
node tests\return-disposition-review\source-available-runtime.cjs --db-name return_disposition_test_bf_review --case f_restock_available,f_restock_inputs,f_old_restock_available_baseline,f_restock_balance_race,f_store_return
```

結果：exit 1。

- PASS `f_restock_available`：15 帳 / 5 reserved 時 view 只顯示 10 可派；draft 15 被拒；draft 10 不增加 reserved；同申請剩 5 時再配 6 被拒。
- PASS `f_restock_inputs`：補貨 qty 四位小數、NaN、錯 tenant SKU、錯店都拒絕；同 SKU 重複兩行 4+6 會累加成 10。
- PASS `f_old_restock_available_baseline`：同一測試把舊版 `rpc_create_wave_from_restock` 套回去時，15 帳 / 5 reserved 仍會建 draft 15，證明測試抓得到舊錯版。
- PASS `f_restock_balance_race`：一條連線先把同一總倉 SKU reserved 從 0 改成 5 且不提交，另一條同時建 draft 15 會真的等 row lock；第一條提交後，第二條重看可派量並拒絕。
- FAIL `f_store_return`：一般退貨 `qty='1.0001'` 被接受。

### 連線收尾

```powershell
node -e 'const {Client}=require("pg");(async()=>{const c=new Client({host:"127.0.0.1",port:56427,user:"returnlocal",database:"postgres"});await c.connect();const sql="select datname,count(*)::int as n from pg_stat_activity where datname = any($1::text[]) and pid <> pg_backend_pid() group by datname order by datname";const r=await c.query(sql,[["return_disposition_test_core_a_fix","return_disposition_test_bf_review","return_disposition_test_flow_base1"]]);console.log(JSON.stringify(r.rows));await c.end();})().catch(e=>{console.error(e.stack||e.message);process.exit(1);})'
```

結果：`[]`，沒有殘留連線。

## 邊界說明

- F 沒有宣稱重做舊 `rpc_create_wave_from_restock` 的完整角色白名單與 caller tenant 比對；這是舊入口既有邊界，本輪只核它沒有因「可派量」修改而退化。
- C 撤回／原單更正尚未納入本報告；不能把本報告當整包退貨流程驗收。
- 本報告只用本機假資料庫驗證，不是正式系統驗收。

## 2026-09-07 F P1 小修複審

資料庫：`return_disposition_test_full_v1`

F SQL hash（CEO 建庫時回報）：`3349DFFD8F091BFF71617240C4851C3C341E47D07B01F2D49C694B8B1B50DDA2`

阿審獨立實跑：

```powershell
node --check tests\return-disposition-review\source-available-runtime.cjs
node tests\return-disposition-review\source-available-runtime.cjs --db-name return_disposition_test_full_v1 --case f_store_return
```

結果：

- `node --check`：exit 0。
- `f_store_return`：PASS。

複審結論：

- 原 P1「一般店家退貨仍接受四位小數數量」已關閉。
- 同一組測試仍確認：少收不可從一般退貨入口送出；`破損`、`過期`、`客人退` 三個合法原因仍可建單，且沒有直接搬庫存。

本輪 F 判定：

- P0：0。
- P1：0。
- P2：0。

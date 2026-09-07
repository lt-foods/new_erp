# 本機抽驗紀錄：退回總倉處理（2026-09-07）

**這是未驗收的候選程式，禁止據此套用真正系統。** CEO 只統籌、機械套用阿寫差異、抽驗；正式審查由 GPT-5.5 阿審執行。GitHub、Supabase、正式資料與環境密鑰均未連線／讀取／修改。

## 已驗證的範圍

| 項目 | 真正結果 | 不代表什麼 |
|---|---|---|
| 改前完整 TypeScript 檢查 | exit 0 | 不代表功能原本正確 |
| 店家少收前端第二版 | tsc exit 0；獨立靜態測試 exit 0；相同測試用 cf10338c 原錯版 exit 1 | 只完成前端，後端阻擋未完成 |
| 少收檔 lint | 改前／改後同一項既有 set-state-in-effect 錯誤，無新增 | 不是全站 lint 全綠 |
| A 核心 SQL 初版 | parser 34 statements／4 函式通過 | 阿審仍有 2 P0／5 P1，未放行 |
| B 來源 SQL 初版 | parser 7 statements／1 函式通過 | 阿審仍有 2 P1／1 P2，未放行 |
| E 待處理畫面初版 | 完整 tsc exit 0；新增頁 lint 有 2 項 set-state-in-effect 錯誤；阿審訂正版 P0=0／P1=8／P2=4 | 輸入、重送、權限、來源等問題未修，未放行 |
| D 測試載入器第二版 | 新假庫 d2 真載入基底 DDL 44／29／43／21／13／9 statements，seed 成功，exit 0 | `_current_tenant_id` 仍漏載，不是整合驗收通過 |
| 初版 A/B 實際載入假庫 | 真 PostgreSQL 成功套入 core_initial；匿名 auth.uid() 回 NULL | 只是安裝測試，不是業務／安全驗收 |
| 下午 runtime 驗收器，CEO 複跑 | 第1組 10件分次成7好／2破／1失通過；第2組來源數量不一致反例失敗，整支 exit 1 | 初版接受同來源10件卻送11件的請求，尚未通過；當時後面權限／並行等案例未跑到 |
| E 實碼小數輸入抽驗 | 從 TS AST 取實際 clampDecimal 執行：`1.`→`1`，`1e3`→`1`，上限0.75時`1`→`0`，`0.0009`→`0.000` | 會靜默改輸入值，不是合格的小數驗證；阿審已更正初審的可接受判斷，列 P1 |
| E 阿審離線回歸測試，CEO 複跑 | 真實函式 AST 抽取後執行，4 項小數檢查＋3 項 UUID fallback 檢查均失敗，exit 1；測試檔語法 exit 0 | 7 項斷言失敗不是 7 個獨立漏洞；只證明輸入及識別碼問題，尚未驗到完整畫面重送流程 |
| 晚間 core 全 8 群，CEO 複跑 | 2 PASS（分次7/2/1、一般出庫保護）；6 FAIL（來源、重送、小數、HQ讀取、並行同請求、並行凍結／負異動），exit 1 | 實際是未退修 A/B 初版；拆開收集錯誤不等於已修正，不能交付現場 |

完整指令均只在本機執行：

```powershell
node D:\7月營運ERP-new_erp\node_modules\typescript\bin\tsc --noEmit --incremental false --project apps/admin/tsconfig.json
node tests/return-disposition-review/shortage-ui-check.cjs
node tests/return-disposition-review/shortage-ui-check.cjs --baseline
node scripts/check-sql-syntax.cjs supabase/migrations/20260907010000_hq_return_disposition_core.sql supabase/migrations/20260907020000_hq_return_disposition_sources.sql
node tests/return-disposition/fixture.cjs --db-name return_disposition_test_d2
node D:\1人公司\_本機工地\return-disposition-tools\probe-initial-core.cjs
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_core_initial --case all
node tests/return-disposition-review/ui-input-runtime.cjs
```

其中 D1 初版失敗：用 regex 判斷含前置註解的 SQL，必要表全被略過且吞掉 missing-object 錯誤，最後失敗。D2 改 AST 判斷後能載入，但真查 `_current_tenant_id` 仍報不存在；摘要說有載不能當證據。

`probe-initial-core.cjs` 是 CEO 的測試基礎設施：複製 d2 純假庫為 `return_disposition_test_core_initial`，只從本機原檔 AST 機械取出真正 `_current_tenant_id`，再原樣套用 A/B。沒有替阿寫修功能。測試連線固定 `127.0.0.1:56427`、`returnlocal`，無遠端參數／環境變數。

## 仍須阿寫修的問題

- A：來源量／位置／原單防偽、並行凍結與出庫、HQ 讀取權限和授權、重送完整比對、小數精度、reserved 一致性、沿用既有異動類型。以 `return-disposition-core-review.md` 為準。
- B：人工／系統操作者時序、原單 source_doc 核對；說清原因快照不含收貨當下新增備註。以 `return-disposition-source-review.md` 為準。
- E：UUID fallback 非 UUID、輸入小數會被悄悄改值、未知送達時不能換新碼重扣、精確 HQ 角色、shortage 應顯示原收貨門市、原單號、分頁／完整事件、鍵盤與標籤、移除技術詞、新 lint 錯誤。具體退修已派 `writer-front-e-fix.md`，尚未收到有效修版。
- D：漏載租戶 helper、手抄／stub 的覆蓋限制、完整 A/B/C/F 載入；本機實測不可只看 setup exit 0。
- C／F：原單更正／撤回／真退貨月鎖、補貨可派量、後端通用少收阻擋與相關畫面口徑，尚未整包交件。

## 施工來源與中斷原因

Claude 交件原始紀錄在 `D:\1人公司\_本機工地\return-disposition-tools\writer-*-result.jsonl`。部分結果是 `is_error=true`，即使工具同時標 subtype=success，也不能當成功交件。

首輪 A/D 大退修曾超過 16,000 輸出長度，沒有套用任何半截。調高接收上限後 D 修版成功；A 修版、E 修版、B/F、D 小修、C 全部被 Claude 額度上限擋下，工具顯示台北 20:10 恢復。未重試限額、未切換帳號、未取得新額度或付費。沒有把候選初版當成已修清問題。F 前端派工稿已備妥，但沒有實際派出。

本檔記錄已執行證據，不替代主需求單第九節；不得因本機存檔就宣稱本案完成或 WV260831002454 已救回。

下午收尾：本案專用 PostgreSQL 已用已核對的 `return-disposition-tools/pgdata` 路徑正常停止，原啟動會話也已結束；假庫／測試檔保留，沒有刪資料。當時所有 Claude 本案派工程序均已結束。

## 晚間續工的實際阻擋（2026-09-07，20:46 後）

已過先前顯示的額度恢復時間，依老闆「繼續啊」實際重派 A/D，兩筆皆 `is_error=true`，回覆 `Your organization does not have access to Claude. Please login again or contact your administrator.`，沒有可套用修版。原始結果保存在工具資料夾 `writer-core-a-resume-result.jsonl` 與 `writer-fixture-d-resume-result.jsonl`。停止其餘派工，不換帳號／購買額度／重試權限拒絕。

唯讀登入查核顯示 loggedIn=true、claude.ai／firstParty／max，exit 0；只代表本機登入狀態，不能用來否定服務端拒絕。沒有重新登入或讀取憑證。須使用者處理原 Claude 帳號登入／權限後才可恢復阿寫施工，不能再說只是等 20:10。

本案專用假庫曾重新啟動並確認 127.0.0.1:56427 接受本機連線。阿審完成本輪獨立測群與 UI 實碼回歸檢查，CEO 複跑結果相同；功能候選仍是未退修初版，不得將測試新增等同修好。UI 測試存檔 `89aaa0d6`，完整結果見 `return-disposition-ui-runtime-test-report.md` 與 `return-disposition-core-runtime-test-report.md`。

21:00 收尾：CEO 查核心假庫其他連線為 0 後，正常停止專用 PostgreSQL（exit 0），確認 127.0.0.1:56427 無回應。一般案例交易回滾，並行測試用的專屬假資料保留供追查，未刪除任何資料。所有阿審工作與本輪 Claude 程序均已結束；沒有背景施工或自動續跑。阿寫仍須原帳號登入／權限恢復，GitHub／Supabase／真帳禁令不變。

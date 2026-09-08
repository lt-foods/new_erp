# return-disposition-review

阿審獨立驗收檔。載入器正本是 `tests/return-disposition/fixture.cjs`，本資料夾不放功能碼，不另抄業務函式，不連 GitHub／Supabase。

用途：

- `core-runtime.cjs`：核心 16 群，含來源、完整重送、權限與並行；測試資料的延後事件會先驗完才切換來源 trigger。
- `source-available-runtime.cjs`：B 來源與 F 可派量／原始數量／真並行；包含旧可派量反例。
- `reversal-runtime.cjs`：C 與真月結的並行檢查，以最新審查報告記載的實跑項目為準。
- `ui-input-runtime.cjs`／`ui-submit-runtime.cjs`：實際頁面函式與 jsdom 元件離線測試，不使用正式 API。
- `shortage-ui-check.cjs`／`f-ui-copy-runtime.cjs`：少收引導與三個既有畫面口徑，包含舊版對照。
- `../return-disposition/flow-smoke.cjs`：CEO 的真 RPC 流程抽驗（不是正式自審），每例強制驗延後限制後回滾。
- `review_assertions.sql`：保留的早期結構草稿，末段仍按名字猜表，與目前 `hq_return_batches` 命名不合；**不列為現行驗收指令**，不可用它的命名失敗判定新功能錯誤。現行以 runtime 與獨立報告為準。

連線固定為專用本機 PostgreSQL，所有命令都從本機工地根目錄執行。每次 fixture 選新名字，不覆蓋既有假庫。禁止改成正式連線，也不要透過會整理共用依賴的 pnpm exec；直接用既有 Node 執行。

```powershell
node tests/return-disposition/fixture.cjs --db-name return_disposition_test_verify_new --with-all
node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_verify_new --case all
node tests/return-disposition/flow-smoke.cjs --db-name return_disposition_test_verify_new
node tests/return-disposition-review/source-available-runtime.cjs --db-name return_disposition_test_verify_new --case b_store_return,b_shortage,f_restock_available,f_restock_inputs,f_old_restock_available_baseline,f_restock_balance_race,f_store_return
node tests/return-disposition-review/reversal-runtime.cjs --db-name return_disposition_test_verify_new
node tests/return-disposition-review/ui-input-runtime.cjs
node tests/return-disposition-review/ui-submit-runtime.cjs
node tests/return-disposition-review/shortage-ui-check.cjs
node tests/return-disposition-review/f-ui-copy-runtime.cjs
```

這是有界假庫，不是完整 ERP：基底 auth／通知等模擬範圍見載入器 README；A/B/C/F 本身的 SQL、政策與授權原樣載入。完整送單／確認／收款、正式瀏覽器、真正帳務與部署未因此驗收。舊錯版反例的預期失敗不是目前修版失敗，報告必須分開記。

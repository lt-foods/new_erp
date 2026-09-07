# return-disposition-review

阿審獨立驗收準備檔，不屬於阿寫的 `tests/return-disposition/fixture.sql` 或 `test.sql`。

用途：

- `review_assertions.sql`：在阿寫 fixture/test 跑完後，補做結構與防線斷言。
- 本資料夾不放功能碼，不重寫阿寫函式，不連 GitHub/Supabase。

預期本機 PostgreSQL：

```powershell
psql -h 127.0.0.1 -p 56427 -U returnlocal -d return_disposition_review -v ON_ERROR_STOP=1 -f .\tests\return-disposition-review\review_assertions.sql
```

正式審查時，如果這份斷言檔過不了，不代表阿寫一定錯，但代表 fixture 或候選 migration 至少有一個關鍵保護沒有證明到。

# new_erp 專案備忘

## 部署 Supabase migration

**重點**:Claude Code on the web 的 sandbox 環境網路策略會擋住對
Supabase pooler 的 TCP (port 5432 / 6543),所以 `scripts/apply_one_migration.cjs`
跟 `supabase db push` 都會 timeout。

**解法**:改走 Supabase **Management API** (HTTPS),env 已備好
`SUPABASE_ACCESS_TOKEN` + `SUPABASE_PROJECT_REF`:

```bash
node -e '
const fs = require("fs");
const sql = fs.readFileSync(process.argv[1], "utf8");
(async () => {
  const res = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/database/query`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query: sql }),
  });
  console.log("HTTP", res.status);
  console.log((await res.text()).slice(0, 2000));
})();
' supabase/migrations/<MIGRATION_FILE>.sql
```

- 用 `postgres` superuser 跑,DDL / `CREATE OR REPLACE FUNCTION` 都可以
- 成功回 `HTTP 201`,SQL 結果用 JSON 陣列回傳
- 建議部署完用 `pg_get_functiondef()` / `select count(*)` 等查詢 sanity-check

## 部署前先看一下歷史 migration 有沒有相同 function

`CREATE OR REPLACE FUNCTION` 整段重寫時,容易把先前散落在多個 migration
裡的修法蓋掉。範例:`20260624000000_order_item_qty_edit.sql` 重寫
`rpc_create_customer_orders` 把 `20260605000008` 的黑名單檢查 +
`20260605000013` 的 cancelled-skip 過濾條件一起拿掉。

`grep -rln "<function_name>" supabase/migrations/` 看過所有歷史版本,
確認沒有 regress 才提交新版。

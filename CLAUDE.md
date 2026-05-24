# CLAUDE.md

專案層級的給 Claude 的 standing rules，**在這個 repo 裡的每個 Claude session 一進來就會載到 context**。
新規則靠經驗累積、踩雷後寫進來；別寫一般性建議，只寫「不寫進來就會再犯一次」的事。

---

## Supabase / DB

### 部署 migration 走 Management API，不要戳 pooler TCP

直連 pooler 的 5432 / 6543 TCP 在這個環境被擋。要對線上 DB 跑 SQL（包含套 migration）統一走 Supabase Management API：

```
POST https://api.supabase.com/v1/projects/{ref}/database/query
Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}
Content-Type: application/json
{ "query": "<sql>" }
```

不要再嘗試 `psql postgresql://...pooler...`、`supabase db push` 直連、Node `pg` client 等等 — 都會卡在 network，浪費時間。

### 重寫 function 前，先 grep 歷史 migration

`supabase/migrations/` 是 append-only，同一支 function / view 常被多支 migration 用 `CREATE OR REPLACE` 修過。若直接基於「最早建立的版本」改寫，會把後面散落的多個修法整個蓋掉，產生 regression。

改一支 function 之前，**一律先**：

```bash
grep -rn "<function_name>" supabase/migrations/
```

把每一個動過該 function 的 migration 都讀過，基於**時間最新**那個版本擴寫，確保所有 prior fix 都保留。
新 migration 檔頭註解務必列出「以哪個版本為基底」、「rollback 指回哪個版本」。

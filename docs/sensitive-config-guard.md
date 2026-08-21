# 敏感設定守門

這份檢查是為了避免門禁或環境設定混在一般功能 PR 裡上線，尤其是：

- `supabase/config.toml` 新增 `verify_jwt = false`
- Edge Function 新增 `Deno.env.get(...)`、`requireEnv(...)`、`mustEnv(...)`
- 前端新增 `process.env...`
- 新增 `.env.example` 變數
- 修改 `vercel.json`
- GitHub Actions 新增 `secrets`、`vars`、`env` 或 `environment`

檢查不會永遠禁止這些改動。真的需要時，PR 說明要勾選「敏感設定」並寫清楚：

- 為什麼需要
- 做了會影響什麼
- 不做會壞什麼
- 上線後怎麼回退

這樣老闆、審查者、後續工程師都能在合併前看到，不會再事後才發現門口設定被改過。

# Edge Functions

## LINE Login OAuth（會員註冊 / 登入）

- `line-oauth-start` — 前端打這支 → 302 到 LINE authorize URL
- `line-oauth-callback` — LINE 授權完跳回這支 → 換 token、驗 id_token、簽 Supabase JWT、redirect 回 `apps/member`

### 必要 secrets（部署前要設定）

```bash
# LINE Login channel（LINE Developers 後台 > 你的 Login channel）
supabase secrets set LINE_CHANNEL_ID=2009883687
supabase secrets set LINE_CHANNEL_SECRET=<新 rotate 過的 secret>

# Callback URL（要跟 LINE 後台登記的一模一樣）
supabase secrets set LINE_CALLBACK_URL=https://anfyoeviuhmzzrhilwtm.supabase.co/functions/v1/line-oauth-callback

# 自己產的 HMAC secret（防 OAuth state CSRF，隨機 32 bytes）
supabase secrets set LINE_STATE_SECRET=$(openssl rand -hex 32)

# 前端 member app 的 base URL（callback redirect 目標）
supabase secrets set MEMBER_FRONT_BASE_URL=http://localhost:3001

# v1 單 tenant：從 tenants 表取該唯一 tenant_id
supabase secrets set DEFAULT_TENANT_ID=<your tenant uuid>

# Supabase 內建的（通常預設有、確認一下）
# SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_JWT_SECRET
```

### LINE Developers 後台要登記的 Callback URL

```
http://localhost:54321/functions/v1/line-oauth-callback
https://anfyoeviuhmzzrhilwtm.supabase.co/functions/v1/line-oauth-callback
https://anfyoeviuhmzzrhilwtm.functions.supabase.co/line-oauth-callback
```

### 部署

```bash
supabase functions deploy line-oauth-start
supabase functions deploy line-oauth-callback
```

### 本機測試

```bash
supabase functions serve line-oauth-start --env-file supabase/functions/.env.local
supabase functions serve line-oauth-callback --env-file supabase/functions/.env.local
```

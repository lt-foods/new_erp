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

### 部署 Edge Function 走 curl + Management API，不要用 supabase CLI

`supabase functions deploy`（不論加不加 `--use-api`）在這個環境的 outbound proxy 下**一定失敗**，回 `{"code":"UnknownError","message":"failed to deploy function: TransportError"}`。原因是 CLI 的 Go HTTP client 過 proxy 做 streaming multipart POST 會炸（同一支 CLI 的 GET 正常，只有帶 body 的上傳掛掉）。別再花時間試 CLI / 裝 Docker / 調 `SSL_CERT_FILE`，都沒用。

改用 `curl` 直打 Management API deploy 端點（`curl` 過 proxy 正常）：

```bash
REF="$SUPABASE_PROJECT_REF"; f="staff-create"
EP="supabase/functions/$f/index.ts"
META=$(printf '{"entrypoint_path":"%s","name":"%s","verify_jwt":false}' "$EP" "$f")
curl -sS --cacert /root/.ccr/ca-bundle.crt \
  -X POST "https://api.supabase.com/v1/projects/$REF/functions/deploy?slug=$f" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -F "metadata=$META;type=application/json" \
  -F "file=@supabase/functions/$f/index.ts;filename=supabase/functions/$f/index.ts;type=application/typescript" \
  -F "file=@supabase/functions/_shared/cors.ts;filename=supabase/functions/_shared/cors.ts;type=application/typescript"
# 回 HTTP 201 + status:ACTIVE 即成功
```

重點：
- 每個被 import 的 `_shared/*.ts` 都要當一個 `-F file=@...` 附上，且 `filename=` 要保留**原始相對路徑**（`supabase/functions/...`），這樣 entrypoint 裡的 `../_shared/cors.ts` 才解得到。
- `verify_jwt` 要跟 `supabase/config.toml` 裡該函式的設定一致（例：`staff-create` / `trial-signup` / `tenant-purge` 都是 `false`，函式內自己驗 caller）。**config.toml 的 verify_jwt 只有部署時才會套用**，改了 config 沒重部署等於沒改。
- 部署完務必驗證：`OPTIONS` preflight 回 200 帶 CORS、無 auth 的 `POST` 回函式自家的 401（代表函式真的在跑，不是 gateway 404）。gateway 404（`{"code":"NOT_FOUND"}`）在前端會被 supabase-js 包成 `Failed to send a request to the Edge Function` — 這句 = 函式**根本沒部署**，不是程式 bug。
- 列出線上已部署函式：`GET https://api.supabase.com/v1/projects/$REF/functions`。repo 有 `supabase/functions/<x>/` 不代表線上有 — 新函式一定要手動部署。

### Secrets API 回的是雜湊，不是密文本體

`GET /v1/projects/{ref}/secrets` 回傳的 `value` 是 SHA-256 雜湊，**不是真值** —
拿去簽 JWT 會一直 `invalid jwt signature`，別在這裡鬼打牆。
要拿能驗過 `PROJECT_JWT_SECRET` 的密鑰，用 `GET /v1/projects/{ref}/postgrest` 的
`jwt_secret`（= Dashboard 的 Legacy JWT Secret）。`DEFAULT_TENANT_ID` 真值是
`00000000-0000-0000-0000-000000000001`（見 HANDOFF），不要信 secrets API 回的值。

### 重寫 function 前，先 grep 歷史 migration

`supabase/migrations/` 是 append-only，同一支 function / view 常被多支 migration 用 `CREATE OR REPLACE` 修過。若直接基於「最早建立的版本」改寫，會把後面散落的多個修法整個蓋掉，產生 regression。

改一支 function 之前，**一律先**：

```bash
grep -rn "<function_name>" supabase/migrations/
```

把每一個動過該 function 的 migration 都讀過，基於**時間最新**那個版本擴寫，確保所有 prior fix 都保留。
新 migration 檔頭註解務必列出「以哪個版本為基底」、「rollback 指回哪個版本」。

### SQL 裡讀「應用角色」一律走 app_metadata，不要用頂層 role claim

```sql
COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')   -- ✅ 應用角色
auth.jwt() ->> 'role'                                   -- ❌ 永遠是 'authenticated'
```

頂層 `role` 是 **Postgres 角色**，登入使用者一律是 `'authenticated'`。
`custom_access_token_hook` 只把 `tenant_id` 拉到頂層，**role 沒有拉**。
寫錯的症狀是「真正的 owner / admin 也被擋掉」，回 `insufficient_role` —— 看起來
像權限設定壞了，其實是這一行。

這個坑踩過至少兩次（`20260502010000_fix_purchase_rls_role_path.sql` 修 RLS、
`20260807000040_fix_store_line_oa_role_path.sql` 修 RPC）。注意 `_current_tenant_id()`
用頂層 `auth.jwt() ->> 'tenant_id'` 是**對的**（hook 有拉），別一起改掉。

允許清單要對齊 `apps/admin/src/lib/role.ts`：管理員層級是 `('owner','admin','')`，
`''` 是沒有顯式 role 的 legacy/dev admin，漏掉它會把舊帳號全擋在外面。

驗證不用真的登入，直接灌 claims 進去打：

```sql
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"<uuid>","app_metadata":{"tenant_id":"<uuid>","role":"admin"}}', true);
SELECT * FROM <your_rpc>();   -- 換成 store_staff 再跑一次，應該要被擋
```

### security_invoker 的彙總 view，分店讀出來的數字會「安靜地少算」

`ALTER VIEW ... SET (security_invoker = on)` 是對的（不設的話 view owner 是 postgres，
分店會看到別人的資料）。但只要 view 裡面 join / 聚合了 `transfers`、`transfer_items`、
`customer_order_items` 這種**對分店帳號有 RLS 限縮**的表，分店直接 `select` 這支 view
不會被擋 —— 它會照樣回一列，只是 SUM 少算了被 RLS 濾掉的那些 row。
「被擋」看得出來，「少算」看不出來，對帳頁就會出現只有分店看得到的假數字。

規則：**彙總 view 一律不給前端直接讀**，包一支 `SECURITY DEFINER` RPC
（函式內執行時 `current_user` 是 owner，RLS 不套用 → 彙總以完整資料計算），
再由 RPC 自己按 `app_metadata.role` + `_jwt_store_ids()` 決定回哪幾列。
例：`rpc_recall_detail` / `rpc_recall_list`（`20260808000110`）包
`v_recall_line_progress` / `v_recall_summary`。

---

## 顧客訂單 (customer_orders)

### 取消 / 斷貨掉一個品項之後，記得重算訂單單頭

訂單單頭的狀態只有取貨那一刻（`rpc_record_pickup`）會重算。品項在**取貨之後**
才被取消（斷貨連動、待補貨取消…）時，沒有任何東西會再去看單頭一眼，訂單就
永遠卡在 `partially_completed`（部分取貨）結不掉 —— 2026-08 一次收尾了 18 張。

既有的「全品項取消 → 整單 cancelled」規則接不住這種單：它的守衛是
`NOT EXISTS (status NOT IN ('cancelled','expired'))`，而 `picked_up` 也在
「NOT IN」外面，所以有取過貨就不成立。

新增任何會把 `customer_order_items` 改成 `cancelled` 的路徑，一律在後面接：

```sql
PERFORM public._close_orders_all_items_settled(v_order_ids, p_operator, NOW());
```

（`20260808000000`；沒有待取品項 `pending/reserved/ready` + 至少一件 `picked_up`
→ `completed`。active 集合刻意跟 `rpc_record_pickup` 的 `v_active_remaining` 同一套，
「先斷貨後取貨」跟「先取貨後斷貨」才會得到同一個結果。）

### 訂單金額加總一律排除 `cancelled` / `expired` 品項

斷貨用的是 `status='cancelled' + stockout_at`（不另開 status 值，見
`20260702020000`），所以任何 `SUM(qty * unit_price)` 沒濾 status 就會**跟客人收
拿不到的貨的錢**。2026-08 修掉時線上 241 張未結單合計多算 NT$24,630。

四個地方要同時改，漏一個就會出現「排序看到的數字跟格子裡的不一樣」：

- `v_customer_order_summary.items_total`（admin 明細 + LIFF 會員端）
- `rpc_wallet_pay_order.v_items_total`（儲值金可扣上限）
- `v_admin_orders_list`（`/orders` 列表的項數 / 件數 / 總金額，伺服端排序用）
- 前端加總：`OrderDetail.tsx`、`orders/page.tsx`、member `OrderCard.tsx`

`items[]` jsonb **不要**濾 —— 前端要繼續把那一列畫出來（紅標「斷貨」/ 刪除線）。

---

## LINE / LIFF

### 在 LINE 內建瀏覽器裡，絕對不要把使用者導去 `access.line.me`

LINE 官方明講「LIFF browser 內的 LINE Login 授權請求行為不保證」，實際結果是
`access.line.me/oauth2/v2.1/authorize` 直接回一頁 **400 Bad Request**，使用者卡死。
兩個都會踩到：

- `liff.login()`（LIFF browser 內登入是 `liff.init()` 自動跑的，**不可以**自己再呼叫一次）
- 自家的 `line-oauth-start` → 302 到 authorize（給外部瀏覽器 / PWA 用的，不能在 LINE 內用）

在 LINE 內（UA 含 `" Line/"`）要登入 → 一律導去 `https://liff.line.me/{LIFF_ID}?store=...`
讓 LINE 重開 LIFF、走 init 的 auto login。往 LIFF 彈要有 sessionStorage 一次性旗標擋住
LIFF ↔ 網頁互推的迴圈，第二次還沒登入就給文字指引（請用外部瀏覽器開）。

debug 提醒：`line-oauth-start` 用 curl 打回 302 → LINE login page **不代表沒問題** —
這條路在一般瀏覽器本來就會過，400 只在真的 LINE webview 裡才會出現。

### LIFF app 的 Endpoint URL 必須跟會員站同網域，中間不能跨網域轉址

LIFF 登入（`access.line.me/liff/v1/authorize`）會把**當下的網址**當 `redirect_uri` 送出去。
只要那個網址不在 LIFF app 註冊的 Endpoint URL 底下，LINE 就回 **400 Bad Request**。

2026-08-03 實測（同一支 LIFF，只換 `redirect_uri`）：

```
redirect_uri=<LIFF app 註冊的 endpoint>        → HTTP 200（正常登入頁）
redirect_uri=https://new-erp-admin.vercel.app/ → HTTP 400 ← 會員看到的那頁
```

當時的坑：LIFF `2009883687-NZX6xXEW` 的 endpoint 被指到一個 Cloudflare Worker
（`line-richmenu-branches.www161616.workers.dev`），那支 worker 又 302 到
`new-erp-admin.vercel.app/orders`。**一跨出網域，LIFF context 就沒了**
（`isInClient()` 變 false、沒有 auto login、LINE 還會跳「此為外部網站」），
接下來任何登入動作都是 400。

所以：要在 LIFF 內轉址，一律轉去 **`https://liff.line.me/{另一支 endpoint 正確的 LIFF_ID}`**，
不要直接 302 到別的網域。查一支 LIFF 的 endpoint：

```bash
curl -s https://liff.line.me/<LIFF_ID> | grep liffEndpointUrl
```

驗 redirect_uri 會不會被擋（不用真的手機）：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -L \
  "https://access.line.me/liff/v1/authorize?app_id=<LIFF_ID>&state=x&response_type=code\
&code_challenge_method=S256&code_challenge=<43字元>&liff_sdk_version=2.29.2&redirect_uri=<URL編碼>"
```

---

## 會員前端（apps/member）

### 要「用 LINE 登入」的新頁面，一律用 useLineLogin，不要自己重寫

登入這條路上的每一個分支都是踩雷換來的（LIFF browser 不能自己 `liff.login()`、
PWA 不能走 LIFF、LINE 內建瀏覽器要改走 OAuth、pair code 會被 liff.state 沖掉…），
全部收在 `apps/member/src/lib/useLineLogin.ts` + `lib/lineAuth.ts`。

複製一份到新頁面 = 下次修 bug 只會修到其中一份，而這種 bug 只在會員手機上重現得出來。
新頁面要登入就：

```tsx
const { status, error, storeId, chooseStore, stores, start, ... } = useLineLogin();
```

畫面自己畫，登入邏輯不要碰。目前使用者：`/`（首頁登入）、`/join`（社群推廣註冊頁）。

順帶一提：**註冊不需要任何表單**。`liff-session` 查不到 binding 又拿到 store 時
會直接 auto-register，所以「用 LINE 登入」＝「用 LINE 註冊」，一顆按鈕就結束
（`/register` 那頁是綁手機號碼用的另一條路，不是註冊的必經之路）。

### 使用者會卡住的分支，一律留 log

會員端的錯誤只發生在對方手機上，我們看不到 console；靠截圖來回問要花掉整個下午。
所以前端只要走到「使用者會卡住 / 功能默默降級」的分支，一律呼叫
`logClientError()` 或 `logCaught()`（`apps/member/src/lib/clientLog.ts`）。

- 寫兩份：DB `client_error_logs`（`liff-api` 的 `log_client_error` action，**免 token**，
  因為最需要記的就是「還沒登入就壞掉」）+ 本機 ring buffer（會員開 `/debug` 可當場給客服）。
- 已在 layout 掛 `ErrorLogger` 攔 `window.onerror` / `unhandledrejection`，
  但**未捕捉的例外不等於有記到**：被 `try/catch` 吞掉的分支要自己補呼叫。
- 不要在 catch 裡只寫 `console.warn` 就算了 — 那等於沒記。

查最近的錯誤：

```sql
SELECT created_at, source, message, detail, env
  FROM client_error_logs ORDER BY id DESC LIMIT 50;
```

保留期自己顧：`SELECT purge_client_error_logs(30);`

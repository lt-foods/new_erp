# CLAUDE.md

專案層級的給 Claude 的 standing rules，**在這個 repo 裡的每個 Claude session 一進來就會載到 context**。
新規則靠經驗累積、踩雷後寫進來；別寫一般性建議，只寫「不寫進來就會再犯一次」的事。

---

## 回覆風格（Alex 2026-08-18 交代）

**精簡。** 講結論、講要他做什麼，其他不要講。

- 不要寫推導過程、不要列證據表格、不要解釋為什麼選這個做法 —— 他要的是結果。
- 不要寫「已知殘留」「連帶影響」「設計取捨」那種段落給他看。那些寫進
  migration 檔頭或 CLAUDE.md 就好，聊天視窗不要出現。
- 技術細節（函式名、SQL、欄位）除非他問，否則不要貼。
- 目標長度：三五行。要他動手的事列成短清單。

**改完自己開 PR，base 一律選 main。** 不要只 push 分支然後叫他去開 —— 他不會去開。
改動內容跟現有分支／已合併的東西不一樣時，就開一支新的 PR，不要往舊的上面疊。

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

### 套上正式庫的 SQL，對應 migration 當天就要合併進 main

凡直接套上正式庫的 SQL（Management API 或 SQL Editor），對應的 migration 檔必須**當天真的進到 main**。沒進 main 的期間 repo ≠ 正式庫，後續開發都會基於錯誤認知往下做：讀 repo 的人以為線上還是舊行為，前端與配套改動也跟著停在半套。

**「PR 顯示 Merged」不等於「進了 main」——要看那個 PR 的 base 是不是 main。** 前例：`20260805000230`（現貨配單：配給客人＝待取，取貨時才扣庫存）8/06 套上線，同批的 PR #629 base 選成 feature 分支本身而不是 main；而該分支帶回 main 的 PR（#627）在 12 分鐘前就已經合併，之後沒有第二個 PR 再帶它回去 → 那支 migration 和同 PR 的前端改動從來沒進過 main，GitHub 上卻是綠色的 Merged。結果 repo 與正式庫脫鉤一週，前端仍是舊的「直售＝立刻結案」語意、取貨頁放行的另一半沒上線，期間 7 張配單訂單卡在取貨頁按不動。

自檢（唯一算數的）：對線上跑完 SQL 後，`git log origin/main -- supabase/migrations/<檔名>` 查得到那支才算收工。

### 反方向也會脫鉤：進了 main 不等於套上線上

上一條的鏡像。8/18 效能批次兩支（`20260818000020` RLS initplan wrap、
`20260818000030` wave join 改等值）merge 進 main 後**從來沒套上正式庫**，
而且檔頭都寫著「已實測 N 倍」——那是作者在 transaction 裡對拍後 ROLLBACK 的數字，
不代表套用過。結果全站每列重複解析 JWT、撿貨需求 view 帶著 1,700 萬次字串比對
跑了 9 天，8/24 功能改版一疊上去就把 Micro(1GB) 壓到 OOM 當機（8/27 全站進不去，
兩次），才在事故調查時發現。8/27 已補套。

- migration 檔頭的「實測」「已驗證」字樣**不是**已部署的證據。唯一算數的是
  對線上問：view 用 `pg_get_viewdef()` 找特徵字串、function 比 `pg_get_functiondef()`、
  policy 查 `pg_policies`。
- 懷疑「repo 有、線上沒有」時，優先檢查同一批次裡**純效能／純重構**的那幾支 ——
  功能支沒套使用者會叫，效能支沒套只會慢，沒人發現。

### 昂貴函式當 WHERE 條件時，IN (子查詢) 前濾等於沒濾

`rpc_receive_transfer` 邏輯 C 想用「訂單含本批 SKU」把 236 張 shipping 單濾成 4 張
再跑 `is_order_item_pickup_ready`（~8ms/張），寫成同一句
`AND co.id IN (SELECT ...) AND public.is_order_pickup_ready(co.id)` 實測**完全沒變快**
（2.4s）：planner 把函式下推到 customer_orders 掃描層、先於 semi-join 執行，
全店掃描照跑函式。MATERIALIZED CTE 也擋不住 —— 函式仍是掃描層 filter。

正解是**兩步走**（20260827000000）：先 `SELECT ARRAY_AGG(...) INTO v_candidates`
收斂母體，第二句才 `WHERE co.id = ANY (v_candidates) AND 昂貴函式(...)`。
跨語句 planner 沒有重排空間。實測 2,046ms → 89ms。
量函式內部哪段慢：pg_temp 函式 + temp table 插樁 + 整包 ROLLBACK
（Management API 對「最後一句是 ROLLBACK」的 payload 會回倒數第二句的結果集，
可以安全地在正式庫上做執行→量時→回滾）。

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

**別信文件裡寫的基底版本，每次都重 grep。** 2026-08-16 的 PLAN 文件把
`_advance_arrived_confirmed_orders` 的基底寫成 `20260811000020`，實際上它被改過
4 次、最新是 `20260813020000`（中間那兩次還是效能修正：per-SKU LATERAL 改成一次
GROUP BY，文山 1,704 張單 × ~5ms ≈ 8.5s 撞 PostgREST 8s timeout）。照文件寫的版本
改下去，等於把 timeout 修正整個蓋掉。

### 開新 migration 前先看有沒有撞號

檔名的時間戳是手選的，很容易跟**同一天別人正在做的**那支撞在一起。
2026-08-16 就撞過：`20260816000040_reenable_free_transfer`（#737）與
`20260816000040_wording_align_spot_sale_error` 同號。兩支動的函式不同、
也都已套上線，實務上沒炸，但「從零重跑」時的順序只能由檔名字串決定，
而且 `git log -- <檔名>` 這類追溯會抓到兩支。

編號前一律先看一眼現況（含同事剛推的）：

```bash
git fetch origin main -q && git ls-tree --name-only origin/main supabase/migrations/ | tail -5
ls supabase/migrations/ | tail -5
```

真的撞到而且**還沒進 main**：直接改號。**已經進 main 又已套上線**（本次情形）：
改名是安全的 —— `supabase_migrations.schema_migrations` 只記錄走 CLI 套過的版本，
而這個 repo 一律走 Management API 直接跑 SQL、**根本不會寫那張表**
（2026-08-16 實測：追蹤表停在 `20260812021000`／248 筆，repo 已有 514 支）。
改名記得把其他 migration 檔頭引用它當「基底版本」的地方一起改，否則追溯線會斷。

### 套 SQL 前先用 pg-query-emscripten 離線驗語法

`scripts/check-sql-syntax.cjs`（用 repo 既有的 `pg-query-emscripten`）不連 DB 就能
擋掉語法錯 —— 免得 Management API 套到一半失敗、`CREATE OR REPLACE` 留下壞掉的函式。

```bash
node scripts/check-sql-syntax.cjs supabase/migrations/<檔名>.sql
```

它會跑 `parse`（外層 SQL）**和 `parsePlpgsql`（函式內文）**。只跑前者等於沒驗到，
因為 PL/pgSQL 的 body 對 parser 來說只是一個字串常數，而 migration 的程式碼大半在那裡面。

⚠ 每個檔案要開新的 wasm instance：同一個 instance 連續 `parsePlpgsql` 多份檔案會在
模組內部爆掉（`Ma[...] is not a function`），那是 emscripten 的狀態問題、不是 SQL 有錯。

### 吃陣列的批次函式，不要包一層 per-row LATERAL

`_sku_commitment(store, sku_ids[])`（20260816000000）刻意設計成「傳一整個 SKU
陣列、單趟 GROUP BY 算完」—— 就是為了不要重蹈 `_advance_arrived_confirmed_orders`
的 8.5s timeout。但 20260816000020 把它寫成：

```sql
LEFT JOIN LATERAL public._sku_commitment(st.store_id, ARRAY[req.s_id]) c ON TRUE  -- ❌ 每列掃一遍
```

一頁 50 列 = 把該店訂單掃 50 遍。文山店（1,704 張單）實測 **3.8 秒**，
逼近 PostgREST 8 秒上限；拿去掃全站直接 `statement timeout`（>120s）。
改成先依店分組、**一間店只呼叫一次**（20260816000030）後：**60ms，63 倍**。

```sql
CROSS JOIN LATERAL public._sku_commitment(
  st.store_id, ARRAY(SELECT r.s_id FROM req r WHERE r.loc_id = st.location_id)) k  -- ✅
```

看到 `ARRAY[單一變數]` 傳進一支收陣列的函式，就是這個坑。

### 「收斂前後對拍」的驗證查詢，兩側母體必須完全一樣

把散落的算法收斂成 canonical 函式之後，一定要對全站跑一次「新舊逐筆比對」。
但**比對查詢本身很容易寫歪，然後你會去修一個不存在的 bug**。

2026-08-16 收斂 `_sku_commitment` 時：新側寫 `FROM stores st WHERE st.is_active`，
舊側直接 `GROUP BY co.pickup_store_id` 沒濾 —— 而**已停用的 5 家分店身上還掛著
1,327 組 (店,SKU) 的未取品項**，於是回了 1,117 筆假 mismatch。函式其實完全正確。

診斷的第一步永遠是先分類，不要直接看數值：

```sql
CASE WHEN 新側 IS NULL THEN 'only_in_legacy'    -- ← 母體不一致，多半是這個
     WHEN 舊側 IS NULL THEN 'only_in_new'
     ELSE 'both_but_diff' END                    -- ← 真的算錯才會落在這裡
```

全部落在 `only_in_*` 就是母體問題，不是算法問題。
既有的驗證 SQL：`scripts/verify-sku-commitment-equivalence.sql`。

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

---

## 顧客訂單 (customer_orders)

### `payment_status` 全站永遠是 `'unpaid'`，不可以拿來判斷「收到錢了沒」

現金在門市取貨當下收，`rpc_record_pickup` **不回寫** `payment_status`；
唯一會寫 `'paid'` 的 `rpc_wallet_pay_order` 線上 0 筆使用。所以：

```sql
SELECT payment_status, count(*) FROM customer_orders GROUP BY 1;
--  unpaid | 65297        ← 全部，一筆 paid 都沒有
```

`WHERE payment_status = 'unpaid'` 等於**沒有 WHERE**。2026-08 的災情：會員中心
「未結單金額」就是這樣寫的，把每位會員開站至今所有取過貨的訂單一路累加 ——
一位團友畫面顯示 $3,072、實際沒領的只有 $1,110，全站多算 NT$482 萬。

要表達「還沒收的錢」，一律用**品項有沒有被取走**：

```sql
SUM(qty * unit_price) FILTER (WHERE status NOT IN ('cancelled','expired','picked_up'))
```

view 已經備好 `v_customer_order_summary.outstanding_amount`（`20260810000000`），
直接用它，不要自己重寫。兩個附帶條件：

- 一定要**品項層級**算。訂單層級（`status <> 'completed'`）會把 `partially_completed`
  已經取走的那半也算進去。
- `transferred_out`（轉手給別人）的品項**留在原單且維持 `pending`**，貨已經在新單上
  → 這個 status 必須整張歸零，否則跟新單重複計算。同理，任何「抓未取貨」的
  查詢都要記得排除它（`20260507000001` 已經為此掃過一輪 view / RPC）。

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

### 取消轉入單只還單頭，「部分轉出」被扣掉的來源品項不會自己長回來

兩條轉單路徑對**來源品項**的處理完全不同，而 `rpc_cancel_aid_order` 只認得其中一條：

| 路徑 | 來源品項 | 來源單頭 |
|---|---|---|
| `rpc_transfer_order_to_store`（整單轉出） | **原封不動** | `transferred_out` |
| `rpc_transfer_order_partial`（部分轉出、**互助認領走這支**） | 等量→整列 `cancelled`、部分→`qty` 遞減 | 只有全轉光才 `transferred_out` |

取消時的復原段（20260713000000 起）只有 `UPDATE customer_orders`，一行都沒動
`customer_order_items` —— 對整單轉出剛好正確，對部分轉出就是**貨在來源單上憑空消失**。
2026-08-18 GRP-20260730-001-TF0002（三峽←南平，經總倉互助）就是這樣，取消後那 1 件
兩張單都沒有。而 `rpc_restore_cancelled_order`（20260818000000）守衛 3 又直接把
「取消時貨已經還給來源單」當事實、擋掉轉入單的復原 → 兩邊都救不回來。

已修：`_restore_transfer_source_items`（20260818000030），在單頭退回**之前**呼叫。
分辨兩條路徑的判準是「來源單 `status='transferred_out'` 且該 (campaign_item, sku)
還有 active 列 → 整單轉出，跳過」；其餘照轉出時的動作反向還原（加回 qty / 復活
cancelled 列 / 補列），並把轉入單的品項標 `cancelled`，避免兩張單掛同一批貨。
來源單 notes 蓋回補標記 → 重跑不會加倍。

**互助板的認領量 20260824080000 起會自動還**：`rpc_cancel_aid_order` /
`rpc_return_aid_order` 逐 link 把該趟數量還給 `mutual_aid_board`
（`_restore_aid_board_qty`，上限夾 `qty_available`，`exhausted` 未過期 → 回
`active`）。認貼文靠 `customer_order_transfer_links.aid_board_id` /
`customer_orders.aid_board_id`（20260824060000）——**兩邊都沒蓋章的舊單取消
還是不會還**，那種要人工加回去。新增任何取消／退回互助單的路徑，記得一樣
接 `_restore_aid_board_qty`，而且要在品項被標 `cancelled` **之前**算量。

### 搬品項的 SQL 一律只挑 active（`pending`/`reserved`/`ready`）

`customer_order_items` 的 `cancelled` 列**不會被刪掉**，永遠留在原單上。所以任何
「把品項搬到另一張單」的 SQL 只要沒濾 status，就會把死掉的列複製成新單的
`pending` —— 憑空生出貨。2026-08-10 忠順店：一張內部補貨單分四次轉給四位客人，
前三次「部分轉出」把來源列標成 `cancelled`，第四次前端偵測「全選全量」自動改走
整單轉出 `rpc_transfer_order_to_store`，而它的 `INSERT ... SELECT` 只有
`WHERE coi.order_id = p_order_id` —— 第四位客人的單上就多出前三位客人的商品。
這個 bug 從 20260507000000 引入整單轉出起就在，掃出 4 起，其中 3 起的幽靈品項
**已經被取貨**（等於店裡多發了一件貨出去）。

- 複製 / 挑選來源品項一律加 `AND status IN ('pending','reserved','ready')`，
  不要寫 `!= 'cancelled'`（漏掉 `picked_up`：貨已交付還能再轉一次）。
- 這個 active 集合跟 `rpc_record_pickup` 的 `v_active_remaining`、
  `_close_orders_all_items_settled` 是同一套，別自己另外定義。
- 已修：`20260810010000_transfer_copy_active_items_only.sql`（含「沒有可轉品項就
  拒絕整單轉出」守衛，直接打 RPC 也不能生出空殼轉入單）。

順帶：轉單只動訂單，**庫存只在取貨那一刻扣**（`stock_movements.movement_type='sale'`，
`source_doc_type='customer_order'`）。所以「幽靈品項轉回內部號」不會讓庫存變多，
把那張單作廢就結束了；只有**已取貨**的幽靈品項才真的動到庫存，要人工盤點處理。

### 取貨閘門放行 ≠ 單頭 status 會動，兩套要分開想

`is_order_item_pickup_ready()` 是**能不能交貨**的閘門，`customer_orders.status`
是**畫面/通知**的依據，兩者由完全不同的程式推動，很容易各走各的：

- 閘門的 Path C（該團該店沒有對齊波次 → 退用「本店該 SKU 有實收」）是 **qty-blind** 的，
  只問有沒有收過、不問收了幾件。
- 單頭要靠 `rpc_mark_orders_shipping_for_wave`（confirmed → shipping，**要求
  `pwi.campaign_id = co.campaign_id`**）+ `rpc_receive_transfer` 邏輯 C（shipping → ready）。

2026-08-11 忠順回報的「有加單卻沒自動配單」就是這個裂縫：總倉把
`GRP-20260717-022` 用**補貨申請**發到 14 間店，補貨波次的
`picking_wave_items.campaign_id` 是 `NULL` → 沒人推 shipping → 收貨端也接不到，
105 張單全卡 `confirmed`；但閘門走 Path C 早就回 true。結果是貨在店裡、
`/pickup` 前端卻只讓 ready/partially_completed/shipping 的單勾品項，店員發不出去，
只剩「從 RR- 內部單轉單給客人」一條路 —— 而**轉單會開一張新單、原團購單永遠留在
confirmed**，變成重複單（線上已抓到 5 位客人中獎，其中 3 位貨都領走了）。
全站同狀態的有 22 個團、265 張單。

所以：

- **新增任何把貨送到店的路徑，收貨端一定要接上 confirmed 單的推進**，
  不要只處理 `status='shipping'`。已修：`20260811000020` 的
  `_advance_arrived_confirmed_orders(store, sku_ids, operator, at)`，
  `rpc_receive_transfer` 邏輯 C 尾巴呼叫它。
- **拿閘門當「到貨通知」的觸發條件時一定要自己加數量守衛**。閘門的 Path A~D'
  本身不管數量，無條件放行會出現「補 2 包、團購欠 8 包 → 8 位團友都收到到貨通知
  卻撲空」。（2026-08-14 / 08-18 之後閘門末端自己帶了兩道數量守衛，見下一節；
  但 Path A / D / D' 仍然豁免，所以這條規矩沒有失效。）
  可配量的算法：`stock_balances.on_hand − 已承諾未取量`，其中「已承諾」要
  **排除 `members.member_type = 'store_internal'` 的單**（RR- /【內部】xx 店是
  現貨池容器，不是對客人的承諾；不排除的話可配量會被歸零，整支等於沒作用）。
  配法比照既有的「依訂單時間自動配」：`ORDER BY created_at, order_no`，
  整單裝得下才推，裝不下跳過繼續試後面的小單。
- 不要順手改成寫 `backorder_at`：那一欄是「少發配貨沒配到」的語意，寫下去
  `is_order_item_pickup_ready` 會回 false，反而多一道要人工解除的關卡。
  維持 `confirmed` 就好，下一批貨收進來時會自然重算。

### 取貨閘門有兩道數量守衛：一道記帳、一道記實體，缺一不可

`is_order_item_pickup_ready` 的 Path B / C 本身是 qty-blind 的，量靠後面兩道守衛擋：

| 守衛 | 母體 | 擋得住 | 擋不住 |
|---|---|---|---|
| campaign-local（20260814060000） | 該團開團後的 hq_to_store 實收 − 該團已取 | 總倉短收（同團同批派 2 收 1） | 貨被別團／別通路領走 |
| 實體庫存（20260818000010） | `stock_balances.on_hand` − 排在前面的已承諾未取 | 貨到了但被領走 | 同團同批短收（別團的貨會讓 on_hand 看起來夠） |

**兩道是 AND，不要以為其中一道就夠。** 2026-08-18 松山災情就是只有前者的後果：
`_pickup_group_supplied` **完全沒有依 campaign 切分**（唯一跟團有關的條件是
`received_at >= 開團時間`，那是下界不是歸屬），所以鮭魚腹條這種每週重開的品，
一批 10 件會被 3 個團各自當成「自己的 10 件」；而扣減只認**同一個 campaign_id**
的 `picked_up`，於是別團客人領走完全不扣。加上 sentinel 團（`__INTERNAL_RESTOCK__`）
底下的 RR- / OV- / **SP- 現貨直配** / AB- 互助載體，以及它們轉單給客人後的單
（`rpc_transfer_order_*` 直接沿用來源單的 `campaign_id`），全部掛在 sentinel 上
→ 這些管道把貨賣光也一件都扣不到真團的帳。結果：`on_hand = 0`，取貨頁照樣
「✅ 已到貨・1 項可取」，店員原話「我庫存檢底的都給完客人了，但是它還可以取貨」。

寫任何「這批貨還能不能發」的判斷時：

- **記帳側的供給不等於實體庫存。** 要問實體一律用
  `on_hand − _sku_commitment`（20260816000000，全站唯一承諾算法），
  不要自己拿 `transfer_items.qty_received` 加總當庫存 —— 那本帳漏掉橫向轉出
  （空中轉 / 互助認領，兩者都 `p_allow_negative => TRUE`）、退貨、盤虧、撤銷補庫存，
  而且會把補貨、互助 Leg-2、拒收回流（都複用 `hq_to_store`）算成團購供給。
- **母體只算「已承諾」（`ready`/`partially_completed`/`shipping`），不要把
  `confirmed`/`pending` 算進去。** 那些是還在等貨的需求；算進來會讓「舊的等貨單」
  擋掉「新的已到貨單」——貨在架上卻發不出去，而長期卡 confirmed 的單線上一直有。
- **排序讓前面的人先拿**（`(created_at, order_no, item_id)`，全站同一套）。
  `on_hand = 5` 有 8 個人在等時，最早的 5 位照常可取，只擋多出來的 3 位，
  不要整組一起關掉。
- `rpc_record_pickup` 寫 `sale` movement **沒有任何庫存檢查**（不走 `rpc_outbound`），
  所以閘門是唯一的防線；閘門放行 = 直接把 `on_hand` 扣成負的。

**兩道守衛的豁免範圍不一樣，這是刻意的：**

- campaign-local：Path A / D / D' 全豁免（維持 20260814060000 的行為）。現貨配單的貨
  本來就不是總倉發的，記帳側算不到它，硬要它過這道會把正常現貨配單整批擋死。
- 實體庫存：**只**豁免容器單（`store_internal`）、offset 單本身、沒綁倉別的店。
  Path A / D / D' **不**豁免。

理由：Path A / D / D' 答的是「這批貨算不算到過店」（到貨問題），實體守衛問的是
「現在還在不在架上」（當下問題）。一張一個月前的減抵單不能證明貨今天還在。

**「帳面不足但貨在架上」的正解是到庫存總覽補庫存（＋新增庫存 / 盤點），不是開減抵單。**
`rpc_create_inventory_deduction` 自己就強制 `on_hand - reserved >= qty`，錯誤訊息寫著
「請先到『庫存總覽』對該商品新增庫存，再開減抵單」—— 帳早就被要求先補正了，
所以拿 DN 豁免 on_hand 檢查等於讓同一批貨無限次交付。

### 查「為什麼這張還可以取貨」時，先看 Path D，不要先看 supplied / available

2026-08-18 松山那件事我第一次診斷判錯：看到 `_pickup_group_supplied` 沒有依 campaign
切分（跨團共用同一批實收），就認定是跨團重複計算。實際跑線上資料才發現該組
`supplied = 0`、`available = -4` —— campaign-local 守衛**本來就擋得住**，真正放行的是
**Path D 的無條件豁免**（3 張 qty=1 的 DN，`reason='加單頁現貨配單'`）。

所以順序是：先問「有沒有 DN / offset 單」，再問數量。一支診斷查詢就夠：

```sql
SELECT public.is_order_item_pickup_ready(coi.id) AS gate,
       public._pickup_group_supplied (co.tenant_id, co.campaign_id, co.pickup_store_id, coi.sku_id) AS supplied,
       public._pickup_group_available(co.tenant_id, co.campaign_id, co.pickup_store_id, coi.sku_id) AS available,
       sb.on_hand,
       EXISTS (SELECT 1 FROM inventory_deduction_notes n
                WHERE n.campaign_id=co.campaign_id AND n.store_id=co.pickup_store_id
                  AND n.sku_id=coi.sku_id AND n.cancelled_at IS NULL) AS path_d
  FROM ...
```

`gate=true` 但 `available` 是負的 → 一定是某條豁免在作用，不是算術問題。

另外：**評估影響範圍時母體不要只抓 `ready`/`shipping`**。松山那兩張的單頭是
`confirmed`，第一版評估因此回報「只有 22 筆、而且全部豁免」，看起來像沒事 ——
實際涵蓋 confirmed / pending 之後是 78 筆 / 110 件 / 71 張單 / 10 家店。
取貨頁的 `ACTIVE_STATUSES` 是 `pending, confirmed, reserved, ready, partially_ready,
partially_completed, shipping`，評估閘門影響時要照這一套。

閘門很貴（~5ms/次），母體上萬筆一定 timeout。先用視窗函數算累計、
再用「這家店收過這個 SKU 沒有」預篩，最後只對倖存者跑閘門
（同 20260813020000 的教訓：planner 不會照你的子句順序跑，要 `MATERIALIZED`）。

### 把貨配給客人之後，【內部】xx 店的現貨池要跟著扣

RR- /【內部】xx 店的單**就是店端的現貨池帳本**，不是純顯示用的 —— 轉單給客人時
`rpc_transfer_order_partial` 會從它身上扣（等量 → 整行 `cancelled`、部分 → `qty` 遞減）。
所以任何「把店內的貨配掉」的新路徑都必須一起扣池子，否則店員看到的可轉出量是假的：
2026-08-11 忠順進 10 包、自動配單配掉 8 包給團購客人，池子還掛著 ×10 ——
真的全部轉出去就是 8 位團友撲空 + 庫存扣成負的。

扣的量要用**兩層上限**夾住（`_trim_internal_pool`，20260811000030）：

```
trim = LEAST(本次配出量, GREATEST(池子未取量 − (on_hand − 已承諾未取), 0))
```

- `GREATEST(..., 0)`：貨是走該團自己的波次進來的時候 `on_hand` 同時蓋得住池子和
  團購單 → trim = 0，不會誤吃店家本來就有的現貨。
- `LEAST(本次配出量, ...)`：只收拾自己造成的超額，不要順手做全域收斂。

扣法比照 `_settle_restock_ride_along`：整行吃掉 → `cancelled`，只吃一部分 → **拆行**
（被配走的另開一列 `cancelled`，折扣按數量比例分攤），一律標 `[已配給團購單]`。
不要直接改 `qty` 了事 —— cancelled 列前端會畫刪除線，店家才看得到「那 8 包去哪了」。
收尾一樣要接 `_close_orders_all_items_settled`。

實際扣行的動作在 `_consume_internal_pool`（20260824060000 從 `_trim_internal_pool`
抽出來共用，標記字串由參數帶）。新的「把池子的貨配掉」路徑一律呼叫它，不要再抄
一份拆行邏輯。

### 「可分配」一定要含已到貨的內部現貨池，否則店家補了帳還是配不出去

`_sku_free_qty`（＝ on_hand − promised − waiting − **pool_claimed**）當現貨直配的
上限，實務上等於把功能關掉：線上四間店 672 組有庫存的 (店,SKU) 裡，**在庫多於
待客取**的 127 組有 100 組配不出去，其中 82 組的擋路者就是池子（平鎮 607 件、
松山 105 件），而池子裡真正在途的只有 32 件 —— 擋住的幾乎全是**已經在架上**的貨。
店員的體感是：庫存總覽寫著有貨、按「配給客人」說可配 0、提示叫他去「新增庫存」、
補完帳還是 0（2026-08-24 回報原話：「調整庫存完不能把庫存再轉出去」；
平鎮店 8/21 08:10 新增 +4、08:38 自己撤銷，就是這樣放棄的）。

所以配單類的上限一律用 `_sku_free_qty_with_pool`
（＝ on_hand − promised − waiting − **在途**池子量），並且**配掉的當下就要扣池子**
（`rpc_create_spot_sale` 尾端呼叫 `_consume_internal_pool`，標 `[已配給客人 SP-x-xxxx]`）：
池子 −N、對客人的承諾 +N，承諾總量不變，取貨閘門的實體庫存守衛才不會擋到後面的客人。

- **在途的池子量不放**（`pool_claimed − pool_arrived`）：RR- 單在補貨到店之前就存在，
  拿架上的貨去沖它就是 20260811000040 修過的錯。
- `_grow_internal_pool` **維持用 `_sku_free_qty`** —— 它是「還有幾件沒有主人」，
  拿含池子的量去長池子會自己餵自己。
- 列表欄位（`rpc_get_stock_commitment_bulk.free_with_pool`）、篩選
  （`rpc_list_allocatable_pairs`）、彈窗上限三邊一定要同一套算法。
  之前「列表寫可用 3、配單視窗寫自由量 0」就是各算各的。

### 「這批貨到店了沒」要看單頭 status，不要用 is_order_item_pickup_ready 當判準

閘門是 **qty-blind** 的（Path C 只問「本店有沒有收過這個 SKU」），所以同一個 SKU
只要到過一次，**後面還沒出貨的批次也會一起回 true**。拿它當「到貨了沒」的判準，
盤點類的查詢會把在途的貨算成已到。

2026-08-11 用它盤「現貨池超額掛帳」時就被騙了兩次：

| 判準 | 算出來的壞帳 | 實際 |
|---|---|---|
| `pool_qty > on_hand − 已承諾`（沒濾到貨） | 395 組 / 2,804 件 | 幾乎全是**還沒到貨**的 RR- 單 |
| 上式 + `is_order_item_pickup_ready` | 79 組 / 221 件 | 仍混入沒出貨的批次 |
| 上式 + `co.status IN ('ready','partially_completed')` | **26 組 / 68 件** | ✅ 真的壞帳 |

RR- ride-along 單在補貨到店**之前**就存在（單頭 `pending`/`confirmed`），
要 restock 收貨後才被 `_settle_restock_ride_along` 推 `ready`。所以對容器單來說
**單頭 status 才是可靠的到貨訊號**，`_trim_internal_pool` 也只吃 ready/部分取貨的池子
（20260811000040）。

連帶注意呼叫順序：`rpc_receive_transfer` 裡自動配單那段（邏輯 E）**必須排在
邏輯 D/D2 之後** —— ride-along 單要先被推 ready，池子收斂才吃得到它，
否則整支會靜默失效（掛在邏輯 C 尾巴時就是這樣）。

### `backorder_at` 是「人工標、人工解」的旗標，加新路徑要自己接解除

少發配貨（`rpc_allocate_shortage`）配不到的品項會標 `backorder_at`，而
`is_order_item_pickup_ready` 內含 `backorder_at IS NULL` → 取貨閘門直接關掉。
問題是這一欄**在 20260811000050 之前完全沒有自動解除的路徑**：全 DB 只有
`rpc_allocate_shortage` / `rpc_create_inventory_deduction` / `rpc_create_offset_sale` /
`rpc_cancel_backorder_items` 會清掉它，四支都要人手動點。`rpc_receive_transfer`
連碰都沒碰，`_advance_arrived_confirmed_orders` 還因為閘門回 false 而**主動跳過**
這種單 —— 所以總倉補派第二批、店家也收了貨，品項照樣掛著待補貨，單頭永遠停在
`partially_completed`（松山 GRP-20260730-016-0008 就這樣卡了 6 天）。

已修：`_settle_arrived_backorders`（`rpc_receive_transfer` 邏輯 A0）。要點：

- **A0 必須排在邏輯 A/B/C/E 之前**。C 的 `is_order_pickup_ready()` 與 E 的
  `_advance_arrived_confirmed_orders` 都要 `backorder_at IS NULL` 才推得動單頭，
  順序反了這批單要等下一次收貨才會動。
- 可配量要**兩套算法取小**：
  `LEAST(supplied + covered − picked − 已配到未取, on_hand − 已承諾未取)`。
  前者對齊 `rpc_get_allocation_candidates`（自動解除才會跟店員手動點
  「⚖️ 配貨」一致），後者對齊 `_advance_arrived_confirmed_orders`。
  **只信前者會誤放行** —— 線上實測 5 列是「supplied 4、picked 0、on_hand 0」，
  貨早從別的路徑出去了，照帳放行就是通知客人來撲空。
- 算「已承諾未取」時要**排除掛著 `backorder_at` 的列**，否則它們自己擋自己，
  整支永遠解不開任何一列。
- 只清旗標、**永不新標**（新標是少發配貨的職責）。

### 收貨頁的「短少」：單批派出量不能拿去比全期需求

`rpc_get_ship_vs_demand_for_transfers` 原本拿**這一張 transfer** 的派出量，比
**該團該店該 SKU 的全期需求**（含已領走的）。同一組分兩批到貨時，第一批早就收
進來的量在算式裡完全不存在 → 第二批補 1 瓶會標「短少 10」。線上 349 個
(團,店,SKU) 已經是多批到貨，283 張標短少的 transfer 有 178 張（1,002 件）是假的。

供給側一律補上 `prior`（同組**其他**已收 transfer 的 `qty_received`，條件比照
`rpc_get_allocation_candidates` 的 supplied）。`over` 刻意維持單批語意，不加
`prior` —— 加了會讓 438 張歷史單突然亮「多給」，那是另一個題目。

連帶：那個 `short` 是收貨頁「⚖️ 配貨」按鈕的顯示條件（`short > 0 || covered > 0`），
而少發配貨是唯一能人工解除 `backorder_at` 的入口。**修掉假短少會順手拿掉入口**，
所以 RPC 另外回一個 `backorder`（這組還掛著幾件待補貨），讓還有人在等的組別一定
看得到入口。改這支的顯示條件時記得三個一起看。

### 把某個角色的動作按鈕拿掉之前，先確認狀態機還有別人推得動

「這一頁不該由總倉操作」是對的判斷，但把按鈕拿掉**不等於**別人就長出入口。
狀態機卡在中間沒有任何 UI 的話，畫面上不會報錯，只會安靜地不動。

前例（空中轉，2026-08）：`rpc_ship_aid_order`（confirmed → shipping，建 AT- 轉移單
＋轉出店出庫）全站唯一入口是 `AidOrderStatusActions`，只掛在 `/hq/inbox`；
而 `/hq/inbox` 在 `BRANCH_HIDDEN_HREFS` 裡、分店根本看不到。後來 air 被拆成獨立
分頁並做成「唯讀、不出任何動作按鈕」（理由沒錯：空中轉不經總倉）→ **全站沒有任何人
能派貨**。線上 5 張單卡在 `confirmed`、`transfers` 一張沒建，最久的卡了 12 天；
進度條還照實寫著「（空中轉、暫無系統紀錄）」沒人當回事。

所以動 UI 權限時：

- 先 `grep -rn "<rpc_name>" apps/` 數一數入口有幾個。**只有一個**就不能只是拿掉，
  要先把它搬到新的正主看得到的地方。
- 正主＝**實際做那件事的人**。空中轉出貨是轉出店（貨從他們手上出去），
  所以按鈕放在轉出店自己那張來源訂單上（`OrderDetail` 反查
  `transferred_from_order_id = 本單 AND is_air_transfer AND status='confirmed'`）。
  **反查、不要用 `transferred_to_order_id`** —— 部分轉出不寫那一欄。
- 對面那一側（接收店）要看得到「在等誰」，不然他們只看到「已確認」三個字，
  只能改走轉單，就變重複單。
- 拿掉入口的同時留一份後備給 HQ；卡住時才有人救得了。

驗這種洞不用等使用者回報，直接問 DB：
「某狀態的單有多少張、對應的下游單據建了沒」——
`SELECT status, count(*), sum((SELECT count(*) FROM transfers t WHERE t.customer_order_id = co.id)) ...`
數字是 0 就是沒人按得到。

### 空中轉沒有「派貨」這一步 —— 轉單當下就建 AT- 單並出貨

前一節那個洞的收尾（2026-08-14）：空中轉的正解不是「把派貨鈕搬給對的人」，
而是**根本不要有那一步**。勾了空中轉＝貨當下就從轉出店出去，
所以 `rpc_transfer_order_to_store` / `rpc_transfer_order_partial` 自己呼叫
`_air_ship_order_items`（20260814030000）建 AT- 轉移單（`store_to_store` /
`shipped` / `is_air_transfer=TRUE` / `customer_order_id=轉入單`）＋轉出店出庫，
轉入單直接進 `shipping`。接收店在 `/wms/inbound` 收掉就 → `ready`（`rpc_receive_transfer`
邏輯 B），月結的 `air_in` / `air_out` 早就實作好（20260512000012），
它只需要那張 transfer 存在且被收貨 —— 不用另外寫加減。

三個踩過的點：

- **出庫要 `p_allow_negative => TRUE`**。轉出店的 `on_hand` 常低於實際
  （同 SKU 被別張單取走、到貨沒入帳），擋下來整筆轉單就失敗、單子永遠卡在收件匣
  —— 2026-08-01 湖口→龍潭那兩張就是這樣停在「已確認」13 天，按派貨一律
  `Insufficient stock`。貨實際上離開轉出店了，記下這筆出庫比拒絕記錄準確；
  負庫存在庫存頁看得到，交給盤點。順手帶 `p_fallback_unit_cost =>
  _current_cost_price(...)`，否則 `avg_cost` 缺值時月結會算 0 元。
- **只出「本次搬進去的」品項**。部分轉出可能分次追加到同一張轉入單，
  每次各有自己的 AT- 單；整張單重出就是重複出貨。所以 helper 收
  `p_item_ids BIGINT[]`（整單版用 `WITH ins AS (INSERT ... RETURNING id)` 收集，
  部分版在迴圈裡 `array_append`）。
- **同店（換客人 / 併入的既有單就在轉出店）不建單**，helper 以
  `source location = dest location` 判掉回 NULL —— `transfers` 有
  `CHECK (source_location <> dest_location)`，硬塞會炸。

`rpc_ship_aid_order` 留著當後備（自動出貨上線前卡住的舊單要有人推得動，
在來源訂單頁「✈ 補出貨」），空中轉分支改成委派同一個 helper，
並加了「已有轉移單就擋下」避免重複出貨。

### 經總倉的互助：Leg-1 身上沒有訂單，別拿單段 transfer 當「這箱貨要去哪」的依據

`rpc_ship_aid_order`（20260510000004）對經總倉的互助拆兩段：
Leg-1 來源店 → 總倉（`customer_order_id = NULL`、`next_transfer_id` = Leg-2）、
Leg-2 總倉 → 收貨店（`customer_order_id` = 轉入單）。所以**只看單一 transfer 的
`customer_order_id` / `dest_location`，Leg-1 會回「沒有訂單、目的地是總倉」** ——
拿它產生的單據給總倉，紙上永遠看不出這箱貨最後要轉去哪一家店（2026-08-15 店家回報
「互助沒有列印、貨會掉」就是這個）。而且派貨之前根本還沒有 transfer，來源店裝箱時
無單可印。

- 要表達「這批互助貨的去向」一律**從 `customer_orders` 出發**（來源店 =
  `transferred_from_order_id` 那張單的 `pickup_store_id`，收貨店 = 本單的
  `pickup_store_id`），不要從單段 transfer 反推。互助出貨單 `/transfers/print-aid`
  就是這樣做的。
- 真的只有 transfer id 可用時（例：內部調撥列表的列印鈕），
  `customer_order_id IS NULL` 就往 `next_transfer_id` 追一段再拿訂單。
- 空中轉（`is_air_transfer`）只有一段、直送收貨店，沒有這個問題。

### 經總倉的轉入單一開始是 `pending`，不是 `confirmed` —— 轉出店的畫面別漏掉這一段

`rpc_transfer_order_to_store` / `rpc_transfer_order_partial` 建轉入單時的 status：
同店 mirror 原單、**跨店空中轉 `confirmed`**（尾端 helper 立刻推 shipping）、
**跨店經總倉 `pending`**（維持總倉確認 gate）。而 `pending → confirmed` 的語意是
「總倉收到貨了」（`AidOrderStatusActions` + 訂單進度條的「總倉收到」），
也就是**箱子已經離開分店之後**才會發生。

所以「轉出店還要為這批貨做事」的狀態集合是 `pending / confirmed / shipping`
（`apps/admin/src/lib/aidTransfer.ts` 的 `AID_IN_FLIGHT_STATUSES`），
漏掉 `pending` = 貨還在店裡、最需要印隨貨單的那一整段畫面上什麼都沒有。
2026-08-18 南平→三峽就是這樣：儀表板的互助出貨提醒只撈 `confirmed/shipping`，
店家原話「三峽可以看見，南平自己看不到轉給三峽的資料，找不到轉貨單可印」。

連帶兩個一定要一起做的：

- **轉入單掛在收貨店名下，轉出店的訂單列表一列都撈不到。** 來源單上要自己把
  「轉出記錄」寫出來（`OrderDetail` 反查 `transferred_from_order_id = 本單`，
  **不要用 `transferred_to_order_id`** —— 部分轉出不寫那一欄），
  否則貨從店裡出去 = 系統上查無此事。
- **連到 `/orders` 的連結一定要帶 `&storeId=<收貨店>`。** 門市篩選對分店帳號會
  預設帶回自家店（`useDefaultStoreFromUser`，只在 storeId 為空時套），
  不帶就是搜出 0 筆，看起來像貨憑空消失。

⚠ 已知還沒補的洞：**「追加轉入（併入既有單）」那條分支不寫 `transferred_from_order_id`**
（兩支 RPC 的 `v_appended` 分支都只加一行 notes）。同一團第二次轉到同一家店的
同一個收件人時就會走到它 —— 反查撈不到，上面兩個畫面又會一起變成「查無此事」，
而且既有單身上那一欄還指著更早的來源單、數量也是整張單的 aid 品項總和（會重複算）。
真的要修得靠一張 order↔order 的連結表（一張轉入單可能有多個來源），不是補寫一欄就好。

### 自由轉貨（rpc_create_free_transfer）：停用過一次，2026-08-16 又打開

時間軸：8/14 停用（`/wms/transfers` 的「+ 建自由轉貨」與 `/transfers/free`
表單移除、`authenticated` 的 EXECUTE 收回，20260814050000）→ 8/16 重新開放
（20260816000040 把 GRANT 還回去、兩個前端入口接回）。既有單的檢視 / 收貨 /
刪草稿 / 改估價從頭到尾都沒動過。

要點：**功能開關要兩層一起動**。只拿掉按鈕、EXECUTE 還通 = 沒停；只接回按鈕、
EXECUTE 還被 REVOKE 著 = 使用者按下去拿到 `permission denied for function`
（前端唯一呼叫點 `FreeTransferCreateForm` 走 authenticated 的 anon key，
函式本體那層角色守衛擋不到這個）。

分工（自由轉貨開著也一樣）：自由轉貨＝商品檔裡沒有的東西（器具 / 樣品 / 零碼，
掛虛擬 SKU + 估價）、只給店↔店（表單濾掉總倉）；有掛顧客訂單的貨走「訂單轉給別人
+ 勾空中轉」；店裡缺貨要總倉派走補貨申請。收貨短少彈窗的「補出貨」CTA 因此留在
`/restock/new`（短少多半是總倉再補一次，而自由轉貨選不到總倉），別再改回
`/transfers/free`。

### 沒有撿貨波次≠沒有單據：`rpc_get_transfer_source_kinds` 的 `air`

收貨頁的來源類型原本只看波次，沒有波次行就回 `'free'` →
畫面標「↔ 轉貨・沒有可對應的單據」而且數量不給點。但空中轉／互助的 AT- 單
**有**掛訂單（`transfers.customer_order_id`），`rpc_get_orders_for_transfer` 的
`from_aid` 分支查得到是哪一張、哪位客人。20260814040000 因此加了
`customer_order_id IS NOT NULL → 'air'`；前端凡是 `srcKind !== 'free'` 的地方
（點數量看訂單）自動對它生效。新增這類「無波次但有單據」的調撥時記得回來看這支。

---

## 互助交流板 (mutual_aid_board)

### 「認領」的本體是訂單轉移；載體單只能存在於那一個交易裡

跨店認領＝`rpc_transfer_order_partial` 把釋出店那張單的品項轉成認領店的單，
貨才會走既有那一套（空中轉／經總倉、收貨頁、月結一加一扣）。所以**沒有訂單就
認領不了**：2026-08-16 線上 29 則進行中的釋出貼文有 27 則是「➕ 手動新增現貨」
（`source_customer_order_id IS NULL`），前端直接不畫認領鈕，店家只看到
「不開放跨店認領」——「怎麼看不到認領的按鈕」就是這個。

補法（`20260816000000`）是認領當下才在釋出店建一張 `AB-<store>-<seq>` 載體單
（restock sentinel trio、單頭 ready），**同一個交易內**立刻轉走。

- **不要改成發文時就建載體單**。載體單掛在 `member_type='store_internal'` 上，
  只要以 ready 停在庫裡就會進 `_trim_internal_pool`（20260811000030/40）的池子
  口徑；手動現貨常常是店家自己的貨、不在 `on_hand` 裡 → 下一次自動配單就把它
  當超額掛帳砍掉（標 `[已配給團購單]`），貼文的貨會莫名其妙消失。
- 手動現貨開放認領之後，`rpc_update_aid_board_listing` 原本「手動現貨沒有認領
  扣量、`qty_available`/`qty_remaining` 一起覆寫」的假設就不成立了 ——
  改總量要保留已認領量（`remaining = 新 available − 已認領`）。

### 手動新增現貨的「商品」是**選填**，不要再改回必填

20260816000000 的前端把它改成必填（不選就沒人能認領），2026-08-26 依老闆指示
改回選填（要能隨意手打，也能從商品庫選）。看到那支 migration 檔頭寫「商品改必填」
不要照著改回去 —— DB 從頭到尾都收 `sku_id IS NULL`（`rpc_post_manual_spot`
的 `p_sku_id` 可為 NULL，只要求有 `spot_title`），擋著的一直只是前端那行檢查。

沒選 SKU 的貼文＝**純公告**：`rpc_claim_manual_spot` 直接擋（沒訂單可轉），
`customer_order_items.sku_id` 又是 NOT NULL → 也開不了單、配不給客人，
因此不進庫存 / 月結 / 銷售報表，只能靠會員按「用 LINE 詢問店家」線下處理。
要救就用「✏️ 修改內容」補選商品（`p_sku_id`，NULL = 不動、不是清除）。
⚠ 補選時挑錯 SKU 會扣錯商品的庫存：認領走 `_air_ship_order_items`，
`p_allow_negative => TRUE`，扣成負的也不會擋。

### 新開 order_no 前綴之前，先查線上有沒有人用了

`SP-` 已經被「現貨直配」(`rpc_create_spot_sale`) 用掉了，而**那支 RPC 在
`supabase/migrations/` 裡找不到**（線上有、repo 沒有 —— 直接套上正式庫沒回寫
migration 的典型後果，見本檔開頭那條）。差一點就讓互助板的載體單跟它撞號。

開新前綴一律先問線上，不要只 grep repo：

```sql
SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prosrc LIKE '%<你的前綴>-%';
SELECT count(*) FROM customer_orders WHERE order_no LIKE '<你的前綴>-%';
```

順帶：`customer_orders_trio_kind_active_uniq` 的 predicate 已經排除
`order_kind='restock'` 與 `order_no LIKE 'SP-%'`，容器單走 `restock` 就不會撞
一店一單的唯一索引。

## 採購單 (purchase_orders)

### 斷貨會「拆單」，而且要能回復 —— 一律走 `_stockout_po_items`

`rpc_stockout_po_item` / `rpc_stockout_purchase_order` 只是入口，真正的核心是
`_stockout_po_items`（20260812000000 起是 v3）。它除了標記品項、連動下游，還負責：

- **拆斷貨單**：把「本次標記斷貨且 `qty_received = 0`」的品項**整列搬**
  （`UPDATE po_id`，不是複製）到一張新 PO。搬列才能讓 `po_item_id` 不變 ——
  `purchase_request_items.po_item_id` 是 PR → campaign 對應的**唯一** 1:1 連結
  （`po_campaigns`，`v_picking_demand_by_po` / `v_order_shortage` 都靠它），
  複製一份等於把貨跟團的對應弄丟。
  部分到貨的品項**不搬**（沿用「只停止等待餘量」語意）：拆了會讓「手上的貨」
  和「PR 連結」落在兩張單上，已到的貨就配不出去。
  整張單都斷貨時**不拆**（原單自己就是斷貨單，不生空殼 PO）；同一張來源單
  再斷貨會併進既有那張未回復的斷貨單。
- **連結**：受影響的下游列寫 `stockout_po_id`（campaign_items /
  customer_order_items / customer_orders / restock_request_lines /
  restock_requests），`rpc_restore_stockout_po` 靠它決定要還原哪些列。
  新增任何寫 `stockout_at` 的路徑，記得一起寫 `stockout_po_id`，
  不然那些列回復不了（舊資料只能靠「斷貨時間 + SKU + campaign」猜）。

順序有雷：**`_stockout_propagate_restock` 一定要在拆單之前呼叫**。它的
「已有歸屬出貨」守衛走 `pri → poi.po_id → pw.source_po_id`，品項先被搬走
守衛就對不上，會把真的已出貨的補貨明細誤判成可取消。

### 斷貨單沿用 `status='cancelled'`，不要新增 status 值

同 `customer_order_items` 那一套（20260702020000）：`po.status IN
('sent','partially_received','fully_received','closed')` 散落在十幾支
view / RPC 當供給與閘門條件，加一個 `'stockout'` 值要同時改完那些地方，
漏一個就是靜默錯帳。斷貨＝ `status='cancelled'` + `stockout_at IS NOT NULL`，
列表的「斷貨」分頁是 `rpc_po_list` 的虛擬 `p_status='stockout'`
（其餘分頁會 `AND stockout_at IS NULL` 排除斷貨單，分頁加總才等於總數）。

### 回復斷貨 = 回到 `draft`，不是回到 `sent`

`rpc_restore_stockout_po`：斷貨單 → `draft` + 清掉 `sent_at/by/channel`
（＝「正常未採購」，可再送一次、也可改廠商），並反向還原開團商品 / 顧客訂單
品項（`cancelled` + 斷貨 → `pending`）/ 整單取消的訂單 / 被收尾成 `completed`
的單（→ `partially_completed`）/ 補貨鏈 / RR- 內部單，另發一則「斷貨已恢復」通知
（先前發過取消通知，不補一則客人會以為訂單自己長回來）。
守衛：有到貨量 / 未取消的進貨單 / 撿貨波次 → 擋下，那不是純斷貨單。

## 補貨申請 (restock_requests)

### RR 推 received 時，ride-along 內部單一律走 _settle_restock_ride_along

RR- 單的品項數量是**申請量**，不是實收量；`_restock_wave_progress` 的
`fully_dispatched` / `all_arrived` 也都不看 `qty_received`。所以「RR 推
received → 內部單直接推 ready」會把短收沒到的貨掛在店身上（2026-08-10
松山 RR-360：出 9 收 5，內部單照樣整張 ready）。

新增任何把 restock_requests 推到 `received` 的路徑，ride-along 單一律呼叫
`_settle_restock_ride_along(request_id, operator, at)`（20260810000000）——
它會先把品項對齊歸屬實收（0 → cancelled＋`[短收未到]`、部分 → 拆行）再推
ready / 全未到自動取消；反向（退回收貨）配 `_unsettle_restock_ride_along`。
既有呼叫點：`rpc_receive_transfer` 邏輯 D/D2、`_stockout_propagate_restock`。

短收造成的總倉帳差不會自動補：出庫已扣、店端沒入，貨等於帳上消失。
HQ 要在 /wms/exceptions 用 `restock_hq`（沖回總倉庫存，20260810000010）
或 vendor_claim / accept 收掉，別放著。

---

## 會員 (members)

### 唯一索引的母體要跟「有沒有人用了」那些查詢的母體一致

`uniq_members_tenant_phone_hash_partial` 只排除 `phone_hash IS NULL`，但全站每一支
「這支號碼被誰用了」的查詢都另外排除 `merged` / `deleted`
（liff-api `lookupByPhone` / `registerAndBind`、`rpc_search_members`、`rpc_resolve_member`…）。
於是被合併掉的舊帳號繼續佔著號碼，而**佔號的那筆誰也查不到** —— 店員在後台輸入手機
一律跳「資料重複衝突(uniq_members_tenant_phone_hash_partial)」，搜尋卻說沒人用，完全無解
（2026-08-31 林口店：83 筆 merged 殘骸各佔一支，其中 24 支的活人本尊根本沒有手機）。

已修（20260831000050）：`rpc_merge_member` 標 merged 的同時清 `phone_hash`
（`phone` 原文留著備查／供 `rpc_unmerge_member` 還原）、本尊沒手機就把號碼交棒過去；
`rpc_upsert_member` 撞號時先查對手是誰，死號就地讓號、活人則吐出點得出名字的錯誤；
並加 `CHECK (status <> 'merged' OR phone_hash IS NULL)` 讓下次寫回去的路徑當場炸掉。

- 新增任何「軟刪除 / 停用 / 併掉」的狀態時，一起問：**它身上有沒有唯一欄位還佔著**？
  有的話不是清掉（GDPR 那支用 `phone_hash = 'DELETED_' || id` 哨兵值讓號）就是交棒。
- 「查得到的人都說沒人用、存下去卻一定撞」＝ 索引母體 ≠ 查詢母體，先去比這兩個集合。
- 交換唯一值（來源讓號、目標接手）**要拆成兩句 UPDATE**。unique index 是逐句即時檢查，
  寫在同一句會撞在自己身上；backfill 也因此得逐筆迴圈，不能一句 UPDATE 掃完。

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

### 分享連結的預覽卡（OG tag）：client component 頁面要拆一層 server wrapper

貼連結到 LINE / FB 時，對方爬蟲讀的是**伺服器吐出來的 HTML**裡的 og tag，
client component 自己 `fetch` 回來的資料它完全看不到。所以 `"use client"` 的頁面
不管畫得多漂亮，預覽卡永遠是站台預設值（沒設 og 時 LINE 會退到 apple-touch-icon，
就是那張店家 logo 小方圖）。

`/shop/c/[id]` 的作法（2026-08-15）：把原本的 client 頁改名 `CampaignDetailClient.tsx`，
`page.tsx` 只留 server wrapper + `generateMetadata`，資料走 liff-api 的
**免 token** action `get_campaign_preview`（爬蟲沒有、也不可能有會員 JWT，
掛在需要 token 的 switch 裡等於整支失效）。三個連帶注意：

- 免 token 的 action 只回「連結本來就打算公開的東西」（團名 / 圖 / 起跳價 / 結單時間），
  不要順手把訂單、會員欄位帶出去。
- og 圖必須是**絕對網址**（爬蟲沒有「當前網域」概念）；站台網域統一從
  `apps/member/src/lib/site.ts` 的 `SITE_URL` 拿，不要每頁各寫一份。
- 封面沒設就退回第一個品項的商品主圖，再沒有才退店家 banner —— 很多團直接沿用
  商品照沒上傳封面，少了這層 fallback 那些團的卡就沒圖。

LINE 會**依網址快取預覽**，改完 og tag 後舊訊息裡的卡片不會變，要貼新網址
（或加 `?v=2`）才看得到新的。驗證不用真的貼 LINE：

```bash
curl -sS <url> | grep -o '<meta property="og[^>]*>'
```

---

## 前端建置（apps/admin, apps/member）

### Next.js 16 預設編到 `safari 16.4` —— 舊 iPhone 上整個 app 不動，而且不會有錯誤畫面

`node_modules/next/dist/shared/lib/modern-browserslist-target.js` 寫死
`['chrome 111','edge 111','firefox 111','safari 16.4']`，沒設 browserslist 就用它
（`build/get-supported-browsers.js`：**有設就以設定為準**，所以修法就是去設）。
而 iPhone 7 / 6s / iPad Air 2 的天花板是 iOS 15.8＝**Safari 15.6**，差這一階
SWC 就會吐出 ES2022 的 class static block（Next 自家的 error boundary 就有，
每一頁都載得到），舊機一個 SyntaxError 整包 chunk 陣亡。

**症狀完全不像壞掉**：會員端每頁都是 client component，SSR 吐的是 `loading=true`
的骨架，所以 hydration 沒發生時畫面就**停在轉圈那一格** —— 沒有紅字、沒有 console
（手機上也看不到）、`client_error_logs` 一筆都沒有，因為 ErrorLogger 自己也在那包
死掉的 bundle 裡。2026-08-18 忠順 992831 回報「點新系統就一直轉圈」就是這個，
從畫面上跟「網路慢」分不出來。看到「某幾支手機轉圈、其他人都正常」先想這條。

- 兩個 app 的 `package.json` 都設了 `browserslist`（下限 Safari 13.1 / iOS 13.4）。
  **不要拿掉**，也不要以為 Next 之後會自己變寬。
- ⚠️ **設了 browserslist 不代表線上真的變了 —— webpack 的 cache 會把它吃掉。**
  Next 沒有把編譯目標算進 filesystem cache 的 key，所以改了 browserslist，
  `.next/cache` 裡已經編好的模組會被原封不動拿來用。本機通常看不出來（多半會先
  `rm -rf .next`），但 **Vercel 每次部署都會還原 `.next/cache`**，於是修改在線上
  等於沒發生。2026-08-18 的 iPhone 7 修法就是這樣白做一次：PR 合併部署後，線上
  `239-*.js` 的雜湊跟修之前**一模一樣**、static block 還在，舊手機照樣開不了。
  已修：`apps/member/next.config.ts` 的 `pinCacheToBrowserslist()` 把 browserslist
  折進 `cache.version`（不要改用 `buildDependencies` —— 那個只對「上一次 build
  就已經在追蹤」的檔案有效，第一次加上去的那一次還是會吃到舊 cache，也就是救不了
  已經壞掉的那次部署）。apps/admin 走 Turbopack，實測沒有這個問題，不用加。
- 檢查已經接進兩個 app 的 `npm run build`（member 的 `vercel.json` 也改成
  `npm run build`），語法不合格就讓部署**紅掉**，不會再靜悄悄上線。
- **browserslist 管不到 `node_modules` 裡已經編好的 dist**（Next 預設不轉譯），
  所以真正的下限是相依套件給什麼算什麼 —— 目前實測是 Safari 14.1
  （`@serwist` 的 class fields）。只能事後檢查：

  ```bash
  cd apps/member && npx next build --webpack     # 要先 build
  node scripts/check-bundle-browser-support.mjs apps/member   # 或 apps/admin
  ```

  它用 AST（不是 grep）揪 class static block / lookbehind / regexp `d`,`v` flag。
  平常靠 build 自動跑；要驗**線上**到底出了什麼，就把線上 `/orders` HTML 裡的
  chunk 全抓下來放進某個 `<dir>/.next/static/chunks/`，再對 `<dir>` 跑同一支。
  **不要只信本機 build** —— 上面那個 cache 坑就是本機綠、線上紅。
- 語法過了不代表跑得動：`Object.hasOwn`、`structuredClone`（都是 Safari 15.4）
  這種**執行期 API** 不會被 browserslist 降級，而 Next 的 polyfill chunk 掛的是
  `noModule`，Safari 15 支援 module 所以**根本不會載**。現在 app router 路徑上
  沒有裸呼叫（Next 自己在 chunk 內附了 `Object.hasOwn` 的 fallback），要自己用
  這類 API 時記得先 feature detect。

### 會員端有「開機守門員」，它必須是 ES5

`apps/member/src/lib/bootGuard.ts` 內嵌在 layout 的 `<body>` 第一個 —— 它**不屬於
任何 chunk**，所以 bundle 全滅時照樣會跑：等不到 hydration 就把轉圈換成看得懂的
訊息，並回報一筆 `source='boot_no_hydration'` 到 `client_error_logs`。上面那次
災情之所以只能靠照片，就是因為當時沒有這層。

- **它自己只能用 ES5**（沒有箭頭函式 / let / 樣板字串 / `fetch` / `Promise`）。
  用了新語法它會跟要救的那包一起 SyntaxError，而且**不會有任何人發現**（畫面上
  什麼都不會發生）。改完一定要跑 `node scripts/check-boot-guard-es5.mjs`。
- 存活訊號是 `ErrorLogger` 在 useEffect 裡設的 `window.__memberBootOk`
  （常數 `BOOT_OK_FLAG`）。兩邊要一致，改名記得一起改。
- 它**不靠 error 事件**判斷：框架 chunk 是釘在 `<head>` 最前面的 async script，
  插不進它們前面（`next/script` 的 `beforeInteractive` 在 Next 16 也是排到
  `<body>` 開頭，實測沒用），誰先跑是條件競爭。所以放棄時會把 chunk 抓回來用
  `new Function` **只解析不執行**，穩定拿到真正的錯誤，順便分辨要跟使用者說
  「手機太舊」還是「網路不通」。

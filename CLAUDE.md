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

### 套上正式庫的 SQL，對應 migration 當天就要合併進 main

凡直接套上正式庫的 SQL（Management API 或 SQL Editor），對應的 migration 檔必須**當天真的進到 main**。沒進 main 的期間 repo ≠ 正式庫，後續開發都會基於錯誤認知往下做：讀 repo 的人以為線上還是舊行為，前端與配套改動也跟著停在半套。

**「PR 顯示 Merged」不等於「進了 main」——要看那個 PR 的 base 是不是 main。** 前例：`20260805000230`（現貨配單：配給客人＝待取，取貨時才扣庫存）8/06 套上線，同批的 PR #629 base 選成 feature 分支本身而不是 main；而該分支帶回 main 的 PR（#627）在 12 分鐘前就已經合併，之後沒有第二個 PR 再帶它回去 → 那支 migration 和同 PR 的前端改動從來沒進過 main，GitHub 上卻是綠色的 Merged。結果 repo 與正式庫脫鉤一週，前端仍是舊的「直售＝立刻結案」語意、取貨頁放行的另一半沒上線，期間 7 張配單訂單卡在取貨頁按不動。

自檢（唯一算數的）：對線上跑完 SQL 後，`git log origin/main -- supabase/migrations/<檔名>` 查得到那支才算收工。

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
- **拿閘門當「到貨通知」的觸發條件時一定要自己加數量守衛**。閘門本身不管數量，
  無條件放行會出現「補 2 包、團購欠 8 包 → 8 位團友都收到到貨通知卻撲空」。
  可配量的算法：`stock_balances.on_hand − 已承諾未取量`，其中「已承諾」要
  **排除 `members.member_type = 'store_internal'` 的單**（RR- /【內部】xx 店是
  現貨池容器，不是對客人的承諾；不排除的話可配量會被歸零，整支等於沒作用）。
  配法比照既有的「依訂單時間自動配」：`ORDER BY created_at, order_no`，
  整單裝得下才推，裝不下跳過繼續試後面的小單。
- 不要順手改成寫 `backorder_at`：那一欄是「少發配貨沒配到」的語意，寫下去
  `is_order_item_pickup_ready` 會回 false，反而多一道要人工解除的關卡。
  維持 `confirmed` 就好，下一批貨收進來時會自然重算。

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

### 自由轉貨（rpc_create_free_transfer）已停用

2026-08-14 起不再開放建單：`/wms/transfers` 的「+ 建自由轉貨」與 `/transfers/free`
表單都移除，`authenticated` 的 EXECUTE 也收回（20260814050000）——
按鈕拿掉但 API 還通等於沒停。既有 199 張單的檢視 / 收貨 / 刪草稿 / 改估價全部保留。
店對店調貨改走「訂單轉給別人 + 勾空中轉」，店內補貨走補貨申請。

連帶（就是前面那條「拿掉入口前先確認有人推得動」）：收貨短少處理彈窗的
「補出貨」CTA 本來指 `/transfers/free`，一起改指 `/restock/new`，
不然那個選項會把人送到一頁沒有按鈕的畫面。

### 沒有撿貨波次≠沒有單據：`rpc_get_transfer_source_kinds` 的 `air`

收貨頁的來源類型原本只看波次，沒有波次行就回 `'free'` →
畫面標「↔ 轉貨・沒有可對應的單據」而且數量不給點。但空中轉／互助的 AT- 單
**有**掛訂單（`transfers.customer_order_id`），`rpc_get_orders_for_transfer` 的
`from_aid` 分支查得到是哪一張、哪位客人。20260814040000 因此加了
`customer_order_id IS NOT NULL → 'air'`；前端凡是 `srcKind !== 'free'` 的地方
（點數量看訂單）自動對它生效。新增這類「無波次但有單據」的調撥時記得回來看這支。

---

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

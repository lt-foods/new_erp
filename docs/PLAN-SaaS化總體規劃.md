# PLAN — ERP SaaS 化總體規劃（對外販售）

> 2026-09-30。目標：把現在只服務「包子媽生鮮小舖」一家的 ERP，變成**可以賣給任何團購店／連鎖店**的訂閱制 SaaS。
> 前作 `docs/PLAN-試用租戶註冊.md`（2026-06-12）只做到「能自助開一個試用租戶」；本文接在它後面，
> 涵蓋安全隔離、租戶設定、LINE 多租戶、收費、平台後台、部署網域、營運，一路到能對外收錢。
> 現況數字全部是 2026-09-30 對線上 DB / repo 實查的，不是估的。

---

## 0. 現況盤點（規劃依據）

### 0.1 已經有的（前作 Phase 0–3 都上線了）

| 項目 | 現況 |
|---|---|
| 租戶主檔 | `tenants`（id / name / status / is_protected / trial_* / contact_email / purged_at），線上 1 筆：包子媽，`active`、`is_protected` |
| 自助試用 | `trial-signup` edge fn + `/signup` + `/welcome` landing（含定價：年繳 799／月繳 999）+ `rpc_seed_trial_tenant`（總倉、S001 示範門市、三個會員等級）|
| 試用到期 | `suspend-expired-trials` cron 每小時；`_current_tenant_id()` 對 suspended/deleted 直接 raise；前端 `TrialGate` 整頁擋 |
| 一鍵刪除 | `rpc_purge_tenant`（掃 catalog 逐表刪，`session_replication_role='replica'`）+ `tenant-purge` edge fn（owner 自刪 / `PLATFORM_ADMIN_SECRET`）|
| 資料層隔離 | 160 張 public 表，**全部** RLS on；141 張有 `tenant_id`，其餘 13 張是子表（items）靠父表、3 張是平台表 |
| 每店 LINE OA | `store_line_oa_credentials`（13 筆）每店自己的 Messaging API channel，token 走 client_credentials 換 |
| FB 粉專 | `fb_pages` 每租戶自己貼 page token |
| 規模 | 705 支 migration、545 支 function（452 支 SECURITY DEFINER）、16 支 edge fn、admin 82 頁、member 24 頁；DB 727 MB、10 萬張訂單、2.6 萬會員、29 家店；Supabase Medium (4GB) |

### 0.2 擋著不能賣的（依嚴重度）

**A. 安全隔離沒有被第二個租戶打過（最嚴重，賣之前必修）**

1. **6 張表對所有登入者全開讀取**：`transfers` / `transfer_items` / `picking_waves` / `picking_wave_items` /
   `goods_receipts` / `goods_receipt_items` 各有一條 `FOR SELECT TO authenticated USING (true)`
   （`20260430160000_picking_auth_read_rls.sql`，線上已驗證還在）。租戶 B 登入就能讀租戶 A 的全部調撥與收貨。
2. **176 支 SECURITY DEFINER RPC 內文完全沒有 tenant 字樣**（其中 49 支 `rpc_*` 對 `authenticated` 開 EXECUTE，
   例：`rpc_advance_order_status`、`rpc_approve_expense`、`rpc_delete_purchase_order`、`rpc_send_settlement_to_store`）。
   它們吃一個 row id 就動手，沒有驗那一列是不是呼叫者的租戶 → 跨租戶 IDOR。
3. **租戶取得方式四種並存**：116 支走 `_current_tenant_id()`（有擋 suspended）、39 支直接讀 `auth.jwt()->>'tenant_id'`
   （不擋）、26 支收 `p_tenant_id` 參數（信任呼叫者）、21 支 SECURITY INVOKER。停權只擋到三成。
4. 兩條 policy 只看 role 不看 tenant（`order_expiry_events.oee_hq_all`、`order_shortage_events.ose_hq_all`，而且 role `'hq'` 根本不存在）。
5. `custom_access_token_hook` 不看 `tenants.status`：停權租戶照樣拿得到 token；`staff-create` 也不看，停權後還能開帳號。
6. 7 支 pg_cron 全站掃、不看租戶狀態：停權租戶的團照樣自動開／結、LINE 記事本照樣發文、退貨照樣自動收。
7. 沒有任何「兩個租戶互打」的自動化測試（`TEST-E2E-T10` 是單租戶、只測跨店）。

**B. 會員端／LINE 完全不知道自己是哪個租戶**

8. `DEFAULT_TENANT_ID` 寫死在 5 支 edge fn：`liff-session`、`line-oauth-callback`、`liff-api`（無 token 的 4 個 action：
   `list_stores` / `get_campaign_preview` / `guest_heartbeat` / 匿名 log）、`community-bot-ingest`、`piaopiao-api`。
9. 只有一組 LINE Login channel（`LINE_CHANNEL_ID/SECRET`、`LINE_LIFF_CHANNEL_ID`）和一個 build-time `NEXT_PUBLIC_LIFF_ID`；
   `stores.line_liff_id` 有欄位但 member app 刻意不用。
10. `line-webhook` 用 `?store=<code>` 找 `store_line_oa_credentials` **沒濾 tenant**，而每個試用租戶都種了 `S001` →
    第二個租戶一綁 OA 就 `maybeSingle()` 炸。`bot_user_id` 也沒有唯一索引。
11. `MEMBER_FRONT_BASE_URL`、`NEXT_PUBLIC_SITE_URL`、`NEXT_PUBLIC_MEMBER_APP_URL` 都是全站一個網址；
    `admin-line-push` 沒店 token 時退用全站 `LINE_MESSAGING_CHANNEL_ACCESS_TOKEN`（＝別的租戶會從包子媽的 OA 發訊息）。
12. `COMMUNITY_BOT_SECRET` 一把共用、對到一個租戶。
13. 品牌寫死在程式：「包子媽生鮮小舖」出現在 member `site.ts` / `layout.tsx` / `join` / `install` / `manifest.json` /
    `/brand/banner.jpg`、admin `tenant.ts`；`storeOrder.ts` 是包子媽 16 家店代碼的固定排序表；
    `line-note-worker` 內含包子媽的提醒文案與網址。
14. Storage：`member-avatars` 路徑 `line-<userId>.ext` 沒租戶前綴；piaopiao 上傳到 `products/piaopiao/<publisher>/`；
    `tenant-purge` 沒清 `line-media`、只列一層目錄。

**C. 商業／營運層完全沒有**

15. 沒有 plan / subscription / invoice / entitlement / feature flag 任何表或程式；定價只是 landing page 上的靜態陣列。
16. 沒有平台管理者角色、沒有平台後台；唯一的平台動作是一把 `PLATFORM_ADMIN_SECRET`（而且是 `!==` 比對，非 constant-time）。
17. 部署：admin 是 GitHub Pages 靜態匯出（`www161616.github.io/new_erp/`）；member 是一個 Vercel project（名字還叫 `new-erp-admin`）。
    沒有 middleware、沒有任何 host / 子網域邏輯、沒有自訂網域。
18. 新租戶 seed 只有總倉、一家店、三個等級；商品標籤規則只 seed 給包子媽（`20260809000020/60`）。
19. 匯入工具只有樂樂 CSV 專用的會員匯入；訂單匯入是空殼。
20. `Asia/Taipei` 在 migration 裡寫死約 315 次；流水號 `pr/po/gr/transfer/stocktake/wave/deduction` 是全站共用 sequence
    （唯一鍵有 tenant_id 不會撞，但號碼會跳、看得出別家的量）。

---

## 1. 架構決策（先定，後面都跟著走）

### 1.1 一庫多租戶（pooled）為主，大客戶另開專案（dedicated）為輔

**決定：所有中小客戶跟包子媽同一個 Supabase project，靠 RLS 隔離。**

- 705 支 migration 已經是一套可重放的 schema，但**每多一個 project 就多一份要用 Management API 逐支套的負擔**
  （CLAUDE.md：這個環境套 migration 只能走 Management API；「進 main ≠ 套上線」已經踩過）。10 個租戶 10 個 project 撐不住。
- 前作建議「試用另開 project」是因為隔離沒驗過。**現在方向是賣，試用會轉正式，搬庫比修隔離貴。**
  所以改成：**先把 Phase 1 的隔離 gate 修過，再開放試用；在那之前 `/signup` 不對外宣傳。**
- 保留一條「dedicated」路：年營收大、要求資料獨立的客戶另開 project，用同一套 migration 部署。
  前提是 Phase 1 做出 `scripts/deploy-migrations-to-project.sh`（對指定 ref 依序套、記錄到 `schema_migrations`）。
  這條路不在前三個階段。

### 1.2 租戶識別碼：`tenants.slug`

member app 沒有 JWT 之前只有 `?store=S001`，而 store code 只在租戶內唯一。要加一個**對外可見、全站唯一、人看得懂**的識別碼：

- `tenants.slug`（`^[a-z0-9-]{3,30}$`，UNIQUE，註冊時填、之後只能由平台改）。
- 會員端網址：`https://m.<平台網域>/<slug>/...`（path 前綴，最便宜）；之後再做 `<slug>.<平台網域>`（wildcard 網域 + middleware 讀 host）
  與客戶自訂網域（Vercel Domains API）。三種對 app 來說都是「從 request 解析出 slug」，內部一律用 slug。
- LINE 相關 URL（LIFF endpoint、webhook、OAuth callback）全部帶 slug 或 tenant id，不再靠 `?store=` 猜租戶。

### 1.3 LINE：每個租戶自己的 Provider（Login channel + LIFF + OA）

LINE user ID 依 **Provider** 切分（`20260807000050`、`line-webhook` 檔頭有寫）。店家的 OA 要能對會員推播，
會員登入拿到的 user ID 就得跟 OA 看到的是同一個 → **Login channel 必須跟 OA 在同一個 Provider 底下，也就是客戶自己的。**
所以「平台一組 LIFF 大家共用」走不通（推播對不到人），只能：

- 每個租戶：自己的 LINE Login channel（channel id / secret）+ 一支 LIFF（endpoint 指到 `m.<平台>/<slug>`）+ 每店一個 OA（已有）。
- 平台存這些設定（見 §3.1 `tenant_integrations`），edge fn 依 slug 撈出來驗 id_token / 換 token / 發訊息。
- 這是**客戶上線最大的摩擦點**（要進 LINE Developers 開 channel、貼 secret、設 endpoint、加 scope）。
  對策：後台做設定精靈（逐步截圖 + 貼上 + 驗證按鈕），並提供「代客設定」付費服務。
- 不用 LINE 的客戶（純後台 ERP）：member app 可以整個關掉，不擋註冊。

### 1.4 收費：先人工、金流第二步

台灣中小店家訂閱制實務：**第一批客戶走匯款 + 人工開通**（平台後台按一下 active + 設到期日），
金流（藍新／綠界／TapPay 定期定額）跟電子發票（`docs/Q17-電子發票廠商比較.md`）等有 10 個付費客戶再接。
資料模型從第一天就照「有金流」設計（§5），只是付款那一步先由人做。

### 1.5 市場：台灣、繁中、Asia/Taipei

時區在 migration 寫死 315 次，改成 per-tenant 的成本遠大於收益。**明訂本 SaaS 第一版只賣台灣**，
時區／幣別／語言都不做多套。寫進服務條款。

---

## 2. Phase 1 — 安全隔離 gate（不過這關不能對外）

目標：兩個租戶互相打不到，停權的租戶什麼都動不了。這階段**只改後端**，前端零改動。

### 2.1 修已知的洞

| # | 動作 | 產出 |
|---|---|---|
| 1 | 把 `20260430160000` 的 6 條 `USING (true)` policy 改成 `tenant_id = (SELECT auth.jwt()->>'tenant_id')::uuid`（沿用 `20260818000020` 的 initplan 寫法） | migration ×1 |
| 2 | `oee_hq_all` / `ose_hq_all` 加 tenant 條件（順便把不存在的 `'hq'` role 改成正確的管理員集合 `('owner','admin','hq_manager','')`） | 同上 |
| 3 | `custom_access_token_hook`：查 `tenants.status`，`suspended/deleted` 直接 raise（拿不到 token）；**基於 `20260424120000` 擴寫，先 grep 確認沒別支動過** | migration ×1 + Dashboard 重新啟用 hook |
| 4 | `staff-create` / `trial-signup` 之外的 edge fn 統一在入口呼叫 `_shared/tenant.ts` 的 `assertTenantActive(tenantId)` | edge fn 共用模組 |
| 5 | 7 支 cron 的 RPC 母體加 `JOIN tenants t ON t.id = x.tenant_id AND t.status IN ('trial','active')` | migration ×1 |
| 6 | `tenant-purge` 的 secret 比對改 constant-time；`PURGE_BUCKETS` 補 `line-media`；listing 改遞迴 | edge fn |

### 2.2 176 支「無 tenant」DEFINER RPC 的體檢

不可能一支一支人工讀。做法：

1. 寫 `scripts/audit-rpc-tenant-guard.mjs`：對線上 `pg_proc` 撈所有 `prosecdef` 且 `authenticated` 有 EXECUTE 的 `rpc_*`，
   分類：(a) 內文有 `_current_tenant_id()`、(b) 直接讀 JWT、(c) 收 `p_tenant_id`、(d) 都沒有。輸出清單進 `docs/AUDIT-rpc-tenant.md`。
2. 對 (d) 的每一支，在函式開頭補一段標準守衛：

   ```sql
   v_tenant := public._current_tenant_id();          -- 停權直接 raise
   SELECT tenant_id INTO v_row_tenant FROM <主表> WHERE id = p_id;
   IF v_row_tenant IS DISTINCT FROM v_tenant THEN RAISE EXCEPTION 'cross_tenant' USING ERRCODE='42501'; END IF;
   ```

   一律**基於最新版本**改（CLAUDE.md：先 grep 所有動過該函式的 migration）。分批出 migration，一批 15–20 支。
3. 對 (b) 39 支：把 `auth.jwt()->>'tenant_id'` 換成 `_current_tenant_id()`，停權才擋得到。
4. 對 (c) 26 支（`rpc_inbound` / `rpc_outbound` / `rpc_make_payment` / `rpc_earn_points`…）：
   函式內加 `IF p_tenant_id <> _current_tenant_id() AND current_setting('request.jwt.claims', true) IS NOT NULL THEN RAISE`
   （service_role 呼叫沒有 claims 才放行，對齊 `20260813000000:752` 既有的 service-context 寫法）。
5. `_current_tenant_id()` 補 `SET search_path = public, pg_temp`（目前沒有）。

### 2.3 雙租戶自動化測試（gate 本身）

- `tests/tenant-isolation/`：用 `trial-signup` 開兩個租戶 A、B，各自建店／商品／團／單／調撥。
- 對**每一張有 tenant_id 的表**（從 catalog 撈，不手寫清單）：用 B 的 JWT 讀 A 的資料 → 必須 0 筆；用 B 的 JWT 改 A 的 id → 必須 error。
- 對每一支 `authenticated` 可 EXECUTE 的 `rpc_*`：用 B 的 JWT 帶 A 的 id 呼叫 → 必須 error 而且 A 的資料沒變（前後 checksum）。
  參數怎麼填：從 `pg_proc.proargnames/proargtypes` 產生，id 類參數填 A 的 id，其他填合法預設值；打不進去的（例外訊息不是 cross_tenant）列出來人工看。
- 停權測試：把 B 標 suspended → B 拿不到 token、既有 token 呼叫任何寫入 RPC 都 raise、cron 跑過 B 的團狀態不變。
- 這套接進 GitHub Actions，對每個 PR 跑（用本機 `supabase start`，不打正式庫）。
- 加到 `TEST-E2E-T10` 的姊妹文件 `TEST-E2E-T11-tenant-isolation.md`。

### 2.4 這階段結束的定義

- 測試全綠；`docs/AUDIT-rpc-tenant.md` 裡 (d) 類歸零。
- 線上實際用第二個租戶（自己開的）跑一輪。
- 在此之前 `/signup` 保持不宣傳（頁面可留著）。

---

## 3. Phase 2 — 租戶身份、設定、去硬編碼

目標：程式裡沒有任何「包子媽」；新租戶靠設定就能長出自己的品牌與 LINE。

### 3.1 資料模型

```sql
ALTER TABLE tenants
  ADD COLUMN slug           TEXT UNIQUE,                       -- §1.2
  ADD COLUMN plan_code      TEXT NOT NULL DEFAULT 'trial',     -- §5
  ADD COLUMN settings       JSONB NOT NULL DEFAULT '{}',       -- 顯示名、logo、banner、主色、客服 LINE、pickup 預設…
  ADD COLUMN owner_user_id  UUID,
  ADD COLUMN billing_email  TEXT,
  ADD COLUMN locale         TEXT NOT NULL DEFAULT 'zh-TW',
  ADD COLUMN timezone       TEXT NOT NULL DEFAULT 'Asia/Taipei';

CREATE TABLE tenant_integrations (        -- 一租戶一列，密鑰欄位只給 service_role 讀
  tenant_id            UUID PRIMARY KEY REFERENCES tenants(id),
  line_login_channel_id     TEXT,
  line_login_channel_secret TEXT,        -- 走 Vault 或 pgsodium 加密，不明文
  line_liff_id              TEXT,
  line_default_oa_basic_id  TEXT,        -- 「用 LINE 詢問店家」的 fallback
  member_base_url           TEXT,        -- https://m.<平台>/<slug>
  community_bot_secret      TEXT,        -- 取代全站 COMMUNITY_BOT_SECRET
  fb_app_config             JSONB,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE VIEW v_tenant_public AS            -- 免登入可讀的部分（品牌、LIFF id、OA id），給 member app 開機用
  SELECT slug, name, settings->'brand' AS brand, i.line_liff_id, i.line_default_oa_basic_id
    FROM tenants t JOIN tenant_integrations i USING (tenant_id) WHERE status IN ('trial','active');
```

- `rpc_get_my_tenant()` 擴回 slug / plan / settings；新 `rpc_update_tenant_settings(jsonb)`（owner/admin）；
  `rpc_set_tenant_integration(...)`（owner，寫入走 Vault）。
- 包子媽 backfill：slug `baozima`、`line_*` 從現在的 env 搬進表、`member_base_url` 填現在的 vercel 網址。

### 3.2 邊界函式改吃租戶設定

| Edge fn | 改法 |
|---|---|
| `liff-session` | 由 `?tenant=<slug>`（member app 帶）撈 `tenant_integrations`，用該租戶的 `line_login_channel_id` 驗 id_token；`DEFAULT_TENANT_ID` 刪除 |
| `line-oauth-start` / `-callback` | state 裡帶 slug；callback 用該租戶的 channel id/secret 換 token；redirect 回該租戶 `member_base_url` |
| `liff-api` 無 token 的 4 個 action | 必帶 `tenant` 參數；`list_stores` / `get_campaign_preview` 依 slug 查 |
| `line-webhook` | URL 改 `?tenant=<slug>&store=<code>`；同時給 `store_line_oa_credentials.bot_user_id` 加 UNIQUE，優先用 `destination` 反查 |
| `admin-line-push` | 刪 `LINE_MESSAGING_CHANNEL_ACCESS_TOKEN` fallback（沒店 token 就回錯，不准借別人的 OA）；連結用租戶 `member_base_url` |
| `line-note-worker` | 文案與網址從 `tenant.settings` / `member_base_url` 拿；包子媽專用字串移到它的 settings |
| `community-bot-ingest` | 用 header 的 secret 反查 `tenant_integrations.community_bot_secret` 決定租戶 |
| `piaopiao-api.list_public_campaigns` | 帶 slug |
| 全部 | 共用 `_shared/tenant.ts`：`resolveTenantBySlug()`、`getIntegrations()`、`assertTenantActive()` |

改完 `grep -rn DEFAULT_TENANT_ID supabase/ apps/` 必須是 0。Secrets 裡的 `DEFAULT_TENANT_ID`、`LINE_CHANNEL_*`、
`LINE_LIFF_CHANNEL_ID`、`LINE_MESSAGING_CHANNEL_ACCESS_TOKEN`、`MEMBER_FRONT_BASE_URL`、`COMMUNITY_BOT_SECRET` 全部下架。

### 3.3 member app 改成執行期解析租戶

- 路由：`app/[slug]/...`（現有 24 頁整個搬進去；根 `/` 改成平台說明頁或 404）。
- 開機順序：讀 URL slug → `liff-api get_tenant_public(slug)` → 拿到 `line_liff_id` 才 `liff.init()`。
  `NEXT_PUBLIC_LIFF_ID` 刪除。`useLineLogin` 內部改吃參數，**外部介面不變**（CLAUDE.md：登入邏輯只能有一份）。
- 品牌：`site.ts` 的 `SITE_NAME` / banner / `manifest.json`（改成 `manifest.webmanifest` route 依 slug 動態產生）/ `layout.tsx` 標題 /
  `join` / `install` 文案全部從 `v_tenant_public.brand` 來；OG tag 的 server wrapper 一樣依 slug 抓。
- localStorage key 加 slug 前綴（`last_store_id` → `${slug}:last_store_id`），同一支手機可以是兩家店的會員。
- `bootGuard.ts` 不動（ES5 規則）。

### 3.4 admin app

- `tenant.ts` 的 env 名稱與「包子媽」fallback 刪掉；登入前只顯示平台名稱。
- `storeOrder.ts` 的固定 16 家店排序改成 `stores.sort_order` 欄位（migration 補欄 + 包子媽 backfill）。
- `NEXT_PUBLIC_MEMBER_APP_URL` 改成從 `rpc_get_my_tenant().member_base_url` 拿。
- 新頁 `/settings/tenant`（品牌、聯絡、時區唯讀）與 `/settings/integrations`（LINE Login / LIFF 精靈、社群機器人 secret、FB）。
  精靈每一步有「測試」按鈕（打 LINE API 驗 channel、用 LIFF id 打 `liff.line.me/<id>` 看 endpoint 是否指到自己）。
- 「刪除我的資料」按鈕從 `TrialExpiredScreen` 搬一份到設定頁（前作 Phase 3 沒做的）。

### 3.5 Storage 與流水號

- `member-avatars` 路徑改 `{tenant_id}/line-{userId}.ext`，舊檔一次搬；purge 才清得到。
- piaopiao 上傳改 `products/{tenant_id}/piaopiao/...`。
- 流水號：`pr_no_seq` 等 8 支全站 sequence 改成 `rpc_next_*` 走 `MAX+1 per tenant`（對齊 `rpc_next_campaign_no` 既有做法）。
  可延後，但要在第二個付費客戶上線前做，否則對方看得出別家每天出幾張單。

### 3.6 Seed 補齊

`rpc_seed_trial_tenant` 補：商品標籤與規則（把 `20260809000020/60` 只 seed 給包子媽的那段改成 per-tenant 函式）、
預設通知模板、預設 pickup 設定、一個示範團與三筆示範商品（可一鍵清除）。標準：**新租戶 owner 登入後每一頁都不白屏、不報錯**，
寫成 checklist 進 `TEST-E2E-T12-new-tenant-smoke.md`。

---

## 4. Phase 3 — 部署與網域

- **admin 搬離 GitHub Pages** 到 Vercel（或同 project 的第二個 root），網域 `app.<平台網域>`。
  原因：GitHub Pages 沒有 header 控制、沒有 preview deployment、`/new_erp` basePath 對客戶不像產品。
  `NEXT_PUBLIC_BASE_PATH` 清空；`deploy-admin.yml` 退場。
- **member**：Vercel project 改名 `member`，網域 `m.<平台網域>`；`[slug]` 路由先上。
  第二步：wildcard `*.m.<平台網域>` + `middleware.ts` 把 host 的第一段 rewrite 成 `/<slug>`。
  第三步：客戶自訂網域（Vercel Domains API 加網域 + 存在 `tenant_integrations.custom_domain`）。
- **LINE 端點**：客戶的 LIFF endpoint 設 `https://m.<平台>/<slug>`；webhook `https://<ref>.functions.supabase.co/line-webhook?tenant=<slug>&store=<code>`；
  OAuth callback 仍是平台一個網址（callback 用 state 裡的 slug 分流），所以 LINE Login channel 的 callback URL 客戶只要貼一個。
- **Supabase 自訂網域**（$10/月）：把 `anfyoeviuhmzzrhilwtm.supabase.co` 藏起來，客戶貼的 URL 才像自家產品；不是必要。
- 兩個 app 的 Vercel env 從此只剩平台級：Supabase URL / anon key / 平台網域。**任何 `NEXT_PUBLIC_` 新增都要過 PR 範本的敏感設定段。**

---

## 5. Phase 4 — 方案、訂閱、收費

### 5.1 資料模型

```sql
CREATE TABLE plans (
  code TEXT PRIMARY KEY,           -- trial / basic / pro / enterprise
  name TEXT NOT NULL,
  price_monthly INT, price_yearly INT,
  limits JSONB NOT NULL,           -- {"stores":3,"staff":10,"members":5000,"line_oa":3,"storage_mb":2048}
  features JSONB NOT NULL          -- {"pos":true,"wms":true,"piaopiao":false,"fb_publish":true,"line_notes":false}
);
CREATE TABLE subscriptions (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  plan_code TEXT NOT NULL REFERENCES plans(code),
  status TEXT NOT NULL CHECK (status IN ('trialing','active','past_due','cancelled')),
  billing_cycle TEXT CHECK (billing_cycle IN ('monthly','yearly')),
  current_period_start TIMESTAMPTZ, current_period_end TIMESTAMPTZ,
  grace_until TIMESTAMPTZ,         -- 到期後寬限（預設 7 天）
  payment_method TEXT,             -- manual_transfer / newebpay / ecpay / tappay
  external_ref TEXT,               -- 金流訂閱 id
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE TABLE subscription_invoices (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subscription_id BIGINT REFERENCES subscriptions(id),
  tenant_id UUID NOT NULL,
  amount INT NOT NULL, currency TEXT DEFAULT 'TWD',
  period_start TIMESTAMPTZ, period_end TIMESTAMPTZ,
  status TEXT CHECK (status IN ('open','paid','void','uncollectible')),
  paid_at TIMESTAMPTZ, paid_via TEXT, receipt_no TEXT,        -- 電子發票號碼之後放這
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE TABLE tenant_usage_daily (tenant_id, day, stores, staff, members, orders, storage_mb, line_pushes, PRIMARY KEY (tenant_id, day));
```

- `tenants.status` 維持四態不動，**由 subscription 推導**：`trialing`→`trial`、`active`→`active`、
  `past_due` 過了 `grace_until`→`suspended`（cron `suspend-expired-trials` 擴成 `sync-tenant-status`）。
- 這幾張表沒有 `tenant_id` RLS 給 authenticated 寫；租戶只能讀自己的（`subscriptions` / `subscription_invoices` self-read policy）。

### 5.2 Entitlement（方案限制）在哪裡擋

- 只在**建立**動作擋（開店、開員工帳號、綁 OA、開啟某模組），不在讀取擋。函式 `_assert_entitlement(feature|limit)`，
  掛在 `rpc_create_store`、`staff-create`、`rpc_set_store_line_oa`、以及 `features` 對應模組的入口 RPC。
- 前端：`rpc_get_my_tenant()` 回 `plan.features`，選單上把沒買的模組顯示成「升級解鎖」（不隱藏，做 upsell）。
- 超量的既有資料**不砍**：降級後超過上限只擋新增。

### 5.3 收費流程

**4a. 人工（第一批客戶）**

- 試用到期前 3 天寄信＋後台 banner；試用頁「升級」按鈕 → 顯示匯款資訊＋方案選擇，送出後建一筆 `subscription_invoices(open)`。
- 平台後台（§6）收到款按「已收款」→ invoice paid、subscription active、`current_period_end` 往後推、tenant active。
- 寬限：到期後 7 天 `past_due`（可用，banner 提醒），之後 suspended（讀得到、寫不了）；suspended 30 天後排進 purge 候選（**永遠人工按刪除**，不自動）。

**4b. 金流（≥10 個付費客戶再做）**

- 台灣訂閱：藍新「信用卡定期定額」或 TapPay「Card Binding + 排程扣款」；兩者都要 webhook 回寫 invoice。
- 電子發票：照 `docs/Q17-電子發票廠商比較.md` 選一家（綠界／藍新自家開），開立後 `receipt_no` 回填。
- 新 edge fn `billing-webhook`（verify signature、冪等 by external id）、`billing-checkout`（產生付款頁）。
- 這部分屬於「新增後端環境值讀取」，PR 一定要勾敏感設定第一格。

### 5.4 方案草案（先用，隨時改）

| 方案 | 價格 | 限制 | 模組 |
|---|---|---|---|
| Trial | 0 / 14 天 | 3 店、5 員工、1,000 會員 | 全開（讓人試到 WMS）|
| Basic | 999／月、799／月年繳（沿用 welcome 頁） | 3 店、10 員工、5,000 會員、3 OA | 開團、訂單取貨、庫存、會員、LINE 推播 |
| Pro | 2,499／月 | 15 店、50 員工、50,000 會員 | + WMS 波次、補貨、互助板、月結、FB 發文、記事本 |
| Enterprise | 談 | 不限；可 dedicated project | + 代客設定、專屬支援 |

---

## 6. Phase 5 — 平台後台（platform admin）

- 新角色：`platform_admins(user_id)` 表（不是 tenant role），只有這張表裡的帳號能進 `/platform/*`。
  JWT hook 順便注入 `is_platform_admin` claim。**不要**再用 `PLATFORM_ADMIN_SECRET` header 當身分。
- 頁面（放在 admin app 的 `/platform` 底下，路由守衛看 claim）：
  1. 租戶列表：slug / 名稱 / 狀態 / 方案 / 到期日 / 用量（店、員工、會員、訂單 30 天）/ 最後登入。
  2. 租戶詳情：改狀態、改方案、延長試用、收款登錄（§5.3 4a）、看 `tenant_integrations` 設定是否完整（LINE 驗證結果）、purge（需輸入 slug 確認）。
  3. 「以此租戶身分登入」（support impersonation）：`rpc_platform_issue_support_token(tenant_id)` 簽一個 1 小時、`role='admin'`、
     `impersonated_by=<platform user>` 的 JWT；所有 audit log 的 operator 保留真實平台帳號。每次使用寫 `platform_audit_log`。
  4. 平台儀表板：租戶數（trial/active/past_due/suspended）、MRR、本週註冊、DB 大小、edge fn 錯誤（從 `client_error_logs` 與 Supabase logs API）。
  5. 系統公告：`platform_announcements` 表，所有租戶 admin 首頁顯示（維護通知、新功能）。
- 這些 RPC 全部 `SECURITY DEFINER` + 開頭 `IF NOT _is_platform_admin() THEN RAISE`。

---

## 7. Phase 6 — 營運能力

### 7.1 Onboarding

- 註冊後的引導 checklist（首頁卡片）：設定品牌 → 建門市 → 綁 LINE OA → 匯入商品 → 匯入會員 → 開第一團。每步完成打勾（存 `tenant.settings.onboarding`）。
- 通用匯入：商品 CSV（含 SKU/條碼/售價）、會員 CSV（手機/姓名/等級/餘額）、供應商 CSV。
  沿用 `rpc_stage_*` / `rpc_commit_*` 兩段式（樂樂匯入的架構），UI 改成欄位對應器而不是寫死樂樂格式。
- 「代客建置」服務項目：客戶給 Excel，我們用同一套匯入工具做。

### 7.2 資料匯出（客戶離開時的義務，也是信任）

- `rpc_export_tenant(p_tenant_id)` → 每張有 tenant_id 的表輸出 CSV 到 storage `exports/{tenant_id}/{date}/`，簽一個 24 小時下載連結。
  跟 purge 一樣掃 catalog，不手寫表清單。設定頁「下載我的全部資料」。

### 7.3 可靠性

- Supabase **PITR** 加購（Medium 以上才給），至少 7 天。
- 資料庫容量計畫：現在一個租戶 727 MB；`tenant_usage_daily.storage_mb` 每日算（`pg_total_relation_size` 依 tenant 不好切，
  用 `count(*) × 平均列大小` 估即可），超過方案上限先提醒。
- Noisy neighbor：`statement_timeout` 對 `authenticated` 角色設 8s（PostgREST 本來就 8s）；重的報表 RPC 改走 `tenant_usage_daily` 之類的預先彙總。
- 監控：Supabase 的 Log Drain 或每小時 cron 把 edge fn 5xx、DB 錯誤、`client_error_logs` 依 tenant 彙總進 `platform_health_daily`，平台儀表板看。
- 每個租戶上線前跑 `TEST-E2E-T12` smoke；每次 release 先在「平台自己的測試租戶」跑一遍再公告。

### 7.4 法務與文件

- 服務條款（含：台灣限定、資料保存、停權規則、退費、`line-note-scraper` 這種違反 LINE 條款的功能**不對外提供**）。
- 隱私權政策、個資處理（會員手機用 hash，已有）。
- 客戶可讀的操作手冊：把 `docs/SOP-*.md` 整理成客戶版（去掉包子媽內部脈絡）。
- Release notes 頁已有（`/release-notes`），改成從平台公告表讀。

---

## 8. 順序、里程碑、估時

| 里程碑 | 內容 | 估時（一人全職） | 可對外做什麼 |
|---|---|---|---|
| **M1 隔離 gate** | §2 全部 | 3–4 週（176 支 RPC 體檢佔一半） | 內部第二租戶試跑；仍不宣傳 |
| **M2 去硬編碼** | §3.1–3.4、3.6 | 3–4 週 | 找 1–2 家熟識店家「免費試用」，人工開通、我們代設 LINE |
| **M3 網域部署** | §4 前兩步 | 1 週 | 有正式產品網址可以放在名片上 |
| **M4 人工收費** | §5.1、5.2、5.3-4a + §6 的 1、2、4 | 2–3 週 | **開始收錢** |
| **M5 平台後台完整** | §6 其餘 + §7.1 匯入 + §7.2 匯出 | 3 週 | 自助上線不用我們插手 |
| **M6 金流與發票** | §5.3-4b | 2–3 週（含廠商申請等待） | 自動續約 |
| M7 進階 | 子網域／自訂網域、dedicated project 部署腳本、per-tenant 流水號 | 各 1 週 | 大客戶 |

M1 → M2 → M3 → M4 嚴格串行（每一階的前提是上一階）；M5、M6 可跟 M4 後的客戶回饋並行。
**最快 3 個月能收第一筆錢**，前提是 M1 不被跳過。

---

## 9. 明確不做（本輪）

- 多幣別、多時區、多語言。
- 把包子媽搬到獨立 project（它就是 pooled 的第一個租戶，`is_protected` 保護它）。
- 自動 purge：任何刪除都要人按。
- 平台共用 LINE Login（§1.3 講過對不到人）。
- `line-note-scraper`（非官方協議）做成對外功能。
- Per-tenant 自訂 cron 排程。

---

## 10. 風險

1. **176 支 RPC 體檢是最大的未知**：可能挖出現在就存在的跨店／跨角色問題，修的時候會動到營運中的邏輯；每批都要跑既有測試與雙租戶測試。
2. **LINE 設定是客戶流失點**：Provider / Login channel / LIFF / OA 四樣東西缺一不可，客戶自己做失敗率高 → 代客設定要當標準服務，不是加值。
3. **同庫的效能**：現在 Medium 4GB 跑一家 29 店；10 家同規模就要上 Large 並回頭看 `_sku_commitment` 那類全站掃描（CLAUDE.md 效能章節）。
   `tenant_usage_daily` 要從 M2 就開始記，才有依據調價與擴容。
4. **`''` legacy admin role**：9 處把空 role 當管理員，新租戶不會有這種帳號，但 platform impersonation token 不要沿用這個洞，明確給 `admin`。
5. **migration 從零重放**：新 dedicated project 或本機 `supabase start` 要能一次跑完 705 支；撞號（CLAUDE.md 有案例）與依賴線上資料的 migration（`20260923120000:317` 的包子媽例外）要先清。
   建議 M1 就加一個 CI job：每個 PR 在乾淨 DB 重放全部 migration。

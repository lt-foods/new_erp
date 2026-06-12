# PLAN — 試用租戶註冊（ERP SaaS 化第一步）

> 2026-06-12。目標：讓潛在客戶（其他商家／加盟主）自助註冊一個**獨立的試用 tenant + owner 帳號**，
> 試用期滿可停用或轉正式；並且**整個 tenant 的資料可以一鍵刪除**（硬性需求）。

---

## 0. 現況盤點（規劃依據）

| 項目 | 現況 |
|------|------|
| 多租戶 | DB 層已就緒：全部業務表（約 100 張）都有 `tenant_id UUID`，RLS 以 `auth.jwt()->>'tenant_id'` 隔離 |
| `tenants` 表 | **不存在**。租戶只是一個散落在各表的 UUID，沒有主檔 |
| JWT | `custom_access_token_hook`（`20260424120000`）從 `auth.users.raw_app_meta_data.tenant_id` 注入 claim |
| 員工帳號建立 | `supabase/functions/staff-create/`：service_role + caller 驗證，可直接沿用骨架 |
| 前端租戶名稱 | `apps/admin/src/lib/tenant.ts` 用 `NEXT_PUBLIC_TENANT_NAME` env，註解已預留「未來改 DB query」 |
| 試用/訂閱 | 無任何 trial / subscription / plan 表 |
| Email | Supabase Auth 內建（dev 用 Inbucket），**production SMTP 未設定** |
| Append-only 保護 | `forbid_append_only_mutation()` 等 **trigger**（非單純 RLS），會擋 DELETE — 影響一鍵刪除的實作方式 |

---

## 1. 架構決策

### 1.1 試用 tenant 放哪裡？（最重要的決策）

**建議：Phase 1 先用「獨立的 trial Supabase project」**，schema 與正式站相同（migrations 本來就可重放）。

- 方案 A：試用 tenant 與正式 tenant 同一個 Supabase project
  - 優點：零額外基礎設施、轉正式無痛（改 status 即可）
  - 缺點：陌生人自助註冊的帳號與**正式營運資料同庫**，任何一條 RLS/RPC 的漏洞都直接暴露正式資料；
    一鍵刪除若寫錯 tenant_id 也是刪正式庫
- 方案 B（建議起步）：另開一個 trial project，只放試用 tenants
  - 優點：正式資料零風險；一鍵刪除天然安全；可以隨時整庫 reset
  - 缺點：轉正式需要搬資料（但試用轉正通常可接受「重新開始」或僅搬主檔）
- 收斂路徑：等 RLS 多租戶實測（T10 security e2e 擴充成雙 tenant 互打）通過後，再把正式站合併進同一 project，走真正的 SaaS。

> 以下設計**兩個方案通用**（都是同一套 migration / edge function），只差部署到哪個 project。

### 1.2 註冊方式

**自助註冊（email + 密碼 + email 驗證）**，不走人工審核：

- 試用本來就要低門檻；濫用風險用「email 驗證 + rate limit + 試用期自動到期 + 一鍵刪除」控制
- 一鍵刪除做好之後，垃圾註冊的清理成本趨近於零，審核制的主要理由就消失了

---

## 2. 資料模型（新 migration）

### 2.1 `tenants` 主檔

```sql
CREATE TABLE tenants (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name             TEXT NOT NULL,                  -- 商家顯示名稱
  status           TEXT NOT NULL DEFAULT 'trial'
                   CHECK (status IN ('trial','active','suspended','deleted')),
  is_protected     BOOLEAN NOT NULL DEFAULT FALSE, -- TRUE = 禁止 purge（正式租戶）
  trial_started_at TIMESTAMPTZ,
  trial_expires_at TIMESTAMPTZ,                    -- NULL = 非試用
  contact_email    TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  purged_at        TIMESTAMPTZ                     -- 一鍵刪除後留墓碑
);
```

- RLS：authenticated 只能 SELECT 自己 JWT tenant_id 那一列；寫入全部走 RPC / edge function。
- **Backfill**：把現行正式 tenant 的 UUID insert 進來，`status='active', is_protected=TRUE`。
  （正式 tenant UUID 要從線上 `auth.users.raw_app_meta_data` 查，不要 hardcode 在 migration 裡，
  用 `INSERT ... SELECT DISTINCT raw_app_meta_data->>'tenant_id' FROM auth.users WHERE ...` 之類的方式撈。）

### 2.2 註冊濫用防護

```sql
CREATE TABLE trial_signup_attempts (   -- rate limit 用，append-only
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email       TEXT NOT NULL,
  ip          INET,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Edge function 檢查：同 email 7 天 1 次、同 IP 24 小時 3 次（數字可調）。

### 2.3 試用期常數

試用長度 **14 天**（edge function env `TRIAL_DAYS` 可調），到期不自動刪資料，
先 `status='suspended'`（擋登入後操作），保留 14 天緩衝再人工/排程 purge。

---

## 3. 註冊流程

### 3.1 新 edge function：`supabase/functions/trial-signup/`

骨架抄 `staff-create`（service_role client、輸入驗證、錯誤格式），但 **不需要 caller token**（公開端點）：

1. 輸入：`{ company_name, email, password, owner_name }` + Turnstile/CAPTCHA token（建議，至少留介面）
2. Rate limit 檢查（`trial_signup_attempts`）
3. `INSERT INTO tenants (name, status, trial_started_at, trial_expires_at, contact_email) ... RETURNING id`
4. `sb.auth.admin.createUser({ email, password, email_confirm: false, app_metadata: { tenant_id, role: 'owner', stores: [] } })`
   - `email_confirm: false` → 走 Supabase Auth 驗證信，**驗完才能登入**
5. 呼叫 `rpc_seed_trial_tenant(tenant_id)` 種基礎資料
6. 任一步失敗 → 反向清理（刪 user、刪 tenant row），不留半套

### 3.2 `rpc_seed_trial_tenant(p_tenant_id UUID)`（SECURITY DEFINER，只給 service_role EXECUTE）

新 tenant 最低可動資料集（實作時要實測 admin app 首頁/各模組不爆）：

- `locations`：一筆 `總倉`（type=central_warehouse）— `staff-create` 的 stores magic value 與多數模組都假設它存在
- `stores`：一筆示範門市（綁上面的 location）
- `member_tiers`：預設等級（對齊正式站 seed）
- 其他模組如有「無資料就白屏/報錯」的硬依賴，邊做邊補進 seed（用 `scripts/e2e/reset.sh` 的 seed 當參考來源）

### 3.3 前端：`apps/admin/src/app/signup/page.tsx`

- 表單：商家名稱、姓名、email、密碼；成功後顯示「去收驗證信」
- `login/page.tsx` 加「免費試用 14 天」入口連結
- 樣式對齊現有 login page

### 3.4 推廣頁（landing page）

公開頁 `apps/admin/src/app/welcome/page.tsx`（2026-06-12 追加需求）：

- Hero：一句話價值主張 + 「免費試用 14 天」CTA（→ `/signup`）+ 登入連結
- 功能亮點：對齊實際模組 — 開團採購、訂單取貨、庫存/WMS、會員/錢包/點數、
  財務月結、多店權限
- 試用說明：免信用卡、全功能、到期資料保留、可一鍵刪除（呼應 Phase 3）
- 純靜態頁，無後端依賴；`/login`、`/signup` 互相連結
- 之後對外宣傳的入口統一用 `/welcome`（root `/` 仍是登入後 dashboard）

### 3.5 Email（前置作業）

Production SMTP 未設定 → 註冊驗證信寄不出去。需先在 Supabase dashboard 接 SMTP（Resend / SendGrid 擇一），
並改 confirmation email template（中文、品牌）。這是 Phase 1 的 **blocking 前置項**。

---

## 4. 租戶感知與試用期控管

### 4.1 前端拿租戶資訊

- 新 RPC `rpc_get_my_tenant()`：回傳 `{ id, name, status, trial_expires_at }`（依 JWT tenant_id）
- `apps/admin/src/lib/tenant.ts`：`getTenantName()` 改成 DB query（檔案註解本來就預留了），env 留作 fallback
- `AuthProvider` 登入後抓一次 tenant，放 context

### 4.2 試用 UI

- `status='trial'`：全站頂部 banner「試用期剩 N 天」
- `status='suspended'`（到期）：登入後只顯示「試用已到期」整頁畫面（聯絡轉正式 / 自助刪除資料），其餘路由擋掉
- 後端防線：到期不能只靠前端。最簡做法 — `_current_tenant_id()` 之外加一個
  `_assert_tenant_active()`，掛進**寫入類** RPC（讀取放行，方便回來看資料）；
  或在 `custom_access_token_hook` 注入 `tenant_status` claim + RLS 寫入 policy 檢查。
  Phase 2 二選一，建議前者（侵入小、好回退）。
  ⚠️ 改 `custom_access_token_hook` 前先 `grep -rn custom_access_token_hook supabase/migrations/`，基於最新版擴寫（CLAUDE.md 規則；目前只有 `20260424120000` 一支動過）。

### 4.3 到期排程

`pg_cron`（Supabase 內建）每日：

```sql
UPDATE tenants SET status='suspended'
 WHERE status='trial' AND trial_expires_at < now();
```

到期提醒信（前 3 天）為 nice-to-have，放 Phase 4。

---

## 5. 一鍵刪除整個 tenant（硬性需求）

### 5.1 核心：`rpc_purge_tenant(p_tenant_id UUID)`（SECURITY DEFINER, owner=postgres）

不手寫 100 張表的 DELETE，用 **動態 SQL 掃 catalog**，未來新表自動納入：

```sql
-- 偽碼
ASSERT tenants.status IN ('trial','suspended') AND NOT is_protected;  -- 雙保險
SET LOCAL session_replication_role = 'replica';  -- 同時關掉 append-only trigger 與 FK trigger
FOR r IN
  SELECT c.relname FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND a.attname='tenant_id' AND c.relkind='r'
LOOP
  EXECUTE format('DELETE FROM public.%I WHERE tenant_id = $1', r.relname) USING p_tenant_id;
END LOOP;
UPDATE tenants SET status='deleted', purged_at=now() WHERE id=p_tenant_id;
```

關鍵點：

- **append-only trigger 會擋 DELETE** → 用 `session_replication_role='replica'` 一次關掉
  （Supabase 的 `postgres` role 有被 GRANT 這個參數；實作時先在 trial project 驗證，
  不行就 fallback 成迴圈內 `ALTER TABLE ... DISABLE TRIGGER USER` / 完事 ENABLE）
- `replica` 也會停掉 FK enforcement → 不用煩惱 100 張表的刪除順序；但**整包必須在同一個 transaction**，
  要嘛全刪成功要嘛 rollback，不會留下斷頭 FK
- **沒有 tenant_id 的子表**（如 `customer_order_items` 若只掛 order_id）要另外處理：
  實作第一步先盤點 `有 FK 指向 tenant 表但自己沒有 tenant_id 欄位` 的表，
  在迴圈前用 JOIN 刪，或乾脆補 `tenant_id` 欄位（後者佳，順便補齊 RLS）
- 權限：`REVOKE ALL FROM authenticated/anon`，**只給 service_role**

### 5.2 包裝：edge function `tenant-purge`

兩個合法 caller，都走這支：

1. **試用者本人**：caller JWT `role='owner'` 且 `tenant_id` = 目標 tenant → 可刪自己（設定頁「刪除我的試用資料」按鈕，需輸入商家名稱確認）
2. **平台管理者**：帶 `PLATFORM_ADMIN_SECRET` header（edge function secret）→ 可刪任何非 protected tenant（清垃圾註冊用）

除 DB 外還要清：

- `auth.users`：`WHERE raw_app_meta_data->>'tenant_id' = ...` 逐一 `auth.admin.deleteUser()`
- Storage：`products` bucket 路徑**已是** `{tenant_id}/{uuid}.{ext}`（20260424120002），
  purge 直接按 prefix 刪；member-avatars 由 LINE 流程寫入（試用範圍外），同樣按 prefix best-effort
- 寫一筆刪除紀錄（誰、何時、刪了哪個 tenant、各表筆數）到平台層 log 表（無 tenant_id、不會被自己刪掉）

---

## 6. 分階段執行

| Phase | 內容 | 產出 |
|-------|------|------|
| **0. 租戶主檔** | `tenants` 表 + backfill 正式租戶 + `rpc_get_my_tenant` + `tenant.ts` 改 DB query | migration ×1、前端小改 |
| **1. 自助註冊** | SMTP 設定（前置）、`trial-signup` edge fn、`rpc_seed_trial_tenant`、`/signup` 頁、rate limit | edge fn ×1、migration ×1、頁面 ×1 |
| **2. 試用期控管** | trial banner、到期擋寫入（`_assert_tenant_active`）、pg_cron suspend | migration ×1、前端 |
| **3. 一鍵刪除** | storage 路徑 tenant 前綴（前置）、`rpc_purge_tenant`、`tenant-purge` edge fn、設定頁刪除按鈕 | migration ×1、edge fn ×1 |
| **4. 加值（可選）** | 到期提醒信、轉正式流程（status→active + 收費）、CAPTCHA、平台管理小後台 | — |

Phase 0–1 可先上（先能註冊試用），2–3 緊接著補（沒有 3 之前不要對外宣傳，垃圾資料會清不掉）。

---

## 7. 風險與待驗證清單

1. **RLS 多租戶實戰驗證**：現有 policy 都是單租戶環境下寫的，從沒被「第二個 tenant」打過。
   擴充 `TEST-E2E-T10-security-rls`：兩個 tenant 互讀互寫，全部要 deny。**這是同庫方案（1.1 A）的硬門檻。**
2. **單租戶假設殘留**：`DEFAULT_TENANT_ID` / `NEXT_PUBLIC_TENANT_NAME` 等 env、
   LINE channel secrets（per-tenant 的 LINE OA 試用租戶第一版直接不給，member app 不在試用範圍）、
   `product_code_autogen` / `member_no` 等序號是否 tenant-scoped — 逐一盤點。
3. **`session_replication_role` 權限**：Supabase managed Postgres 上要實測（見 5.1）。
4. **無 tenant_id 的子表盤點**（見 5.1 第三點）。
5. ~~Storage 檔案路徑無租戶前綴~~ → 已確認 products bucket 本來就是 `{tenant_id}/...`，無此問題。
6. **部署**：migration 一律走 Management API（CLAUDE.md 規則），不要戳 pooler TCP。

---

## 8. 明確不做（本期）

- Member app（LINE 會員端）的試用 — 試用範圍只有 admin ERP
- 線上金流 / 自動扣款轉正式 — 轉正式先走人工
- 試用 tenant 之間的資料匯入/匯出

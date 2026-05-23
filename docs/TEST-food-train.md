# food-train 測試項目 — 開團「美食列車」類別 + /shop 置頂專區 + 上架推播廣播

> **設計變更（2026-05-23）：** 美食列車最終定案為 **`close_type` 第 4 個值**
> (`regular`/`fast`/`limited`/`food_train`)，不再使用獨立的 `category` 欄位。
> 以下檢查項目若提到「category 欄位」或「p_category 參數」，請改讀為
> 「`close_type='food_train'` 篩選」。下方測試會在下個版本重整。

**對應 migration:** `supabase/migrations/20260626000000_food_train_category.sql`
**對應 RPC 變更:** `rpc_upsert_campaign` 不變（沿用 `p_close_type` 傳 `'food_train'`）
**對應 Edge Function 變更:** `supabase/functions/admin-notify/index.ts` 加 broadcast mode
**對應 liff-api 變更:** `list_active_campaigns` 加 category 回傳 + filter
**對應 UI 變更:**
- `apps/admin/src/components/CampaignForm.tsx`（類別下拉）
- `apps/admin/src/app/(protected)/campaigns/page.tsx`（badge + 篩選 + 觸發廣播）
- `apps/member/src/app/shop/page.tsx`（頂部 banner）
- `apps/member/src/app/shop/food-train/page.tsx`（新全列表頁）
- `apps/member/src/components/CampaignCard.tsx`（badge）

---

## 1. Schema / Migration 層

### 1.1 group_buy_campaigns.category 欄位
- [ ] 欄位存在、TEXT、NULL 可空、預設 NULL
  ```sql
  SELECT column_name, data_type, is_nullable, column_default
    FROM information_schema.columns
   WHERE table_name='group_buy_campaigns' AND column_name='category';
  -- 預期: category | text | YES | NULL
  ```
- [ ] CHECK constraint 限定值（NULL 或 'food_train'）
  ```sql
  SELECT conname, pg_get_constraintdef(oid)
    FROM pg_constraint
   WHERE conrelid='group_buy_campaigns'::regclass
     AND pg_get_constraintdef(oid) ILIKE '%category%';
  -- 預期含: CHECK (category IS NULL OR category IN ('food_train'))
  ```
- [ ] 既有 campaign 的 category 一律為 NULL（migration 不該回填）
  ```sql
  SELECT COUNT(*) FROM group_buy_campaigns WHERE category IS NOT NULL;
  -- migration 後預期: 0
  ```

### 1.2 rpc_upsert_campaign signature
- [ ] 新 signature 含 `p_category TEXT DEFAULT NULL`，舊版本若 OR REPLACE 同 in/out 維持
  ```sql
  SELECT pg_get_function_arguments(oid)
    FROM pg_proc WHERE proname='rpc_upsert_campaign';
  -- 應含 "p_category text default null"
  ```
- [ ] EXECUTE grant 維持給 authenticated
  ```sql
  SELECT has_function_privilege('authenticated',
    'rpc_upsert_campaign(bigint,text,text,text,text,text,timestamptz,timestamptz,timestamptz,integer,integer,text,text)',
    'EXECUTE');
  ```

---

## 2. RPC 行為（SQL 直測）

### 2.1 新建 food_train campaign
**情境：** 以 owner JWT 呼叫 `rpc_upsert_campaign(p_id:=NULL, p_category:='food_train', …)`
**預期：** row 寫入、`category='food_train'`、`status='draft'`、無 CHECK 例外。

### 2.2 新建 NULL category（向後相容）
**情境：** 呼叫 `rpc_upsert_campaign(…, p_category:=NULL)`（或不傳）
**預期：** row 寫入、`category IS NULL`、行為與既有完全一致。

### 2.3 CHECK constraint 拒絕無效值
**情境：** 直接 SQL `INSERT … category='kitchen_train'`
**預期：** 23514 check_violation。

### 2.4 編輯時不傳 p_category 維持原值（COALESCE）
**情境：** food_train campaign 存在 → 呼叫 `rpc_upsert_campaign(p_id:=X)`（其餘欄位）不帶 p_category
**預期：** category 維持 'food_train'，不被清成 NULL。

### 2.5 編輯時 p_category=NULL 顯式清除
**情境：** food_train campaign → 呼叫帶 `p_category:=NULL`
**預期：** 視 RPC 實作而定 — 若沿用 COALESCE 則維持原值（測這個分支）。決策：MVP 不支援「清除回 NULL」，僅可在新建時設定；測試應驗證「重編輯 NULL 不蓋掉」。

### 2.6 close_type 與 category 正交
**情境：** 建立 `close_type='fast' + category='food_train'`
**預期：** 同時存在；/shop 該團應同時出現在限時專區 hero 與美食列車區塊（前端兩處都看到）。

### 2.7 跨 tenant 隔離
**情境：** tenant A 建 food_train、tenant B 呼叫 listActiveCampaigns
**預期：** B 看不到 A 的 food_train（RLS / tenant_id 過濾）。

### 2.8 listActiveCampaigns 回傳 category
**情境：** liff-api action='list_active_campaigns'
**預期：** 每個 campaign payload 含 `category` 欄位（值為 NULL 或 'food_train'）。

### 2.9 listActiveCampaigns 用 category 篩選
**情境：** liff-api action='list_active_campaigns', `category:='food_train'`
**預期：** 只回 category='food_train' 的 open 團，其他被濾掉。

---

## 3. admin-notify broadcast mode（Edge Function 直測）

### 3.1 broadcast=true 全 tenant 廣播
**情境：** POST admin-notify `{ broadcast:true, title:'美食列車新團', message:'XXX 開團了', url:'/shop/food-train' }`，tenant 內有 3 個 member、皆有 push subscription、皆 no_new_order=false
**預期：** `notifications` 表新增 3 筆、每筆 member_id 對應；webpush 送 3 筆、回傳 `{ ok:true, sent:3 }`。

### 3.2 broadcast 排除 no_new_order=true
**情境：** 3 個 member 中 1 個 `no_new_order=true`
**預期：** `notifications` 新增 2 筆、push 送 2 筆；不通知的那位 notifications 表查不到本次新 row。

### 3.3 broadcast 排除 status≠'active'
**情境：** 1 個 member status='inactive' 或 GDPR 軟刪
**預期：** 不寫 notifications、不送 push。

### 3.4 broadcast 對 0 push subscription 也 ok
**情境：** 某 member 已寫 notifications 但無 push_subscriptions row
**預期：** notifications 仍新增、push 該 member 跳過、整體 200、`sent` 計數不含該員、無 5xx。

### 3.5 既有 single-member 模式不受影響
**情境：** POST `{ member_id: X, title, message }`（無 broadcast 欄位）
**預期：** 行為與 PR #257 取貨通知一致；`pickup notify` 既有流程仍綠。

### 3.6 broadcast 需 hq / owner / admin role
**情境：** 以 store_clerk JWT 呼叫 broadcast
**預期：** 401/403 拒絕；不寫 notifications、不送 push。

### 3.7 verify_jwt 設定確認
- [ ] config.toml `[functions.admin-notify]` 維持預設（或顯式 verify_jwt=true）；admin 走 supabase session JWT 呼叫
- [ ] member 端 LIFF 不能呼叫此函式（前端應無此呼叫路徑）

---

## 4. Admin UI 行為（preview 互動）

### 4.1 CampaignForm「類別」下拉
- [ ] `/campaigns` → 「新增開團」modal 開啟，類別下拉 render，選項：「無」/「美食列車」
- [ ] 預設值為「無」（NULL）
- [ ] 選「美食列車」後儲存 → DB `category='food_train'`
- [ ] 編輯既有 food_train campaign → 下拉回顯「美食列車」
- [ ] 編輯既有 NULL campaign → 下拉回顯「無」

### 4.2 列表頁 badge
- [ ] `/campaigns` 列表，food_train 列顯示綠色（或品牌色）「美食列車」badge
- [ ] NULL category 列不顯示 badge（不能誤渲染空 badge）
- [ ] 月曆 / 週曆視圖（如已存在）也帶 badge

### 4.3 列表頁類別篩選
- [ ] 篩選器加「類別」維度（全部 / 美食列車 / 一般）
- [ ] 篩選「美食列車」→ 只剩 food_train 列

### 4.4 儲存觸發廣播
- [ ] 新建 food_train 並直接 status='open' → 儲存後 admin-notify broadcast 被呼叫一次
  - [ ] 觀察 Network panel 有 POST `/functions/v1/admin-notify` 200
  - [ ] `notifications` 表收到對應筆數
- [ ] draft → open 編輯儲存（food_train）→ 觸發廣播一次
- [ ] 已 open 的 food_train 再次儲存（其他欄位變更）→ **不**再觸發廣播
- [ ] 非 food_train（NULL category）的 draft → open 儲存 → **不**觸發廣播
- [ ] 廣播失敗（網路/權限）→ UI 顯示警告但不阻擋儲存成功（避免儲存失敗丟資料）

### 4.5 跨頁 regression
- [ ] 編輯 regular / fast / limited 既有團（皆 NULL category），下拉維持「無」、儲存後其餘欄位不變

---

## 5. Member /shop UI

### 5.1 /shop 頂部「美食列車」banner
- [ ] 有 ≥1 個 open + food_train → banner 渲染
- [ ] banner 在「限時專區」banner **之上**
- [ ] banner 樣式（綠或品牌色，與限時專區可分辨）
- [ ] 點 banner → 導向 `/shop/food-train`
- [ ] 0 個 food_train open → banner **不**渲染
- [ ] 同時有 fast + food_train → 兩個 banner 都顯示

### 5.2 /shop/food-train 全列表頁
- [ ] 頁面渲染（PageShell title="美食列車"）
- [ ] 列表只顯示 category='food_train' 且 status='open'
- [ ] 空狀態文案（仿 /shop/flash）
- [ ] 列表項目樣式（hero + row，或同 /shop/flash pattern）
- [ ] 點商品卡 → 進 `/shop/c/[id]` 詳情頁

### 5.3 CampaignCard food_train badge
- [ ] grid variant 顯示 badge
- [ ] hero variant 顯示 badge
- [ ] NULL category 不顯示

### 5.4 推播落地（顧客端）
- [ ] 觸發 broadcast 後，顧客 `/notifications` 出現該筆
- [ ] 點通知 → 跳轉 `/shop/food-train`
- [ ] PWA 已訂閱推播 → 收到系統通知（iOS PWA 16.4+ 測，依 [[reference_ios_pwa_push_gotchas]]）

---

## 6. Regression

- [ ] `/shop` 限時專區 banner 仍正常（無 food_train 時不被新邏輯影響）
- [ ] `/shop/flash` 頁面仍綠
- [ ] 既有 regular / fast / limited campaign 編輯保存後 category 一律維持 NULL
- [ ] `rpc_upsert_campaign` 既有所有呼叫處（finalize、rpc_schedule_candidate、restock）皆能不傳 p_category 正常編譯與執行
- [ ] admin-notify 取貨通知（apps/admin/src/app/(protected)/pickup/page.tsx）single member 模式 send=1 仍綠
- [ ] CampaignThumb / CampaignOrdersPanel 不受 category 影響

---

## 7. RLS / 顧客可讀

- [ ] anon JWT（或 liff-api 走 service_role 後過濾 tenant）能 select category
  ```sql
  SET LOCAL ROLE anon;
  SET LOCAL request.jwt.claims = '{"tenant_id":"<T>"}';
  SELECT id, category FROM group_buy_campaigns LIMIT 1;
  ```
- [ ] 跨 tenant 仍被 RLS 擋

---

## 驗收門檻

全部 §1-§7 勾完、**無 console error**、**Supabase prod SQL 套用成功**、**admin build + tsc 過**、**run-feature-tests 報告全綠** 才可標 done。

**Out of scope（未來再做）：**
- 推播排程（指定時間發）
- 多個 category 值（如 生鮮 / 衣物）— 本期僅 food_train 一值
- broadcast 取消按鈕 / 補發按鈕
- 美食列車「限定商品」或專屬定價規則

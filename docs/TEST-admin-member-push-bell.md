# admin-member-push-bell 測試項目 — 後台會員列表顯示「已安裝 App 並開啟通知」鈴鐺

**對應 migration:** `supabase/migrations/20260619000010_rpc_members_with_push.sql`（新增 SECURITY DEFINER RPC）
**對應 UI 變更:** `apps/admin/src/app/(protected)/members/page.tsx`
**對應背景:** `supabase/migrations/20260520000000_web_push_subscriptions.sql`（push_subscriptions + RLS：member 自己 / role='hq'）、`20260603000000_push_subs_unique_per_member.sql`（UNIQUE(tenant_id, member_id)）

> 重點：admin JWT role 非 `'hq'` → 直接 `select from push_subscriptions` 會被 RLS 靜默回 0 列（同 reference_admin_jwt_role_null 模式）。故必走 SECURITY DEFINER RPC。鈴鐺語意 = 該 member 有 push_subscriptions（一筆，因 PWA 安裝 + 授權通知 + 訂閱才會產生）。

## 1. Schema / Migration 層

### 1.1 RPC signature
- [ ] `rpc_members_with_push(p_member_ids BIGINT[])` 存在、回傳 member_id 集合
  ```sql
  SELECT proname, prosecdef, pg_get_function_identity_arguments(oid)
    FROM pg_proc WHERE proname = 'rpc_members_with_push';
  ```
- [ ] `prosecdef = true`（SECURITY DEFINER）
- [ ] 有 `GRANT EXECUTE ... TO authenticated`
  ```sql
  SELECT grantee, privilege_type FROM information_schema.routine_privileges
   WHERE routine_name = 'rpc_members_with_push';
  ```
- [ ] tenant 來源固定（JWT / `_current_tenant_id()`），參數不含 tenant，呼叫端無法跨租戶撈

### 1.2 既有結構未動
- [ ] `push_subscriptions` 表、RLS policy（push_subs_self_all / push_subs_hq_all）、UNIQUE(tenant_id, member_id) 皆未被本 migration 變更
  ```sql
  SELECT polname FROM pg_policy WHERE polrelid = 'push_subscriptions'::regclass;
  ```

## 2. RPC 行為（SQL 直測）

### 2.1 有訂閱的 member 會被回傳
**情境：** tenant T 內 member A 有一筆 push_subscriptions；呼叫 `rpc_members_with_push(ARRAY[A])`
**預期：** 結果含 A

### 2.2 沒訂閱的 member 不回傳
**情境：** member B 無 push_subscriptions；`rpc_members_with_push(ARRAY[B])`
**預期：** 結果不含 B（空）

### 2.3 混合輸入只回有訂閱者
**情境：** `rpc_members_with_push(ARRAY[A,B,C])`，僅 A、C 有訂閱
**預期：** 結果恰為 {A,C}，無重複（UNIQUE 保證每 member ≤1 列）

### 2.4 空陣列
**情境：** `rpc_members_with_push(ARRAY[]::bigint[])`
**預期：** 回空、無錯

### 2.5 不存在的 member id
**情境：** 傳入從未存在的 id（如 99999999）
**預期：** 忽略、無錯、不在結果

### 2.6 跨 tenant 不外洩（關鍵）
**情境：** 以 tenant T 身分呼叫，傳入屬於 tenant T2 且 T2 有訂閱的 member id
**預期：** 不回傳該 id（RPC 內以呼叫端 tenant 過濾）

### 2.7 admin 角色（role 非 'hq' / 可能 NULL）仍取得正確結果（本功能存在理由）
**情境：** 以後台 admin 使用者 JWT（role 非 'hq'）呼叫 RPC，對象 member 有訂閱
**預期：** 正常回傳該 member（SECURITY DEFINER 繞過 push_subscriptions RLS）；對照：同帳號直接 `select from push_subscriptions` 得 0 列

### 2.8 大量 id
**情境：** 傳入 ~200 個 member id（含部分有訂閱）
**預期：** 正確回傳子集、無逾時（idx_push_subs_member 命中）

## 3. UI 行為（preview 互動）

### 3.1 列表掛載
- [ ] `/members` 正常載入、**無 console error**
- [ ] 既有欄位（編號/姓名/取貨店/手機/訂單數/未取貨金額/儲值/時間）顯示如常

### 3.2 鈴鐺顯示
- [ ] 已知有訂閱的 member 該列姓名旁出現 🔔，hover/title 為「已安裝 App 並開啟通知」
- [ ] 無訂閱的 member 該列**無** 🔔
- [ ] 同列同時為樂樂匯入者：🔔 與「樂樂」badge 並存不重疊、不破版

### 3.3 分頁 / 搜尋 / 排序後仍正確
- [ ] 翻到第 2 頁：該頁 member 的 🔔 依該頁 id 重新查詢、正確
- [ ] 搜尋過濾後：結果列的 🔔 對應正確 member
- [ ] 切換排序：🔔 跟著該 member 列、不串列

### 3.4 失敗降級
- [ ] RPC 回空 / 失敗時：列表照常渲染（只是無 🔔），不報錯、不白頁

## 4. Regression
- [ ] 會員列表既有功能：關鍵字搜尋、門市篩選、各欄排序、分頁、顯示已合併/已刪除 toggle 全部不受影響
- [ ] 訂單數 / 未取貨金額 / 儲值 三個既有批次查詢結果不變（新增的 push 查詢不干擾既有 Promise 群）
- [ ] 會員明細 modal、編輯、新增 不受影響
- [ ] member app `/me` #285 那顆鈴鐺與推播訂閱流程 **完全不動**（本功能僅新增後台唯讀 RPC，未碰 rpc_upsert_push_subscription / 寫入路徑）
- [ ] 其他 SELECT push_subscriptions 的地方（推播發送）行為不變

## 5. 驗收門檻

全部 §1–§4 勾完、**無 console error**、**Supabase dev push 成功**、**build + type-check 過** 才可標 done。
（沙箱限制：本機 docker / admin live preview 受阻時，§2 改以使用者貼 Supabase Studio 跑、§3 由使用者自審；agent 負責 tsc/build + 碼審 + 產驗證 SQL。）

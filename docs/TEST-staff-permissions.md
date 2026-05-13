# 員工權限管理測試項目 — Staff Permissions v1

**對應 migration（待建）：** `supabase/migrations/2026MMDDxxxx_staff_permissions.sql`
**對應 UI 變更（待建）：**
- `apps/admin/src/app/(protected)/staff/page.tsx`（新頁面）
- `apps/admin/src/components/RoleChip.tsx`（共用 chip）
- 側欄選單加「員工管理」入口

**對應 PRD / ADR：**
- `docs/decisions/2026-04-23-系統立場-混合型.md`（看得到 ≠ 管得到）

**參考實作：** `rpc_get_staff_names` @ `supabase/migrations/20260428170000_*.sql`（既有 SECURITY DEFINER 操作 auth.users 的 pattern）

---

## v1 範圍

✅ **做**：列出員工、改 role、綁 store(s)、停用/啟用、防鎖死
❌ **不做**（v2+）：邀請新員工（要 Edge Function + service_role）、自建 staff 表、離職紀錄、操作日誌

---

## Role 清單（既有，不擴增）

| Role | 等級 | 用途 |
|---|---|---|
| `owner` | 最高 | 系統擁有人，可改任何人 |
| `admin` | HQ 系統管理 | 同 owner 但不能 demote owner |
| `hq_manager` | HQ 經理 | 全 tenant 讀寫，不能管員工 |
| `hq_accountant` | HQ 會計 | 財務模組讀寫 |
| `purchaser` | 採購 | 採購模組 |
| `assistant` | HQ 助理 | 低權限 HQ |
| `store_manager` | 店長 | 自己店訂單 / 員工 |
| `store_staff` | 店員 | 自己店唯讀 |

---

## 1. Schema / Migration 層

### 1.1 無新表
- [ ] 不新增任何表；沿用 `auth.users` + `auth.users.raw_app_meta_data` JSONB
- [ ] `raw_app_meta_data` 內含 keys：`tenant_id`, `role`, `stores`（陣列 of store_id BIGINT 或 store name TEXT —— 看既有 useDefaultStoreFromUser 用什麼）
  ```sql
  SELECT raw_app_meta_data
    FROM auth.users
   WHERE email = 'cktalex@gmail.com';
  ```
- [ ] 加新 key `disabled` (boolean) — 用於停用：登入仍可，但 RLS / RPC 反 disable=true 阻擋

### 1.2 RPC signatures
- [ ] `rpc_list_staff() RETURNS TABLE (...)` — SECURITY DEFINER + 全 tenant 過濾
- [ ] `rpc_update_staff_role(p_user_id UUID, p_role TEXT) RETURNS BOOLEAN`
- [ ] `rpc_update_staff_stores(p_user_id UUID, p_store_ids BIGINT[]) RETURNS BOOLEAN`
- [ ] `rpc_set_staff_disabled(p_user_id UUID, p_disabled BOOLEAN) RETURNS BOOLEAN`
- [ ] 全部 GRANT EXECUTE TO authenticated；但內部驗 `caller role IN ('owner','admin')` 否則 RAISE

### 1.3 安全規則（caller 驗證）
- [ ] caller role 必須 IN ('owner','admin')，否則 RAISE
- [ ] **owner 不能 demote 自己**（防鎖死）
- [ ] **owner 不能 disable 自己**
- [ ] admin 不能 promote 自己 為 owner
- [ ] admin 不能 demote owner

---

## 2. RPC 行為（SQL 直測）

### 2.1 `rpc_list_staff` happy path
**情境：** owner 呼叫
**預期：** 回傳該 tenant 全部 user：`{ user_id, email, display_name, role, stores, disabled, created_at, last_sign_in_at }`

### 2.2 `rpc_list_staff` 非 admin reject
**情境：** store_manager 呼叫
**預期：** RAISE EXCEPTION 'permission denied'

### 2.3 `rpc_list_staff` 跨 tenant 隔離
**情境：** tenant A admin 呼叫
**預期：** 只回傳 tenant_id = A 的 users；tenant B 的 0 row

### 2.4 `rpc_update_staff_role` happy
**情境：** owner 改 Alice 從 store_manager → hq_manager
**預期：** auth.users.raw_app_meta_data.role 更新；回傳 true

### 2.5 `rpc_update_staff_role` 防鎖死 — owner self demote
**情境：** owner 改自己 role 為 store_staff
**預期：** RAISE EXCEPTION 'owner cannot demote self'

### 2.6 `rpc_update_staff_role` admin 不能 promote owner
**情境：** admin 把 Alice 改成 owner
**預期：** RAISE EXCEPTION 'admin cannot grant owner role'

### 2.7 `rpc_update_staff_role` admin 不能 demote owner
**情境：** admin 改 owner Bob → admin
**預期：** RAISE EXCEPTION 'admin cannot modify owner'

### 2.8 `rpc_update_staff_role` 跨 tenant reject
**情境：** tenant A owner 對 tenant B 的 user 改 role
**預期：** RAISE EXCEPTION 'user not in tenant'

### 2.9 `rpc_update_staff_role` 非法 role reject
**情境：** owner 改成 role='superhero'
**預期：** RAISE EXCEPTION 'invalid role'

### 2.10 `rpc_update_staff_stores` happy
**情境：** owner 設 Alice stores = [1, 3, 5]
**預期：** raw_app_meta_data.stores = [1,3,5]；對 store_id 存在性檢查

### 2.11 `rpc_update_staff_stores` 含不存在 store_id
**情境：** stores = [1, 9999]
**預期：** RAISE EXCEPTION 'store 9999 not in tenant'

### 2.12 `rpc_set_staff_disabled` happy
**情境：** owner 把 Bob disabled = true
**預期：** raw_app_meta_data.disabled = true；Bob 下次 RLS 檢查 disabled 被擋（HQ 表 / store 表都不可見）

### 2.13 `rpc_set_staff_disabled` 防鎖死 — owner self disable
**情境：** owner disable 自己
**預期：** RAISE EXCEPTION 'owner cannot disable self'

### 2.14 既有 RLS 對 disabled user 處理
**情境：** disabled=true 的 user 嘗試讀 customer_orders
**預期：** 0 rows（RLS policies 統一加 `AND COALESCE((auth.jwt() -> 'app_metadata' ->> 'disabled')::boolean, false) = false`）
- 注意：本 PR 範圍 **不**改既有 RLS 加 disabled 檢查（會碰太多 policy），改用「停用 = 改 role='disabled'」軟刪除 簡化（status 改 role 'none'）

**MVP 簡化方案**：不用 disabled flag，改用「設 role=`disabled` 的特殊值」：
- raw_app_meta_data.role = 'disabled' 時 RLS 都 fail（既有 role IN (...) 不含 'disabled'）
- 對應 staff 列表顯示「已停用」chip
- 重啟用 = 改回原 role

### 2.15 JWT 重整
**情境：** owner 改 Alice role 後，Alice 已登入 session
**預期：** Alice 既有 JWT 仍是舊 role（JWT 不會自動 refresh）；下次 refresh / re-login 才生效
- 不在 RPC 強制 logout（會 break session）
- UI 顯示提示「需重新登入才會生效」

---

## 3. UI 行為（preview 互動）

### 3.1 `/staff` 頁面 mount
- [ ] 路由載入無 console error
- [ ] 標題「員工管理」可見
- [ ] 非 owner/admin caller 看到「沒有權限」+ 跳轉 `/`

### 3.2 列表
- [ ] Table 顯示：email / display_name / role chip / stores chip / 最後登入 / 狀態 chip
- [ ] role chip 顏色：owner=紫 / admin=藍 / hq_*=綠 / store_*=琥珀 / disabled=灰
- [ ] 自己 row 加「（你）」標示

### 3.3 改 role
- [ ] row 內「改 role」按鈕 → 開 modal
- [ ] role 下拉只列出 caller 能授予的 role（admin 看不到 owner）
- [ ] 確認後 toast「需重新登入才生效」

### 3.4 改 stores
- [ ] row 內「改取貨店」按鈕 → 開 modal
- [ ] 多選 checkbox 列出 active stores
- [ ] HQ role（owner/admin/hq_*）的 store 設定可選但不影響存取（HQ 全見）
- [ ] store_manager / store_staff 必須選 ≥ 1 店

### 3.5 停用 / 啟用
- [ ] 「停用」按鈕（紅）→ 二次確認「停用後該員工將無法登入後台」→ 改 role='disabled'
- [ ] 自己 row 沒有「停用」按鈕（防鎖死）
- [ ] disabled user row 改顯示「啟用」按鈕，可選原 role 回復

### 3.6 視覺一致
- [ ] 用既有 Table / Modal / SpinButton
- [ ] role chip 是新元件 `RoleChip.tsx`

### 3.7 側欄選單入口
- [ ] 「分店業務 ▾」或新分組「設定 ▾」加「員工管理」link
- [ ] 只 owner/admin 看得到該 link（其他 role 隱藏）

---

## 4. Regression

- [ ] 既有 `useRole()` hook 不變
- [ ] 既有 `useDefaultStoreFromUser` 邏輯不受影響
- [ ] 既有 `rpc_get_staff_names` 不被改 signature
- [ ] 既有 RLS policies 不改（disabled 用 role='disabled' 達成）
- [ ] cktalex 既有 owner session 仍可正常 access 所有頁面
- [ ] 改完 role 後 admin user 重 login，新權限正確生效

---

## 5. 驗收門檻

§1-§4 全綠 + **無 console error** + **`supabase db push` 成功** + **`pnpm --filter admin build` 過** + **用第二個 dev user (e.g. store_manager test 帳號) 驗 reject 流程** 才可標 done.

---

## 6. v2+ 範圍備忘（不在本 PR 內）

- 邀請新員工（Edge Function + service_role 建 auth.users）
- 自建 `staff_members` 表（員工編號 / 部門 / 入職日 / 離職紀錄）
- 操作日誌（誰在何時改了誰的 role）
- 細粒度權限（per-feature toggle 而非 role-based）

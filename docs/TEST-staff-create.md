# staff-create 測試項目 — 員工管理「新增員工」

**對應 Edge Function:** `supabase/functions/staff-create/index.ts`（新增）
**對應 UI 變更:** `apps/admin/src/app/(protected)/staff/page.tsx`（新增「新增員工」按鈕 + `CreateStaffModal`）
**對應 PRD / 決策:** `docs/decisions/2026-04-23-系統立場-混合型.md`；解除 `20260613000150_staff_permissions.sql` 標註的 *v1 不做：邀請新員工*
**無 SQL migration**：沿用 `auth.users` + `raw_app_meta_data`，service_role 直驗 `stores` 表。

> 說明：建立 staff 必須用 service_role（Auth Admin API），無法做成 client RPC，故無 §1 Schema/§2 SQL-RPC，改為 §1 Edge Function 合約 + §2 Edge Function 行為。

## 1. Edge Function 合約

- [ ] 函式 `staff-create` 已部署；`supabase/config.toml` **無** `[functions.staff-create]` 區塊（沿用 `verify_jwt = true` 預設，與 `admin-notify` 一致）
- [ ] 只需內建 secret `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`，未新增其他 secret
- [ ] `OPTIONS` 回 CORS（`_shared/cors.ts`）；非 `POST` 回 405
- [ ] 缺 `Authorization` header → 401
- [ ] Request body：`{ email, display_name, role, stores: string[] }`
- [ ] 成功 response：`{ ok: true, user_id, email, temp_password }`，HTTP 200
- [ ] service_role key 僅存在於函式端，**不**出現在任何 client bundle / response（除 `temp_password` 外）/ log

## 2. Edge Function 行為

### 2.1 caller 未認證 / 非授權
**情境：** 無 token、或一般 `store_staff`、或 `app_metadata` 無 `tenant_id` 的帳號呼叫
**預期：** 分別回 401 / 403；不建立任何 auth user

### 2.2 owner 建立一般員工（happy path）
**情境：** owner 帶合法 `email`、`display_name`、`role='store_manager'`、`stores=['平鎮店']`
**預期：** 回 200 + `temp_password`；`auth.users` 新增一筆，`raw_app_meta_data` 含 `tenant_id`(=caller tenant)、`role`、`stores`，`raw_user_meta_data.display_name` 正確，`email_confirmed_at` 非空

### 2.3 admin 建立一般員工
**情境：** admin（非 owner）建立 `role='hq_accountant'`
**預期：** 成功，tenant 同 caller

### 2.4 角色升權防護（admin 不可建 owner）
**情境：** admin caller 帶 `role='owner'`
**預期：** 403（對齊 `rpc_update_staff_role`「admin cannot grant owner」），不建立帳號

### 2.5 owner 可建 owner
**情境：** owner caller 帶 `role='owner'`
**預期：** 成功

### 2.6 非法 role
**情境：** `role='superuser'`（不在合法集）或 `role='disabled'`（不可用建立方式產生停用帳號）
**預期：** 400/422，不建立帳號

### 2.7 store 名稱驗證
**情境一：** `stores=['不存在的店']` → 預期 reject，不建立
**情境二：** `stores=['總倉']`（magic value）→ 預期允許
**情境三：** `stores=[]` 或未帶 → 預期允許（空綁定）
**情境四：** 帶其他 tenant 的 store 名稱 → 預期 reject（tenant 隔離）

### 2.8 Email 重複
**情境：** `email` 已存在於 `auth.users`
**預期：** 回 409 + 可讀訊息（如「此 Email 已有帳號」），不覆寫既有帳號

### 2.9 Email 格式 / 必填
**情境：** 缺 `email`、空 `display_name`、`email` 非 email 格式
**預期：** 400，不建立帳號

### 2.10 tenant 注入防護
**情境：** body 夾帶 `tenant_id` 試圖指定其他 tenant
**預期：** 一律以 caller 的 `app_metadata.tenant_id` 為準（body 的 tenant 被忽略）

### 2.11 自訂密碼（password 選填）
**情境一：** body 帶 `password='MyPass123'`（≥6 碼）
**預期：** 成功；回應 `password_source='admin'` 且 **不含** `temp_password`；該帳號可用此密碼登入
**情境二：** body 不帶 `password` 或 `password=''`
**預期：** 成功；回應 `password_source='generated'` + `temp_password`（沿用舊行為）
**情境三：** body 帶 `password='abc'`（<6 碼）
**預期：** 422「密碼至少 6 碼」，不建立帳號
**情境四：** `password` 含前後空白（如 `' a b 12 '`）
**預期：** 不被 trim，原樣作為密碼（長度以原字串計）

## 3. UI 行為（preview 互動）

### 3.1 入口與權限
- [ ] `/staff` 以 owner/admin 登入：header 出現「新增員工」按鈕
- [ ] 過時副標題（「需先由 Supabase Dashboard 建立」）已更新為新流程描述
- [ ] 非 owner/admin 仍被 `router.replace("/")` 導離（沿用既有 `canManage` 防線）

### 3.2 CreateStaffModal 欄位
- [ ] 點「新增員工」開 modal，欄位齊全：Email、顯示名、角色 select、綁定店（含「總倉」）
- [ ] 角色 select 不含 `disabled`
- [ ] caller 為 admin 時角色 select **不含** `owner`；caller 為 owner 時 **含** `owner`（沿用 `RoleModal` grantable 邏輯）
- [ ] 綁定店 checkbox 沿用 `StoresModal` 樣式（總倉 + stores 兩欄格）

### 3.3 送出 happy path
- [ ] 填妥 → 送出 → 成功面板顯示一次性臨時密碼，可一鍵複製，文案標明「只顯示一次」
- [ ] 關閉成功面板 → 清單 reload，新員工出現（email/顯示名/角色/綁定店正確、建立時間為今天）
- [ ] 用該 Email + 臨時密碼可登入 admin（`last_sign_in_at` 後續會更新）

### 3.4 送出 validation / 錯誤
- [ ] Email 空 / 顯示名空 → 前端擋或函式回錯，錯誤訊息顯示於 modal
- [ ] 重複 Email → modal 顯示「此 Email 已有帳號」類訊息，不關閉、不 reload
- [ ] 送出中 SpinButton 轉圈、無「送出中…」文字（沿用 `feedback_loading_spinner_no_text`）

### 3.5 密碼欄（選填）
- [ ] modal 有「密碼」欄，placeholder 提示「留空＝系統自動產生」
- [ ] 留空送出 → 成功面板顯示一次性臨時密碼（可複製、標「只顯示這一次」）
- [ ] 自訂 ≥6 碼送出 → 成功面板**不顯示密碼**，改顯示「請用你剛剛設定的密碼通知對方」
- [ ] 自訂 <6 碼 → modal 內顯示「密碼至少 6 碼」，不送出
- [ ] 自訂密碼建立後，用該 Email + 自訂密碼可登入 admin

## 4. Regression

- [ ] `rpc_list_staff` 清單仍正常載入、排序（owner→…→disabled）不變
- [ ] 既有「改角色」Modal 正常（含 admin 不能改 owner、不能改自己）
- [ ] 既有「綁店」Modal 正常（`rpc_update_staff_stores` TEXT[]）
- [ ] 既有「停用 / 啟用」正常
- [ ] `admin-notify` 等其他 Edge Function 未受影響（共用 `_shared/cors.ts` 未改）
- [ ] `staff/page.tsx` 其餘排版（DataTable、RoleChip）未跑版；dark mode 正常
- [ ] admin build / type-check 通過；無 console error

## 5. 驗收門檻

全部 §1–§4 勾完、**無 console error**、**Edge Function 部署成功**、**admin build + type-check 過** 才可標 done。
（執行階段需 owner/admin session + 已部署函式；sandbox 受限項目由使用者於實機驗證。）

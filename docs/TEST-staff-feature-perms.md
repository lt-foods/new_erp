# 員工功能權限 v1 — 訂單樞紐「檢視所有門市」個別授權

**對應 migration：** `supabase/migrations/20260803000000_staff_feature_perms.sql`
**對應 UI：**
- `apps/admin/src/lib/staffPerms.ts`（新檔：perm 清單 + JWT 讀取 hook）
- `apps/admin/src/app/(protected)/staff/page.tsx`（員工列表加「功能權限」欄 + modal）
- `apps/admin/src/app/(protected)/orders/pivot/page.tsx`（分店鎖可被權限解除）
- `apps/admin/src/lib/useDefaultStoreFromUser.ts`（加 `enabled` 參數）

**背景：** 樞紐表原本只有 HQ 帳號看得到全部門市欄位，分店帳號一律鎖自己店。
需要讓「特定分店同仁」也看得到全部店，但不想把他升成 HQ 帳號（會連帶開放
商品 / 採購 / 總倉收件匣等頁面）。→ role 之外加一層可個別授予的功能權限。

---

## 設計

- 權限存在 `auth.users.raw_app_meta_data.perms`（JSON 字串陣列），與既有 `role` / `stores` 同一個地方。
- v1 只有一個 key：`orders_pivot_all_stores`。
- 授予者：owner / admin，在 `/staff` → 該員工列的「功能權限」。
- **改完該員工要重新登入（或 token refresh）才會進 JWT 生效** — 與改 role / 綁店一致。

---

## 1. RPC 層

### 1.1 `_is_valid_staff_perm`
- [x] `_is_valid_staff_perm('orders_pivot_all_stores')` → true
- [x] `_is_valid_staff_perm('nope')` → false

### 1.2 `rpc_update_staff_perms(p_user_id, p_perms)`
- [ ] owner 對分店員工設 `['orders_pivot_all_stores']` → `raw_app_meta_data.perms` 更新、回 true
- [ ] 傳 `[]` → 收回全部功能權限（key 仍在，值為 `[]`）
- [ ] 傳重複值 / 空字串 → 自動去重去空白後寫入
- [ ] 傳白名單外的 key → `RAISE EXCEPTION 'invalid perm: %'`
- [ ] 非 owner/admin caller → `permission denied: requires owner/admin role`
- [ ] 跨 tenant 的 user_id → `user % not in tenant`
- [ ] admin 改 owner → `admin cannot modify owner`

### 1.3 `rpc_list_staff`
- [x] 回傳多一個 `perms JSONB` 欄位（`TABLE(user_id, email, display_name, role, stores, perms, disabled, created_at, last_sign_in_at)`）
- [ ] 沒設過 perms 的舊帳號 → 回 `[]` 而非 null
- [ ] 其餘欄位 / 排序 / owner-admin gate 與改版前一致（regression）

### 1.4 `_jwt_has_perm`
- [ ] 給日後在 RPC / RLS 加 server-side gate 用；v1 前端自行讀 JWT，沒有呼叫點
- [ ] `perms` 不是陣列（舊帳號 / 髒資料）→ 回 false 不報錯

---

## 2. UI — `/staff`

- [x] 列表多一欄「功能權限」，有授權者顯示藍色 chip「訂單樞紐：檢視所有門市」，無則「—」
- [x] 每列多一顆「功能權限」按鈕 → 開 modal，標題 `功能權限 — <email>`
- [x] modal checkbox 依該員現況預設勾選
- [x] 取消勾選後儲存 → 送出 `rpc_update_staff_perms { p_user_id, p_perms: [] }`
- [ ] 非 owner/admin 進不了 `/staff`（既有行為，未改）

## 3. UI — `/orders/pivot`

| 帳號 | 預期 |
|---|---|
| HQ（stores 含「總倉」或未綁店） | 全部門市下拉（未改變） |
| 分店帳號 · 未授權 | 顯示 `🏬 <店名> (僅本店)` 鎖定 chip、無下拉 |
| 分店帳號 · 已授權 | 顯示門市下拉、預設「全部取貨店」、可自由切換 |

- [x] 未授權：鎖定 chip 出現、下拉不存在（Playwright fixture 驗證）
- [x] 已授權：下拉出現且選項為「全部取貨店 / 各分店」，預設值為空（＝全部）
- [x] 兩種情況都無 console error
- [ ] 授權者切到單店後，篩選結果只剩該店（localStorage 會記住上次選擇）

## 4. Regression

- [x] `useDefaultStoreFromUser` 新增的 `enabled` 參數有預設值 `true` → 其餘 8 個呼叫點行為不變
- [x] `useUserBranchStoreId` 本身沒改 → 訂單列表 / 庫存 / 盤點 / 收貨等頁面的分店鎖不受影響
- [x] `apps/admin` typecheck + `next build` 通過；eslint 無新增問題
- [ ] 沒有功能權限的分店帳號，其他頁面權限完全不變

---

## 5. 之後要加新的細粒度權限時

1. migration 在 `_is_valid_staff_perm` 白名單加 key
2. `apps/admin/src/lib/staffPerms.ts` 的 `ALL_STAFF_PERMS` 加一筆（key / label / desc）
3. 要 server-side 擋的話，在對應 RPC / RLS 用 `_jwt_has_perm('<key>')`

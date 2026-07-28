# orders-edit 測試項目 — /orders 改售價 + 加備註

**對應 migration:**
- `supabase/migrations/20260605000000_orders_discount_widen_and_check.sql`
- `supabase/migrations/20260605000001_customer_order_audit_log.sql`
- `supabase/migrations/20260605000002_rpc_edit_order_price_and_notes.sql`

**對應 UI 變更:**
- `apps/admin/src/components/OrderDetail.tsx`
- `apps/admin/src/components/OrderAuditDrawer.tsx`（新）
- `apps/admin/src/app/(protected)/pickup/print/page.tsx`
- `apps/admin/src/app/(protected)/pickup/print-list/page.tsx`
- `apps/admin/src/app/(protected)/pickup/page.tsx`
- `apps/admin/src/components/PickupDialog.tsx`

**對應 plan:** `C:\Users\Alex\.claude\plans\zazzy-mapping-starfish.md`

---

## 1. Schema / Migration 層

### 1.1 customer_orders.discount_amount 變更
- [ ] `discount_amount` 型別已是 `NUMERIC(18,4)`
  ```sql
  SELECT data_type, numeric_precision, numeric_scale
    FROM information_schema.columns
   WHERE table_name='customer_orders' AND column_name='discount_amount';
  -- expect: numeric, 18, 4
  ```
- [ ] CHECK constraint `customer_orders_discount_amount_nonneg` 存在
  ```sql
  SELECT conname, pg_get_constraintdef(oid)
    FROM pg_constraint
   WHERE conrelid='customer_orders'::regclass
     AND conname='customer_orders_discount_amount_nonneg';
  ```
- [ ] 既有 row 沒被破壞（migration 不能讓現有資料失敗）
  ```sql
  SELECT count(*) FROM customer_orders WHERE discount_amount < 0;  -- expect 0
  ```

### 1.2 customer_order_audit_log 表
- [ ] 表存在且欄位齊全
  ```sql
  SELECT column_name, data_type, is_nullable
    FROM information_schema.columns
   WHERE table_name='customer_order_audit_log'
   ORDER BY ordinal_position;
  -- expect: id bigint, tenant_id uuid, order_id bigint, entity_type text,
  --         entity_id bigint nullable, field text, before_value jsonb,
  --         after_value jsonb, edit_reason text nullable,
  --         operator_id uuid, created_at timestamptz
  ```
- [ ] CHECK constraint：`entity_type IN ('order','item')` + `field IN ('unit_price','item_notes','discount_amount','order_notes')`
- [ ] FK：`order_id REFERENCES customer_orders(id) ON DELETE CASCADE`
- [ ] Index：`(tenant_id, order_id, created_at DESC)` + `(order_id, entity_type, entity_id)`
  ```sql
  SELECT indexname, indexdef FROM pg_indexes
   WHERE tablename='customer_order_audit_log';
  ```
- [ ] RLS 已啟用且只有 SELECT policy（無 INSERT/UPDATE/DELETE policy）
  ```sql
  SELECT polname, polcmd FROM pg_policy
   WHERE polrelid='customer_order_audit_log'::regclass;
  -- expect only 'r' (SELECT) policies
  ```
- [ ] `forbid_append_only_mutation` trigger 在表上
  ```sql
  SELECT tgname FROM pg_trigger
   WHERE tgrelid='customer_order_audit_log'::regclass
     AND NOT tgisinternal;
  ```

### 1.3 RPC signatures
- [ ] `_check_order_edit_perm(BIGINT)` 存在、SECURITY DEFINER、回傳 customer_orders
- [ ] `rpc_update_order_item_price(BIGINT, BIGINT, NUMERIC, UUID, TEXT)` 存在
- [ ] `rpc_update_order_discount(BIGINT, NUMERIC, UUID, TEXT)` 存在
- [ ] `rpc_update_order_notes(BIGINT, TEXT, UUID, TEXT)` 存在
- [ ] `rpc_update_order_item_notes(BIGINT, BIGINT, TEXT, UUID, TEXT)` 存在
- [ ] 4 個 public RPC 都 GRANT EXECUTE TO authenticated；helper 沒 grant
  ```sql
  SELECT proname, prosecdef, pg_get_function_arguments(oid)
    FROM pg_proc
   WHERE proname IN ('_check_order_edit_perm','rpc_update_order_item_price',
                     'rpc_update_order_discount','rpc_update_order_notes',
                     'rpc_update_order_item_notes');
  ```

---

## 2. RPC 行為（SQL 直測）

### 2.1 rpc_update_order_item_price — happy path
**情境：** HQ 帳號改某 item 的 unit_price 從 100 → 90
**預期：**
- `customer_order_items.unit_price = 90`、`updated_by = operator`、`updated_at` 更新
- `customer_order_audit_log` 多一筆：`entity_type='item', entity_id=<item>, field='unit_price', before_value=100, after_value=90, operator_id=<operator>`

### 2.2 rpc_update_order_item_price — no-op
**情境：** new 值 = 舊值
**預期：** 不更新主表 `updated_at`、**不寫 audit log**、不報錯，回傳目前 row

### 2.3 rpc_update_order_item_price — 負值拒絕
**情境：** `p_new_unit_price = -1`
**預期：** RAISE EXCEPTION `unit_price must be >= 0`，主表與 audit log 都沒動

### 2.4 rpc_update_order_item_price — item 不屬於 order
**情境：** `p_item_id` 屬於別張 order
**預期：** RAISE EXCEPTION `item % not in order %`

### 2.5 rpc_update_order_discount — happy path
**情境：** HQ 改 discount_amount 0 → 50
**預期：** `customer_orders.discount_amount = 50`，audit log `field='discount_amount', before=0, after=50`

### 2.6 rpc_update_order_discount — CHECK 拒絕負值
**情境：** `p_new_discount = -1`
**預期：** RAISE EXCEPTION（RPC 主動檢查 + DB CHECK 雙保險）

### 2.7 rpc_update_order_notes — null 與空字串
- [ ] `p_new_notes = NULL` → 寫入 NULL，audit log `after_value = null`
- [ ] `p_new_notes = ''` → 寫入空字串，audit log `after_value = ""`

### 2.8 rpc_update_order_item_notes — happy path
**情境：** 從 NULL → "客人現金付清"
**預期：** item.notes 更新；audit `field='item_notes', before=null, after='客人現金付清'`

### 2.9 權限矩陣（同一張 order，pickup_store_id=A）
> 用三組 JWT 分別跑：HQ admin / store-A user / store-B user

| 角色 | 4 個 RPC | 預期 |
|---|---|---|
| HQ owner / admin / hq_manager | 全部 | 成功 |
| role NULL（admin tier 慣例） | 全部 | 成功 |
| store-A user (`store_id`=A) | 全部 | 成功 |
| store-B user (`store_id`=B) | 全部 | RAISE `permission denied` |
| 無 role 無 store_id | 全部 | RAISE `permission denied` |

- [ ] HQ admin 全部過
- [ ] role NULL 全部過
- [ ] store-A 全部過
- [ ] store-B 全部被拒
- [ ] 跨 tenant：HQ-tenant1 對 tenant2 訂單 → RAISE `order % not found`

### 2.10 並發鎖
**情境：** 同 item 兩個 session 同時改 unit_price
**預期：** 第二個 session 等第一個 commit 後讀到新值；兩筆 audit log 都在；無 lost update

### 2.11 Audit log append-only
- [ ] 直接 `UPDATE customer_order_audit_log SET ...` → 報錯（trigger）
- [ ] 直接 `DELETE FROM customer_order_audit_log` → 報錯（trigger）
- [ ] 認證 user 直接 `INSERT INTO customer_order_audit_log` → 失敗（無 INSERT policy）

---

## 3. UI 行為（preview 互動）

### 3.1 OrderDetail — header 編輯
**路徑：** `/orders` → 點任一訂單列 → OrderDetail 開啟
- [ ] 開啟 OrderDetail 無 console error
- [ ] 看到「整單折扣」與「單頭備註」欄位
- [ ] 應收金額顯示三行：原始小計 / − 整單折扣 / = 應收
- [ ] 點折扣欄 → 變 input → 輸入 50 → blur → 折扣顯示 50、應收金額 = 小計 − 50
- [ ] reload 頁面後折扣仍是 50
- [ ] 點折扣欄 → 輸入 -1 → blur → alert 錯誤訊息、值回到原本
- [ ] 點折扣欄 → 輸入 0 → blur → 應收金額 = 小計
- [ ] 點單頭備註 → 輸入 "test note" → blur → 顯示更新；reload 還在
- [ ] Esc 取消編輯（不打 RPC、值還原）

### 3.2 OrderDetail — line item 編輯
- [ ] 商品 table 多一欄「備註」
- [ ] 點 unit_price → 輸入 90 → blur → cell 顯示 90、小計 / 應收同步重算
- [ ] 點 unit_price → 輸入 -5 → blur → alert 錯、值還原
- [ ] 點 item.notes → 輸入文字 → blur → 顯示更新
- [ ] 同一輪改多個 item 都各自獨立 RPC，不互相干擾

### 3.3 OrderAuditDrawer
- [ ] 動作列有「查看編輯歷史」按鈕
- [ ] 點開 drawer，列出剛剛的編輯（時間 desc），每筆顯示：時間 / 欄位中文名 / before → after / 操作人姓名 / reason（若有）
- [ ] 沒有編輯的訂單 → drawer 顯示「尚無編輯紀錄」
- [ ] 操作人 UUID 解析為姓名（透過 `rpc_get_staff_names`）

### 3.4 店家權限 UI
- [ ] 店家帳號（store_id=A）開自店訂單 → 4 個欄位都可編輯
- [ ] 店家帳號開**他店**訂單 → 4 個欄位純文字、無 input
- [ ] HQ 帳號開任何店訂單 → 全部可編輯

### 3.5 Pickup 列印金額對齊
**前置：** 找一張 discount_amount > 0 的訂單
- [ ] `/pickup/print/<order>` 列印小白單顯示「折扣 -X」、總額 = 小計 − 折扣
- [ ] `/pickup/print-list` 列表合計含折扣
- [ ] `/pickup` 主頁訂單列「金額」顯示扣折扣後
- [ ] PickupDialog 顯示的 `totalAmount` 已扣折扣

---

## 3.6 店長店員編輯備註（2026-07-28 `20260728000000_order_notes_store_edit.sql`）

> 備註 RPC 權限自 `_check_order_edit_perm`（認 `store_id`，實際 staff 帳號沒有此欄）
> 改為 `_check_order_edit_notes_perm`（認 `app_metadata.stores[]` 店名，同 qty 編輯）。
> §2.9 / §3.4 的 store_id 矩陣對備註兩支 RPC 已不適用，以下取代：

| 角色 | rpc_update_order_notes / rpc_update_order_item_notes | 預期 |
|---|---|---|
| HQ owner / admin / hq_manager / hq_accountant / role NULL | 兩支 | 成功 |
| stores[] 含 '總倉' | 兩支 | 成功 |
| store_manager / store_staff，stores[] 含訂單取貨店名 | 兩支 | 成功 |
| store_manager / store_staff，stores[] 不含訂單取貨店名 | 兩支 | RAISE `permission denied` |
| 單價 / 折扣 4 支 RPC | 權限不變 | 店長店員仍被拒 |

- [ ] 店長帳號開自店訂單 → 單頭備註 + 品項備註可點擊編輯、儲存後 reload 還在
- [ ] 店員帳號開自店訂單 → 同上
- [ ] 店長/店員開**他店**訂單 → 備註純文字、無 input
- [ ] 店長/店員開自店訂單 → 單價、折扣欄仍唯讀
- [ ] 備註修改寫入 audit log，店家帳號在「查看編輯歷史」看得到

---

## 4. Regression

- [ ] LIFF `/orders/:id` 顧客端的 `payable_amount` 仍正確（直接讀 `v_customer_order_summary` 不應壞）
- [ ] LIFF `OrderCard.tsx` / `SettlementCard.tsx` 的應付金額仍對得起 admin
- [ ] `rpc_record_pickup` 仍可正常執行（不依賴金額計算）
- [ ] 既有訂單列表 `/orders` 篩選 / 排序 / 分頁 不受影響
- [ ] 訂單轉手 (`rpc_create_offset_order`) 仍能執行（已知限制：事後改價不會回灌 offset 訂單，預期）
- [ ] 商品 / 候選池 / 其他模組 build 過、type-check 過

---

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功**、**build + type-check 過** 才可標 done。

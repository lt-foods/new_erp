# 訂單 qty 編輯 測試項目

**對應 migration:** `supabase/migrations/20260624000000_order_item_qty_edit.sql`

**對應 UI:**
- `apps/admin/src/components/OrderDetail.tsx`(qty cell 改為 inline editable + saveAllDraft 新增 qty 分支)
- `apps/admin/src/lib/rpcError.ts`(新增 qty / campaign closed 的中文翻譯)

**對應 PRD:** `docs/PRD-訂單取貨模組.md`(待確認訂單可改數量)

---

## 1. 設計重點

1. **店家可改自家 pending 訂單 qty** — 沿用 `_check_order_edit_perm` helper(HQ 全部 / 店家限自家 pickup_store_id)
2. **加單緩衝期** — `rpc_create_customer_orders` 從 `status='open'` 放寬為 `status IN ('open','closed')`,讓 closed 階段(App 已隱藏)HQ/店家仍可補加單
3. **PR 鎖定後不能再改** — 訂單 status 變 confirmed 後 RPC 直接擋(Stage 4 PR RPC 自動推進到 confirmed)
4. **qty > 0** — 配合 schema `CHECK (qty > 0)`,刪品項不在本 scope
5. **稽核** — 寫 `customer_order_audit_log`,no-op 不寫

---

## 2. RPC 行為(SQL 直測複核語意)

### 2.1 rpc_create_customer_orders 放寬閘

**前置:** 一個 closed 狀態的 campaign,有對應 channel + member

**情境 A:** 加單到 closed campaign
- 直接呼叫 `rpc_create_customer_orders(campaign_id, channel_id, [{...}])`
- **預期:** 成功,訂單 status='pending' 建立

**情境 B:** 加單到 locked campaign
- **預期:** RAISE `campaign X is locked; only open/closed campaigns accept manual entry`
- UI 翻譯顯示「此團狀態為「已鎖定」,僅「開團中」或「已收單」可以加單。」

**情境 C:** 加單到 cancelled / draft campaign
- **預期:** 同上 RAISE

### 2.2 rpc_update_order_item_qty 主流程

**前置:** 一張 pending 訂單,品項 qty=3

#### Case 2.2.1: HQ 改自家訂單
- HQ user(role IN owner/admin/hq_manager/role NULL)
- Call `rpc_update_order_item_qty(order_id, item_id, 5, op, '客人加碼')`
- **預期:**
  - 成功,回傳 row.qty=5
  - `customer_order_items.qty` 變 5
  - `customer_order_audit_log` 多一筆:`entity_type='item', field='qty', before_value=3, after_value=5, edit_reason='客人加碼'`

#### Case 2.2.2: 店家改自家(同 pickup_store_id)
- 店家 user(role NOT IN HQ tier,但 jwt.store_id 等於 order.pickup_store_id)
- **預期:** 同上,成功

#### Case 2.2.3: 店家改他店
- 店家 user,jwt.store_id ≠ order.pickup_store_id
- **預期:** RAISE `permission denied: role=store_manager store=X cannot edit order Y`

#### Case 2.2.4: 訂單已 confirmed
- 訂單 status='confirmed'(或任何非 pending)
- **預期:** RAISE `訂單狀態為 confirmed,僅 待確認 訂單可改數量`
- UI 翻譯顯示「訂單狀態為「已確認」,僅「待確認」訂單可改數量。」

#### Case 2.2.5: qty=0 或負數
- p_new_qty=0(或 -1)
- **預期:** RAISE `qty must be > 0`
- UI 翻譯顯示「數量必須大於 0(如需刪除品項請聯絡總部)」

#### Case 2.2.6: qty=null
- p_new_qty=null
- **預期:** 同 2.2.5

#### Case 2.2.7: item 不屬於 order
- p_item_id 屬於別張訂單
- **預期:** RAISE `item X not in order Y`

#### Case 2.2.8: no-op(舊值=新值)
- 訂單 qty=3,p_new_qty=3
- **預期:** 成功(不報錯),回傳 row,但 `customer_order_audit_log` **不寫新紀錄**

#### Case 2.2.9: 跨 tenant
- order_id 屬於 tenant A,JWT 是 tenant B
- **預期:** RAISE `order X not found in tenant Y`

---

## 3. UI(`/orders/<id>` 或 hq inbox / pivot OrderDetail drawer)

### 3.1 qty cell 互動

#### Case 3.1.1: pending + canEdit(HQ 或店家自家)
- 進入 OrderDetail,品項列 qty 欄位
- **預期:** 顯示為可點擊的 inline number 編輯框

#### Case 3.1.2: pending 但無權限
- 進入 OrderDetail,head.status='pending' 但 canEdit=false(其他店店家)
- **預期:** qty 顯示為純文字,不可編輯

#### Case 3.1.3: 非 pending(confirmed/shipping/ready/...)
- **預期:** qty 顯示為純文字,不可編輯(因為 `canEditQty = canEdit && head.status === "pending"`)

### 3.2 編輯流程

#### Case 3.2.1: 改 qty + 存檔
- pending 訂單,點 qty 5→7,離開焦點
- 編輯區出現黃色 dirty 提示
- 按「儲存」
- **預期:**
  - 成功 alert 或無錯誤
  - 列表 qty 變 7
  - 小計重算
  - audit log 多一筆

#### Case 3.2.2: 改 qty=0 或負
- 輸入 0,按存檔
- **預期:** 跳錯「數量必須大於 0(如需刪除品項請聯絡總部)」

#### Case 3.2.3: 同時改 qty + 單價(同一品項)
- pending 訂單,改 qty 3→5 + 改單價 100→90
- 按存檔
- **預期:** 兩支 RPC 各被呼叫一次,audit log 兩筆(qty + unit_price)

#### Case 3.2.4: 改 qty 在 confirmed 訂單
- 在已 confirmed 訂單,qty cell **不應該顯示為可編輯**(canEditQty=false)
- 若繞過 UI 直接呼叫 RPC → 跳「訂單狀態為「已確認」,僅「待確認」訂單可改數量。」

### 3.3 加單緩衝期(closed 階段)

#### Case 3.3.1: closed campaign 走加單頁
- campaign.status='closed'(已結團,App 隱藏)
- 進入 `/campaigns/order-entry?id=<closed_campaign>`
- 加單流程能完成
- **預期:** 訂單成功建立,status='pending'

---

## 4. 與其他流程的相依性

| 上游 | 行為 |
|------|------|
| `_check_order_edit_perm` | 沿用,跟其他 edit RPC 用同一個 helper(`20260605000002:10-48`) |
| Stage 2 `confirmed_at` 修復 | 不直接相關,但完成後手動 confirm 也會寫 confirmed_at |
| Stage 4 PR 自動 confirm | 完成後 pending→confirmed,本 RPC 直接擋,符合預期 |

| 下游 | 行為 |
|------|------|
| `OrderAuditDrawer` | 自動顯示新 `field='qty'` 的稽核紀錄(不需改) |
| `customer_orders.updated_at` | 由 trigger `trg_touch_corders` 自動更新 |

---

## 5. 回歸風險

- 既有 rpc_update_order_item_price / notes / discount **不受影響**(共用 helper,獨立 update column)
- 既有 rpc_create_customer_orders **行為微變**:closed 階段也可加單,但顧客 LIFF 不會看到 closed 團,所以對顧客流程無感
- 沒有 schema 變動(只 CREATE OR REPLACE 既有函式 + 新增一支)

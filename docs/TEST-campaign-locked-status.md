# 開團 locked 狀態 + PR 自動鎖團 測試項目

**對應 migration:**
- `supabase/migrations/20260623000000_campaign_status_locked.sql` (Stage 2:加 locked + RLS + 3 個 RPC/view 加白名單)
- `supabase/migrations/20260625000000_pr_create_lock_campaign_and_orders.sql` (Stage 4:PR 建立時自動鎖團 + auto-confirm)

**對應 UI:** `apps/admin/src/components/OrderDetail.tsx` (confirmed 訂單 qty 顯示 🔒)

**對應 PRD:** `docs/PRD-採購模組.md`(請購單建立後鎖定需求)

---

## 1. 設計重點

1. **PR 建立瞬間連動兩件事**(原子操作):
   - 把該 close_date 下所有 `closed` campaigns → `locked`
   - 把那些 campaigns 下的所有 `pending` 訂單 → `confirmed`、寫稽核 `auto-confirmed by PR #N`
2. **觸發點明確**:只有 `rpc_create_pr_from_close_date` 跟 `rpc_append_campaign_to_pr` 兩條路。`rpc_approve_restock_to_pr`(補貨單)**不**觸發,因為訂單不在 pending。
3. **不影響 LIFF**:顧客 App 只 SELECT `status='open'`,locked / confirmed 都看不到。
4. **店家 RLS**:Stage 2 已加 locked 進 `gbc_store_read` 白名單,locked campaign 對店家可見。

---

## 2. RPC 行為(SQL 直測)

### 2.1 rpc_create_pr_from_close_date 主流程

**前置:**
- 一個 close_date(例 `2026-07-01`)有 2 個 `closed` campaigns
- 各 campaign 下有 pending 訂單若干、有 cancelled 訂單若干、有 1-2 個已被 HQ 手動 confirm 的訂單

#### Case 2.1.1: 基本流程
- Call `rpc_create_pr_from_close_date('2026-07-01', '<operator>')`
- **預期:**
  - 回傳 v_pr_id
  - `purchase_requests` 多一筆 (status='draft')
  - `purchase_request_items` 多筆(per SKU 加總)
  - `purchase_request_campaigns` join 表多 2 筆(兩個 campaign 都 link 到此 PR)
  - **兩個 campaigns 都從 `closed` → `locked`**
  - **所有 pending 訂單都從 `pending` → `confirmed`、`confirmed_at` 填上、`updated_by=operator`**
  - `customer_order_audit_log` 多 N 筆(每張被推進的訂單一筆):
    - `entity_type='order', entity_id=NULL, field='status'`
    - `before_value='"pending"', after_value='"confirmed"'`
    - `edit_reason='auto-confirmed by PR #<v_pr_id>'`
    - `operator_id=<operator>`
  - **已被 HQ 手動 confirm 的訂單跳過**(因為 helper 用 `WHERE status='pending'` 過濾)
  - **cancelled / expired / transferred_out 訂單跳過**

#### Case 2.1.2: 沒有 closed campaign
- p_close_date 上無 closed campaign
- **預期:** RAISE `no closed campaigns on date %`

#### Case 2.1.3: 有 closed campaign 但無訂單
- **預期:** RAISE `no orders to aggregate for close_date %`

### 2.2 rpc_append_campaign_to_pr

**前置:** 一張 draft PR(source_close_date='2026-07-01')、另一個同 close_date 的 closed campaign 還沒被併入

#### Case 2.2.1: 追加 campaign
- Call `rpc_append_campaign_to_pr(pr_id, append_campaign_id, '<op>')`
- **預期:**
  - `purchase_request_items` 對應 SKU qty 累加 / 新增
  - `purchase_request_campaigns` 多一筆 (pr_id, append_campaign_id)
  - **該 campaign 從 `closed` → `locked`**
  - **該 campaign 下的 pending 訂單推進到 confirmed,寫 audit log**
  - 已被 create_pr_from_close_date 鎖過的其他 campaign 不受影響(維持 locked)

#### Case 2.2.2: 追加 locked campaign(已被另一張 PR 鎖過)
- 該 campaign 目前 status='locked'(別張 PR 已鎖)
- **預期:** RAISE `campaign % not in closed status (current: locked)`(維持原守衛)

#### Case 2.2.3: PR 不是 draft
- PR 已 submitted / fully_ordered
- **預期:** RAISE `PR % is not in draft status`

### 2.3 _lock_orders_after_pr_aggregation helper 直測

#### Case 2.3.1: 空陣列
- Call `_lock_orders_after_pr_aggregation('{}', '<op>', 999)`
- **預期:** 回傳 0,無副作用

#### Case 2.3.2: 跨 tenant 安全
- p_campaign_ids 包含他 tenant 的 campaign
- **預期:** 該 campaign 的訂單**不**被推進(WHERE tenant_id = current_tenant 過濾掉)

#### Case 2.3.3: 已 confirmed 訂單跳過
- 訂單 status='confirmed'
- **預期:** 跳過,不重複寫 audit log

---

## 3. UI 行為

### 3.1 開團列表 `/campaigns`
- locked campaign 在 filter dropdown 出現「已鎖定」選項
- Badge 顯示 rose 色「已鎖定」
- 可結算按鈕對 locked campaign 顯示(rpc_finalize_campaign 允許從 locked)
- 發 FB 按鈕對 locked campaign 顯示(維持業務連續性)
- 批次操作按鈕**不**讓選 locked target(rpc_bulk_set_campaign_status 故意不擴充)

### 3.2 訂單詳情 `/orders/<id>` 或 inbox drawer

#### Case 3.2.1: pending + canEdit
- qty 顯示為可編輯輸入框
- 改完按存檔 → 成功

#### Case 3.2.2: confirmed + canEdit(被 PR 鎖定後)
- qty 顯示為 `<數字> 🔒` + hover tooltip「已被請購單鎖定,如需調整請聯絡總部」
- 不可編輯

#### Case 3.2.3: 其他終態(shipping / ready / completed / ...)
- qty 顯示為純數字(沒 🔒,因為不是被 PR 鎖,是流程已進下游)

### 3.3 加單流程

#### Case 3.3.1: locked campaign 嘗試加單
- `/campaigns/order-entry` 選 locked campaign
- 試圖 call `rpc_create_customer_orders`
- **預期:** RAISE `campaign % is locked; only open/closed campaigns accept manual entry`
- UI 翻譯:「此團狀態為「已鎖定」,僅「開團中」或「已收單」可以加單。」

---

## 4. e2e 完整情境

### 情境 A:完整流程
1. 建一個 open campaign,放 2 筆顧客訂單(各 1 個 SKU,qty=3)
2. `rpc_close_campaign(campaign_id, op)` → campaign 變 closed,訂單仍 pending
3. 店家進 OrderDetail 改其中一筆 qty 從 3 → 5
   - 看到 OrderAuditDrawer 多一筆 `field='qty', before=3, after=5`
4. `rpc_create_pr_from_close_date(close_date, op)` → 看到:
   - campaign 變 locked、UI 顯示 rose 色 badge
   - 兩筆訂單 status 都變 confirmed、confirmed_at 都有時間
   - OrderAuditDrawer 各多一筆 `field='status', reason='auto-confirmed by PR #N'`
   - purchase_request_items 反映改後 qty(其中一個 SKU 是 5 不是 3)
5. 嘗試再改 qty → 跳「訂單狀態為「已確認」,僅「待確認」訂單可改數量。」
6. 嘗試對該 campaign 加單 → 跳「此團狀態為「已鎖定」,僅「開團中」或「已收單」可以加單。」

### 情境 B:多 campaign 同日
1. 建 2 個 open campaigns 同 close_date,各放 1 筆訂單
2. 結團 campaign A → A 變 closed
3. 結團 campaign B → B 變 closed
4. `rpc_create_pr_from_close_date` → A 跟 B 都變 locked、所有訂單都 confirmed
5. PR 內 SKU 是 A+B 的加總(per SKU 合併)

### 情境 C:緩衝期補加單
1. campaign 已 closed(App 已隱藏),店家發現有客人漏單
2. 店家在 `/campaigns/order-entry` 選 closed campaign 加單成功(Stage 3 放寬閘)
3. HQ 還沒開 PR,訂單可在 OrderDetail 改 qty
4. HQ 開 PR → 該補的訂單也一起被推進到 confirmed

### 情境 D:已先手動 confirm
1. pending 訂單 → HQ 手動點「→ 已確認」(`rpc_advance_order_status`)→ confirmed
2. HQ 開 PR → 該訂單**已**在 confirmed,helper 用 `WHERE status='pending'` 跳過,不重複寫 audit log
3. PR 內仍包含該訂單的 SKU(因為 PR 彙總是看 `co.status NOT IN cancelled/expired/transferred_out`,confirmed 不被排除)

### 情境 E:回歸補貨流程(不應觸發)
1. 從 hq inbox 把 shortage 補貨單轉成 PR(`rpc_approve_restock_to_pr`)
2. **預期:** 該 PR 建立成功,但**不**觸發 lock+auto-confirm(因為走的是 restock 路徑,訂單不在 pending)
3. 補貨單對應的 campaigns 維持原狀,不被誤鎖

---

## 5. 回歸風險

| 風險點 | 緩解 |
|--------|------|
| audit log CHECK constraint 擴充影響既有寫入 | 只是放寬,不會擋掉既有 field 值 |
| `_lock_orders_after_pr_aggregation` 同時鎖多訂單可能 deadlock | 用 `FOR UPDATE` + 順序 id ascending(預設行為),deadlock 風險低 |
| 一個 campaign 在 helper 跑完前 race condition 加新訂單 | helper 在 RPC 末段執行,前面已把 campaign 推到 locked,new order RPC 會被 status 閘擋下 |
| confirmed_at 既有 NULL 訂單 | Stage 2 已修 rpc_advance_order_status;Stage 4 helper 在 INSERT 時補上,雙路徑一致 |
| Stage 3 / Stage 4 migration 應用順序 | 20260624 → 20260625,Stage 3 寫 field='qty' 在 Stage 4 擴充 CHECK 後才實際被允許寫;production 部署兩支一起跑,中間不會有窗口期 |

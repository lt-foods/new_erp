# campaign-resync 測試項目 — 開團「重新同步商品/價格」按鈕 + RPC

**對應 migration:** `20260620000010_rpc_resync_campaign_from_product.sql`（#299，原 HQ gate）＋ `20260620000020_rpc_resync_campaign_admin_only.sql`（權限收緊為僅管理員，CREATE OR REPLACE）— 兩支都要套用，prod 以 20 為準
**對應 UI 變更:** `apps/admin/src/components/CampaignItemsTable.tsx`、`apps/admin/src/components/CampaignForm.tsx`、`apps/admin/src/lib/role.ts`（新增 `isAdmin`）
**背景:** 開團後 `campaign_items` 價格被 `locked_at` 鎖定、零售價變動不再 sync；忘記輸入售價時訂單會以 $0 快照成立。本功能提供**管理員**手動重新同步開團名稱/價格、並回填「待確認」訂單。

---

## 1. Schema / Migration 層

### 1.1 RPC signature
- [ ] `rpc_resync_campaign_from_product(BIGINT, BOOLEAN, UUID)` 存在、`prosecdef = true`（SECURITY DEFINER）、`proconfig` 含 `search_path=public`
  ```sql
  select proname, prosecdef, proconfig,
         pg_get_function_arguments(oid) args, pg_get_function_result(oid) ret
    from pg_proc where proname='rpc_resync_campaign_from_product';
  ```
  預期：1 列、`prosecdef=t`、args `p_campaign_id bigint, p_dry_run boolean DEFAULT true, p_operator uuid DEFAULT NULL`、ret `jsonb`
- [ ] `GRANT EXECUTE ... TO authenticated` 已下
  ```sql
  select grantee, privilege_type from information_schema.routine_privileges
   where routine_name='rpc_resync_campaign_from_product';
  ```
- [ ] migration 重跑冪等（`CREATE OR REPLACE FUNCTION`）— 連續 apply 兩次不報錯

### 1.2 不新增表 / 欄位
- [ ] 本 migration 只 `CREATE OR REPLACE FUNCTION` + `GRANT`，無 `ALTER TABLE` / `CREATE TABLE`（稽核沿用既有 `customer_order_audit_log`）

---

## 2. RPC 行為（SQL 直測）

> 測試前置：找一個 `status='open'` 且 `product_id` 有值的開團，準備 (a) 1 個 active SKU 有零售價 (b) 該團數筆 `status='pending'` 訂單（含 unit_price=0 與非 0 各一）(c) 1 筆 `status='confirmed'` 訂單 (d) 1 筆 `status='cancelled'` 訂單。

### 2.1 dry_run 預覽不寫入
**情境：** `p_dry_run=true` 呼叫。
**預期：** 回傳 JSONB 含 `dry_run=true`、`name_before/name_after`、`items[]`（每 SKU `sku_code/old_price/new_price`）、`pending_orders`、`pending_order_lines`、待確認訂單 `amount_before/amount_after`；呼叫後 `campaign_items`、`customer_order_items`、`group_buy_campaigns.name`、`customer_order_audit_log` **完全沒有變動**。

### 2.2 實跑：開團名稱同步
**情境：** product.name 與 campaign.name 不同，`p_dry_run=false`。
**預期：** `group_buy_campaigns.name` = products.name、`updated_at` 更新；回傳 `name_changed=true`。

### 2.3 實跑：campaign_items 重新定價
**情境：** campaign_items.unit_price 與現行零售價不同（含 =0 與非 0）。
**預期：** 該 active SKU 的 `campaign_items.unit_price` = 現行零售價、`updated_at` 更新；`locked_at` **不變**（不解鎖、不被阻擋）；回傳 `items_repriced` 計數正確。

### 2.4 實跑：補缺漏 active SKU
**情境：** product 底下有 active SKU 尚未在 campaign_items。
**預期：** 新增 campaign_items 列（unit_price=現行零售價、sort_order=999）；已存在的不重複（ON CONFLICT DO NOTHING）；回傳 `skus_added` 計數。

### 2.5 實跑：待確認訂單明細回填（含非 0 覆蓋）
**情境：** 該團 `status='pending'` 訂單，明細 unit_price 有 =0 也有非 0（與新售價不同）。
**預期：** 兩者皆被改為現行零售價；每筆變動寫一列 `customer_order_audit_log`（entity_type='item'、field='unit_price'、before/after 正確、operator_id 非 NULL、edit_reason 非空）；回傳 `pending_order_lines_updated`、`pending_orders_affected` 正確。

### 2.6 不動非待確認訂單
**情境：** 同團存在 `confirmed` / `completed` / `cancelled` / `reserved` / `ready` 訂單，明細 unit_price 為舊值。
**預期：** 這些訂單明細 unit_price **完全不變**、無對應 audit log。

### 2.7 守門：active SKU 無有效零售價 → 拒跑
**情境：** 該團某 active SKU 無 `prices(scope='retail', effective_to IS NULL)` 或解析價 ≤ 0。
**預期：** `RAISE EXCEPTION`（訊息含缺價 SKU 數/代碼）；整個交易 rollback，**campaign_items / 訂單 / 名稱 / audit 皆無變動**（dry_run 與實跑都要擋）。

### 2.8 守門：開團狀態限制
**情境：** campaign.status ∈ {closed, ordered, receiving, ready, completed, cancelled}。
**預期：** `RAISE EXCEPTION`「只有草稿/開團中…（目前為 X）」；無任何變動。draft / open 才放行。

### 2.9 權限：僅管理員（owner/admin）放行，其餘拒絕
**情境：** 分別以 role = `store_manager`／`hq_manager`／`hq_accountant`／`assistant` 呼叫；再以 `owner`／`admin`／`''`(NULL) 呼叫。
**預期：** 前四者皆 `RAISE EXCEPTION`「權限不足：僅管理員可重新同步開團」（**hq_manager/hq_accountant 也要被擋**，與舊 HQ gate 不同）；owner/admin/NULL（dev admin）放行。

### 2.10 租戶隔離
**情境：** `p_campaign_id` 屬於別 tenant。
**預期：** `RAISE EXCEPTION` campaign not found in tenant；無變動。

### 2.11 product_id 為 NULL 的舊團
**情境：** campaign.product_id IS NULL。
**預期：** 不做名稱同步、不補 SKU，但仍正常重新定價既有 campaign_items 與待確認訂單；不報錯。

### 2.12 冪等
**情境：** 連續實跑兩次。
**預期：** 第二次 `items_repriced=0`、`pending_order_lines_updated=0`、`name_changed=false`、不再寫 audit log（值相同即跳過）。

---

## 3. UI 行為（preview 互動 — 留使用者自審）

> Admin live-preview 沙箱被網路阻擋（見 memory），UI 項目以程式碼審查 + build/type-check 為主，實際點擊互動交付使用者在 prod/本機自審。

### 3.1 按鈕顯示條件
- [ ] 編輯開團 Modal 內 `CampaignItemsTable` 出現「重新同步商品/價格」按鈕
- [ ] 僅 `status ∈ {draft, open}` **且 `isAdmin(role)`（owner/admin/'' ）** 才顯示
- [ ] 非管理員（hq_manager / hq_accountant / store_*）登入：按鈕**不顯示**
- [ ] role 尚未載入（`useRole()` 回 null）時按鈕**不顯示**（fail-closed、不閃現）
- [ ] `🔒 已鎖定` 標記同時存在時，按鈕仍可按（locked_at 不阻擋）

### 3.1b CampaignForm 儲存按鈕（同 admin gate）
- [ ] 管理員：編輯開團 Modal 內「儲存」/「建立開團」按鈕正常顯示可存
- [ ] 非管理員：submit 按鈕**不顯示**、改顯示「僅管理員可儲存開團」、取消鈕仍在
- [ ] role 載入中（null）：submit 與提示**皆不顯示**（不閃現）

### 3.2 預覽 → 確認流程
- [ ] 按按鈕先呼叫 RPC `p_dry_run=true`，跳出 Modal 顯示：名稱 old→new、各 SKU old→new 表、待確認訂單金額 before→after、影響筆數
- [ ] 載入態為純 spinner（無「載入中」字樣）
- [ ] 「確認」呼叫 RPC `p_dry_run=false`；「取消」關閉 Modal、無任何寫入
- [ ] 守門 / 權限 RAISE EXCEPTION 經 `translateRpcError` 顯示可讀錯誤、不 crash

### 3.3 成功後刷新
- [ ] 實跑成功後 `CampaignItemsTable.reload()` 觸發、單價即時更新
- [ ] `onResynced` 回呼使外層 `CampaignOrdersPanel` / 列表金額一併刷新（不需重開 Modal）

---

## 4. Regression
- [ ] `/campaigns` 列表（含行內 開團/結單/整單結算/刪除）行為不變
- [ ] `CampaignItemsTable` 明細顯示、`CampaignOrdersPanel` 統計不受影響
- [ ] `CampaignForm` 改動為**全域**（編輯 Modal + 獨立新增開團路由皆套同 admin gate）：管理員行為與既往一致；非管理員失去 submit 鈕（刻意行為變更，非 regression）— 確認非管理員仍能開 Modal/檢視、`取消` 正常
- [ ] `_lock_campaign_prices_on_open` / `_sync_retail_price_to_campaigns` / `_sync_product_name_to_campaigns` / 1-campaign-1-product invariant trigger 行為不變（resync 不繞過 invariant：補 SKU 必同 product）
- [ ] `rpc_create_customer_orders` 加單仍快照 campaign_items.unit_price（未被本功能改壞）
- [ ] `customer_order_audit_log` append-only trigger 仍擋 UPDATE/DELETE；本 RPC 僅 INSERT
- [ ] `v_customer_order_summary` / `CampaignOrdersPanel` 金額（qty×unit_price）回填後正確、結單/應收下游連動正確

## 5. 驗收門檻

全部 §1–§4 勾完、**無 console error**、**Supabase dev push 成功（或 prod Studio 套用成功）**、**admin build + type-check 過** 才可標 done。

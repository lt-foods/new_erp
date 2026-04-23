# 核心模組測試項目 — 會員 / 訂單 / 供應商

**範圍：**
- 會員模組 UI：`/members`、`/members/new`、`/members/edit`、`/members/detail`
- 訂單模組 UI：`/campaigns`、`/campaigns/new`、`/campaigns/edit`、`/orders`
- 供應商 UI：`/suppliers`
- Migration：`20260425120000_core_crud_rpcs.sql`（relaxed RLS + 寫入 RPC）

## 1. Schema / RPC

### 1.1 RLS relaxed read policies（tenant_id 匹配即可讀）
- [ ] `members` / `member_tiers` / `member_cards` / `member_points_balance` / `wallet_balances` / `points_ledger` / `wallet_ledger` 各有一條 `authenticated` SELECT policy（tenant_id 匹配）
- [ ] `suppliers` 有 `authenticated` SELECT policy
- [ ] `stores` / `line_channels` / `post_templates` / `group_buy_campaigns` / `campaign_items` / `campaign_channels` / `customer_orders` / `customer_order_items` 各有一條 `authenticated` SELECT policy

### 1.2 寫入 RPC（SECURITY DEFINER、tenant_id 從 JWT）
- [ ] `rpc_upsert_member(id, phone, name, gender, birthday, tier_id, home_store_id, status, notes)` 存在、`GRANT EXECUTE TO authenticated`
- [ ] `rpc_upsert_member_tier(id, code, name, sort_order, benefits, is_active)` 存在
- [ ] `rpc_upsert_supplier(id, code, name, tax_id, contact_name, phone, email, address, payment_terms, lead_time_days, is_active, notes)` 存在
- [ ] `rpc_upsert_store(id, code, name, location_id, pickup_window_days, allowed_payment_methods, is_active, notes)` 存在
- [ ] `rpc_upsert_line_channel(id, code, name, channel_type, home_store_id, is_active, notes)` 存在
- [ ] `rpc_upsert_campaign(id, campaign_no, name, description, status, close_type, start_at, end_at, pickup_deadline, pickup_days, notes)` 存在
- [ ] `rpc_upsert_campaign_item(id, campaign_id, sku_id, unit_price, cap_qty, sort_order, notes)` 存在

### 1.3 RPC 行為
- [ ] `rpc_upsert_member` INSERT 補 `phone_hash = sha256(phone)`、`birth_md = TO_CHAR(birthday,'MM-DD')`
- [ ] 同 tenant 同 phone 第二次 INSERT 被 UNIQUE 阻擋
- [ ] `rpc_upsert_member` UPDATE 只動傳入非 null 欄位
- [ ] `rpc_upsert_supplier` UNIQUE (tenant_id, code) 阻擋重複
- [ ] `rpc_upsert_campaign` 預設 `status='draft'`、UNIQUE (tenant_id, campaign_no) 阻擋重複

## 2. 會員 UI

### 2.1 `/members` 列表
- [ ] 載入顯示「共 N 筆」
- [ ] 搜尋 phone / name（debounce 250ms）
- [ ] 篩選 tier / status
- [ ] 顯示 member_no、name、phone、tier、points / wallet 餘額、status、更新時間
- [ ] 分頁 50 筆
- [ ] 點 member_no → 跳 `/members/detail?id=X`
- [ ] 「新增會員」按鈕 → `/members/new`

### 2.2 `/members/new` + `/members/edit`
- [ ] 欄位：member_no、phone、name、gender、birthday、tier、status、notes
- [ ] 必填：member_no、phone、name
- [ ] phone 格式：只接受數字（10 碼或國際碼）
- [ ] 提交成功 → `/members/edit?id=X&saved=1`
- [ ] Edit：載入既有欄位、UPDATE 成功顯示 banner
- [ ] Edit：phone 不可改（唯一鍵）或允許改時需警告

### 2.3 `/members/detail`
- [ ] 顯示會員 info + tier + 現行 points balance + wallet balance
- [ ] Points ledger tab：最近 50 筆（change、balance_after、source、time）
- [ ] Wallet ledger tab：最近 50 筆
- [ ] 返回 `/members` 連結

## 3. 訂單模組 UI

### 3.1 `/campaigns` 列表
- [ ] 搜尋 campaign_no / name
- [ ] 篩選 status
- [ ] 顯示 campaign_no、name、status、start_at/end_at、pickup_deadline、item 數、orders 數
- [ ] 點 campaign_no → `/campaigns/edit?id=X`
- [ ] 「新增開團」→ `/campaigns/new`

### 3.2 `/campaigns/new` + `/campaigns/edit`
- [ ] 欄位：campaign_no、name、description、status、close_type、start_at、end_at、pickup_deadline、pickup_days、notes
- [ ] Edit：商品明細子表（sku、unit_price、cap_qty）inline CRUD
- [ ] 提交成功 → `/campaigns/edit?id=X&saved=1`

### 3.3 `/orders` 列表
- [ ] 篩選 campaign、status、pickup_store、phone（會員）
- [ ] 顯示 order_no、campaign、member name、nickname、status、item 數、total、updated_at
- [ ] 分頁 50 筆

## 4. 供應商 UI

### 4.1 `/suppliers`
- [ ] 列表 + 搜尋 code / name
- [ ] 新增按鈕展開 inline 表單
- [ ] 欄位：code、name、tax_id、contact_name、phone、email、address、payment_terms、lead_time_days、is_active、notes
- [ ] 提交成功 reload 列表
- [ ] 點 row 進 inline edit
- [ ] is_active toggle

## 5. Sidebar / Header

- [ ] Header 加 會員 / 開團 / 訂單 / 供應商 4 個連結
- [ ] active link 有樣式區別

## 6. Regression

- [ ] `/products` 列表仍正常
- [ ] `/products/new` + `/products/edit` 儲存仍正常
- [ ] TypeScript build 通過
- [ ] 0 console error

## 7. 驗收門檻

§1-§6 全部勾完、`npm run build` 通過、Supabase push 成功才算 done。

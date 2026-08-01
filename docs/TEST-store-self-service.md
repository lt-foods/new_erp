# 分店自助轉貨 + 補貨申請 測試項目 — store-self-service

**對應 migration（待建）:**
- `<ts>_virtual_product_and_transfer_freeform.sql`（products.is_virtual + transfer_items.description/estimated_amount + seed MISC SKU）
- `<ts>_restock_requests_schema.sql`（restock_requests + lines + RLS）
- `<ts>_rpc_store_self_service.sql`（5 支 RPC）

**對應 UI 變更（待建）:**
- `apps/admin/src/app/(protected)/transfers/free/page.tsx`（自由轉貨建單）
- `apps/admin/src/app/(protected)/restock/new/page.tsx`（分店建補貨申請）
- `apps/admin/src/app/(protected)/restock/page.tsx`（分店端列表）
- `apps/admin/src/app/(protected)/restock/inbox/page.tsx`（HQ inbox）
- `apps/admin/src/app/(protected)/picking/workstation/page.tsx`（撿貨頁顯示 description fallback）
- `apps/admin/src/app/(protected)/layout.tsx`（sidebar 加 nav）

---

## 1. Schema / Migration 層

### 1.1 products.is_virtual 欄位
- [ ] `products` 加 `is_virtual BOOLEAN NOT NULL DEFAULT FALSE`
- [ ] 既有 product 全部 is_virtual = FALSE
- [ ] Seed：每 tenant 一筆 product (`product_code = 'MISC'`, `name = '虛擬轉貨商品'`, `is_virtual = TRUE`, `status = 'active'`)
- [ ] Seed：MISC product 下有一筆 sku (`sku_code = 'MISC-01'`, `status = 'active'`)

```sql
SELECT product_code, name, is_virtual, status
  FROM products WHERE is_virtual = TRUE;
SELECT s.sku_code, s.status FROM skus s
  JOIN products p ON p.id = s.product_id WHERE p.is_virtual = TRUE;
```

### 1.2 transfer_items 加 description / estimated_amount
- [ ] `transfer_items.description TEXT` 加（虛擬轉貨用、實 SKU 留 NULL）
- [ ] `transfer_items.estimated_amount NUMERIC(18,4)`（虛擬轉貨估價）
- [ ] CHECK：`(description IS NULL) OR (estimated_amount IS NOT NULL)` — 有描述就要有估價

### 1.3 restock_requests 表
- [ ] 含欄位：id / tenant_id / requesting_store_id（FK stores）/ status / notes / requested_by / requested_at / approved_by / approved_at / rejected_by / rejected_at / rejected_reason / linked_transfer_id（FK transfers）/ linked_pr_id（FK purchase_requests）/ 稽核四欄位
- [ ] `status` CHECK IN (`pending`, `approved_transfer`, `approved_pr`, `shipped`, `received`, `rejected`, `cancelled`)
- [ ] `default 'pending'`
- [ ] index：`idx_restock_status (tenant_id, requesting_store_id, status)`
- [ ] partial index：`idx_restock_pending (tenant_id) WHERE status='pending'`
- [ ] updated_at 有 touch trigger

### 1.4 restock_request_lines 表
- [ ] id / tenant_id / request_id（FK ON DELETE CASCADE）/ sku_id（FK skus）/ qty NUMERIC>0 / unit_price NUMERIC≥0 / notes / 稽核四欄位
- [ ] UNIQUE (request_id, sku_id)

### 1.5 RLS policy
- [ ] restock_requests：分店看自己 store_id；HQ role（owner/admin/hq_manager）看全部
- [ ] restock_request_lines：跟 parent request 相同
- [ ] 寫入只走 RPC

### 1.6 RPC signatures
- [ ] `rpc_create_free_transfer(p_source_location BIGINT, p_dest_location BIGINT, p_lines JSONB[], p_notes TEXT)` → BIGINT
- [ ] `rpc_create_restock_request(p_store_id BIGINT, p_lines JSONB[], p_notes TEXT)` → BIGINT
- [ ] `rpc_approve_restock_to_transfer(p_request_id BIGINT)` → BIGINT (transfer_id)
- [ ] `rpc_approve_restock_to_pr(p_request_id BIGINT)` → BIGINT (pr_id)
- [ ] `rpc_reject_restock(p_request_id BIGINT, p_reason TEXT)` → VOID
- [ ] 全部 GRANT EXECUTE TO authenticated

```sql
SELECT proname, pg_get_function_arguments(oid) FROM pg_proc
 WHERE proname IN ('rpc_create_free_transfer','rpc_create_restock_request',
                   'rpc_approve_restock_to_transfer','rpc_approve_restock_to_pr','rpc_reject_restock');
```

---

## 2. RPC 行為（SQL 直測）

### 2.1 rpc_create_free_transfer — happy path
**情境：** store_manager A 店建自由轉貨到 B 店、3 行（描述 + 數量 + 估價）

**預期：** transfers 多一筆 (source/dest 對、status='draft')；transfer_items 3 筆，sku_id 全是 MISC-01，description 填、estimated_amount 填

### 2.2 rpc_create_free_transfer — source==dest 拒絕
**情境：** source_location = dest_location

**預期：** RAISE EXCEPTION（沿用 transfers CHECK）

### 2.3 rpc_create_free_transfer — 無 description 拒絕
**情境：** lines 內某行 description 為空

**預期：** 拒絕（自由轉貨必填描述）

### 2.4 rpc_create_restock_request — happy path
**情境：** store_manager A 店建單，2 個既有 active SKU + qty + notes

**預期：** restock_requests + 2 lines、status='pending'、unit_price snapshot

### 2.5 rpc_create_restock_request — 跨 tenant SKU 拒絕
**情境：** lines 內某 sku_id 屬別 tenant

**預期：** RAISE EXCEPTION 'sku % not in tenant'

### 2.6 rpc_create_restock_request — 虛擬 SKU 拒絕
**情境：** lines 內 sku 屬於 is_virtual product

**預期：** RAISE EXCEPTION（restock 限真商品）

### 2.7 rpc_approve_restock_to_transfer — happy path
**情境：** HQ admin 對 pending request 呼叫 approve_to_transfer

**預期：**
- 自動建 transfers 1 筆（source=HQ default location、dest=requesting_store_id 的 location、status='draft'）
- transfer_items 鏡像 request lines 數
- request.status='approved_transfer'、linked_transfer_id 寫入

### 2.8 rpc_approve_restock_to_transfer — 非 pending 拒絕
**情境：** request 已 approved_transfer / approved_pr / rejected

**預期：** RAISE EXCEPTION 'request already processed'

### 2.9 rpc_approve_restock_to_pr — happy path
**情境：** HQ admin 對 pending request 呼叫 approve_to_pr

**預期：**
- 找 24h 內未 send 的 PR、有就 append；沒就建新 PR
- PR lines 含本 request 的 sku
- request.status='approved_pr'、linked_pr_id 寫入

### 2.10 rpc_reject_restock — happy path
**情境：** HQ admin 拒絕、附 reason

**預期：** request.status='rejected'、rejected_reason 寫入、rejected_by + rejected_at 寫入

### 2.11 rpc_reject_restock — 非 pending 拒絕
**情境：** request 已被處理

**預期：** RAISE EXCEPTION

### 2.12 role check：分店店員不可 approve
**情境：** JWT role='store_staff' 呼叫 rpc_approve_restock_to_transfer

**預期：** RAISE EXCEPTION 'permission denied'

### 2.13 role check：分店店員可建 request
**情境：** JWT role='store_staff' 呼叫 rpc_create_restock_request

**預期：** 成功（自家店 only）

### 2.14 rpc_approve_restock_lines_to_pr — 依品相分張開請購單（20260714000040）
**情境：** pending request 有 2 個品相（不同 SKU），HQ 先只選品相 A 呼叫
`rpc_approve_restock_lines_to_pr(req_id, ARRAY[line_a])`，再呼叫第二次（p_line_ids=NULL）

**預期：**
- 第一次：新 draft PR 只含品相 A、line_a.linked_pr_id 寫入；request 停留 'pending'、
  header linked_pr_id 記第一張 PR、approved_at 仍 NULL
- 部分開單期間：rpc_approve_restock_to_transfer / rpc_reject_restock /
  rpc_delete_restock_request 全部 RAISE（不可整張派貨/拒絕/刪除）
- 重複開同一明細 → RAISE '已開過請購單'；別張申請的明細 id → RAISE '不屬於補貨申請'
- 第二次（NULL = 全部剩餘品相）：第二張獨立 PR；全明細開單 → status='approved_pr'、
  approved_by/at 寫入、header linked_pr_id 仍為第一張
- 舊 rpc_approve_restock_to_pr(req_id) 為薄包裝（= 全部剩餘品相一張 PR），行為不變

### 2.15 rpc_cancel_restock_lines — 剩餘品相刪除（不再補貨）（20260714000050）
**情境：** 品相 A 已開請購單的 pending request，HQ 對品相 B 呼叫
`rpc_cancel_restock_lines(req_id, ARRAY[line_b])`，之後再開單/刪除剩餘品相

**預期：**
- 未開任何請購單前呼叫 → RAISE '請用「拒絕」'（整張不補貨走既有拒絕流程）
- 刪 B：line_b.cancelled_at 寫入、sentinel RR- 訂單對應 sku 明細 status='cancelled'；
  還有品相未處理 → request 停留 'pending'
- 已開單品相不可刪、已刪品相不可再刪、已刪品相不可開請購單 → 各自 RAISE
- 開單 NULL（全部剩餘）會排除已刪品相；全品相處理完（開單或刪除）→
  status='approved_pr'、approved_by/at 寫入
- 「刪除全部剩餘品相」也會直接結案（至少一個品相已開單 → approved_pr）

### 2.16 rpc_delete_free_transfer — 自由轉貨刪除（20260801000010）
**情境：** 分店建錯自由轉貨（draft、store_to_store、無訂單 FK），店家自行刪除

**預期：**
- HQ 職能（owner/admin/hq_manager/''）：任何 draft 自由轉貨可刪
- 門市職能（store_manager/store_staff）：source 或 dest 在自己店
  （_jwt_store_location_ids()）→ 可刪；不相干店 → RAISE 'own store'
- 非 store_to_store、customer_order_id 有值（互助接力單）、
  next_transfer_id 有值 → RAISE 'not a free transfer'
- 非 draft（總倉已配送）→ RAISE 'only draft can be deleted'
- 硬刪 transfers、transfer_items 由 ON DELETE CASCADE 連帶刪
- 跨 tenant id → 'not found'

---

## 3. UI 行為（preview 互動）

### 3.1 /transfers/free — 自由轉貨建單
- [ ] 頁載入無 console error
- [ ] 來源店 / 目的店 dropdown 載入完整 stores 清單
- [ ] 「+ 新增一行」可加多行（描述 / 數量 / 單位 / 估價 / 備註）
- [ ] source==dest 時提交按鈕 disable
- [ ] 提交後 → 跳到 transfers 列表 + 新單顯示在最上

### 3.2 /restock/new — 分店建補貨申請
- [ ] 商品搜尋 dropdown 限 active 真商品（not is_virtual）
- [ ] 選 SKU 後 unit_price auto-fill branch 價（store_manager+ 看得到）
- [ ] qty 可輸入小數
- [ ] 提交成功 → 跳到 /restock 列表

### 3.3 /restock — 分店端列表
- [ ] Tabs：全部 / pending / approved（含 approved_transfer + approved_pr）/ shipped / received / rejected
- [ ] 自家店的 request 才顯示
- [ ] approved_transfer 列顯示「→ 轉貨單 #TRxxxxx」連結
- [ ] approved_pr 列顯示「→ PR #PRxxxxx」連結
- [ ] rejected 列顯示拒絕原因

### 3.4 /restock/inbox — HQ inbox
- [ ] 上方 stat card：本月 pending N / 已派貨 / 已採購 / 已拒絕
- [ ] Pending tab：每 row「派貨」「進貨」「拒絕」三按鈕
- [ ] 「派貨」彈確認 → 呼叫 approve_to_transfer → row 移除 pending tab、出現在 history tab
- [ ] 「進貨」同上
- [ ] 「拒絕」彈出原因輸入 modal → 提交

### 3.4b /wms/transfers — 自由轉貨刪除按鈕
- [x] draft + store_to_store + 無 customer_order_id 的 row 顯示「刪除」
- [x] shipped / 互助接力單（customer_order_id 有值）/ 退訂單（return_to_hq）不顯示
- [x] 按刪除 → confirm → 呼叫 rpc_delete_free_transfer → row 移除、無 console error
      （Playwright + fixture 驗證，store_manager 角色）

### 3.5 撿貨頁 description fallback
- [ ] 撿貨工作站 wave row 顯示：`{transfer_items.description ?? sku.product_name}`
- [ ] 既有真實 SKU 撿貨流程不變

### 3.6 Sidebar
- [ ] 加「自由轉貨」連結（store_manager+ 可見）
- [ ] 加「補貨申請」連結（分店看自己/HQ 看 inbox）

---

## 4. Regression

### 4.1 既有 hq_to_store transfer
- [ ] 既有「總倉派貨」流程不受影響（campaigns 結單後自動派貨）

### 4.2 既有 customer_orders 流程
- [ ] 完全不動（restock 不走 customer_orders）

### 4.3 月結算（store_monthly_settlement）
- [ ] 既有 hq_to_store transfer 仍正確計入應收
- [ ] approved_transfer 走完後計入（同樣是 hq_to_store transfer）
- [ ] free transfer：用 estimated_amount 計入（新增來源類別、`store_to_store_estimated`）
- [ ] settlement print 頁分節呈現

### 4.4 撿貨 wave 既有顯示
- [ ] 真實 SKU 仍顯示 product_name（description 為 NULL 時 fallback 走 sku 名稱）

### 4.5 既有 transfer_items.sku_id NOT NULL 約束
- [ ] 自由轉貨用 MISC SKU、約束不違反

---

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功**、**build + type-check 過** 才可標 done。

# campaign-to-purchase 測試項目 — 結單日 → 內部請購單 → 拆 PO 全流程

**對應 migration:** `supabase/migrations/20260428120000_campaign_to_purchase.sql`（待建）
**對應 UI 變更:**
- `apps/admin/src/app/(protected)/campaigns/page.tsx`（結單按鈕）
- `apps/admin/src/app/(protected)/purchase/requests/new/page.tsx`（新建：請購單工作底稿、含「帶入該日商品」按鈕）
- `apps/admin/src/app/(protected)/purchase/requests/page.tsx`（新建：PR 列表）
- `apps/admin/src/app/(protected)/purchase/orders/page.tsx`（新建：PO 列表）
- `apps/admin/src/components/PurchaseOrderEdit.tsx`（新建）
- `apps/admin/src/components/PurchaseOrderSendModal.tsx`（新建）
- `apps/admin/src/components/PurchaseRequestPrint.tsx`（新建：列印依供應商 group）

**對應 PRD:**
- `docs/PRD-訂單取貨模組.md` §7.5（結單）
- `docs/PRD-採購模組.md` §7.2 §7.3 §7.4（PR / PO / 供應商）
- `docs/PRD-採購模組-v0.2-addendum.md` §1 §2.1 §2.2（內審 + 門檻）

**對應 Issue:** [#76 rpc_create_pr_from_campaign](https://github.com/lt-foods/new_erp/issues/76)

**設計原則（對齊 lt-erp UX）：**
1. **PR 是跨供應商工作底稿**：一張 PR 多家供應商混排，每行 line item 帶 `suggested_supplier_id`
2. **「帶入該日商品」**：選結單日 → 一鍵把該日所有 closed campaign 的商品全帶入一張 PR（per SKU 彙總）
3. **送審 → 拆 PO**：PR 通過內審後依 `suggested_supplier_id` 自動拆多張 PO（每張 PO 一個 supplier）
4. **列印**：依 supplier grouping、每組獨立 section + subtotal

---

## 1. Schema / Migration 層

### 1.1 `purchase_requests` 欄位擴充
- [ ] 新增 `source_type TEXT NOT NULL DEFAULT 'manual' CHECK (source_type IN ('manual','close_date'))`
- [ ] 新增 `source_close_date DATE`（用於「帶入該日商品」追溯）
- [ ] 新增 `total_amount NUMERIC(18,4) NOT NULL DEFAULT 0`（送審時計算快照）
- [ ] CHECK：`source_type='close_date'` → `source_close_date` 必填
  ```sql
  SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname LIKE 'purchase_requests_source%';
  ```

### 1.2 `purchase_request_items` 欄位擴充
- [ ] 新增 `unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0`（採購人員可編輯）
- [ ] 新增 `line_subtotal NUMERIC(18,2) GENERATED ALWAYS AS (qty_requested * unit_cost) STORED`
- [ ] 新增 `source_campaign_id BIGINT REFERENCES group_buy_campaigns(id)`（追溯出處）
- [ ] 既有 `suggested_supplier_id` 不變（給拆 PO 時用）

### 1.3 `suppliers` 欄位擴充（v0.2 PRD §Q4）
- [ ] 新增 `preferred_po_channel TEXT CHECK (...) DEFAULT 'line'`
- [ ] 新增 `line_contact TEXT`

### 1.4 Sequences
- [ ] `pr_no_seq` / `po_no_seq`，格式 `PR{yyMMdd}{NNNN}` / `PO{yyMMdd}{NNNN}`
  ```sql
  SELECT sequence_name FROM information_schema.sequences WHERE sequence_name IN ('pr_no_seq','po_no_seq');
  ```

### 1.5 RPC signature
- [ ] 新 RPC `rpc_create_pr_from_close_date(p_close_date DATE, p_operator UUID) RETURNS BIGINT`（「帶入該日商品」核心）
- [ ] 新 RPC `rpc_close_campaign(p_campaign_id BIGINT, p_operator UUID) RETURNS VOID`（純切 status，**不**自動產 PR）
- [ ] 新 RPC `rpc_submit_pr(p_pr_id BIGINT, p_operator UUID) RETURNS VOID`（送出審核：算 total + 套 threshold + 設 review_status）
- [ ] 新 RPC `rpc_split_pr_to_pos(p_pr_id BIGINT, p_dest_location_id BIGINT, p_operator UUID) RETURNS BIGINT[]`（依 suggested_supplier_id 拆多張 PO）
- [ ] 新 RPC `rpc_send_purchase_order(p_po_id BIGINT, p_channel TEXT, p_operator UUID) RETURNS VOID`
- [ ] 新 helper `rpc_next_pr_no()` / `rpc_next_po_no()`
- [ ] 既有 `rpc_merge_prs_to_po` 保留不動（manual 合併情境）
  ```sql
  SELECT proname, pg_get_function_identity_arguments(oid)
    FROM pg_proc WHERE proname IN ('rpc_create_pr_from_close_date','rpc_close_campaign','rpc_submit_pr','rpc_split_pr_to_pos','rpc_send_purchase_order');
  ```

### 1.6 Index
- [ ] `idx_pr_close_date` ON `purchase_requests (tenant_id, source_close_date) WHERE source_type='close_date'`
- [ ] `idx_pri_supplier` ON `purchase_request_items (suggested_supplier_id)`

### 1.7 Grants & RLS
- [ ] 5 個新 RPC `GRANT EXECUTE` 給 `authenticated`
- [ ] `purchase_requests` 既有 RLS 不變

---

## 2. RPC 行為（SQL 直測）

### 2.1 happy path — 「帶入該日商品」單 campaign
**情境：** 2026-04-25 有 campaign A status=closed，A 內 SKU1×30、SKU2×12，sku_suppliers 設 SKU1→S1、SKU2→S2。
**預期：**
- 呼叫 `rpc_create_pr_from_close_date('2026-04-25', op)` → 回傳 PR id
- PR 一張：source_type='close_date'、source_close_date='2026-04-25'、status='draft'
- pr_no = `PR260425{NNNN}`
- PR items 兩行：
  - SKU1, qty=30, suggested_supplier=S1, unit_cost=S1.default_unit_cost, source_campaign_id=A
  - SKU2, qty=12, suggested_supplier=S2, unit_cost=S2.default_unit_cost, source_campaign_id=A

### 2.2 happy path — 「帶入該日商品」多 campaign 合併
**情境：** 2026-04-25 有 campaign A (SKU1×30) + campaign B (SKU1×20, SKU3×5) 都 status=closed。
**預期：**
- 產一張 PR、3 行 items：
  - SKU1, qty=50（A+B 加總）, source_campaign_id=NULL（多來源）或記第一個
  - SKU2 不存在（A 沒有）
  - SKU3, qty=5, source_campaign_id=B
- pr_no 連號

### 2.3 happy path — SKU 沒設 preferred 供應商
**情境：** SKU99 在 sku_suppliers 沒任何資料。
**預期：** PR items 含 SKU99、`suggested_supplier_id=NULL`、`unit_cost=0`、UI 端標紅讓採購補。

### 2.4 守衛 — 該日無 closed campaign
**情境：** 2026-04-30 無任何 closed campaign。
**預期：** RAISE `'no closed campaigns on date %'`，無 PR 建立。

### 2.5 守衛 — 該日 campaign 無下單
**情境：** 2026-04-25 有 campaign C status=closed 但無 customer_orders。
**預期：** RAISE `'no orders to aggregate for close_date %'`，無 PR 建立。

### 2.6 跨 tenant 隔離
**情境：** tenant T1 的 op 呼叫帶入「2026-04-25」，T2 也有 closed campaign。
**預期：** 只彙總 T1 的 campaign，T2 完全不被掃。

### 2.7 結單守衛 — campaign 狀態錯誤
**情境：** campaign D status='draft'。
**預期：** `rpc_close_campaign(D, op)` RAISE `'campaign % not in open status'`。

### 2.8 結單 happy path
**情境：** campaign E status='open'。
**預期：** 切 status='closed'、updated_by/updated_at 填上、**不**自動產 PR（須由「帶入該日商品」另行觸發）。

### 2.9 送審 — 低於門檻自動 approved
**情境：** PR 總額 5000、threshold global=10000。
**預期：** 呼叫 `rpc_submit_pr(pr, op)` → status='submitted'、review_status='approved'、submitted_at=NOW()、total_amount=5000。

### 2.10 送審 — 超過門檻 pending_review
**情境：** PR 總額 15000、threshold global=10000。
**預期：** status='submitted'、review_status='pending_review'、review_threshold_amount=10000 寫入快照。

### 2.11 送審守衛 — 已送審
**情境：** PR review_status='approved' 或 'pending_review'。
**預期：** RAISE `'PR % already submitted'`。

### 2.12 拆 PO — happy path 多供應商
**情境：** PR R1 review_status='approved'、items：(SKU1 S1×30)、(SKU2 S1×10)、(SKU3 S2×5)。
**預期：**
- 呼叫 `rpc_split_pr_to_pos(R1, dest_loc, op)` → 回傳 2 個 PO id
- PO1：supplier=S1、items=(SKU1×30, SKU2×10)、status='draft'
- PO2：supplier=S2、items=(SKU3×5)、status='draft'
- po_no auto-gen 連號
- PR items 全部 `po_item_id` 連到對應 PO items
- PR.status='fully_ordered'

### 2.13 拆 PO 守衛 — review_status 未通過
**情境：** PR review_status='pending_review' 或 'rejected'。
**預期：** RAISE `'PR not approved (current: ...)'`，無 PO 建立。

### 2.14 拆 PO 守衛 — 含未指派供應商
**情境：** PR R2 含 1 行 `suggested_supplier_id=NULL`。
**預期：** RAISE `'PR has unassigned supplier items'`，全部 rollback。

### 2.15 拆 PO 守衛 — 已拆過
**情境：** PR R3 status='fully_ordered'（已拆過）。
**預期：** RAISE `'PR already split'`。

### 2.16 PO 發送 — LINE channel happy
**情境：** PO X status='draft'、來源 PR review_status='approved'、supplier.preferred_po_channel='line'。
**預期：** 呼叫 `rpc_send_purchase_order(X, 'line', op)` → status='sent'、sent_at/sent_by/sent_channel 填齊。

### 2.17 PO 發送守衛 — 已發送
**情境：** PO Y status='sent'。
**預期：** RAISE `'PO % already sent'`。

### 2.18 PO 發送守衛 — pending_review
**情境：** PO 來源 PR review_status='pending_review'。
**預期：** RAISE `'PO has PR pending review'`。

### 2.19 PO 發送守衛 — invalid channel
**情境：** 傳入 channel='xyz'。
**預期：** RAISE `'invalid channel: xyz'`。

### 2.20 audit 四欄位
**情境：** 每張新建 / 更新檢查 created_by/updated_by/created_at/updated_at。
**預期：** 全填 = operator UUID + NOW()。

### 2.21 1 PO : N GR — 分批收貨保留
**情境：** PO 拆完後建 GR1 收 60%、再建 GR2 收 40%。
**預期：** PO.status `partially_received → fully_received`、`goods_receipts.po_id` 兩張並存（FK 不限唯一）、qty_received 累加。**新流程不可破壞此關係。**

### 2.22 1 PO : N GR — 短收守在 partially_received
**情境：** GR 只收 PO 的一部分。
**預期：** PO.status='partially_received'、剩餘可再建 GR 補收。

---

## 3. UI 行為（preview 互動）

### 3.1 Campaign 結單按鈕
- [ ] `/campaigns` 列表每列「結單」按鈕：status='open' 才顯示
- [ ] 點按鈕 → confirm dialog「確定結單？」
- [ ] confirm → 呼叫 `rpc_close_campaign` → toast「已結單」
- [ ] 列表狀態欄改為「已結單」、按鈕消失
- [ ] 失敗 → toast 顯示 RPC 錯誤訊息

### 3.2 採購單工作底稿頁 `/purchase/requests/new`
- [ ] 頁面 mount 不噴 console error
- [ ] 頂部欄位：採購日期 / 結單日 dropdown / 「帶入該日商品」按鈕
- [ ] 結單日 dropdown：列出最近 30 天內有 closed campaign 的日期
- [ ] 點「帶入該日商品」→ 呼叫 `rpc_create_pr_from_close_date` → 跳到 `/purchase/requests/<新 id>` 編輯頁
- [ ] 失敗（如該日無 closed campaign）→ toast 顯示錯誤

### 3.3 採購單編輯頁 `/purchase/requests/<id>`
- [ ] 表格欄位：項次 / 品名+商品編號 / 供應商 / 單位 / 數量 / 成本 / 售價 / 分店價 / 小計 / 刪除
- [ ] **跨供應商混排**（per-row supplier dropdown）
- [ ] 數量 / 成本 input 可編輯、即時更新小計（GENERATED column）
- [ ] 售價 / 分店價：JOIN `prices` 即時顯示、不可編輯
- [ ] 底部：未稅小計 / 含稅總計 / 備註 textarea
- [ ] 按鈕：清空 / 列印 / 存為草稿 / 送出審核
- [ ] 「存為草稿」= UPDATE status='draft' + 各欄位
- [ ] 「送出審核」= 呼叫 `rpc_submit_pr` → toast「已送審」+ disable 編輯
- [ ] 任意 row 供應商 NULL → 「送出審核」標警告但不擋（拆 PO 時才擋）

### 3.4 PR 列印 — 依供應商 grouping
- [ ] 列印按鈕 → 新分頁 / `window.print` 友善版面
- [ ] 標題：`{總倉名稱} - 內部採購單` + 日期
- [ ] **依 `suggested_supplier_id` 分組**，每個 supplier 一個 section
- [ ] 每 section 欄位：項次 / 商品編號 / 商品名稱 / 數量 / 成本 / 售價 / 分店價 / 利潤 / 利潤小計 / 小計
- [ ] 每 section 結尾：該供應商 subtotal
- [ ] 全清單結尾：總計（未稅 / 含稅）
- [ ] `suggested_supplier_id IS NULL` 另起「未指派供應商」section、標紅
- [ ] CSS `@media print` 處理分頁、隱藏編輯按鈕、固定欄寬

### 3.5 PR 列表 `/purchase/requests`
- [ ] 篩選：source_type / review_status / status / 結單日範圍
- [ ] 列表欄：pr_no / source_close_date / 總金額 / status / review_status / 建立人 / 建立時間
- [ ] 點 pr_no → 跳編輯頁

### 3.6 PR 列表 — 審核操作
- [ ] review_status='pending_review' 列右側「通過」/「退回」（admin/hq_manager 才見）
- [ ] 「退回」需填 reason → `rpc_reject_purchase_request`
- [ ] 「通過」→ `rpc_approve_purchase_request`、列表即時更新

### 3.7 PR 拆 PO
- [ ] PR review_status='approved' 編輯頁出現「拆成 PO」按鈕
- [ ] 點按鈕 → confirm dialog 顯示預覽：依 supplier 分組會產出幾張 PO + 各總額
- [ ] confirm → `rpc_split_pr_to_pos` → toast「已產生 N 張 PO」→ 跳 PO 列表
- [ ] 含未指派供應商行 → 按鈕 disabled + tooltip「有未指派供應商」

### 3.8 PO 列表 `/purchase/orders`
- [ ] 篩選：status / supplier / 日期區間
- [ ] 列表欄：po_no / supplier / 總金額 / status / 預計到貨 / 已收 % / 建立時間
- [ ] 點 po_no 跳編輯頁

### 3.9 PO 編輯頁
- [ ] mount 帶入既有資料、所有欄位 round-trip
- [ ] status='draft' 時 line items 可改 qty / unit_cost / 刪除 / 新增
- [ ] status='sent' 後 line items 全 readonly、只能改 notes
- [ ] line_subtotal GENERATED 自動更新
- [ ] save → UPDATE 並 refresh

### 3.10 PO 發送 modal
- [ ] PO 編輯頁 status='draft' 顯示「發送 PO」按鈕
- [ ] 任一來源 PR.review_status='pending_review' → 按鈕 disabled
- [ ] 點按鈕 → modal 依 supplier.preferred_po_channel 顯示對應 UI：
  - LINE：格式化 PO 文字 + 「複製文字」 + supplier.line_contact + 「我已貼到 LINE」
  - Email：「下載 PDF」+ `mailto:` + 「我已寄出」
  - Phone：顯示 supplier.phone + 通話紀錄文字框
- [ ] 確認 → `rpc_send_purchase_order` → status='sent' + toast

### 3.11 內審金額門檻設定
- [ ] `/admin/purchase-thresholds`（或塞 settings 子頁）
- [ ] CRUD：global / supplier / category 三 scope
- [ ] 即時影響後續 `rpc_submit_pr` 的 threshold 判斷

---

## 4. Regression

- [ ] `/campaigns/order-entry`（小幫手加單 MVP-0）流程不變
- [ ] `/campaigns` 既有「編輯 / 新增 / 商品明細」流程不變
- [ ] `/orders` 列表 + 訂單明細 Modal 不變
- [ ] `/suppliers` CRUD 不變、`preferred_po_channel` 顯示在編輯表單但 default 'line' 不破壞既有 row
- [ ] `customer_orders` reserve / release / pickup flow 不變
- [ ] `goods_receipts` / `purchase_returns` 既有 RPC 不變
- [ ] **既有 `rpc_merge_prs_to_po`** 保留原簽名、原行為（手動合併情境）
- [ ] **1 PO : N GR 關係保留**：`goods_receipts.po_id` FK 不被改 UNIQUE
- [ ] PO `_refresh_po_status` trigger 行為不變
- [ ] 稽核四欄位：所有新建 / 更新填齊
- [ ] tenant 隔離：跨 tenant 操作全擋
- [ ] Build pass：`npm run build --workspace apps/admin`
- [ ] Type check 過

---

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功**、**build + type-check 過** 才可標 done.

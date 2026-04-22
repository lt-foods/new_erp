---
title: PRD - 應付帳款 + 零用金 + 費用
module: AccountsPayable
status: draft-v0.2
owner: alex.chen
created: 2026-04-22
updated: 2026-04-22
tags: [PRD, ERP, v0.2, 應付帳款, 零用金, 費用, lt-erp-integration, accounting]
---

# PRD — 應付帳款 + 零用金 + 費用模組（Accounts Payable + Petty Cash + Expense）

> **新 module PRD**（非 addendum），v0.2 獨立成冊。
> 驅動原因：v0.1 原標 P1 deferred；Q4 決議拉進 v0.2、pilot 門市上線時會計帳目必備。
> 參考：lt-erp 的 `MakePayment` / `PettyCashPanel` / `AddExpense` / `ExpenseList` 四個功能。
> 決議來源：[[decisions/2026-04-22-v0.2-scope-decisions]] Q4。
> 銜接：[[PRD-庫存模組-v0.2-addendum]] §3.5（transfer settlement → vendor_bill）、[[PRD-供應商整合-v0.2]]（xiaolan → purchases → bills）。

---

## 1. 模組定位

- [x] **應付帳款（AP）**：管供應商 bill + 付款；獨立於銷售端 `payments` 表（那是 AR）
- [x] **零用金（Petty Cash）**：每店現金備用金、每日收支流水
- [x] **費用（Expense）**：費用申請 → 審核 → 支付（可從零用金支、可從公司帳戶支）
- [x] **加盟店模式兼容**：加盟主**各自收款 / 各自月結**；總部僅代總倉供應商付款
  - 加盟店間的月結（PRD #2 §3.5）走 AP 管道代收代付
  - 加盟店自己的費用不走 AP、自行承擔（例外：總部代墊可 flag `settled_by_hq`）
- [x] **不做**：
  - 銀行對帳（bank reconciliation）— v1 人工做
  - 外匯 / 多幣別 — TWD only
  - 發票自動比對（OCR / eInvoice）— P1 考慮
  - 預算管控 / 預算限額 — P1

---

## 2. 核心概念

- [x] **Vendor Bill**：供應商帳單 — 可來自 PO 收貨、可來自 xiaolan 匯入、可來自 transfer settlement（加盟店互相欠）
- [x] **Vendor Payment**：實際付款動作 — 一筆 payment 可對多張 bill（partial pay / aggregated pay）
- [x] **Petty Cash Account**：每店一個備用金帳戶（有 balance / credit_limit）
- [x] **Petty Cash Transaction**：每筆零用金進出（append-only）
- [x] **Expense**：費用申請（交通、文具、雜支…）、需審核、支付管道可選
- [x] **Stores as Suppliers**：加盟店在 `suppliers` 表有對應 row（Flag 8 依賴、§3.1 建立規則）

---

## 3. 資料模型

### 3.1 新增表：`vendor_bills`（主檔、可編輯）

```sql
CREATE TABLE vendor_bills (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  bill_no TEXT NOT NULL,                               -- 系統生成 'BILL-202604-0001'
  supplier_id BIGINT NOT NULL REFERENCES suppliers(id),
  source_type TEXT NOT NULL
    CHECK (source_type IN ('purchase_order', 'goods_receipt', 'transfer_settlement', 'xiaolan_import', 'manual')),
  source_id BIGINT,                                    -- FK varies by source_type
  bill_date DATE NOT NULL,
  due_date DATE NOT NULL,
  amount NUMERIC(18,4) NOT NULL CHECK (amount > 0),
  paid_amount NUMERIC(18,4) NOT NULL DEFAULT 0
    CHECK (paid_amount >= 0 AND paid_amount <= amount),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'partially_paid', 'paid', 'cancelled', 'disputed')),
  currency TEXT NOT NULL DEFAULT 'TWD',                -- v1 只有 TWD
  tax_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
  supplier_invoice_no TEXT,                            -- 供應商開的發票號
  notes TEXT,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, bill_no)
);

CREATE INDEX idx_bills_supplier ON vendor_bills (tenant_id, supplier_id, status);
CREATE INDEX idx_bills_due ON vendor_bills (tenant_id, due_date)
  WHERE status IN ('pending', 'partially_paid');
CREATE INDEX idx_bills_source ON vendor_bills (tenant_id, source_type, source_id);
```

**為何 `source_type` + `source_id` 而非多個 FK**：
- bill 可從 4+ 種來源產生（PO、GR、settlement、xiaolan、手動）
- 每個來源表一個 nullable FK 會很亂（4 個欄位只一個非 NULL）
- 用 `source_type` + `source_id` polymorphic、查詢時自己 JOIN
- 代價：DB 層無 FK integrity；以 application layer 保證（RPC 建 bill 時驗證 source 存在）

### 3.2 新增表：`vendor_bill_items`（明細、append-only）

```sql
CREATE TABLE vendor_bill_items (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  bill_id BIGINT NOT NULL REFERENCES vendor_bills(id) ON DELETE CASCADE,
  line_no INTEGER NOT NULL,
  description TEXT NOT NULL,
  sku_id BIGINT REFERENCES skus(id),                   -- nullable（settlement bill 無 sku）
  qty NUMERIC(18,3),
  unit_cost NUMERIC(18,4),
  amount NUMERIC(18,4) NOT NULL,
  po_item_id BIGINT REFERENCES purchase_order_items(id),  -- source trace
  gr_item_id BIGINT REFERENCES goods_receipt_items(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only，不帶 created_by（繼承 bill.created_by）+ 不帶 updated_*
);

CREATE INDEX idx_bill_items_bill ON vendor_bill_items (bill_id, line_no);
```

### 3.3 新增表：`vendor_payments`（主檔、可編輯）

和銷售端的 `payments` 表**獨立**（那邊是 AR、這邊是 AP）。

```sql
CREATE TABLE vendor_payments (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  payment_no TEXT NOT NULL,
  supplier_id BIGINT NOT NULL REFERENCES suppliers(id),
  amount NUMERIC(18,4) NOT NULL CHECK (amount > 0),
  method TEXT NOT NULL
    CHECK (method IN ('cash', 'bank_transfer', 'check', 'offset', 'petty_cash', 'other')),
  bank_account TEXT,                                   -- 轉帳帳號 tail 4
  check_no TEXT,                                       -- 支票號
  paid_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  paid_from_petty_cash_id BIGINT,                      -- FK 加在 §3.5 建表後
  status TEXT NOT NULL DEFAULT 'completed'
    CHECK (status IN ('pending', 'completed', 'voided')),
  notes TEXT,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, payment_no)
);

CREATE INDEX idx_vpay_supplier ON vendor_payments (tenant_id, supplier_id, paid_at DESC);
```

### 3.4 新增表：`vendor_payment_allocations`（付款分配、append-only）

一筆付款可對多張 bill：

```sql
CREATE TABLE vendor_payment_allocations (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  payment_id BIGINT NOT NULL REFERENCES vendor_payments(id) ON DELETE CASCADE,
  bill_id BIGINT NOT NULL REFERENCES vendor_bills(id),
  allocated_amount NUMERIC(18,4) NOT NULL CHECK (allocated_amount > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only
);

CREATE INDEX idx_vpay_alloc_bill ON vendor_payment_allocations (bill_id);
CREATE INDEX idx_vpay_alloc_pay ON vendor_payment_allocations (payment_id);
```

### 3.5 新增表：`petty_cash_accounts`（主檔、可編輯）

```sql
CREATE TABLE petty_cash_accounts (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  store_id BIGINT NOT NULL REFERENCES stores(id),
  account_name TEXT NOT NULL,                          -- '台北店零用金'
  balance NUMERIC(18,4) NOT NULL DEFAULT 0,            -- 當前餘額（trigger 維護）
  credit_limit NUMERIC(18,4) NOT NULL DEFAULT 0,       -- 預支上限
  custodian_user_id UUID,                              -- 保管人
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, store_id, account_name)
);

CREATE INDEX idx_pca_store ON petty_cash_accounts (tenant_id, store_id) WHERE is_active;
```

**balance 維護方式**：由 `petty_cash_transactions` insert trigger 自動更新 `balance`（類似 `stock_balances`）。

### 3.6 新增表：`petty_cash_transactions`（append-only 流水）

```sql
CREATE TABLE petty_cash_transactions (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  account_id BIGINT NOT NULL REFERENCES petty_cash_accounts(id),
  txn_date DATE NOT NULL DEFAULT CURRENT_DATE,
  direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  amount NUMERIC(18,4) NOT NULL CHECK (amount > 0),
  purpose TEXT NOT NULL,
  category_id BIGINT REFERENCES expense_categories(id),  -- §3.8，may be NULL for 'in'
  expense_id BIGINT REFERENCES expenses(id),           -- §3.7，若 expense-driven txn
  vendor_payment_id BIGINT REFERENCES vendor_payments(id),  -- 若 petty → pay supplier
  receipt_photo_url TEXT,                              -- 單據照片（Storage URL）
  notes TEXT,
  created_by UUID,                                     -- 即 operator_id
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only
);

CREATE INDEX idx_pct_account_date ON petty_cash_transactions (account_id, txn_date DESC);
CREATE INDEX idx_pct_category ON petty_cash_transactions (category_id) WHERE category_id IS NOT NULL;
```

**vendor_payments.paid_from_petty_cash_id FK 回補**：

```sql
ALTER TABLE vendor_payments
  ADD CONSTRAINT fk_vpay_petty_cash
  FOREIGN KEY (paid_from_petty_cash_id) REFERENCES petty_cash_transactions(id);
```

### 3.7 新增表：`expenses`（主檔、可編輯）

```sql
CREATE TABLE expenses (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  expense_no TEXT NOT NULL,
  applicant_id UUID NOT NULL,
  store_id BIGINT REFERENCES stores(id),               -- 哪店發生（null = HQ）
  category_id BIGINT NOT NULL REFERENCES expense_categories(id),
  amount NUMERIC(18,4) NOT NULL CHECK (amount > 0),
  currency TEXT NOT NULL DEFAULT 'TWD',
  expense_date DATE NOT NULL,
  description TEXT NOT NULL,
  receipt_photo_url TEXT,
  approval_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (approval_status IN ('pending', 'approved', 'rejected', 'paid')),
  approved_by UUID,
  approved_at TIMESTAMPTZ,
  rejection_reason TEXT,
  paid_by_vendor_payment_id BIGINT REFERENCES vendor_payments(id),  -- 公司帳戶付
  paid_by_petty_cash_txn_id BIGINT REFERENCES petty_cash_transactions(id),  -- 零用金付
  settled_by_hq BOOLEAN NOT NULL DEFAULT FALSE,        -- 總部代墊 flag
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, expense_no),
  CHECK (
    (paid_by_vendor_payment_id IS NULL)::int
    + (paid_by_petty_cash_txn_id IS NULL)::int >= 1  -- 兩者不能同時有
  )
);

CREATE INDEX idx_expenses_status ON expenses (tenant_id, approval_status);
CREATE INDEX idx_expenses_store ON expenses (tenant_id, store_id, expense_date DESC);
CREATE INDEX idx_expenses_applicant ON expenses (applicant_id, approval_status);
```

### 3.8 新增表：`expense_categories`（主檔）

```sql
CREATE TABLE expense_categories (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  parent_id BIGINT REFERENCES expense_categories(id),
  approval_threshold NUMERIC(18,4),                    -- 超過需審核
  default_pay_method TEXT
    CHECK (default_pay_method IN ('petty_cash', 'company_account', 'either', NULL)),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);
```

**Seed data**（v0.2 初始）：交通 / 文具 / 餐飲 / 通訊 / 水電 / 雜支 / 修繕 / 採購雜項。

---

## 4. 業務流程

### 4.1 Vendor Bill 建立（來自 4 個來源）

**Source 1：PO 收貨後**
```
GR confirm → trigger 建 vendor_bill（source_type='goods_receipt'）
  amount = SUM(gr_items.qty_received * unit_cost)
  supplier_id = gr.supplier_id
  due_date = gr.receive_date + supplier.payment_terms（解析為天）
  status='pending'
```

**Source 2：xiaolan 匯入 resolve**
```
admin 在 xiaolan tab 按 resolve → RPC rpc_resolve_xiaolan_purchase
  → 建 purchase_order
  → 建 vendor_bill（source_type='xiaolan_import', source_id=xiaolan_purchase.id）
```

**Source 3：transfer settlement confirm（Flag 8）**
```
admin confirm 月結算 → rpc_confirm_transfer_settlement
  → 若 net > 0 → 建 vendor_bill（source_type='transfer_settlement', source_id=settlement.id）
    supplier_id = debtor_store 對應的 supplier（§4.7 mapping）
```

**Source 4：手動**
```
admin UI 手動建 bill（會計補登）→ RPC rpc_create_manual_bill
  source_type='manual', source_id=NULL
```

### 4.2 Vendor Payment 流程（MakePayment）

```
admin 選 supplier → 顯示該 supplier 所有 pending/partially_paid bills →
  勾選要付的 bills + 填 allocation amount（可分配部分 / 跨多張）→
  選 payment method + bank_account / check_no →
  RPC rpc_make_payment(payment, allocations[])
    前置:
      pg_advisory_xact_lock('vpay:' || supplier_id)
      for each alloc: SELECT FOR UPDATE bill + 驗 bill.paid_amount + alloc.allocated <= bill.amount
    執行:
      INSERT INTO vendor_payments (...)
      for each alloc:
        INSERT INTO vendor_payment_allocations (payment_id, bill_id, allocated_amount)
        UPDATE vendor_bills SET paid_amount += alloc.allocated,
          status = CASE WHEN paid_amount = amount THEN 'paid' ELSE 'partially_paid' END
      若 method='petty_cash' → 同步走 §4.4 零用金流水
```

### 4.3 Expense 申請 → 審核 → 支付

```
員工建 expense（category, amount, photo）→ approval_status='pending'
  若 amount < category.approval_threshold → 自動 approved
  否則 → 等上層審
approver → RPC rpc_approve_expense(expense_id, note) or rpc_reject_expense(expense_id, reason)
  → approval_status='approved'
approved expense 進「待支付」清單 →
  admin 選支付方式：
    option A: 從公司帳戶 → rpc_pay_expense_via_vendor_payment
      → 建 vendor_payment（supplier_id = 員工個人 supplier，或通用 '內部費用' supplier）
      → 建 vendor_bill（source_type='manual' + expense_id 寫 note）
      → allocate payment → bill → expense.paid_by_vendor_payment_id, approval_status='paid'
    option B: 從零用金 → rpc_pay_expense_via_petty_cash
      → 建 petty_cash_transactions（direction='out', expense_id=...）
      → expense.paid_by_petty_cash_txn_id, approval_status='paid'
```

### 4.4 零用金流水（PettyCashPanel）

```
每月補款（admin）→ rpc_post_petty_cash_txn(account_id, direction='in', amount, purpose='月補款')
  → balance += amount
員工用零用金買東西（走 expense → §4.3 B）
  → petty_cash_txn direction='out'
  → balance -= amount
  → 若 balance + credit_limit < 0 → RAISE EXCEPTION
月底對帳：account.balance 應 = 實際盒內現金
```

### 4.5 Aging Report（應付帳齡）

```sql
CREATE OR REPLACE VIEW v_ap_aging AS
SELECT
  supplier_id,
  supplier_name,
  SUM(CASE WHEN due_date >= CURRENT_DATE THEN unpaid END) AS current_due,
  SUM(CASE WHEN due_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1 THEN unpaid END) AS "1_30_overdue",
  SUM(CASE WHEN due_date BETWEEN CURRENT_DATE - 60 AND CURRENT_DATE - 31 THEN unpaid END) AS "31_60_overdue",
  SUM(CASE WHEN due_date < CURRENT_DATE - 60 THEN unpaid END) AS "60_plus_overdue",
  SUM(unpaid) AS total_unpaid
FROM (
  SELECT b.supplier_id, s.name AS supplier_name, b.due_date,
         b.amount - b.paid_amount AS unpaid
  FROM vendor_bills b JOIN suppliers s ON s.id = b.supplier_id
  WHERE b.status IN ('pending', 'partially_paid')
) sub
GROUP BY supplier_id, supplier_name;
```

### 4.6 Cash Flow Report

```sql
-- 每月 cash flow: in(AR 已收) - out(AP 已付) + petty_cash 淨流出
CREATE OR REPLACE VIEW v_cash_flow_monthly AS ...
```

（具體 SQL 在 migration 階段定；PRD 層級先定義有此 view）

### 4.7 加盟店 supplier mapping（Flag 8 依賴）

- 每家 `stores` 在 `suppliers` 表有對應 row
- 建 store 時 trigger：`INSERT INTO suppliers (code='STORE-' || store.code, name=store.name, ...)`
- `stores` 加欄位 `supplier_id BIGINT REFERENCES suppliers(id)` 直接 link
- PRD #2 §4.6 `rpc_confirm_transfer_settlement` 用此 mapping

**Schema delta**（補進本 PRD）：
```sql
ALTER TABLE stores ADD COLUMN supplier_id BIGINT REFERENCES suppliers(id);

CREATE OR REPLACE FUNCTION sync_store_as_supplier() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.supplier_id IS NULL THEN
    INSERT INTO suppliers (tenant_id, code, name, is_active, created_by)
    VALUES (NEW.tenant_id, 'STORE-' || NEW.code, NEW.name, TRUE, NEW.created_by)
    RETURNING id INTO NEW.supplier_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_store_as_supplier BEFORE INSERT ON stores
  FOR EACH ROW EXECUTE FUNCTION sync_store_as_supplier();
```

---

## 5. RPC / API

列核心 6 支，其他在 migration 階段補全：

| RPC | 權限 | 作用 |
|---|---|---|
| `rpc_create_manual_bill(payload)` | admin | 手動建 bill |
| `rpc_make_payment(payment, allocations[])` | admin / hq_manager | 付款 + 分配到多張 bill |
| `rpc_add_expense(payload)` | authenticated | 員工申請費用 |
| `rpc_approve_expense(expense_id, note)` | approver role | 審核通過 |
| `rpc_reject_expense(expense_id, reason)` | approver role | 審核退回 |
| `rpc_post_petty_cash_txn(account_id, direction, amount, purpose)` | store_manager / admin | 零用金流水 |

**共通防禦**：
- 所有 RPC `SECURITY DEFINER`
- 鎖的 scope 以 supplier 或 account 為單位 (`pg_advisory_xact_lock`)
- 寫操作必 `SELECT ... FOR UPDATE` 先鎖再寫
- 返回 JSONB with error detail（不用 HTTP 400、用 PostgreSQL EXCEPTION 向上拋）

---

## 6. RLS Policy

### 6.1 `vendor_bills` / `vendor_bill_items` / `vendor_payments` / `vendor_payment_allocations`

- admin / hq_accountant：ALL
- store_manager：SELECT where 關聯 supplier_id = store.supplier_id（自己店被代收代付的 bill）
- 其他 role：看不到

### 6.2 `petty_cash_accounts` / `petty_cash_transactions`

- store_manager (custodian)：SELECT own store + INSERT txn（自己保管的 account）
- admin：ALL
- 其他店：看不到別店 petty_cash

### 6.3 `expenses`

- applicant：SELECT own + INSERT own + UPDATE own if status='pending'
- approver role：SELECT where amount >= threshold AND status='pending'
- admin：ALL

### 6.4 `expense_categories`

- 任何 authenticated：SELECT
- admin：INSERT / UPDATE / DELETE

---

## 7. 稽核

| 表 | 類型 | 稽核欄位 |
|---|---|---|
| `vendor_bills` | 主檔 | 四欄全帶 |
| `vendor_bill_items` | append-only | `created_at` only（bill_id 繼承 bill.created_by） |
| `vendor_payments` | 主檔 | 四欄全帶 |
| `vendor_payment_allocations` | append-only | `created_at` only |
| `petty_cash_accounts` | 主檔 | 四欄全帶 + `custodian_user_id` 追保管人變更 |
| `petty_cash_transactions` | append-only | `created_by` + `created_at` |
| `expenses` | 主檔 | 四欄全帶 + `approved_by`/`approved_at` 追審核動作 |
| `expense_categories` | 主檔 | 四欄全帶 |

**審核動作稽核不新開 log 表** — 依賴主檔本身欄位（approved_by / reviewed_at 等）。若 pilot 反饋需詳細 log 再建 P1。

---

## 8. 反模式避開

| # | 反模式 | 本 PRD 處理 |
|---|---|---|
| 1 | shared_kv | 全用正規表 |
| 2 | silent write failures | RPC 全 RAISE EXCEPTION |
| 3 | REST PATCH 副作用 | bill status / payment allocation 一律 RPC |
| 5 | state 只在 memory | 所有金額狀態落 DB |
| **新** | double-payment race | `pg_advisory_xact_lock('vpay:' || supplier_id)` + bill `SELECT FOR UPDATE` |
| **新** | petty cash 超支 | petty_cash_accounts.balance trigger 維護 + credit_limit CHECK |
| **新** | expense 循環批准 | RPC 檢查 `applicant_id != approved_by`（不可自審） |

---

## 9. 與其他模組的整合點

- **採購模組**（PRD #3）：GR confirm → 自動建 vendor_bill（§4.1 Source 1）
- **供應商整合**（PRD #4）：xiaolan resolve → 建 vendor_bill（§4.1 Source 2）
- **庫存模組**（PRD #2）：transfer_settlement confirm → 建 vendor_bill（§4.1 Source 3，Flag 8）
- **銷售模組**（既有）：銷售 `payments` 表是 AR；本模組 `vendor_payments` 是 AP；兩者不共用表但 cash flow view 合併
- **會員模組**（既有）：不直接耦合；員工 expense 的 applicant_id = `members.id`（若 is_employee）
- **通知模組**（既有）：
  - bill due 提醒：due_date - 7 天 → LINE OA
  - expense approval pending：> 24h → approver 收 LINE
  - 月結算 bill 新建 → debtor store 收通知

---

## 10. Open Questions

- [ ] **發票比對**：lt-erp 無、new_erp 考慮 P1 做（上傳 PDF → OCR → 自動 match bill）；v0.2 用 `supplier_invoice_no` 欄位手動填
- [ ] **預算管控**：category 是否加 monthly_budget？超過警示？v1 不做；pilot 反饋再決定
- [ ] **跨店 expense 代墊**：B 店員工出差 A 店事件，expense 算 B 店還是 A 店？目前 `store_id` 自填；未來可能加 `on_behalf_of_store_id`
- [ ] **外匯**：陸貨採購 1688 人民幣 → 匯率怎麼算？v1 TWD only，bill 上用「匯率鎖定當日」算 TWD amount；P1 做 multi-currency
- [ ] **加盟店 supplier 自動建**：§4.7 的 trigger 是否要真的「每家 store 都自動建」— 可能造成 supplier 表膨脹；A. 自動（現況）/ B. 手動（admin 決定）
- [ ] **月結算 bill 的 supplier 歸屬**：加盟店 A 欠 B → bill 的 supplier_id = B 店對應 supplier；但加盟主之間可能覺得「不要讓對方看到我的 supplier id」— 是否需要中介抽象？

---

## 11. 相關檔案

- 決議文件：[[decisions/2026-04-22-v0.2-scope-decisions]] Q4
- 關聯 PRD：
  - [[PRD-採購模組-v0.2-addendum]] § 業務流程（GR → bill）
  - [[PRD-供應商整合-v0.2]] § xiaolan resolve
  - [[PRD-庫存模組-v0.2-addendum]] §3.5（settlement → bill，Flag 8）
- 整合計畫：`C:\Users\Alex\.claude\plans\snazzy-riding-toucan.md` §1（應收/應付/現金）、§3 Phase 4（本 PRD 補進）
- 後續：`supabase/migrations/20260423*_ap_petty_expense.sql`（8 張表 + RLS + trigger + seed categories）

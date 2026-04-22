---
title: PRD - 採購模組 v0.2 Addendum
module: Purchase
status: draft-v0.2
owner: alex.chen
created: 2026-04-22
updated: 2026-04-22
base: PRD-採購模組.md (v0.1)
tags: [PRD, ERP, v0.2, addendum, 採購, lt-erp-integration, pending-review, import-land-goods]
---

# PRD — 採購模組 v0.2 Addendum

> 本文件為 [[PRD-採購模組]] v0.1 的 **增補**。
> 驅動原因：lt-erp 有 `PendingReview` 內部審核 + 陸貨多月到貨追蹤 + 1688 / 拼多多 import，new_erp v0.1 未列。
> 決議來源：[[decisions/2026-04-22-v0.2-scope-decisions]] Q5（退回龍潭 enum 合併）、Q3（Apps Script monorepo）。
> **注意**：供應商 Google Sheets sync（xiaolan_* 表 + Apps Script）獨立在 [[PRD-供應商整合-v0.2]]，不在本 addendum。

---

## 1. v0.2 增補範疇

| # | 新增功能 | 類型 |
|---|---|---|
| 1 | **PR → PO 內部審核（pending_review）** | 既有 `purchase_requests` 加 status + 新 RPC × 2 |
| 2 | **陸貨多月到貨追蹤** | 既有 `suppliers` 加 `is_overseas` + `goods_receipts` 加 4 欄 + 新 view |
| 3 | **退回龍潭收貨（GR 退貨）觸發 return_to_hq transfer** | 既有 `purchase_returns` flow 微調（參考 PRD #2 Q5） |
| 4 | **漂漂館 sub-brand 識別** | 既有 `brands` 加 `is_sub_brand` flag |
| 5 | **1688 / 拼多多 訂單 import hook** | 新 staging table + RPC（實際 parse 在 Apps Script，見 PRD #4） |

**不改動**：v0.1 的 `purchase_orders` / `purchase_order_items` / `suppliers` / `supplier_skus` / `purchase_returns` 主體全部保留。

---

## 2. 資料模型

### 2.1 既有表欄位補充：`purchase_requests`（PR 內部審核）

```sql
ALTER TABLE purchase_requests
  ADD COLUMN review_status TEXT NOT NULL DEFAULT 'approved'
    CHECK (review_status IN ('pending_review', 'approved', 'rejected')),
  ADD COLUMN review_note TEXT,
  ADD COLUMN reviewed_by UUID,
  ADD COLUMN reviewed_at TIMESTAMPTZ,
  ADD COLUMN review_threshold_amount NUMERIC(18,4);  -- 觸發審核的金額門檻快照

CREATE INDEX idx_pr_review_status ON purchase_requests (tenant_id, review_status)
  WHERE review_status = 'pending_review';
```

**為何獨立 `review_status`**（不改現有 `status`）：
- v0.1 的 `status` 是 PR 生命週期（draft → submitted → closed）
- `review_status` 是**內部審核**的正交狀態：任何 PR 被建立後、若金額 ≥ 門檻 → 自動標 `pending_review`
- 兩維度獨立讓邏輯清晰：`status='submitted' AND review_status='pending_review'`

### 2.2 新增表：`purchase_approval_thresholds`（主檔、可編輯）

```sql
CREATE TABLE purchase_approval_thresholds (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('global', 'category', 'supplier', 'store')),
  scope_id BIGINT,                                     -- NULL for 'global'
  threshold_amount NUMERIC(18,4) NOT NULL CHECK (threshold_amount >= 0),
  approver_role TEXT NOT NULL DEFAULT 'admin'
    CHECK (approver_role IN ('admin', 'hq_manager', 'owner')),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_pat_scope ON purchase_approval_thresholds (tenant_id, scope, COALESCE(scope_id, 0))
  WHERE active = TRUE;
```

**為何可設多 scope**：lt-erp 的 PendingReview 只有單一門檻，new_erp 改為多層（global 預設 / 某 category / 某 supplier）— 更貼近業態（陸貨常超大額、本地蔬果小額）。

### 2.3 既有表欄位補充：`suppliers`（海外旗標，Flag 11 A）

v0.1 `suppliers` 缺 `is_overseas`，本 addendum 補：

```sql
ALTER TABLE suppliers
  ADD COLUMN is_overseas BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX idx_suppliers_overseas ON suppliers (tenant_id, is_overseas)
  WHERE is_overseas = TRUE;
```

**使用情境**：
- `is_overseas=TRUE` → 建 PO 時 trigger 自動標 `goods_receipts.is_land_goods=TRUE`
- 初始資料：`UPDATE suppliers SET is_overseas=TRUE WHERE code IN (...)`（pilot migration 階段人工標）
- 不依賴 `lead_time_days` 推論（避免誤判：本地供應商也可能 lead time 長）

### 2.4 既有表欄位補充：`goods_receipts`（陸貨多月到貨）

```sql
ALTER TABLE goods_receipts
  ADD COLUMN expected_arrival_date DATE,               -- PO 建立時推估
  ADD COLUMN arrival_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (arrival_status IN ('pending', 'arrived', 'delayed', 'partial', 'cancelled')),
  ADD COLUMN arrival_note TEXT,                        -- 延遲原因（供應商回覆）
  ADD COLUMN is_land_goods BOOLEAN NOT NULL DEFAULT FALSE;  -- 陸貨 flag（影響到貨追蹤邏輯）

CREATE INDEX idx_gr_arrival ON goods_receipts (tenant_id, arrival_status, expected_arrival_date)
  WHERE arrival_status IN ('pending', 'delayed');
```

**為何**：
- 陸貨採購週期長（2~4 個月）、需要追蹤 ETA + 延遲狀態
- `is_land_goods=TRUE` 的 GR 在 admin dashboard 單獨一區列出
- 其他 supplier 的 GR 預設 `is_land_goods=FALSE`、不顯示在追蹤區
- `is_land_goods` 由 GR on-insert trigger 自動填（依 supplier.is_overseas）

### 2.5 新增 DB view：`v_pending_arrivals`（陸貨到貨追蹤）

```sql
CREATE OR REPLACE VIEW v_pending_arrivals AS
SELECT
  gr.id                 AS gr_id,
  gr.tenant_id,
  gr.gr_no,
  gr.po_id,
  po.po_no,
  po.supplier_id,
  sup.name              AS supplier_name,
  gr.expected_arrival_date,
  gr.arrival_status,
  gr.arrival_note,
  EXTRACT(DAY FROM NOW() - gr.expected_arrival_date)::INT AS days_overdue,
  (SELECT SUM(qty_expected * unit_cost)
     FROM goods_receipt_items gri
     WHERE gri.gr_id = gr.id)  AS expected_value
FROM goods_receipts gr
JOIN purchase_orders po ON po.id = gr.po_id
JOIN suppliers sup ON sup.id = gr.supplier_id
WHERE gr.is_land_goods = TRUE
  AND gr.arrival_status IN ('pending', 'delayed');
```

Admin 儀表 filter `days_overdue > 0` 顯示警示。

### 2.6 既有表欄位補充：`brands`（漂漂館）

```sql
ALTER TABLE brands
  ADD COLUMN is_sub_brand BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN parent_brand_id BIGINT REFERENCES brands(id);

CREATE INDEX idx_brands_sub ON brands (tenant_id, parent_brand_id)
  WHERE is_sub_brand = TRUE;
```

**為何不新開 table**：lt-erp 把「漂漂館」當獨立模組，其實是本店的子品牌（共用 SKU 系統）；new_erp 用 brand 層級搞定、不需新 module。

**使用情境**：
- `brands` 表插一筆 `{name: '漂漂館', is_sub_brand: TRUE, parent_brand_id: <本店品牌 id>}`
- `products.brand_id` 可指向漂漂館 brand id → 自動歸類
- Report / 報表 可依 `is_sub_brand` filter

### 2.7 新增表：`external_purchase_imports`（1688 / 拼多多 staging）

```sql
CREATE TABLE external_purchase_imports (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('1688', 'pinduoduo', 'taobao', 'other')),
  batch_id TEXT NOT NULL,
  raw_row JSONB NOT NULL,                              -- Apps Script fetch 的原始資料
  parsed_sku_id BIGINT REFERENCES skus(id),
  parsed_supplier_id BIGINT REFERENCES suppliers(id),
  parsed_qty NUMERIC(18,3),
  parsed_unit_cost NUMERIC(18,4),
  parsed_amount NUMERIC(18,4),
  parsed_expected_arrival_date DATE,
  resolved_po_id BIGINT REFERENCES purchase_orders(id),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'resolved', 'skipped', 'error')),
  error_message TEXT,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only
);

CREATE INDEX idx_ext_pur_batch ON external_purchase_imports (tenant_id, batch_id);
CREATE INDEX idx_ext_pur_status ON external_purchase_imports (tenant_id, status);
```

**append-only** — 僅 `created_by` + `created_at`。

**資料流**：
- Apps Script (PRD #4 `apps-script/marketplace-import/`) 定時 fetch 1688 / 拼多多訂單 API → POST 到 Supabase REST → INSERT external_purchase_imports
- admin 在 new_erp 後台「待處理匯入」tab → preview + SKU match
- 確認 → RPC `rpc_resolve_external_purchase(batch_id)` → 批次建 `purchase_orders` + `purchase_order_items`

---

## 3. 業務流程

### 3.1 PR 內部審核（pending_review）

```
小幫手建 purchase_request →
  系統 on_insert trigger：
    select applicable threshold from purchase_approval_thresholds
      (scope precedence: supplier > category > store > global)
    if PR.total_amount >= threshold:
      UPDATE PR SET review_status = 'pending_review', review_threshold_amount = threshold
    else:
      review_status = 'approved'（default）
審核者（依 approver_role）→ 到「待審核」tab 看列表 →
  選項 A: approve → RPC rpc_approve_purchase_request(pr_id, note)
    → review_status='approved' + reviewed_by/at 寫入
    → 若 PR.status='draft' 自動推進 → 'submitted'（進下一階段）
  選項 B: reject → RPC rpc_reject_purchase_request(pr_id, note)
    → review_status='rejected' + 原 PR.status 不變（讓小幫手看到後改）
建 PO（rpc_create_po_from_pr）要求 review_status='approved' 才能生成
```

### 3.2 陸貨多月到貨追蹤

```
admin 建 PO（supplier = 陸貨供應商） →
  自動推估 expected_arrival_date（依 supplier.lead_time_days）
  自動標 goods_receipts.is_land_goods = TRUE（基於 supplier.is_overseas flag）
admin dashboard「陸貨到貨追蹤」→ 看 v_pending_arrivals →
  動作：
    更新 ETA（arrival_note 記原因）→ rpc_update_arrival_eta(gr_id, new_eta, note)
    標為「已到」→ 走既有 GR confirm flow
    標為「延遲」→ status='delayed' + 通知對應有此 SKU 訂單的 admin
  通知模組 hook：若同 SKU 有未結 customer_order_items → 觸發「未到貨積壓」事件（PRD #1 §2.7）
```

### 3.3 退回龍潭（與 PRD #2 Q5 銜接）

```
總倉對某批 GR 要退貨給供應商 →
  已有 purchase_returns flow（v0.1）走退貨 → status='shipped'
  同時：加盟店退貨給總倉（退回龍潭）= 走 PRD #2 的 transfer_type='return_to_hq'
  兩者互相獨立、但**同一張 GR 可能兩邊都走**：
    加盟店 → 總倉（transfer return_to_hq）→ 總倉 → 供應商（purchase_return）
  admin dashboard 需要顯示「批次 X：已從 N 家店退回、已退供應商 M」→ 查兩張表 JOIN
```

**不新增 schema**：走既有 `purchase_returns` + `transfers.transfer_type` 雙表；只在 admin UI 合併顯示。

### 3.4 1688 / 拼多多 匯入（概要，詳細流程在 PRD #4）

```
Apps Script (apps-script/marketplace-import/) 每 6 小時 fetch 一次 →
  寫 external_purchase_imports (status='pending')
admin 在 new_erp → 待匯入 tab →
  SKU match（auto by supplier_sku_code, 無 match 顯示候選）
  supplier match（by 店家名 / 關鍵字）
  確認 → RPC rpc_resolve_external_purchase(batch_id)
```

---

## 4. RPC / API

### 4.1 `rpc_approve_purchase_request(p_pr_id, p_note)` (approver-role-only)

```sql
-- 前置:
--   檢查 auth.role IN (threshold.approver_role)
--   SELECT ... FOR UPDATE on purchase_requests WHERE id = p_pr_id AND review_status = 'pending_review'
-- 執行:
--   UPDATE purchase_requests
--     SET review_status='approved', review_note=p_note,
--         reviewed_by=auth.uid(), reviewed_at=NOW()
--   若原 status='draft' → UPDATE status='submitted'
-- 返回: void
```

### 4.2 `rpc_reject_purchase_request(p_pr_id, p_note)` (同上)

```sql
-- 類似 approve：review_status='rejected', reviewed_by/at, note 必填
-- 不改 PR.status（讓小幫手看到後自行修改再重跑）
```

### 4.3 `rpc_update_arrival_eta(p_gr_id, p_new_eta, p_note)`

```sql
-- 前置:
--   SELECT ... FOR UPDATE on goods_receipts
--     WHERE id = p_gr_id AND arrival_status IN ('pending', 'delayed')
-- 執行:
--   若 p_new_eta > 原 expected_arrival_date + 7 day → arrival_status='delayed'
--   否則 → arrival_status='pending'
--   UPDATE expected_arrival_date + arrival_note, updated_by
-- 通知觸發（若 delayed）:
--   INSERT INTO notification_events(type='arrival_delayed', target=hq_admins, ...)
-- 返回: void
```

### 4.4 `rpc_resolve_external_purchase(p_batch_id)` (admin-only)

```sql
-- 前置: 檢查 auth.role = 'admin'
-- 執行:
--   loop external_purchase_imports WHERE batch_id = p_batch_id AND status='pending'
--     若 parsed_sku_id IS NULL OR parsed_supplier_id IS NULL → status='error', skip
--     GROUP BY parsed_supplier_id:
--       INSERT INTO purchase_orders (tenant, supplier, order_date, expected_arrival_date, source='marketplace')
--       for each row in group:
--         INSERT INTO purchase_order_items (po_id=new, sku_id, qty, unit_cost)
--         UPDATE external_purchase_imports SET resolved_po_id=new_po_id, status='resolved'
-- 返回: JSONB {pos_created: N, items_created: M, errors: K}
```

---

## 5. RLS Policy

### 5.1 `purchase_requests`（review_status 加入）

現有 policy 保留；新增：
- `review_status='pending_review'` 的 PR：發起人 store 可 SELECT；approver role（admin / hq_manager）可 UPDATE（走 RPC）
- `review_status='rejected'`：發起人能看到 reject 原因（前端顯示 `review_note`）

### 5.2 `purchase_approval_thresholds`

- admin / owner：ALL
- 其他 role：SELECT only（看得到規則、但不能改）

### 5.3 `goods_receipts`（欄位擴充後）

現有 policy 保留；`is_land_goods` / `arrival_status` 都是資料欄位、不影響 RLS 維度。

### 5.4 `external_purchase_imports`

- admin：ALL
- 其他 role：看不到（這是總倉作業）

### 5.5 `brands`（欄位擴充後）

現有 policy 保留。

---

## 6. 稽核

| 表 | 類型 | 稽核欄位 |
|---|---|---|
| `purchase_requests`（擴充）| 主檔 | 既有 4 欄 + 新增 `reviewed_by` / `reviewed_at` 記審核動作 |
| `purchase_approval_thresholds` | 主檔 | 四欄全帶 |
| `suppliers`（擴充）| 主檔 | 既有 4 欄 |
| `goods_receipts`（擴充）| 主檔 | 既有 4 欄 |
| `brands`（擴充）| 主檔 | 既有 4 欄 |
| `external_purchase_imports` | append-only | `created_by` + `created_at` only |

審核動作額外稽核：
- `rpc_approve_purchase_request` / `rpc_reject_purchase_request` 都寫 `purchase_audit_log`（若 v0.1 已有；否則共用既有稽核機制）
- 若無 `purchase_audit_log`、`purchase_requests.updated_by/at` 就是 SSOT

---

## 7. 反模式避開

對應 integration plan §4：

| # | 反模式 | 本 addendum 處理 |
|---|---|---|
| 2 | silent write failures | RPC 全部 `RAISE EXCEPTION` |
| 3 | REST PATCH 副作用 | `review_status` 轉移只能走 RPC |
| 5 | state 只在 memory | review / arrival 狀態全落 DB |
| 7 | 搬家邏輯讀寫分離 | 不處理（本 addendum 不涉及歷史資料 import） |

**新反模式（陸貨特有）**：
- ETA 多次更新沒有歷史 → 每次走 RPC 記 `arrival_note`（累加 append-style：`2026-04-22: 供應商回覆延一週\n2026-04-29: 再延`）
- 若 pilot 反饋需要獨立 `arrival_eta_history` 表再開 P1

---

## 8. Open Questions

- [ ] **PR 審核的通知**：目前靠 admin 主動到 tab 看；是否該加「pending 超過 24h → LINE 通知 approver」（通知模組 v0.2 hook）
- [x] ~~**陸貨 supplier 識別**~~：Flag 11 A — v0.1 無此欄位、本 addendum §2.3 補 `suppliers.is_overseas`
- [ ] **`purchase_approval_thresholds` scope precedence 是否需要 UI**：目前 RPC 硬編 `supplier > category > store > global`；若 pilot 要調整 → 加 `priority INT` 欄位
- [ ] **marketplace import 的錯誤處理**：parsed_sku_id IS NULL 的 rows 是否有 auto-suggest 機制（bigm model 查過歷史 supplier_sku_code）— 留 P1
- [ ] **1688 / 拼多多 API 憑證**：存在哪（Supabase Vault / 環境變數 / Apps Script PropertiesService）— 在 PRD #4 統一定

---

## 9. 相關檔案

- 主文：[[PRD-採購模組]] v0.1
- 整合計畫：`C:\Users\Alex\.claude\plans\snazzy-riding-toucan.md` §1（採購）、§3 Phase 3.5
- 決議文件：[[decisions/2026-04-22-v0.2-scope-decisions]] Q3, Q5
- 關聯 PRD：
  - [[PRD-供應商整合-v0.2]]（Apps Script marketplace 實作）
  - [[PRD-庫存模組-v0.2-addendum]] §2.1（`transfer_type='return_to_hq'`）
- 後續：`supabase/migrations/20260423*_purchase_review_arrival.sql`（下次 session）

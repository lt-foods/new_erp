---
title: PRD - 訂單 / 取貨模組 v0.2 Addendum
module: Order
status: draft-v0.2
owner: alex.chen
created: 2026-04-22
updated: 2026-04-22
base: PRD-訂單取貨模組.md (v0.1.1)
tags: [PRD, ERP, v0.2, addendum, 訂單, 取貨, lt-erp-integration, picking-wave, matrix]
---

# PRD — 訂單 / 取貨模組 v0.2 Addendum

> 本文件為 [[PRD-訂單取貨模組]] v0.1.1 的 **增補** — 不重複 v0.1 內容，只列 v0.2 新增 / 變更。
> 驅動原因：lt-erp feature audit 後確認 `admin`/`branch_admin` 核心 UX 要照搬（**開團總表 matrix + 揀貨波次**）。
> 決議來源：[[decisions/2026-04-22-v0.2-scope-decisions]]（Q2 保守 advisory lock、Q5 transfer enum）。

---

## 1. v0.2 增補範疇

| # | 新增功能 | 類型 |
|---|---|---|
| 1 | **開團總表 matrix**（store × product 數量格）| 新 UX view（dataset 用既有表） |
| 2 | **揀貨波次（picking waves）** | 新 table × 3（含 audit log）+ 新 RPC × 3 |
| 3 | **結單日（cutoff_date）顯式欄位** | `group_buy_campaigns` 加 1 欄位 |
| 4 | **未到貨積壓檢視** | 新 DB view |
| 5 | **樂樂 CSV 匯入** | 新 staging table + import flow |

**不改動**：v0.1 的核心流程（campaign 建立 / 下單登打 / 取貨）全部保留；本 addendum 是「結單後的後端作業」補強 + 「開團期間的 admin 儀表」補強。

---

## 2. 資料模型

### 2.1 既有表欄位補充（`group_buy_campaigns`）

```sql
ALTER TABLE group_buy_campaigns
  ADD COLUMN cutoff_date DATE,                         -- 結單日（明確存）
  ADD COLUMN expected_arrival_date DATE,               -- 預計到貨日
  ADD COLUMN matrix_row_order INTEGER DEFAULT 0;       -- 總表排序（手動拖拉）

CREATE INDEX idx_gbc_cutoff_date ON group_buy_campaigns (tenant_id, cutoff_date)
  WHERE status IN ('open', 'closed');
```

**為何**：
- `cutoff_date`：lt-erp 概念直接對應（未來報表 / 統計 group by cutoff_date 很常用）
- `expected_arrival_date`：配送排程需要；與採購模組 `goods_receipts.expected_arrival_date` 協同（v0.2 採購 addendum 補）
- `matrix_row_order`：總表手動排序（admin 拖拉）

### 2.2 新增表：`picking_waves`（主檔、可編輯）

```sql
CREATE TABLE picking_waves (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  wave_code TEXT NOT NULL,                             -- 人類可讀 '2026W17-A'
  wave_date DATE NOT NULL,                             -- 波次執行日
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'picking', 'picked', 'shipped', 'cancelled')),
  store_count INTEGER NOT NULL DEFAULT 0,
  item_count INTEGER NOT NULL DEFAULT 0,               -- 不同 SKU 數
  total_qty NUMERIC(18,3) NOT NULL DEFAULT 0,
  note TEXT,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, wave_code)
);

CREATE INDEX idx_waves_date ON picking_waves (tenant_id, wave_date DESC);
CREATE INDEX idx_waves_status ON picking_waves (tenant_id, status);
```

### 2.3 新增表：`picking_wave_items`（明細、可編輯 picked_qty）

```sql
CREATE TABLE picking_wave_items (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  wave_id BIGINT NOT NULL REFERENCES picking_waves(id) ON DELETE CASCADE,
  sku_id BIGINT NOT NULL REFERENCES skus(id),
  store_id BIGINT NOT NULL REFERENCES stores(id),
  qty NUMERIC(18,3) NOT NULL,                          -- 計畫揀貨數
  picked_qty NUMERIC(18,3),                            -- 實際揀貨數（NULL = 未完成）
  campaign_id BIGINT REFERENCES group_buy_campaigns(id),  -- 對應 campaign
  generated_order_id BIGINT REFERENCES sales_orders(id),  -- 揀完生成的 SO
  note TEXT,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (wave_id, sku_id, store_id)
);

CREATE INDEX idx_wave_items_wave ON picking_wave_items (wave_id);
CREATE INDEX idx_wave_items_store ON picking_wave_items (tenant_id, store_id, wave_id);
```

**稽核四欄位**：兩表都是可編輯主檔、帶全欄（依 `feedback_audit_columns.md`）。

### 2.4 新增表：`picking_wave_audit_log`（append-only log）

```sql
CREATE TABLE picking_wave_audit_log (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  wave_id BIGINT NOT NULL REFERENCES picking_waves(id) ON DELETE CASCADE,
  wave_item_id BIGINT REFERENCES picking_wave_items(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN (
    'wave_created', 'wave_status_changed', 'item_added', 'item_removed',
    'picked_qty_changed', 'so_generated', 'wave_cancelled'
  )),
  before_value JSONB,                                  -- 變更前快照（applicable field）
  after_value JSONB,                                   -- 變更後快照
  note TEXT,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only：不帶 updated_*
);

CREATE INDEX idx_wave_audit_wave ON picking_wave_audit_log (tenant_id, wave_id, created_at DESC);
CREATE INDEX idx_wave_audit_item ON picking_wave_audit_log (wave_item_id) WHERE wave_item_id IS NOT NULL;
```

**為何獨立 log 表**：
- `picked_qty` 變動會很頻繁（揀貨現場每掃一次條碼就寫一次）— 借 `stock_movements` 語意不對（物流移動 vs 揀貨進度）
- Wave status 轉移 + item 增減也要追蹤 → 用統一 log 表一次解決
- append-only（依 `feedback_audit_columns.md`）：僅 `created_by` + `created_at`

**寫入來源**：
- `rpc_create_picking_wave` → `action='wave_created'`
- `rpc_update_picked_qty(wave_item_id, new_qty)` → `action='picked_qty_changed'`
- `generate_sales_order_from_wave` → `action='so_generated'`（每張 SO 寫一筆）

### 2.5 新增表：`external_order_imports`（樂樂 CSV staging）

```sql
CREATE TABLE external_order_imports (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('lele', 'shopee', 'other')),
  batch_id TEXT NOT NULL,                              -- 小幫手上傳批次
  raw_row JSONB NOT NULL,                              -- 原始 CSV row
  parsed_sku_id BIGINT REFERENCES skus(id),
  parsed_customer_identifier TEXT,
  parsed_qty NUMERIC(18,3),
  parsed_amount NUMERIC(18,4),
  resolved_order_id BIGINT REFERENCES customer_orders(id),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'resolved', 'skipped', 'error')),
  error_message TEXT,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- Append-only：不帶 updated_*
);

CREATE INDEX idx_ext_imports_batch ON external_order_imports (tenant_id, batch_id);
CREATE INDEX idx_ext_imports_status ON external_order_imports (tenant_id, status);
```

**append-only**（依 `feedback_audit_columns.md`）：僅 `created_by` + `created_at`。

### 2.6 新增 DB view：`v_open_group_matrix`（開團總表 dataset）

```sql
CREATE OR REPLACE VIEW v_open_group_matrix AS
SELECT
  gbc.id            AS campaign_id,
  gbc.tenant_id,
  gbc.cutoff_date,
  gbc.matrix_row_order,
  ci.sku_id,
  s.name            AS store_name,
  coi.channel_id,
  lc.home_location_id AS store_id,
  SUM(coi.qty)      AS total_qty,
  COUNT(DISTINCT co.member_id) AS customer_count
FROM group_buy_campaigns gbc
JOIN campaign_items ci ON ci.campaign_id = gbc.id
LEFT JOIN customer_order_items coi ON coi.campaign_item_id = ci.id
LEFT JOIN customer_orders co ON co.id = coi.order_id
LEFT JOIN line_channels lc ON lc.id = co.channel_id
LEFT JOIN stores s ON s.id = lc.home_location_id
WHERE gbc.status IN ('open', 'closed')
GROUP BY gbc.id, gbc.tenant_id, gbc.cutoff_date, gbc.matrix_row_order,
         ci.sku_id, s.name, coi.channel_id, lc.home_location_id;
```

UI pivot：rows = `(cutoff_date, sku_id)`、cols = `store_name`、cell = `total_qty`。

### 2.7 新增 DB view：`v_stalled_items`（未到貨積壓）

```sql
CREATE OR REPLACE VIEW v_stalled_items AS
SELECT
  coi.id            AS order_item_id,
  coi.tenant_id,
  gbc.id            AS campaign_id,
  gbc.cutoff_date,
  gbc.expected_arrival_date,
  coi.sku_id,
  coi.qty,
  co.channel_id,
  co.member_id,
  EXTRACT(DAY FROM NOW() - gbc.expected_arrival_date)::INT AS days_overdue
FROM customer_order_items coi
JOIN customer_orders co ON co.id = coi.order_id
JOIN campaign_items ci ON ci.id = coi.campaign_item_id
JOIN group_buy_campaigns gbc ON gbc.id = ci.campaign_id
WHERE coi.status IN ('pending', 'reserved')
  AND gbc.expected_arrival_date IS NOT NULL
  AND gbc.expected_arrival_date < CURRENT_DATE;
```

Admin 儀表：`days_overdue DESC` 排序跨 campaign 列出。

---

## 3. 業務流程

### 3.1 開團總表 matrix（admin 端）

UX 照搬 lt-erp `admin.html` 團總表（整合 plan §2 #2）：

1. 預設顯示**未來 7 天 + 過去 3 天** cutoff_date 的 campaign
2. 每列 = `(cutoff_date, sku)`、每欄 = `store_name`、格 = `total_qty`（點進去看訂單明細）
3. 上方 filter：cutoff_date range / brand / sku search
4. 右側 side panel：選中 cell 時顯示該 store 該 SKU 的訂單列表（member + qty + note）
5. Admin 可拖拉 row（改 `matrix_row_order`）
6. **唯讀統計區**：整團合計 / 各 store 合計 / 各 SKU 合計

**不照搬**：lt-erp 的 inline edit qty（會寫回 shared_kv race）— new_erp 改到訂單明細頁才能改、經 `rpc_update_order_item`。

### 3.2 揀貨波次 — 建立 → 揀貨 → 生成 SO

```
┌─────────────────────────────────────────────┐
│ Step 1: 建立波次（admin）                    │
├─────────────────────────────────────────────┤
│ - 選多個 cutoff_date 已過 + 已到貨 的 campaign│
│ - RPC rpc_create_picking_wave(campaign_ids)  │
│ - 系統自動 aggregate (sku × store) → 建 items│
│ - status = 'draft'                           │
├─────────────────────────────────────────────┤
│ Step 2: 揀貨執行（總倉員工）                  │
├─────────────────────────────────────────────┤
│ - 按 store 分區列印揀貨單                    │
│ - 現場逐筆掃條碼 → 填 picked_qty             │
│ - 完成 → status = 'picked'                   │
├─────────────────────────────────────────────┤
│ Step 3: 生成 SO（admin 按鈕）                 │
├─────────────────────────────────────────────┤
│ - RPC generate_sales_order_from_wave(wave_id)│
│ - 為每家 store 建 1 張 sales_order            │
│ - 塞入 picked_qty > 0 的 wave_items           │
│ - 寫 generated_order_id 回 wave_items         │
│ - status = 'shipped'                         │
└─────────────────────────────────────────────┘
```

### 3.3 未到貨積壓檢視

Admin dashboard 上方 badge：「**15 個 item 已過預計到貨日**」→ 點進去看 `v_stalled_items`。
每筆可：
- 標記「已電聯供應商」（寫 `notes` 欄位）
- 觸發通知給該店小幫手（顧客稍後告知）
- 直接取消訂單（走既有 cancel flow）

### 3.4 樂樂 CSV 匯入流程

```
1. 上傳 CSV → 解析每列 → 寫 external_order_imports (status='pending')
2. 預覽頁：系統 auto-match SKU by barcode / name
   - matched: 顯示綠燈
   - ambiguous: 列舉候選 SKU
   - unmatched: 紅燈（必須解決才能下一步）
3. 選一個 campaign + cutoff_date（必選）
4. 確認 → RPC rpc_import_external_orders(batch_id, campaign_id)
   - 批次建 customer_orders + items
   - 寫回 resolved_order_id + status='resolved'
5. 失敗列保留 status='error'、error_message 記原因
```

**不照搬**：lt-erp 的 skip/add/overwrite 三選項（已知造成 bug）。改為「先選 cutoff_date → 清殘值 → import」（integration plan §4 #6）。

---

## 4. RPC / API

### 4.1 `rpc_create_picking_wave(p_campaign_ids, p_wave_date)`

```sql
-- 參數:
--   p_campaign_ids BIGINT[]   -- 要納入的 campaign
--   p_wave_date DATE
-- 副作用:
--   建 picking_waves (status='draft')
--   aggregate (sku × store) from v_open_group_matrix
--   批次 insert picking_wave_items
-- 返回: wave_id
-- 鎖: pg_advisory_xact_lock('picking_wave:create')  -- 防同時建重複波次
```

### 4.2 `generate_sales_order_from_wave(p_wave_id)` ⚠️ 保守防禦 + post-commit 驗證

根據 Q2 決議（保守 advisory lock、不預設 lt-erp root cause）+ Flag 4 加強（生成後驗 count）：

```sql
-- 參數: p_wave_id BIGINT
-- 前置檢查:
--   1. pg_advisory_xact_lock(p_wave_id::bigint)              -- 序列化
--   2. SELECT ... FOR UPDATE on picking_waves
--        WHERE id = p_wave_id AND status = 'picked'
--   3. 若狀態非 'picked' → RAISE EXCEPTION
--   4. 預計算 expected_store_count = COUNT(DISTINCT store_id)
--          + expected_item_count  = COUNT(*) of picked_qty > 0
--   5. 若 expected_item_count = 0 → RAISE EXCEPTION '無可生成明細'
-- 執行:
--   for each store in wave:
--     INSERT INTO sales_orders (...) → new_so_id
--     INSERT INTO sales_order_items (...) from picking_wave_items WHERE picked_qty > 0
--       → 取得 inserted_items_count for this store
--     若 inserted_items_count = 0 → RAISE EXCEPTION '空 SO'（defense-in-depth）
--     UPDATE picking_wave_items SET generated_order_id = new_so_id
--     INSERT INTO picking_wave_audit_log (action='so_generated', wave_id, after_value={so_id, items_count, store_id})
--   UPDATE picking_waves SET status = 'shipped'
-- Post-commit 驗證（同 transaction、commit 前）：
--   actual_so_count = SELECT COUNT(DISTINCT generated_order_id) FROM picking_wave_items WHERE wave_id = p_wave_id
--   actual_item_count = SELECT COUNT(*) FROM sales_order_items
--                       JOIN picking_wave_items ON picking_wave_items.generated_order_id = sales_order_items.sales_order_id
--                       WHERE picking_wave_items.wave_id = p_wave_id
--   IF actual_so_count != expected_store_count → RAISE EXCEPTION '生成 SO 數不符'
--   IF actual_item_count != expected_item_count → RAISE EXCEPTION '生成明細數不符'
-- 返回: JSONB {so_count: INT, item_count: INT, so_ids: BIGINT[]}
```

**反模式避開**（integration plan §4 #4）：
- 絕不默默 commit 空 SO（每張 SO 都必須有至少一筆 item）
- **生成後重查 count 驗 = 預期值**（Flag 4）— 防止「看起來 insert 成功但 trigger/RLS 吞掉」的 lt-erp BUG-014 情境
- 任一步不符直接 `RAISE EXCEPTION` → 整 transaction rollback

### 4.3 `rpc_update_picked_qty(p_wave_item_id, p_new_qty, p_note)`

揀貨現場單筆 qty 更新專用 RPC，每次呼叫寫一筆 audit log：

```sql
-- 參數: p_wave_item_id BIGINT, p_new_qty NUMERIC, p_note TEXT
-- 前置:
--   SELECT ... FOR UPDATE on picking_wave_items
--     JOIN picking_waves ON ...
--     WHERE picking_wave_items.id = p_wave_item_id AND picking_waves.status IN ('draft', 'picking')
-- 執行:
--   old_qty = current picked_qty
--   UPDATE picking_wave_items SET picked_qty = p_new_qty, updated_by = auth.uid()
--   INSERT INTO picking_wave_audit_log (
--     action='picked_qty_changed',
--     wave_id, wave_item_id,
--     before_value={picked_qty: old_qty}, after_value={picked_qty: p_new_qty},
--     note=p_note
--   )
--   若 picking_waves.status = 'draft' → UPDATE status = 'picking'
-- 返回: void
```

### 4.4 `rpc_import_external_orders(p_batch_id, p_campaign_id)`

```sql
-- 參數: p_batch_id TEXT, p_campaign_id BIGINT
-- 前置:
--   SELECT ... FOR UPDATE on group_buy_campaigns WHERE id = p_campaign_id AND status IN ('open', 'closed')
-- 執行:
--   loop external_order_imports WHERE batch_id = p_batch_id AND status = 'pending'
--     for each row with parsed_sku_id NOT NULL:
--       INSERT INTO customer_orders (...) + customer_order_items
--       call rpc_reserve(sku_id, qty)
--       UPDATE external_order_imports SET resolved_order_id, status='resolved'
--     skip parsed_sku_id IS NULL (status remains 'pending' or 'error')
-- 返回: JSON {resolved: N, skipped: N, errors: N}
```

---

## 5. RLS Policy

### 5.1 `picking_waves` / `picking_wave_items`

- **總倉員工 / admin**：SELECT ALL + INSERT + UPDATE + DELETE（若 `status='draft'`）
- **加盟店員工（store_id=X）**：僅 SELECT `picking_wave_items WHERE store_id = auth_store_id`（看自己店要收到的東西）
- **service_role**：bypass（Apps Script 用不到這邊）

### 5.2 `external_order_imports`

- **總倉小幫手**：SELECT + INSERT（自己上傳的 batch）
- **加盟店員工**：看不到（樂樂 import 是總倉作業）

### 5.3 `v_open_group_matrix` / `v_stalled_items`

- **admin**：ALL
- **加盟店員工**：透過 view 下 filter `WHERE store_id = auth_store_id`（underlying 表已 RLS，view 沿用）

---

## 6. 稽核

- `picking_waves` + `picking_wave_items` — 主檔、帶全 4 欄位 + `touch_updated_at` trigger
- `picking_wave_audit_log` — append-only、僅 `created_by` + `created_at`（§2.4）
- `external_order_imports` — append-only、僅 `created_by` + `created_at`

**`picked_qty` 變動的稽核路徑**（Flag 2 決議）：
- UI 每次掃條碼 / 改 qty 走 `rpc_update_picked_qty` → 同 transaction 內寫 1 筆 `picking_wave_audit_log`
- 不借用 `stock_movements`（那邊是物流移動語意、不是揀貨進度）
- **不跟庫存扣減混淆**：揀貨階段不扣庫存；等 `generate_sales_order_from_wave` 產 SO 後、SO shipping flow 才扣庫存（走既有 `stock_movements`）

---

## 7. 反模式避開

對應 integration plan §4：

| # | 避開反模式 | 本 addendum 如何處理 |
|---|---|---|
| 1 | `shared_kv` jsonb blob | N/A（本 addendum 全用正常表） |
| 2 | silent write failures | `generate_sales_order_from_wave` 每步 `RAISE EXCEPTION`；client 用 `writeOrThrow()` helper |
| 3 | REST PATCH 副作用 | wave 狀態轉移一律走 RPC（SECURITY DEFINER），禁止 client PATCH |
| 4 | picking wave race（BUG-014）| `pg_advisory_xact_lock(wave_id)` + `SELECT FOR UPDATE` + **生成後重查 count 驗證**（Flag 4）+ **不預設 lt-erp 的 root cause**（Q2） |
| 5 | state 只在 memory | wave 狀態永遠落 DB、UI 每次讀取以 DB 為準 |
| 6 | CSV import skip/add/overwrite | 改成「先選 cutoff_date → 清殘值 → import」 |

---

## 8. Open Questions（本 v0.2 範疇）

- [ ] **樂樂 CSV 欄位格式**：需使用者提供一張實際 CSV 樣本才能定 schema parsing rule
- [ ] **揀貨波次是否按 `expected_arrival_date` 自動成形**：目前 Step 1 是「小幫手手動選 campaign」；未來可加自動建議（同一 arrival date 的 campaign 預設打包成一 wave）
- [ ] **Matrix 排序 `matrix_row_order` 存方式**：目前是 INT、手動拖拉；若 SKU 數量爆炸（100+）可能要改 page 區段
- [ ] **「已電聯」標記位置**：目前想在 `customer_orders.notes` 累加寫；若要明確 timestamp 需新 `order_followup_log` 表（留 P1）

---

## 9. 相關檔案

- 主文：[[PRD-訂單取貨模組]] v0.1.1
- 整合計畫：`C:\Users\Alex\.claude\plans\snazzy-riding-toucan.md` §1 (訂單取貨), §2 (UX), §3 Phase 1, §4
- 決議文件：[[decisions/2026-04-22-v0.2-scope-decisions]] Q2, Q5
- Schema：後續 migration 檔 `supabase/migrations/20260423*_picking_waves.sql`（下次 session）
- Mockup：`docs/mockups/order-pickup-matrix.html` / `picking-wave-list.html`（下次 session）

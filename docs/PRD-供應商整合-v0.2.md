---
title: PRD - 供應商整合（Google Sheets + Marketplace）
module: SupplierIntegration
status: draft-v0.2
owner: alex.chen
created: 2026-04-22
updated: 2026-04-22
tags: [PRD, ERP, v0.2, 供應商, 整合, Apps-Script, xiaolan, Google-Sheets, 1688, 拼多多]
---

# PRD — 供應商整合模組（Supplier Integration）

> **新 module PRD**（非 addendum），v0.2 獨立成冊。
> 業態現實：小蘭（xiaolan）系供應商用 Google Sheets 對帳；1688 / 拼多多 / 淘寶用 web scraping / API 匯入。都走 Google Apps Script。
> 決議來源：[[decisions/2026-04-22-v0.2-scope-decisions]] Q3（Apps Script monorepo `apps-script/`）。
> 整合計畫：`C:\Users\Alex\.claude\plans\snazzy-riding-toucan.md` §3 Phase 3 / §1（供應商整合）。

---

## 1. 模組定位

- [x] **外部資料匯入樞紐**：把 Google Sheets / marketplace 訂單資料同步進 new_erp
- [x] **xiaolan_* tables**：6 張表對應 lt-erp 舊架構、照搬資料模型避免大 migration
- [x] **Apps Script monorepo**：Q3 決議、所有 script 放 `new_erp/apps-script/` 下
- [x] **不重建採購單**：本模組是**資料入口**；解析後的資料經 staging table 再由 admin 決定要不要轉成正式 `purchase_orders`（採購 PRD #3）
- [x] **anon RLS policy**：Apps Script 用 Supabase service_role / anon key，需開對應 RLS policy

---

## 2. 核心概念

- [x] **小蘭（xiaolan）**：泛指一個供應商系列（使用者語意）— 本系統用 6 張 `xiaolan_*` 表承接其 Google Sheets 結構
- [x] **Apps Script triggers**：每個子 script 有自己的時間觸發器（daily / hourly / on-edit）
- [x] **staging → resolve** 兩段式：Apps Script 寫進 staging table（`xiaolan_*` / `external_*_imports`）；admin 手動 resolve 成 `purchase_orders`
- [x] **冪等性**：Apps Script 同一批次重跑不能 double-insert（靠 `source_ref_id` UNIQUE）
- [x] **clasp 管理**：每個子資料夾一個 `.clasp.json`（Apps Script CLI）

---

## 3. Apps Script Monorepo 結構

```
new_erp/
├── apps-script/
│   ├── README.md                       # 總覽 + deploy 步驟
│   ├── .gitignore                      # 排除 .clasp.json 的 scriptId 隱私
│   ├── _shared/                        # 共用 lib（HTTP helper, Supabase client wrapper）
│   │   ├── SupabaseClient.gs
│   │   ├── Utils.gs
│   │   └── appsscript.json
│   ├── xiaolan-sync/                   # 小蘭 Google Sheets → Supabase
│   │   ├── Main.gs                     # 進入點 + trigger handlers
│   │   ├── XiaolanParser.gs            # 解析 Sheets tab
│   │   ├── SupabaseWriter.gs           # 寫 xiaolan_* 表
│   │   ├── .clasp.json                 # scriptId 本機配置（gitignored）
│   │   ├── .clasp.template.json        # scriptId placeholder（committed）
│   │   └── appsscript.json
│   ├── lele-csv-import/                # 樂樂通路 CSV（見 PRD #1 §3.4）
│   │   ├── Main.gs
│   │   ├── CSVParser.gs
│   │   └── ...
│   └── marketplace-import/             # 1688 / 拼多多 / 淘寶
│       ├── Main.gs
│       ├── Sources/
│       │   ├── Alibaba1688.gs
│       │   ├── Pinduoduo.gs
│       │   └── Taobao.gs
│       └── ...
```

**Deploy workflow**：
1. 各子資料夾 `clasp push` 推到對應 Apps Script project
2. 設 `clasp setup` 指向正確 Google Cloud project（每個 script 有獨立 project）
3. CI/CD 暫不自動 deploy（v0.2 先人工、避免 credentials 洩漏）

**Secrets 管理**（Flag 5 PRD #3 Open Q）：
- Supabase URL + service_role key：Apps Script `PropertiesService.getScriptProperties()`（每個 script 獨立設）
- 1688 / 拼多多 API credentials：同上、不進 git
- 初次 setup 需人工在 Apps Script IDE 的「專案屬性」設

---

## 4. 資料模型：`xiaolan_*` 6 張表

照搬 lt-erp 結構 → new_erp，但清理 `shared_kv` 反模式。所有表都加稽核欄位（依 `feedback_audit_columns.md`）。

### 4.1 `xiaolan_purchases`（append-only 匯入流水）

```sql
CREATE TABLE xiaolan_purchases (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  source_ref_id TEXT NOT NULL,                         -- Sheets row id (idempotency key)
  sheet_tab TEXT NOT NULL,                             -- 來自哪個 tab
  purchase_date DATE,
  supplier_code TEXT,
  item_description TEXT,
  qty NUMERIC(18,3),
  unit_cost NUMERIC(18,4),
  amount NUMERIC(18,4),
  resolved_po_id BIGINT REFERENCES purchase_orders(id),
  resolved_sku_id BIGINT REFERENCES skus(id),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'resolved', 'skipped', 'error')),
  raw_row JSONB,                                       -- 原始 row（debug 用）
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)                    -- 冪等性 key
);

CREATE INDEX idx_xiaolan_pur_status ON xiaolan_purchases (tenant_id, status);
CREATE INDEX idx_xiaolan_pur_date ON xiaolan_purchases (tenant_id, purchase_date DESC);
```

### 4.2 `xiaolan_piaopiao`（漂漂館進貨 staging）

```sql
CREATE TABLE xiaolan_piaopiao (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  source_ref_id TEXT NOT NULL,
  sheet_tab TEXT,
  purchase_date DATE,
  item_description TEXT,
  qty NUMERIC(18,3),
  unit_cost NUMERIC(18,4),
  resolved_sku_id BIGINT REFERENCES skus(id),
  resolved_brand_id BIGINT REFERENCES brands(id),      -- 應指向漂漂館 sub_brand
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'resolved', 'skipped', 'error')),
  raw_row JSONB,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);
```

### 4.3 `xiaolan_order_tracking`（訂單追蹤流水）

```sql
CREATE TABLE xiaolan_order_tracking (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  source_ref_id TEXT NOT NULL,
  external_order_no TEXT NOT NULL,                     -- 供應商那邊的單號
  tracking_no TEXT,
  carrier TEXT,
  status_text TEXT,                                    -- 原始狀態文字
  status_code TEXT
    CHECK (status_code IN ('created', 'shipped', 'in_transit', 'arrived', 'returned', 'unknown')),
  last_event_at TIMESTAMPTZ,
  resolved_po_id BIGINT REFERENCES purchase_orders(id),
  resolved_gr_id BIGINT REFERENCES goods_receipts(id),
  raw_row JSONB,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);

CREATE INDEX idx_xiaolan_track_external ON xiaolan_order_tracking (tenant_id, external_order_no);
```

### 4.4 `xiaolan_arrivals`（到貨紀錄）

```sql
CREATE TABLE xiaolan_arrivals (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  source_ref_id TEXT NOT NULL,
  arrival_date DATE NOT NULL,
  external_order_no TEXT,
  item_description TEXT,
  qty_arrived NUMERIC(18,3),
  condition_note TEXT,                                 -- 品相 / 瑕疵
  resolved_gr_id BIGINT REFERENCES goods_receipts(id),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'resolved', 'skipped', 'error')),
  raw_row JSONB,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);
```

### 4.5 `xiaolan_returns`（退貨紀錄）

```sql
CREATE TABLE xiaolan_returns (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  source_ref_id TEXT NOT NULL,
  return_date DATE NOT NULL,
  external_order_no TEXT,
  reason TEXT,
  qty_returned NUMERIC(18,3),
  refund_amount NUMERIC(18,4),
  resolved_purchase_return_id BIGINT REFERENCES purchase_returns(id),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'resolved', 'skipped', 'error')),
  raw_row JSONB,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);
```

### 4.6 `xiaolan_settings`（主檔、可編輯）

```sql
CREATE TABLE xiaolan_settings (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  sheet_id TEXT NOT NULL,                              -- Google Sheets ID
  sheet_tabs JSONB NOT NULL,                           -- [{tab_name, maps_to_table}] 對應
  supplier_code_mapping JSONB,                         -- lt-erp 舊代碼 → new supplier_id
  sku_match_rules JSONB,                               -- 解析時的 regex / fuzzy match 規則
  sync_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  last_synced_at TIMESTAMPTZ,
  last_sync_status TEXT,
  last_sync_error TEXT,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, sheet_id)
);
```

**append-only 5 表 + 主檔 1 表** — 合計 6 張 `xiaolan_*`（對應 integration plan §3 Phase 3）。

---

## 5. 業務流程

### 5.1 xiaolan Google Sheets sync

```
Apps Script trigger (daily 02:00) →
  讀 xiaolan_settings 的 sheet_id + tabs →
  for each tab:
    fetch last_synced_at 之後的 rows
    parse each row → POST to Supabase REST →
      INSERT INTO xiaolan_<table> (source_ref_id=sheet_row_id, raw_row=json, status='pending')
      ON CONFLICT (source_ref_id) DO NOTHING  -- 冪等
  UPDATE xiaolan_settings SET last_synced_at=NOW(), last_sync_status='success'
admin 到 new_erp 後台「小蘭待處理」tab →
  看每張 xiaolan_* 的 pending rows → match SKU / supplier → resolve
resolve 走 RPC（§6）：把 pending → purchase_orders / goods_receipts / purchase_returns
```

### 5.2 marketplace import 流程（重複 PRD #3 §3.4，這裡補 script 細節）

```
Apps Script (marketplace-import/Sources/Alibaba1688.gs) 每 6 小時 →
  call 1688 API (API key 存 PropertiesService) → fetch orders
  for each order:
    INSERT INTO external_purchase_imports (source='1688', raw_row=order_json, ...)
admin 到 new_erp → 待匯入 tab → SKU match → rpc_resolve_external_purchase()
```

### 5.3 錯誤處理與重跑

- Apps Script 任何錯誤寫 `xiaolan_settings.last_sync_error` + 發 email 給 admin（`MailApp.sendEmail`）
- 手動重跑：admin UI「強制 resync」按鈕 → 呼叫 Apps Script Web App endpoint（需 OAuth token）
- 單列錯誤：標 `status='error'` + `raw_row` 保留；admin 手動修正後再 resolve

---

## 6. RPC / API

### 6.1 `rpc_resolve_xiaolan_purchase(p_xiaolan_id, p_po_id, p_sku_id)`

```sql
-- 前置:
--   SELECT ... FOR UPDATE on xiaolan_purchases WHERE id = p_xiaolan_id AND status = 'pending'
--   檢查 po_id 有效 + sku_id 存在
-- 執行:
--   UPDATE xiaolan_purchases SET resolved_po_id, resolved_sku_id, status='resolved'
--   若 purchase_orders 上沒有對應 item → optionally INSERT purchase_order_items（admin 決定）
-- 返回: void
```

類似的 resolve RPC 還有：
- `rpc_resolve_xiaolan_piaopiao`
- `rpc_resolve_xiaolan_tracking` → update 對應 `goods_receipts.arrival_status`（銜接 PRD #3 §2.4）
- `rpc_resolve_xiaolan_arrival` → 建 GR / 更新 GR
- `rpc_resolve_xiaolan_return` → 建 purchase_return

**為何每張表獨立 RPC**：每張對應的業務動作不同（建 PO vs 建 GR vs 建 return），signature / 驗證邏輯差太大。

### 6.2 `rpc_bulk_resolve_xiaolan(p_table, p_ids[], p_auto_match=true)`

批次 resolve（admin 勾多列按一次）：

```sql
-- 參數:
--   p_table TEXT CHECK (p_table IN ('purchases','piaopiao','arrivals','returns','tracking'))
--   p_ids BIGINT[]
--   p_auto_match BOOLEAN = TRUE  -- 是否啟用 xiaolan_settings.sku_match_rules auto-match
-- 執行:
--   loop over ids:
--     call rpc_resolve_xiaolan_<table>(id, ...)
--     auto-match 的 SKU / supplier 從 xiaolan_settings.sku_match_rules 推斷
-- 返回: JSONB {resolved: N, skipped: N, errors: K}
```

---

## 7. RLS Policy

### 7.1 `xiaolan_*` 5 張 staging table

- **service_role（Apps Script 用）**：SELECT + INSERT（寫 staging）
- **admin**：ALL（resolve / cancel / review）
- **其他 role**：看不到（總倉作業）

### 7.2 `xiaolan_settings`

- admin：ALL
- service_role：SELECT only（只讀 config）
- 其他：看不到

### 7.3 `external_purchase_imports`（於 PRD #3 §2.7 定義）

已在 PRD #3 處理，本 PRD 不重覆。

### 7.4 Apps Script 使用 service_role 的風險控管

- service_role key 有完整 DB 權限、外流後果嚴重
- 緩解：
  - Apps Script 專案 owner 限定總部 admin Google 帳號
  - Apps Script properties 手動設（不入 git）
  - 每季輪換 key（寫進 runbook）
  - 若 leak：立刻 rotate、檢查 audit log

---

## 8. 稽核

| 表 | 類型 | 稽核欄位 |
|---|---|---|
| `xiaolan_purchases` | append-only | `created_by` + `created_at` |
| `xiaolan_piaopiao` | append-only | 同上 |
| `xiaolan_order_tracking` | append-only | 同上 |
| `xiaolan_arrivals` | append-only | 同上 |
| `xiaolan_returns` | append-only | 同上 |
| `xiaolan_settings` | 主檔 | 四欄全帶 + `touch_updated_at` trigger |

**resolve 動作**寫入**目標表**（`purchase_orders` 等）的 `created_by` = admin uid；staging 表只記 `status` 轉移（不另開 log）。

---

## 9. 反模式避開

對應 integration plan §4：

| # | 反模式 | 本 PRD 處理 |
|---|---|---|
| 1 | shared_kv blob | **完全避開**：每個業務實體有自己的表（`xiaolan_*` 各自獨立）、不再 jsonb 整檔覆蓋 |
| 2 | silent write failures | Apps Script 的 HTTP response 必檢 + `writeOrThrow()` helper 包裝 |
| 3 | REST PATCH 副作用 | staging → resolve 一律走 RPC |
| 4 | import race | Apps Script 用 `UrlFetchApp` 配 `ON CONFLICT DO NOTHING` 保證冪等 |
| 5 | state 只在 memory | 所有解析 state 落 `xiaolan_*` 表 |

**新反模式（供應商整合特有）**：
- **Apps Script trigger 誤觸發多次** → INSERT 用 `UNIQUE (tenant_id, source_ref_id) ON CONFLICT DO NOTHING`
- **Sheets row 被編輯後 row id 變動** → 設計 `source_ref_id` 是 Sheets 永久列 ID（Google Sheets 有 row hash）
- **Supabase service_role key 外流** → monorepo gitignore 所有 `.clasp.json`、properties 手動設定

---

## 10. Open Questions

- [ ] **Sheets tab 變動**：若小蘭改 tab 名稱 / 欄位順序 → `xiaolan_settings.sheet_tabs` 需要同步更新；目前靠 admin 手動改 config、沒做 schema diff 偵測
- [ ] **xiaolan 歷史資料 import**：lt-erp 已有歷史 shared_kv 資料、要不要一次性 import 進 new xiaolan_*？建議不 import（以 pilot cutoff 為界）、但需 user 確認
- [ ] **`_shared/SupabaseClient.gs` 是否封裝**：目前每個子 script 各自寫 HTTP helper；未來想封裝成共用 lib → 但 Apps Script 子專案共享需 `Library` 模式（略複雜）
- [ ] **1688 / 拼多多 API 是否真的有 open API**：部分 marketplace 需 scraping（法遵灰區）— 確認後決定 Apps Script 或手動匯入 CSV
- [ ] **Apps Script quota**：每帳號每天 UrlFetchApp 20000 次限制；若供應商資料量爆大需分攤到多 Google 帳號（每個帳號一 script）

---

## 11. 相關檔案

- 整合計畫：`C:\Users\Alex\.claude\plans\snazzy-riding-toucan.md` §1（供應商整合）、§3 Phase 3
- 決議文件：[[decisions/2026-04-22-v0.2-scope-decisions]] Q3
- 關聯 PRD：
  - [[PRD-採購模組-v0.2-addendum]]（`external_purchase_imports` staging table + resolve RPC）
  - [[PRD-訂單取貨模組-v0.2-addendum]]（樂樂 CSV `external_order_imports` — 共用 pattern）
- 後續：
  - `supabase/migrations/20260423*_xiaolan_tables.sql`（6 張表 + RLS policies）
  - `apps-script/README.md`（deploy 文件）
  - `apps-script/_shared/` + `xiaolan-sync/` + `lele-csv-import/` + `marketplace-import/` 實作

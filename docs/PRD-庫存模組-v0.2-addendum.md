---
title: PRD - 庫存模組 v0.2 Addendum
module: Inventory
status: draft-v0.2
owner: alex.chen
created: 2026-04-22
updated: 2026-04-22
base: PRD-庫存模組.md (v0.1)
tags: [PRD, ERP, v0.2, addendum, 庫存, lt-erp-integration, demand-request, mutual-aid, transfer-settlement]
---

# PRD — 庫存模組 v0.2 Addendum

> 本文件為 [[PRD-庫存模組]] v0.1 的 **增補**。
> 驅動原因：lt-erp 的「店間互動」全套（需求 / 欠品 / 互助 / 88 折）+ 月結算、new_erp v0.1 沒列 — 整合 plan §1（店間互動）+ §3 Phase 2/3.5 確認加入。
> 決議來源：[[decisions/2026-04-22-v0.2-scope-decisions]] Q5（transfer enum 合併）。

---

## 1. v0.2 增補範疇

| # | 新增功能 | 類型 |
|---|---|---|
| 1 | **`transfer_type` enum**（含 `return_to_hq`）| 既有 `transfers` 加 1 欄位（Q5） |
| 2 | **需求表（demand requests）** | 新 table + 新 RPC × 2 |
| 3 | **欠品自動 roll-over（backorders）** | 新 table + 新 RPC × 1 |
| 4 | **互助交流板（mutual aid board）** | 新 table × 2 |
| 5 | **88 折出清（aid clearance offers）** | 新 table |
| 6 | **店轉店月結算（transfer settlements）**（net>0 自動建 vendor_bill，Flag 8）| 新 table × 2 + 新 RPC × 2 |

**不改動**：v0.1 的 `stock_balances` / `stock_movements` / `transfers` 主體 / `stocktakes` / `reorder_rules` 全部保留。

---

## 2. 資料模型

### 2.1 既有表欄位補充（`transfers`，Q5）

```sql
ALTER TABLE transfers
  ADD COLUMN transfer_type TEXT NOT NULL DEFAULT 'store_to_store'
    CHECK (transfer_type IN ('store_to_store', 'return_to_hq', 'hq_to_store'));

CREATE INDEX idx_transfers_type ON transfers (tenant_id, transfer_type, status);
```

**為何**：
- `store_to_store`：原 v0.1 既有場景（互調）— default 值
- `return_to_hq`：退回龍潭（加盟店把賣不完 / NG / 陸貨備多的貨退回總倉，Q5）
- `hq_to_store`：配送（總倉轉到加盟店）— pre-existing 場景、顯式化

**UX 影響**：前端兩個按鈕（「店轉店」vs「退回龍潭」）只是 prefill `transfer_type` 不同；RLS / report / 月結算都用單表 query。

### 2.2 新增表：`demand_requests`（主檔、可編輯）

店家需求單 — 加盟店發出缺貨 / 想調貨的請求，總倉或其他店可回應。

```sql
CREATE TABLE demand_requests (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  requester_store_id BIGINT NOT NULL REFERENCES stores(id),
  sku_id BIGINT NOT NULL REFERENCES skus(id),
  qty NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  urgency TEXT NOT NULL DEFAULT 'normal'
    CHECK (urgency IN ('normal', 'urgent', 'critical')),
  reason TEXT,
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'fulfilled_by_transfer', 'fulfilled_by_po', 'cancelled', 'expired')),
  target_date DATE,                                    -- 期望到貨日
  fulfilled_transfer_id BIGINT REFERENCES transfers(id),
  fulfilled_po_id BIGINT REFERENCES purchase_orders(id),
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_dr_store_status ON demand_requests (tenant_id, requester_store_id, status);
CREATE INDEX idx_dr_sku_open ON demand_requests (tenant_id, sku_id) WHERE status = 'open';
```

**生命週期**：
- `open` → `fulfilled_by_transfer`（別店 / 總倉以 transfer 回應）
- `open` → `fulfilled_by_po`（總倉轉成 PO 補貨）
- `open` → `cancelled`（店家自行取消）
- `open` → `expired`（超過 target_date + 7 天自動過期、batch job）

### 2.3 新增表：`backorders`（主檔、可編輯）

結單後貨沒到 / 到不夠 → 欠品自動 roll-over 到下一波 campaign。

```sql
CREATE TABLE backorders (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  original_customer_order_item_id BIGINT NOT NULL REFERENCES customer_order_items(id),
  sku_id BIGINT NOT NULL REFERENCES skus(id),
  store_id BIGINT NOT NULL REFERENCES stores(id),
  member_id BIGINT REFERENCES members(id),
  qty_pending NUMERIC(18,3) NOT NULL CHECK (qty_pending > 0),
  rollover_to_campaign_id BIGINT REFERENCES group_buy_campaigns(id),  -- 自動 roll 到哪期
  rollover_customer_order_item_id BIGINT REFERENCES customer_order_items(id),  -- 新建的對應 item
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'rolled_over', 'resolved', 'cancelled')),
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_backorders_sku_status ON backorders (tenant_id, sku_id, status);
CREATE INDEX idx_backorders_member_pending ON backorders (member_id, status) WHERE status = 'pending';
```

**主檔類**（Flag 5 B 決議）：四欄全帶 + `touch_updated_at` trigger；狀態轉移直接 UPDATE（不另開事件表）。

**邏輯**：
- 結單時系統偵測 customer_order_items 中有 qty 沒完全履約的 → 自動建 backorder(status='pending')
- 下次同 SKU 的 campaign 開團 → RPC `rollover_backorders(new_campaign_id)` 把 pending 的自動轉成下波訂單
- 顧客通知：「上期您 X 沒拿到、本期已自動排入」

### 2.4 新增表：`mutual_aid_board`（主檔、可編輯）

店家互助交流板 — 店家貼出「本店多 X、有需要的來拿」。

```sql
CREATE TABLE mutual_aid_board (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  offering_store_id BIGINT NOT NULL REFERENCES stores(id),
  sku_id BIGINT NOT NULL REFERENCES skus(id),
  qty_available NUMERIC(18,3) NOT NULL CHECK (qty_available > 0),
  qty_remaining NUMERIC(18,3) NOT NULL,                -- 被拿走後剩多少
  expires_at TIMESTAMPTZ NOT NULL,
  note TEXT,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'exhausted', 'expired', 'cancelled')),
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_aid_active ON mutual_aid_board (tenant_id, status, expires_at)
  WHERE status = 'active';
```

### 2.5 新增表：`mutual_aid_claims`（append-only 流水）

每次別店「認領」mutual_aid_board 上的貨 = 一筆 claim。

```sql
CREATE TABLE mutual_aid_claims (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  board_id BIGINT NOT NULL REFERENCES mutual_aid_board(id),
  claiming_store_id BIGINT NOT NULL REFERENCES stores(id),
  qty NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  resulting_transfer_id BIGINT REFERENCES transfers(id),   -- 自動開 transfer（store_to_store）
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_aid_claims_board ON mutual_aid_claims (board_id, created_at DESC);
```

**邏輯**：
- RPC `rpc_claim_aid(board_id, qty)` → 鎖 board → 扣 qty_remaining → 建 claim → 建 transfer（`transfer_type='store_to_store'`、自動填料）→ board 若 qty_remaining=0 改 status='exhausted'
- 整套 atomic（`SELECT ... FOR UPDATE on board`）

### 2.6 新增表：`aid_clearance_offers`（主檔、可編輯）

88 折出清 — 店家把要過期 / 賣不動的庫存**以 88 折**發到互助板，admin 可轉為 HQ backfill 需求。

```sql
CREATE TABLE aid_clearance_offers (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  offering_store_id BIGINT NOT NULL REFERENCES stores(id),
  sku_id BIGINT NOT NULL REFERENCES skus(id),
  qty_available NUMERIC(18,3) NOT NULL,
  qty_remaining NUMERIC(18,3) NOT NULL,
  discount_rate NUMERIC(5,3) NOT NULL DEFAULT 0.88
    CHECK (discount_rate IN (0.88, 0.85, 0.80)),       -- Flag 7 C: 三選一
  expires_at TIMESTAMPTZ NOT NULL,
  reason TEXT,                                         -- e.g. '效期剩 3 天'
  status TEXT NOT NULL DEFAULT 'offered'
    CHECK (status IN ('offered', 'claimed_by_store', 'backfilled_by_hq', 'expired', 'cancelled')),
  converted_demand_id BIGINT REFERENCES demand_requests(id),  -- admin 轉成 HQ 需求單
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_aid_clearance_active ON aid_clearance_offers (tenant_id, status)
  WHERE status = 'offered';
```

**為何獨立表（不併進 `mutual_aid_board`）**：
- 有折扣率需要記（互助交流是原價轉移、出清是折價）
- admin 有轉 demand_request 的動作（`converted_demand_id`）
- 統計 / 報表需要分開（「出清金額 vs 互助金額」）

### 2.7 新增表：`transfer_settlements`（主檔、可編輯）

店轉店月結算 — 月底算各店互調金額、產生對帳單。

```sql
CREATE TABLE transfer_settlements (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  settlement_month DATE NOT NULL,                      -- 月首日，如 '2026-04-01'
  store_a_id BIGINT NOT NULL REFERENCES stores(id),
  store_b_id BIGINT NOT NULL REFERENCES stores(id),
  a_to_b_amount NUMERIC(18,4) NOT NULL DEFAULT 0,      -- A 給 B 的貨合計
  b_to_a_amount NUMERIC(18,4) NOT NULL DEFAULT 0,      -- B 給 A 的貨合計
  net_amount NUMERIC(18,4) NOT NULL,                   -- net = a_to_b - b_to_a；正 = A 欠 B
  transfer_count INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'confirmed', 'settled', 'disputed')),
  settled_at TIMESTAMPTZ,
  settled_by UUID,
  generated_vendor_bill_id BIGINT,                     -- FK to vendor_bills (PRD #5)，Flag 8 auto-build
  notes TEXT,
  created_by UUID, updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, settlement_month, store_a_id, store_b_id),
  CHECK (store_a_id < store_b_id)                      -- canonical ordering 避免重複
  -- FK to vendor_bills 在 PRD #5 migration 加（晚於本表建立、避免 circular dep）
);

CREATE INDEX idx_settlements_month ON transfer_settlements (tenant_id, settlement_month DESC);
```

### 2.8 新增表：`transfer_settlement_items`（明細、append-only）

```sql
CREATE TABLE transfer_settlement_items (
  id BIGSERIAL PRIMARY KEY,
  tenant_id UUID NOT NULL,
  settlement_id BIGINT NOT NULL REFERENCES transfer_settlements(id) ON DELETE CASCADE,
  transfer_id BIGINT NOT NULL REFERENCES transfers(id),
  direction TEXT NOT NULL CHECK (direction IN ('a_to_b', 'b_to_a')),
  amount NUMERIC(18,4) NOT NULL,
  transfer_date DATE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only
);

CREATE INDEX idx_settlement_items_settlement ON transfer_settlement_items (settlement_id);
```

---

## 3. 業務流程

### 3.1 退回龍潭（Q5 UX 雙按鈕）

```
店長點「退回龍潭」→
  前端 prefill transfer_type='return_to_hq' + dest_location='龍潭總倉' →
  小幫手填 SKU + qty + reason →
  confirm → 走既有 transfer flow（shipped → received）→
  月結算 netting（§3.5）
```

和「店轉店」唯一差別：按鈕 + dest 預設值。Data 層同表、RLS 同 policy、report 同 query。

### 3.2 需求單流程

```
店長 → 填 demand_request (sku, qty, urgency, target_date)
admin dashboard → 看所有 open 需求 →
  選項 1：某別店有貨 → admin 觸發 rpc_fulfill_demand_by_transfer(demand_id, source_store_id)
    → 自動建 transfer（store_to_store）→ demand status='fulfilled_by_transfer'
  選項 2：總倉無 / 想走採購 → admin 觸發 rpc_convert_demand_to_po(demand_id)
    → 建 purchase_requisition item → demand status='fulfilled_by_po'
  選項 3：無解 → admin 或店長 cancel
```

**不照搬**：lt-erp 是店家直接看到所有店庫存（privacy 問題）— new_erp 只讓 admin 看全局、店家只看自己的 + mutual_aid_board 上公開的。

### 3.3 欠品 roll-over

```
結單 trigger（group_buy_campaigns 狀態 → 'closed'）→
  掃 customer_order_items WHERE 實際到貨 < 訂單 qty →
  INSERT backorders（status='pending'）
下次同 SKU campaign open →
  admin 按「rollover backorders」→
  RPC rpc_rollover_backorders(new_campaign_id) →
  pending 自動變成新 customer_order_items
  通知顧客：「上期您 X 沒拿到、本期已自動排入」
```

### 3.4 互助交流 + 88 折出清

**交流板**：
- 店家 → 貼 mutual_aid_board（qty + 過期時間）
- 別店瀏覽板 → 點「我要 N」→ RPC `rpc_claim_aid(board_id, qty)` → 自動建 transfer
- 原店若後悔 → cancel board（qty_remaining = qty_available 時才允許）

**88 折出清**：
- 店家 → 貼 aid_clearance_offer（qty + discount + 原因）
- 別店看到 → 以 88 折認領（RPC `rpc_claim_clearance(offer_id, qty)`）→ 建 transfer（special pricing）
- **admin 權限**：若無店認領、admin 可按「轉 HQ backfill」→ RPC `rpc_convert_clearance_to_demand(offer_id)`
  → 建 demand_request（HQ 以 88 折收貨）→ 走退回龍潭 transfer

### 3.5 店轉店月結算（含自動觸發應付）

```
月初排程 job（每月 1 日 03:00）→
  RPC rpc_generate_transfer_settlement(month=prev_month) →
    loop over all pairs (store_a < store_b) with transfers in that month →
      aggregate a→b amount + b→a amount
      net = a_to_b - b_to_a
      INSERT transfer_settlements + transfer_settlement_items (status='draft')
  admin dashboard 看對帳單 → 和相關店長確認 →
    admin 觸發 rpc_confirm_transfer_settlement(settlement_id) →
      status='confirmed'
      若 net_amount > 0（A 欠 B）→ 自動建 vendor_bill（Flag 8）：
        INSERT INTO vendor_bills (
          supplier_id = B 店對應的「加盟店 supplier」,
          source_type = 'transfer_settlement',
          source_id = settlement_id,
          amount = |net_amount|,
          due_date = confirmed_date + 30 days,
          ...
        )
      UPDATE transfer_settlements SET generated_vendor_bill_id = new_bill_id
  貨款實際支付 → 走 PRD #5 的 rpc_make_payment → vendor_bill status='paid' → settlement status='settled'
  若有爭議 → status='disputed'；vendor_bill 也擋住不能付
```

**跨模組語義**：
- 加盟店之間互調 **產生實際金流**（A 欠 B）→ 走應付模組結算（統一由總部代收代付、或店家自己對）
- `vendor_bills.source_type='transfer_settlement'` 讓應付模組能 back-reference 月結算單
- 需要建「加盟店 supplier」記錄（每家加盟店在 `suppliers` 表有一筆對應 row）— 採購模組 v0.1 已有 suppliers、這個 mapping 在 PRD #5 處理

---

## 4. RPC / API

### 4.1 `rpc_fulfill_demand_by_transfer(p_demand_id, p_source_store_id)`

```sql
-- 前置:
--   SELECT ... FOR UPDATE on demand_requests WHERE id = p_demand_id AND status = 'open'
--   檢查 source store 庫存 >= p_demand.qty（走既有 stock_balances 查詢）
-- 執行:
--   INSERT INTO transfers (transfer_type='store_to_store', source=p_source_store_id, dest=p_demand.requester_store_id, ...)
--   INSERT INTO transfer_items (sku_id=p_demand.sku_id, qty_requested=p_demand.qty)
--   UPDATE demand_requests SET status='fulfilled_by_transfer', fulfilled_transfer_id=new_transfer_id
-- 返回: new_transfer_id
```

### 4.2 `rpc_rollover_backorders(p_new_campaign_id)`

```sql
-- 前置:
--   SELECT ... FOR UPDATE on group_buy_campaigns WHERE id = p_new_campaign_id AND status = 'open'
--   pg_advisory_xact_lock('rollover:' || p_new_campaign_id)
-- 執行:
--   SELECT backorders WHERE status='pending' AND sku_id IN (SELECT sku_id FROM campaign_items WHERE campaign_id = p_new_campaign_id)
--   for each backorder:
--     INSERT INTO customer_orders (campaign_id=p_new_campaign_id, member_id=b.member_id, ...)
--     INSERT INTO customer_order_items (sku_id, qty=b.qty_pending, source='rollover', ...)
--     UPDATE backorders status='rolled_over', rollover_customer_order_item_id=new_item_id
-- 返回: INT (rolled over 數)
```

### 4.3 `rpc_claim_aid(p_board_id, p_qty)` / `rpc_claim_clearance(p_offer_id, p_qty)`

兩者結構相同、不同表：

```sql
-- 前置:
--   SELECT ... FOR UPDATE on mutual_aid_board (or aid_clearance_offers) WHERE id = p_board_id AND status = 'active'
--   若 qty_remaining < p_qty → RAISE EXCEPTION
-- 執行:
--   UPDATE board SET qty_remaining = qty_remaining - p_qty
--   若 qty_remaining = 0 → status = 'exhausted'
--   INSERT INTO mutual_aid_claims (board_id, claiming_store_id=auth.uid().store, qty=p_qty, ...)
--   INSERT INTO transfers (transfer_type='store_to_store', source=board.offering_store_id, dest=auth.store_id, ...)
--     （出清版：sales_orders 走 discount_rate）
--   UPDATE claim SET resulting_transfer_id = new_transfer_id
-- 返回: new_transfer_id
```

### 4.4 `rpc_convert_clearance_to_demand(p_offer_id)` (admin-only)

```sql
-- 前置: 檢查 auth role = 'admin'
-- 執行:
--   INSERT INTO demand_requests (sku_id, qty=offer.qty_remaining, requester_store_id=HQ, reason='88 折出清收貨')
--   UPDATE aid_clearance_offers SET status='backfilled_by_hq', converted_demand_id=new_demand_id
--   （後續由 admin 走 rpc_fulfill_demand_by_transfer 收回 HQ）
-- 返回: new_demand_id
```

### 4.5 `rpc_generate_transfer_settlement(p_month)`

```sql
-- 參數: p_month DATE (該月月首)
-- 前置:
--   pg_advisory_xact_lock('settlement:' || p_month)
--   若已有 (tenant, month, any pair) 的 settlement in status IN ('confirmed','settled') → RAISE EXCEPTION '已確認不可重算'
-- 執行:
--   DELETE transfer_settlements + items WHERE month = p_month AND status = 'draft'
--   SELECT from transfers + transfer_items + prices
--     WHERE DATE_TRUNC('month', shipped_at) = p_month
--           AND transfer_type IN ('store_to_store', 'return_to_hq')
--           AND status IN ('received', 'closed')
--   GROUP BY (LEAST(source, dest), GREATEST(source, dest))
--   for each pair:
--     INSERT INTO transfer_settlements (status='draft', ...)
--     INSERT INTO transfer_settlement_items for each underlying transfer
-- 返回: INT (生成的 settlement 數)
```

**為何 advisory lock**：同月重算要序列化；draft 重跑可取代、confirmed 不可。

### 4.6 `rpc_confirm_transfer_settlement(p_settlement_id)` (admin-only，Flag 8)

```sql
-- 前置:
--   檢查 auth role = 'admin'
--   SELECT ... FOR UPDATE on transfer_settlements WHERE id = p_settlement_id AND status = 'draft'
--   若狀態非 'draft' → RAISE EXCEPTION
-- 執行:
--   UPDATE transfer_settlements SET status='confirmed', settled_by=auth.uid(), settled_at=NOW()
--   若 net_amount > 0：
--     -- 自動建 vendor_bill（跨模組）
--     SELECT supplier_id = (SELECT supplier_id FROM stores WHERE id = debtor_store_id)
--     若 supplier_id IS NULL → RAISE EXCEPTION '加盟店 X 尚未建立對應 supplier 記錄'
--     INSERT INTO vendor_bills (
--       supplier_id,
--       source_type='transfer_settlement',
--       source_id=p_settlement_id,
--       amount=|net_amount|,
--       bill_date=NOW()::DATE,
--       due_date=NOW()::DATE + INTERVAL '30 days',
--       status='pending',
--       ...
--     ) RETURNING id → new_bill_id
--     UPDATE transfer_settlements SET generated_vendor_bill_id = new_bill_id
--   若 net_amount = 0：不建 vendor_bill，直接 status='confirmed' 即可
-- 返回: JSONB {settlement_id, vendor_bill_id_or_null, net_amount}
```

**為何獨立 confirm RPC**（而非 generate 就直接建）：
- generate 是 batch 計算、status='draft' 供 admin review
- confirm 是 explicit 決策 → 觸發實際金流語意（跨到應付模組）
- 避免 generate 時自動建 bill、admin 又改的 race

---

## 5. RLS Policy

### 5.1 `transfers` (`transfer_type` 加入後)

現有 policy 保留 — `transfer_type` 不影響權限（RLS filter 仍走 `source_location` / `dest_location` 的 store 關聯）。

### 5.2 `demand_requests`

- 店家：SELECT own + INSERT own + UPDATE own (若 status='open') + DELETE own (若 status='open')
- admin：ALL
- 其他店：**不能看別店的 demand**（避免資訊外流、只看 mutual_aid_board）

### 5.3 `mutual_aid_board` / `aid_clearance_offers`

- 任何 authenticated 店家：SELECT ALL（故意公開、這就是它的意義）
- 發佈人 store：INSERT / UPDATE / DELETE own（若 qty_remaining = qty_available）
- admin：ALL

### 5.4 `mutual_aid_claims`

- 店家：SELECT own（自己 claim 的 + 自己板子被 claim 的）
- admin：ALL

### 5.5 `transfer_settlements` / items

- 店家：SELECT where store_a_id = me OR store_b_id = me
- admin：ALL
- 店家 UPDATE 權限：僅標註 `disputed`（不能改金額）

---

## 6. 稽核

| 表 | 類型 | 稽核欄位 |
|---|---|---|
| `demand_requests` | 主檔 | 四欄全帶 + `touch_updated_at` trigger |
| `backorders` | 主檔（Flag 5 B）| 四欄全帶 + `touch_updated_at` trigger |
| `mutual_aid_board` | 主檔 | 四欄全帶 |
| `mutual_aid_claims` | append-only | `created_by` + `created_at` only |
| `aid_clearance_offers` | 主檔 | 四欄全帶 |
| `transfer_settlements` | 主檔 | 四欄全帶 + `settled_by` / `settled_at` 額外追蹤結算動作 |
| `transfer_settlement_items` | append-only | `created_at` only（item 無操作者語意、純 aggregation） |

---

## 7. 反模式避開

對應 integration plan §4：

| # | 反模式 | 本 addendum 處理 |
|---|---|---|
| 1 | shared_kv blob | N/A（正常表） |
| 2 | silent write failures | 所有 RPC 用 `RAISE EXCEPTION` |
| 3 | REST PATCH 副作用 | 狀態轉移 / qty 扣減一律 RPC |
| 5 | state 只在 memory | demand / claim 狀態全落 DB |
| 7 | 讀寫分離的搬家 | lt-erp 的 shared_kv 舊資料**不 import**（使用者已決定 v1 cutoff） |

**新反模式（本 v0.2 特有）**：
- **mutual_aid 超賣**：必須 `SELECT ... FOR UPDATE on board` 再扣 qty_remaining
- **settlement 雙重生成**：`pg_advisory_xact_lock('settlement:' || month)` + confirmed / settled 狀態擋重算

---

## 8. Open Questions

- [x] ~~**出清折扣率是否可調**~~：Flag 7 C — 固定三選一 enum `(0.88, 0.85, 0.80)`
- [x] ~~**月結算 vs 應付模組耦合**~~：Flag 8 B — net>0 自動建 vendor_bill（詳見 §3.5 + §4.6）
- [ ] **mutual_aid 是否要總倉參與**：現在 board 只限店↔店；若總倉也要貼（出清庫存）→ 加 `offering_store_id` 可以是「HQ location」
- [ ] **backorder rollover 的顧客 opt-out**：顧客可能不想等、想直接退款 → 需 `customer_orders.rollover_opt_out` flag（v0.2+）
- [ ] **加盟店 supplier mapping**：Flag 8 依賴每家 `stores` 有對應 `suppliers` row — 建立規則（手動 / 自動 on store create）留 PRD #5 決定
- [ ] **net=0 月結算處理**：不建 vendor_bill、直接標 confirmed；若未來需要「零結算也要記錄」再改

---

## 9. 相關檔案

- 主文：[[PRD-庫存模組]] v0.1
- 整合計畫：`C:\Users\Alex\.claude\plans\snazzy-riding-toucan.md` §1（店間互動）、§3 Phase 2/3.5
- 決議文件：[[decisions/2026-04-22-v0.2-scope-decisions]] Q5
- v0.1 schema：`docs/sql/inventory_schema.sql`（既有 transfers 表）
- 後續：`supabase/migrations/20260423*_demand_backorder_aid_settlement.sql`（下次 session）

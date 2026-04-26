---
title: TEST — 訂單轉手 + 分店內部訂單（Phase 5a-1）
module: Order / Inter-store
status: draft
owner: alex.chen
created: 2026-04-26
---

# 測試清單 — 訂單轉手 (棄單轉出) + 分店內部訂單 (店長叫貨)

把「貨從 A 店流到 B 店」的所有場景統一收斂到 `customer_orders`：

1. **客戶棄單 → 互助轉訂單**：A 店原訂單轉手給 B 店、B 店掛新客人或店長自己
2. **店長叫貨進門市**：店長自己 key 訂單、客戶 = 分店內部 member
3. **互助交流板認領**：認領者 key 訂單、源頭追到釋出店（5b 才用）
4. **88 折出清**：內部訂單 + `unit_price` 折價（無新欄位）

## Scope

- Migration：`supabase/migrations/20260507000000_order_transfer_and_internal.sql`
- 上游：`customer_orders` v0.2、`members` v0.2 (member_type)
- 下游（不在本 PR）：互助板 UI、訂單登打 UI 補強、總倉調度中心

## Schema delta

```sql
-- customer_orders 加轉手欄位 + 新 status
ALTER TABLE customer_orders
  ADD COLUMN transferred_from_order_id BIGINT REFERENCES customer_orders(id),
  ADD COLUMN transferred_to_order_id   BIGINT REFERENCES customer_orders(id);

ALTER TABLE customer_orders DROP CONSTRAINT customer_orders_status_check;
ALTER TABLE customer_orders ADD CONSTRAINT customer_orders_status_check
  CHECK (status IN ('pending','confirmed','reserved','ready',
                    'partially_ready','partially_completed',
                    'completed','expired','cancelled',
                    'transferred_out'));

-- members.member_type 加 'store_internal'
ALTER TABLE members DROP CONSTRAINT members_member_type_check;
ALTER TABLE members ADD CONSTRAINT members_member_type_check
  CHECK (member_type IN ('full','guest','store_internal'));

-- customer_order_items.source 加兩個值
ALTER TABLE customer_order_items DROP CONSTRAINT customer_order_items_source_check;
ALTER TABLE customer_order_items ADD CONSTRAINT customer_order_items_source_check
  CHECK (source IN ('manual','screenshot_parse','csv','rollover','liff',
                    'store_internal','aid_transfer'));

-- 加索引方便查 transferred_from/to chain
CREATE INDEX idx_corders_transferred_from ON customer_orders (transferred_from_order_id)
  WHERE transferred_from_order_id IS NOT NULL;
CREATE INDEX idx_corders_transferred_to ON customer_orders (transferred_to_order_id)
  WHERE transferred_to_order_id IS NOT NULL;
```

## RPC 簽章

### `rpc_get_or_create_store_member(p_store_id BIGINT, p_operator UUID) RETURNS BIGINT`

每店一筆 `member_type='store_internal'` member、on-demand 建立、後續重用。

- `member_no = 'STORE-' || store.id`
- `name = '【內部】' || store.name`
- `home_store_id = p_store_id`
- `phone = NULL`、`line_user_id = NULL`

### `rpc_create_store_internal_order(...)`

```sql
rpc_create_store_internal_order(
  p_campaign_id  BIGINT,
  p_store_id     BIGINT,           -- pickup_store = 自己店
  p_items        JSONB,            -- [{campaign_item_id, qty, unit_price}, ...]
  p_operator     UUID,
  p_notes        TEXT DEFAULT NULL
) RETURNS BIGINT  -- new order_id
```

行為：
- `member_id = rpc_get_or_create_store_member(p_store_id, p_operator)`
- `pickup_store_id = p_store_id`
- `channel_id` = 該店任一 line_channel.id（home_store_id = p_store_id 取一）；若無則用 fallback channel
- `customer_order_items.source = 'store_internal'`
- `unit_price` 用 `p_items` 帶來的（支援 88 折/任意定價）

### `rpc_transfer_order_to_store(...)`

```sql
rpc_transfer_order_to_store(
  p_order_id              BIGINT,        -- 原棄單
  p_to_pickup_store_id    BIGINT,        -- 接收店
  p_to_member_id          BIGINT,        -- 新客人 / 接收店店長 (NULL = 用 store_internal)
  p_to_channel_id         BIGINT,        -- 新店的 line_channel
  p_operator              UUID,
  p_reason                TEXT DEFAULT NULL
) RETURNS BIGINT  -- new_order_id
```

行為（atomic）：
1. `pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id))`
2. `SELECT FOR UPDATE` 原訂單；驗 `status IN ('pending','confirmed','reserved')`、未 transferred
3. 若原訂單已有 `reserved_movement_id`（已 allocate）→ 走 `release` reverse 庫存釋放
4. 建新訂單：複製 items、`source='aid_transfer'`、`transferred_from_order_id = 原`
5. 原訂單 `status='transferred_out'`、`transferred_to_order_id = 新`
6. `notes` 兩邊各自記轉出/轉入時間 + reason + operator
7. 返回 `new_order_id`

---

## 測試項目

### A. `rpc_get_or_create_store_member`

- [ ] A1：第一次呼叫 → 建立新 member、返回 id；驗 `member_type='store_internal'`、`member_no='STORE-{id}'`
- [ ] A2：再次呼叫同 store_id → 返回相同 id、不重複建（idempotent）
- [ ] A3：concurrent 兩支同 store_id → 第二支拿到第一支建的、不重複建（advisory lock 或 unique constraint 擋）
- [ ] A4：`home_store_id` = p_store_id；`phone IS NULL`；`name` 以「【內部】」開頭

### B. `rpc_create_store_internal_order` Happy path

- [ ] B1：呼叫成功、返回 `new_order_id`
- [ ] B2：`member_id` 對應 store_internal member
- [ ] B3：`pickup_store_id = p_store_id`
- [ ] B4：每行 `customer_order_items.source = 'store_internal'`
- [ ] B5：`unit_price` 沿用 `p_items.unit_price`（支援任意定價、含 88 折）
- [ ] B6：`channel_id` 自動取該店的 line_channel；若無 channel → 用 fallback 或 RAISE
- [ ] B7：`order_no` 格式 `INT-{store_id}-{epoch}` 或類似可辨識

### C. `rpc_create_store_internal_order` 88 折定價

- [ ] C1：`p_items.unit_price = list_price * 0.88` 傳入 → 訂單 item 寫入折價
- [ ] C2：`unit_price = 0` → 視為合法（內部訂單可免費出貨）
- [ ] C3：`unit_price < 0` → exception

### D. `rpc_transfer_order_to_store` Happy path

- [ ] D1：原訂單 status='pending' → 呼叫成功、返回 new_order_id
- [ ] D2：原訂單 `status='transferred_out'`、`transferred_to_order_id = new_order_id`
- [ ] D3：新訂單 `transferred_from_order_id = 原`、`pickup_store_id = p_to_pickup_store_id`、`member_id = p_to_member_id`、`channel_id = p_to_channel_id`
- [ ] D4：新訂單 items 數量 / sku / unit_price 完全複製原訂單
- [ ] D5：新訂單 items 的 `source = 'aid_transfer'`
- [ ] D6：兩邊 `notes` 含「轉出 → 訂單 #{new}」/「轉入 ← 訂單 #{old}」+ reason + operator + timestamp

### E. `rpc_transfer_order_to_store` 庫存處理

- [ ] E1：原訂單未 allocate（無 reserved_movement_id）→ 直接轉、新訂單沿無 allocate 狀態
- [ ] E2：原訂單已 allocate（有 reserved_movement_id）→ 自動 release 庫存（reverse stock_movement）→ 新訂單回 'pending'、需重走 allocate
- [ ] E3：庫存釋放後 stock_balances.reserved 對應減少；on_hand 不變

### F. `rpc_transfer_order_to_store` 邊界 / 錯誤

- [ ] F1：`p_order_id` 不存在 → `RAISE EXCEPTION 'order % not found'`
- [ ] F2：原訂單 `status='ready'` / `'partially_ready'` / `'completed'` / `'cancelled'` / `'expired'` → exception（已過可轉的階段；ready 後已撿好應該走完成、不再轉手）
- [ ] F3：原訂單已 `transferred_out`（重複轉手）→ exception
- [ ] F4：`p_to_pickup_store_id = 原 pickup_store_id` → **允許**（同店換客人 / 換掛店長），但不產生 TR、不走總倉審核流程（pickup_store 沒變、撿貨/派貨流不會被觸發）
- [ ] F5：`p_to_member_id` 不屬於 `p_to_pickup_store_id`（home_store_id 不符）→ warning 但不擋（可接收）
- [ ] F6：新 (campaign_id, channel_id, member_id) 觸發 UNIQUE 衝突（已有同 trio 訂單）→ exception
- [ ] F7：`p_to_member_id = NULL` → 自動呼叫 `rpc_get_or_create_store_member(p_to_pickup_store_id)` 用內部 member

### G. 與既有功能整合

- [ ] G1：`order_expiry_events` / `order_shortage_events` (#72/#73/#75) 對 'transferred_out' 不觸發
- [ ] G2：`v_pr_progress` / 撿貨 wave 流程不被影響（transferred_out 不算入 demand）
- [ ] G3：撿貨 wave 抓需求時 `WHERE status NOT IN ('cancelled','expired','transferred_out')`
- [ ] G4：訂單列表頁顯示 transferred_out 訂單時、附 transferred_to 訂單超連結
- [ ] G5：chain 深度不擋（A→B→C→D 允許）、用 transferred_to_order_id 串連可追溯

### H. RLS / 權限

- [ ] H1：所有 RPC `SECURITY DEFINER`、`GRANT EXECUTE TO authenticated`
- [ ] H2：應用層 UI 帶 p_operator；admin / 店長角色限制由 UI 層守

### I. 鏈路驗證（end-to-end）

- [ ] I1：A 店建一張 status=confirmed 訂單 → admin 呼叫 transfer 給 B 店 → B 店訂單列表能看到、A 店的標記 transferred_out
- [ ] I2：B 店把這張訂單跑完撿貨/派貨/收貨 → 訂單 status 走完 → A 店看自己原訂單仍是 transferred_out 但顯示「→ 已被 B 店履行」
- [ ] I3：店長 X 用 `rpc_create_store_internal_order` 為 X 店叫貨 → 跑完撿貨派貨 → X 店 stock_balances.on_hand 增加
- [ ] I4：店長 X 用 88 折定價建 internal order → unit_price 正確寫入、後續無人為改價

## 不在範圍

- 互助交流板 UI 與 mutual_aid_replies（Phase 5c）
- 訂單登打 UI 加「為分店叫貨」mode（Phase 5b）
- 棄單 detail 頁加「轉出」按鈕（Phase 5b）
- 總倉調度中心 UI（Phase 5d）
- transfers schema delta（溫層 / 空中轉 / 損壞）（Phase 5a-2）

## 驗證方式

- 用 `scripts/rpc-order-transfer.sql`（待寫）造 fixture：1 campaign + 2 stores + 2 channels + 1 member + 1 order
- 跑每個 A-I 測項，記 actual / expected
- 寫 report 到 `docs/TEST-order-transfer-report.md`

## 後續

- Phase 5a-2 寫 transfers schema delta + 總倉操作 RPC
- Phase 5b UI 接這些 RPC

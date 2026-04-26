---
title: TEST — 總倉調度後端（Phase 5a-2）
module: Inventory / Transfer
status: draft
owner: alex.chen
created: 2026-04-26
---

# 測試清單 — transfers 總倉調度（schema delta + 4 批次 RPC）

對應 lt-erp 圖 2「店轉店與退倉審核」總倉端調度功能。

## Scope

- Migration：`supabase/migrations/20260508000000_transfer_hq_dispatch.sql`
- 上游：v0.2 transfers (含 transfer_type)
- 下游（不在本 PR）：總倉調度中心 UI（Phase 5d）

## Schema delta

```sql
ALTER TABLE transfers
  ADD COLUMN shipping_temp TEXT
    CHECK (shipping_temp IN ('frozen','chilled','ambient','mixed')),
  ADD COLUMN is_air_transfer BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN hq_notes TEXT;

ALTER TABLE transfer_items
  ADD COLUMN damage_qty NUMERIC(18,3) NOT NULL DEFAULT 0
    CHECK (damage_qty >= 0),
  ADD COLUMN damage_notes TEXT,
  ADD COLUMN damage_movement_id BIGINT REFERENCES stock_movements(id);

CREATE INDEX idx_transfers_air ON transfers (tenant_id, is_air_transfer)
  WHERE is_air_transfer = TRUE;
CREATE INDEX idx_transfers_temp ON transfers (tenant_id, shipping_temp)
  WHERE shipping_temp IS NOT NULL;
```

**設計說明**：
- `shipping_temp` nullable — 既有 transfer 不強制有溫層；新建議 UI 強制選
- `is_air_transfer` 預設 FALSE — 對應 lt-erp 圖 1 checkbox「空中轉（A 店直接交付 B 店、不經過總倉）」
- `hq_notes` 跟 `notes` 區分 — `notes` 是分店端、`hq_notes` 是總倉端
- `damage_qty` 在 transfer_items（per item 損壞數量）；不超過 qty_received
- `damage_movement_id` link 到對應的 stock_movements `'damage'` 紀錄、稽核軌跡

## 對應 lt-erp 圖 2 五個狀態 tabs（view 層 derive）

| Tab | view 條件 |
|---|---|
| 待審核 | `status='draft'` |
| 已到總倉 | `dest_location = HQ AND status = 'received'`（中轉首段） |
| 已配送 | `source_location = HQ AND status = 'shipped'`（中轉末段或 HQ→分店） |
| 已收到 | `dest_location ≠ HQ AND status = 'received'` |
| 空中轉 | `is_air_transfer = TRUE`（不分 status） |

不需要新加 status enum，現有 enum 夠用。

## RPC 簽章

### `rpc_transfer_arrive_at_hq_batch(p_transfer_ids BIGINT[], p_operator UUID) RETURNS JSONB`

批次「已到總倉」— 對 dest=HQ 的 TR 從 'shipped' 推到 'received'。

```
loop p_transfer_ids:
  驗 dest_location = HQ + status = 'shipped'
  PERFORM rpc_receive_transfer(id, NULL, p_operator, NULL)  -- 全收
回傳: { processed: int, succeeded: bigint[], failed: [{id, reason}] }
```

### `rpc_transfer_distribute_batch(p_transfer_ids BIGINT[], p_hq_location_id BIGINT, p_operator UUID) RETURNS JSONB`

批次「配送」— 對 source=HQ 的 TR 從 'draft'/'confirmed' 推到 'shipped'，產生 transfer_out stock_movement。

```
loop p_transfer_ids:
  驗 source_location = p_hq_location_id + status IN ('draft','confirmed')
  for each transfer_item: rpc_outbound(transfer_out)
  UPDATE transfers SET status='shipped', shipped_by=p_operator, shipped_at=NOW()
回傳: { processed: int, succeeded: bigint[], failed: [{id, reason}] }
```

### `rpc_register_damage(p_transfer_item_id BIGINT, p_damage_qty NUMERIC, p_notes TEXT, p_operator UUID) RETURNS BIGINT`

登記損壞 — 在 transfer_item 上記 damage_qty + 寫 'damage' stock_movement 從 dest_location 扣。

```
驗 transfer_item 存在、其 transfer.status IN ('received','closed')
驗 p_damage_qty <= qty_received - 已 damage_qty
INSERT stock_movement (movement_type='damage', location=dest_location, quantity=-damage_qty, source_doc='transfer', source_doc_id=transfer.id)
UPDATE transfer_items SET damage_qty += p_damage_qty, damage_notes append, damage_movement_id = new
回傳: damage_movement_id
```

### `rpc_transfer_batch_delete(p_transfer_ids BIGINT[], p_operator UUID) RETURNS JSONB`

批次刪除 — 只允 status='draft' 的 TR。

```
loop p_transfer_ids:
  驗 status='draft'
  DELETE transfer_items WHERE transfer_id = id
  DELETE transfers WHERE id = id
回傳: { processed: int, deleted: bigint[], failed: [{id, reason}] }
```

---

## 測試項目

### A. Schema delta

- [ ] A1：`transfers.shipping_temp` 接受 'frozen'/'chilled'/'ambient'/'mixed'、其他值 → CHECK fail
- [ ] A2：`transfers.is_air_transfer` 預設 FALSE
- [ ] A3：`transfers.hq_notes` 可空
- [ ] A4：`transfer_items.damage_qty` 預設 0、 CHECK >= 0
- [ ] A5：既有 transfers 資料 unaffected（shipping_temp NULL、is_air_transfer FALSE）

### B. `rpc_transfer_arrive_at_hq_batch` Happy path

- [ ] B1：傳入多筆 dest=HQ + shipped 的 TR → 全部推到 received
- [ ] B2：每筆對應 dest_location 產生 transfer_in stock_movement
- [ ] B3：transfer_items.qty_received = qty_shipped (走 rpc_receive_transfer 全收 path)
- [ ] B4：返回 JSONB 含 succeeded array

### C. `rpc_transfer_arrive_at_hq_batch` 邊界

- [ ] C1：傳入空 array → exception or 返回 processed=0
- [ ] C2：包含 dest 不是 HQ 的 TR → 該筆 failed、其他 succeeded（不 abort 整批）
- [ ] C3：包含 status ≠ 'shipped' 的 TR → 該筆 failed
- [ ] C4：所有都 fail → 返回 succeeded=[] failed=full list

### D. `rpc_transfer_distribute_batch` Happy path

- [ ] D1：傳入多筆 source=HQ + draft/confirmed 的 TR → 全部推到 shipped
- [ ] D2：每筆對應 source_location 扣 transfer_out stock_movement
- [ ] D3：transfer_items.qty_shipped = qty_requested、out_movement_id 寫入
- [ ] D4：transfers.shipped_by + shipped_at 寫入
- [ ] D5：返回 JSONB

### E. `rpc_transfer_distribute_batch` 邊界

- [ ] E1：包含 source 不是 HQ → failed
- [ ] E2：包含 status='shipped' 已配送 → failed
- [ ] E3：庫存不足 → 該筆 failed（rpc_outbound 拋）
- [ ] E4：part fail / part success 共存

### F. `rpc_register_damage` Happy path

- [ ] F1：transfer status='received'、damage_qty=2 → INSERT 'damage' stock_movement (-2 at dest)
- [ ] F2：transfer_items.damage_qty 更新為 2、damage_notes / damage_movement_id 寫入
- [ ] F3：dest_location 的 stock_balances.on_hand 減 2
- [ ] F4：返回 damage_movement_id
- [ ] F5：再次呼叫 累加到 4（不覆蓋）

### G. `rpc_register_damage` 邊界

- [ ] G1：transfer status='shipped' 還沒收貨 → exception
- [ ] G2：damage_qty > qty_received → exception
- [ ] G3：damage_qty < 0 → exception (CHECK)
- [ ] G4：damage_qty 累加超過 qty_received → exception
- [ ] G5：transfer_item 不存在 → exception

### H. `rpc_transfer_batch_delete` Happy path

- [ ] H1：多筆 draft → 全刪
- [ ] H2：transfer_items 一併刪（CASCADE）
- [ ] H3：返回 JSONB

### I. `rpc_transfer_batch_delete` 邊界

- [ ] I1：包含 status ≠ 'draft' → failed、不刪
- [ ] I2：empty array → exception or processed=0

### J. is_air_transfer 標記行為（手動 INSERT 驗）

- [ ] J1：INSERT transfers with is_air_transfer=TRUE → 可塞 source 跟 dest 都不是 HQ
- [ ] J2：is_air_transfer=TRUE 的 TR 不會被 batch_arrive (dest 不是 HQ)
- [ ] J3：is_air_transfer=TRUE 的 TR 不會被 batch_distribute (source 不是 HQ)
- [ ] J4：is_air_transfer=TRUE 的 TR 用 rpc_receive_transfer 直接由 dest 端確認收貨

### K. shipping_temp

- [ ] K1：INSERT 帶 shipping_temp='frozen' → 成功
- [ ] K2：UPDATE shipping_temp='mixed' → 成功
- [ ] K3：INSERT shipping_temp='room' → CHECK fail

## 不在範圍

- 總倉調度中心 UI（Phase 5d）
- 整單溫層的 default derive（從 sku 自動算 mixed）
- 損壞庫存的進一步處理（賠償、保險、報廢）
- transfer reverse 邏輯（已在 cleanup_wv pattern）

## 驗證方式

- `scripts/rpc-transfer-hq-dispatch.sql` 造 fixture（HQ + 2 stores + 2 skus + 庫存）
- 跑 A-K 測項
- 寫 report

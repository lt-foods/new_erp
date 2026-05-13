---
title: TEST — 取貨後庫存扣帳 invariant
module: Pickup / Inventory
status: passed
ran_at: 2026-05-14
verified_by: alex.chen + claude (full E2E chain)
---

# 取貨 ↔ stock_movement 一致性 invariant

## 背景

跑完整 E2E 鏈路（建商品→取貨）後發現：
- 訂單 status='completed' ✓
- order_items.status='picked_up' ✓
- order_pickup_events 有記錄 ✓
- **但 `customer_order_items.pickup_movement_id = NULL`**
- **stock_balances 沒扣** — 顧客取走但帳面顯示貨還在分店

根因：`rpc_record_pickup` 漏寫 `stock_movements` (type='sale')、也漏回填 `pickup_movement_id`。

影響：所有歷史取貨 — 分店帳面庫存膨脹、月結算對不上實體。

## 修法

`20260614000030_fix_pickup_stock_movement.sql`：

1. CREATE OR REPLACE `rpc_record_pickup` — 每個 item 寫 stock_movement (sale, -qty) + 回填 pickup_movement_id
2. Backfill 歷史 picked_up + NULL pickup_movement_id 的 items
3. Add `fn_check_pickup_movements_consistency()` 給 e2e 用
4. Migration 末尾 self-check 0 orphans 才 apply

## Invariant

**每個 `customer_order_items.status='picked_up'` 必須有 `pickup_movement_id` 對應 stock_movement (type='sale', location=pickup_store.location_id)。**

## 驗證 SQL

```sql
SELECT COUNT(*) FROM fn_check_pickup_movements_consistency();
-- expect: 0

-- 看詳情
SELECT * FROM fn_check_pickup_movements_consistency();
-- 欄位: issue / order_id / order_no / item_id / sku_id / qty / pickup_store_id
```

## 驗證 (2026-05-14, E2E)

| 測項 | 結果 | 證據 |
|---|---|---|
| fn_check 0 orphans | ✓ | `SELECT COUNT(*) FROM fn_check_pickup_movements_consistency() = 0` |
| E2E 完整鏈路 stock 全 0 | ✓ | HQ 0 / 松山 0 / 萬華 0 / 四號 0 |
| 3 個 E2E order items pickup_movement_id | ✓ | items 35/36/37 all have movement_id |
| New sale movements | ✓ | 3 筆 sale -15/-10/-5 @ 各店 |
| Backfill 既有 picked_up | ✓ | 8 historical items backfilled |

## 4 層防護（沿用 PR campaigns invariant 模式）

| Layer | 機制 |
|---|---|
| 1. RPC 寫入 | `rpc_record_pickup` 必寫 `stock_movement` + 回填 `pickup_movement_id` |
| 2. Invariant fn | `fn_check_pickup_movements_consistency()` 列孤兒 |
| 3. Self-check | Migration 末尾跑 fn、有孤兒 RAISE (除非該店未設 location_id) |
| 4. E2E TEST | 加進 TEST-E2E-T3 / TEST-E2E-master 必跑項 |

## 整合進 E2E

在 master 黃金路徑 § 7 取貨段結尾 + 各 invariant sweep 段加：

```sql
SELECT COUNT(*) FROM fn_check_pickup_movements_consistency();
-- expect: 0
```

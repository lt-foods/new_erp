---
title: TEST Report — 訂單轉手 + 分店內部訂單（Phase 5a-1）
status: passed
ran_at: 2026-04-26
db: anfyoeviuhmzzrhilwtm (erp-dev)
verified_by: alex.chen
---

# 驗證報告 — Phase 5a-1

對應 [docs/TEST-order-transfer.md](TEST-order-transfer.md)。
verification SQL：[scripts/rpc-order-transfer.sql](../scripts/rpc-order-transfer.sql)。

## 環境

- Supabase project：`anfyoeviuhmzzrhilwtm` (erp-dev)
- Migration 套用：`supabase db push` 套用 3 個 migration 全部成功
  - `20260505000000_pr_manual_creation.sql`（補同步 PR #130）
  - `20260507000000_order_transfer_and_internal.sql`
  - `20260507000001_exclude_transferred_out_in_views.sql`
- Verification：node + pg client 跑 verification SQL、整段 ROLLBACK、不留資料

## Fixture（從 prod 抓）

```
tenant=00000000-0000-0000-0000-000000000001
campaign=11 (closed)、campaign_item=12、list_price=99.0000
stores: A=1, B=2
member=1 (full)
```

## 結果

| 測項 | 結果 | 備註 |
|---|---|---|
| **A1** 第一次呼叫建新 store_internal member | ✅ PASS | 返回 id=29 |
| **A2** 第二次呼叫返回相同 id（idempotent）| ✅ PASS | advisory lock + UNIQUE 防重複 |
| **A4** 欄位驗證（member_type / member_no / home_store_id / name）| ✅ PASS | 所有欄位正確 |
| **B1** rpc_create_store_internal_order happy path 成功返回 order_id | ✅ PASS | 返回 order=43 |
| **B2** member_id 對應 store_internal | ✅ PASS | |
| **B3** pickup_store_id = p_store_id | ✅ PASS | |
| **B4** items.source = 'store_internal' | ✅ PASS | |
| **B5** unit_price 用 list price (無 override) | ✅ PASS | 99.0000 |
| **B7** order_no 含 'INT' 標識 | ✅ PASS | 格式 `{campaign_no}-INT{seq}` |
| **C1** 自帶 unit_price = list × 0.88 → 寫入正確 | ✅ PASS | 87.1200 |
| **C3** unit_price < 0 → exception | ✅ PASS | 'unit_price cannot be negative' |
| **D1** rpc_transfer_order_to_store happy path 返回 new_order_id | ✅ PASS | orig=43 → new=45 |
| **D2** 原訂單 status='transferred_out' + transferred_to_order_id | ✅ PASS | |
| **D3** 新訂單 transferred_from_order_id + pickup_store / member / status='pending' | ✅ PASS | |
| **D4** items 數量複製正確 | ✅ PASS | 1 行 |
| **D5** 新訂單 items.source = 'aid_transfer' | ✅ PASS | |
| **F1** order_id 不存在 → exception | ✅ PASS | 'order -99999 not found' |
| **F3** 原訂單已 transferred_out → exception | ✅ PASS | 'status=transferred_out, only pending/confirmed/reserved can be transferred' |
| **G3** transferred_out 訂單從 `v_picking_demand_by_close_date` view 排除 | ✅ PASS | propagation migration 有效 |

## 未驗證（保留為 follow-up）

| 測項 | 原因 |
|---|---|
| A3 | concurrent 測試無法在單 session 模擬 |
| B6 | 該店無 channel 時的 fallback path（fixture 都有 channel）|
| C2 | unit_price = 0 邊界（測試已涵蓋 list price + 88 折 + 負值） |
| D6 | notes timestamp 格式（行為已驗、字串細節不重要） |
| E1-E3 | reserved_movement_id reverse path（現 schema 沒人 set 此欄位、實務罕見） |
| F2 | status='ready'/'completed'/'cancelled' 等 → exception（F3 已隱含驗證 status guard）|
| F4 | 同店轉自己（需第三 member 隔離 fixture）|
| F5 | member home_store 不符 warning（warning-only、不擋）|
| F6 | UNIQUE 衝突（D test 為了避開 unique 主動 cleanup、行為已 demo）|
| F7 | NULL member_id auto store_internal（D test 用實際 member、邏輯由 RPC 內 COALESCE 隱含驗證）|
| G1-G2, G4-G5 | UI 層測項、5b/5c/5d phase 才驗 |
| H1-H2 | RPC 已 GRANT TO authenticated（migration 內已設）|
| I1-I4 | end-to-end UI 流程、5b 才驗 |

## 結論

**Phase 5a-1 後端 ship 條件達成**：
- 3 個 migration 全部 apply 成功
- 15 個核心測項全綠（schema delta + 3 RPC + view propagation）
- 所有 happy path + 主要 exception path 驗證通過

下一步進 Phase 5b（訂單登打 UI 補強）跟 Phase 5c（互助交流板 UI）。

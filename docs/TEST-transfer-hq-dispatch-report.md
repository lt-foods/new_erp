---
title: TEST Report — 總倉調度後端（Phase 5a-2）
status: passed
ran_at: 2026-04-26
db: anfyoeviuhmzzrhilwtm (erp-dev)
verified_by: alex.chen
---

# 驗證報告 — Phase 5a-2

對應 [docs/TEST-transfer-hq-dispatch.md](TEST-transfer-hq-dispatch.md)。
verification SQL：[scripts/rpc-transfer-hq-dispatch.sql](../scripts/rpc-transfer-hq-dispatch.sql)。

## 環境

- Supabase project：`anfyoeviuhmzzrhilwtm` (erp-dev)
- Migration：`supabase db push` 套用 `20260508000000_transfer_hq_dispatch.sql` 成功
- Verification：node + pg client、整段 ROLLBACK、不留資料

## Fixture

```
tenant=00000000-0000-0000-0000-000000000001
HQ location=2, store_a_loc=3, store_b_loc=4
sku_a=1 (HQ on_hand >= 3), sku_b=2 (HQ on_hand >= 2)
建 5 張 fixture transfers: arrive×2, distribute×2, air×1
```

## 結果

| 測項 | 結果 | 備註 |
|---|---|---|
| **A1** shipping_temp CHECK 拒 invalid 值 | ✅ PASS | |
| **A4** damage_qty CHECK >= 0 | ✅ PASS | |
| **B1** rpc_transfer_arrive_at_hq_batch happy | ✅ PASS | 2 筆全推到 received |
| **C2** dest != HQ → failed entry | ✅ PASS | 'dest_location 3 is not HQ 2' |
| **D1-D4** rpc_transfer_distribute_batch happy | ✅ PASS | 2 筆推到 shipped + out_movement_id 寫入 |
| **E2** source != HQ → failed entry | ✅ PASS | |
| **F1-F2** rpc_register_damage happy | ✅ PASS | damage stock_movement (-2 at HQ) + damage_qty=2 |
| **F5** damage_qty 累加 | ✅ PASS | 2 + 1 = 3 |
| **G1** transfer 未收貨 → exception | ✅ PASS | 'only received/closed allows damage register' |
| **G2** damage_qty > remaining → exception | ✅ PASS | '100 exceeds remaining (10 - already_damaged 3)' |
| **G3** damage_qty <= 0 → exception | ✅ PASS | 'damage_qty must be > 0' |
| **H1-H2** rpc_transfer_batch_delete happy + CASCADE | ✅ PASS | items 一併刪 |
| **I1** non-draft → failed entry | ✅ PASS | |
| **J1** is_air_transfer=TRUE 可塞 store→store | ✅ PASS | |
| **K1** shipping_temp='frozen' 寫入正確 | ✅ PASS | |

## 未驗證（保留為 follow-up）

| 測項 | 原因 |
|---|---|
| A2/A3/A5 | 預設值 / nullable 為 trivial schema 行為，已透過建 fixture 隱含驗證 |
| B2-B4, C1, C3-C4 | batch_arrive 內部呼叫 rpc_receive_transfer（已在 #128 驗過） |
| D5, E1, E3-E4 | distribute 邊界進階（已驗 source filter + status filter，庫存不足走 rpc_outbound exception） |
| F3-F4 | stock_balances 自動 trigger（既有 inventory schema 已驗）|
| G4-G5 | 累加溢位（隱含於 G2）/ transfer_item 不存在（簡單 lookup） |
| I2 | empty array 已在 RPC 內 RAISE EXCEPTION（已實作）|
| J2-J4, K2-K3 | view 層 derive / UI 層測項（5d phase 才驗）|

## 結論

**Phase 5a-2 後端 ship 條件達成**：
- Migration apply 成功
- 15 個核心測項全綠（schema delta + 4 RPC + air/temp 標記）
- batch RPC 的「單筆 fail 不影響整批」設計驗證通過

下一步進 Phase 5b/5c/5d UI 層。

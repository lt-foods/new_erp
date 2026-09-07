# 總倉退回貨處理 — A 核心 API 契約

Migration: `20260907010000_hq_return_disposition_core.sql`

## 表

| 表 | 用途 |
|---|---|
| `hq_return_batches` | 批次：每筆來源 movement 唯一，追蹤 good/damaged/lost/revoked/pending |
| `hq_return_events` | 處理事件：append-only，每次分配一筆，request_id 冪等 |

## 內部 Helper

### `_hq_hold_return(...) → BIGINT`

建批次＋凍結 `reserved`。**REVOKE** PUBLIC/anon/authenticated，僅供後端安全呼叫（B 段接線）。同 `source_movement_id` 冪等回傳既有 id。需：movement quantity > 0、同 tenant、SKU 匹配、location type = `central_warehouse`。

## 前端 RPC

### `rpc_dispose_hq_return(p_batch_id, p_request_id, p_qty_good, p_qty_damaged, p_qty_lost, p_damage_reason, p_loss_reason, p_goods_confirmed, p_notes) → JSONB`

處理退回批次。Role 白名單：owner/admin/hq_manager。`auth.uid()` 為操作者。

- 分次或一次處理（如 10 = 7好 + 2破 + 1失）
- 全 0 / 負數 / 超過 pending → 拒絕
- 破損/遺失需原因；好貨需 `goods_confirmed = true`
- `p_request_id` UUID 冪等：重試回原結果，payload 不同拒絕
- 破損寫 `hq_return_damage` 負 movement；遺失寫 `hq_return_loss` 負 movement
- 好貨不寫 movement（從 reserved 釋放回 available）
- 鎖順序：batch → balance

回傳：`{ event_id, batch_id, idempotent, qty_good, qty_damaged, qty_lost, damage_movement_id, loss_movement_id, new_status }`

## Guard Trigger

`trg_guard_hq_pending`（BEFORE INSERT on stock_movements）：有 pending 批次的 (tenant, location, sku)，任何負 movement 不能讓 on_hand 跌破 pending 總量。本案自己先減 pending 再寫 movement，不被擋。無 pending 的 SKU 與店鋪不受影響。

## List View

`v_hq_return_batches_list`（security_invoker）：同 tenant 可讀，帶 `qty_pending` 計算欄。UI 可依 `sku_id` / `source_transfer_item_id` join 品名店名，不跨 tenant。

## 不在 A 範圍

- B：來源接線（store_return / shortage → `_hq_hold_return`）
- C：原單更正/撤回、月鎖
- D：前端 UI、本機測試

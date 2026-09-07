# 總倉退回貨處理 — B 來源接線契約

Migration: `20260907020000_hq_return_disposition_sources.sql`

## 時序

```
[store_return 路徑]
  rpc_receive_transfer (return_to_hq, shipped→received)
    ├─ rpc_inbound → stock_movements INSERT (transfer_in, qty>0, HQ location)
    ├─ UPDATE transfer_items SET in_movement_id = v_in_mov_id   ← 觸發點
    └─ trg_hq_return_source (AFTER UPDATE)
        └─ _hq_hold_return → hq_return_batches + reserved

[48h auto-accept 路徑]
  rpc_auto_accept_overdue_returns → PERFORM rpc_receive_transfer(...)
    └─ 同上路徑，operator='00000000-…-0000' → auto_flag='system'

[shortage restock_hq 路徑]
  rpc_resolve_transfer_item_shortage (restock_hq)
    ├─ rpc_inbound → stock_movements INSERT (transfer_cancel, qty>0, source_location)
    ├─ UPDATE transfer_items SET shortage_restock_movement_id = v_mov_id   ← 觸發點
    └─ trg_hq_return_source (AFTER UPDATE)
        └─ _hq_hold_return → hq_return_batches + reserved

[shortage redispatch 路徑]
  rpc_resolve_transfer_item_shortage (redispatch)
    ├─ rpc_inbound (若尚未 restock) → shortage_restock_movement_id 寫入
    └─ 同上觸發
```

## 核心匹配條件

| 條件 | store_return | shortage |
|------|-------------|----------|
| 觸發欄位 | `in_movement_id` NULL→非NULL | `shortage_restock_movement_id` NULL→非NULL |
| transfer_type | `return_to_hq` | 任意（靠 location type 過濾） |
| movement_type | `transfer_in` | `transfer_cancel` |
| movement.quantity | > 0 | > 0 |
| location type | dest = `central_warehouse` | source = `central_warehouse` |
| tenant 一致 | movement.tenant = transfer.tenant | 同左 |
| SKU 一致 | movement.sku = item.sku | 同左 |
| source_kind | `store_return` | `shortage` |

## 不觸發的情境

- 一般到貨（hq_to_store）：transfer_type ≠ return_to_hq → 跳過
- 商店收 HQ 派貨（store_to_store）：同上
- 短收沖帳 return_to_hq（純帳務單）：in_movement_id IS NULL → 不觸發
- 店對店短少 restock：source_location type ≠ central_warehouse → 跳過
- UPDATE 同值（冪等保護）：OLD.col IS NOT DISTINCT FROM NEW.col → 跳過

## C 段需接的入口

C 段（原單更正/撤回）需處理以下情境：

1. **撤回收貨 (rpc_unreceive_transfer)**：transfer_items.in_movement_id 被清空
   → 需減量或撤回對應 hq_return_batches（依 source_movement_id 找批次）
   → 若批次 status=pending 可整批 revoke；partial/有 events 需依規則處理

2. **撤回短少處理 (rpc_undo_transfer_item_shortage)**：shortage_restock_movement_id 被清空
   → 同上邏輯找對應批次並處理

3. **修改實收 (rpc_adjust_received_transfer)**：qty_received 變更
   → 若 in_movement_id 沒變（movement 本身被 reversal），C 需偵測並調整批次

入口建議：C 在 hq_return_batches 上提供 `_hq_revoke_return(p_source_movement_id)` 函式，
B 的 trigger 不負責減量/撤回（B 只建不拆）。

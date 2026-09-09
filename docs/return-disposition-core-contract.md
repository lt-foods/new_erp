# 總倉退回貨處理 — A 核心 API 契約

Migration: `20260907010000_hq_return_disposition_core.sql`

## 表

| 表 | 用途 |
|---|---|
| `hq_return_batches` | 批次：每筆來源 movement 唯一，追蹤 good/damaged/lost/revoked/pending |
| `hq_return_events` | 處理事件：append-only，每次分配一筆，request_id 冪等 |

## 內部 Helper

### `_hq_hold_return(...) → BIGINT`

建批次＋凍結 `reserved`。**REVOKE** PUBLIC/anon/authenticated，僅供後端安全呼叫（B 段接線）。`source_transfer_item_id` 必填；movement、item、父 transfer 必須逐項吻合 tenant、HQ location、SKU、來源種類、原單與數量。movement 的 `source_doc_line_id` 可為 NULL（真收貨既有行為），有值時必須等於 item id；item 的 `in_movement_id`／`shortage_restock_movement_id` 必須反向指回 movement。同 `source_movement_id` 重試會核對完整 payload，一致才回既有 id，不一致拒絕。來源成本原值保存，NULL 不猜成 0。

鎖順序：先鎖同 tenant/location/SKU 的 `stock_balances`，再讀／鎖既有 batch；與處理 RPC、負異動 guard 一致。

## 前端 RPC

### `rpc_dispose_hq_return(p_batch_id, p_request_id, p_qty_good, p_qty_damaged, p_qty_lost, p_damage_reason, p_loss_reason, p_goods_confirmed, p_notes) → JSONB`

處理退回批次。Role 白名單：owner/admin/hq_manager。`auth.uid()` 為操作者。

- 分次或一次處理（如 10 = 7好 + 2破 + 1失）
- NULL／非有限值／負數／超過 3 位小數／超界／全 0／超過 pending → 精準拒絕，不先 cast 四捨五入
- 破損/遺失需原因；好貨需 `goods_confirmed = true`
- `p_request_id` UUID 必填；同 tenant/request 由 transaction advisory lock 序列化。重試核對三個數量、兩個原因、`goods_confirmed`、備註，NULL／空白先用同一規則正規化；一致回第一次完整原結果（含當時 `new_status`），不同拒絕且不重扣
- 破損沿用 `damage` 負 movement；遺失沿用 `manual_adjust`，兩者皆以 `source_doc_type='hq_return_batch'` 與 batch id 留單據鏈，不新增全域 movement 類型
- 好貨不寫 movement（從 reserved 釋放回 available）
- 鎖順序：先未鎖查 batch 定位鍵，再 `balance → batch`，鎖後重讀 batch 與 pending
- 處理前要求 `reserved >=` 同 tenant/location/SKU 的全部 pending，且 `on_hand` 足夠本次破損＋遺失實際扣量；不一致直接拒絕

回傳：`{ event_id, batch_id, idempotent, qty_good, qty_damaged, qty_lost, damage_movement_id, loss_movement_id, new_status }`

## Guard Trigger

`trg_guard_hq_pending`（BEFORE INSERT on stock_movements）：負 movement 一律先鎖同 (tenant, location, sku) balance，再重讀全部 pending；因此即使鎖前 pending=0，也不會漏掉同時建立中的 hold。任何負 movement 不能讓 on_hand 跌破 pending 總量。本案自己在同一把鎖內先減 pending 再寫 movement，不被擋。鎖後仍無 pending 的 SKU 不改原負庫存政策。trigger function 為固定 search_path 的 SECURITY DEFINER，且撤銷前端執行權。

## List View

`v_hq_return_batches_list`（security_invoker）：只授權 authenticated 中同 tenant 的 owner/admin/hq_manager 讀取，帶 `qty_pending` 計算欄。底表、事件表與 view 同刀設定 SELECT grant + role RLS；anon、店端、空 role、跨 tenant 均不可讀。UI 可依 `sku_id` / `source_transfer_item_id` join 品名店名。

## 不在 A 範圍

- B：來源接線（store_return / shortage → `_hq_hold_return`）
- C：原單更正/撤回、月鎖
- D：前端 UI、本機測試

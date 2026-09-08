# 總倉退回貨處理 — F 後端可派量契約

Migration: `20260907040000_hq_return_disposition_available.sql`

## 後端規則

- `rpc_create_store_return` 公開 signature 與原本的 tenant、店別、預鎖、待退量、建單和回傳行為不變。
- 通用退貨只收「破損／過期／客人退」。傳「少收」會整筆拒絕，並引導回 `/wms/inbound` 找原派貨單「修改實收」。
- 通用退貨在 cast、聚合或寫入 `NUMERIC(18,3)` 前先驗原始 `qty`：只收有限正數且最多 3 位小數；不接受 `NaN`、`Infinity`、0、負數或 `1.0001`，也不靜默四捨五入。
- `v_picking_demand_no_po.gr_qty` 的對外欄名不變，數字改為 `GREATEST(HQ on_hand - HQ reserved, 0)`。PO 的累計實收 `gr_qty` 沒有被改口徑。
- `rpc_create_wave_from_restock` 公開 signature、`approved_transfer`、只派申請店、申請剩餘量、已 wave 去重、建單與回傳行為不變。
- 這支舊 RPC 原本沒有額外的角色白名單；本輪仍以補貨申請的 tenant 為資料邊界，`p_operator` 沿用原行為只寫建單人。F 沒有宣稱補齊全站舊 RPC 權限。
- 建 wave 前先依 SKU 固定順序鎖住 HQ `stock_balances`，再驗 `on_hand - reserved`。不足時整筆 rollback，不建 wave，補貨需求仍留在原狀態。
- 分配數量只收有限正數、最多 3 位小數；SKU 不屬本 tenant 會直接拒絕，不會在聚合時靜默消失。

## 與 B 的實物／帳務分界

- 店家真退貨的 `transfer_in` 只建一筆待確認保留量。
- `restock_hq` / `redispatch` 真回帳的 `transfer_cancel` 也各只建一筆待確認保留量。
- 它們另建的 `return_to_hq` 短收沖帳子單沒有 `in_movement_id`，不是第二批實物，不可重複建保留量。

## 本輪不改、F-UI 下輪必須收斂的文字

- `TransferShortageResolveModal.tsx` 仍寫 `hq_supply` 直接讀 `stock_balances.on_hand`；必須改成「可派 = 帳上 - 待確認保留量」，並刪掉「回帳後沒有被保留」的過期說法。
- `wms/picking/page.tsx` 的 `RestockRow.gr_qty`、「HQ 庫存」tooltip與「庫存」字樣仍把欄位說成 `on_hand`；必須改為「HQ 可派」，不可再冒充帳上數。
- `inventory/page.tsx` 已經讀到 `reserved`，但仍留著「reserved 全站沒維護／恒為 0」舊說法。總倉列必須明列「帳上」「待確認」「可派」三個不混用的數字。

## 整合依賴

- F 要吃到 A/B 已把未確認量正確加入 `stock_balances.reserved`；A 仍要保留現有公開 signature 與必要欄位。
- C 還必須負責原單撤回／更正時把保留量一起撤掉或拒絕；F 單獨正確不代表整包已可上線。

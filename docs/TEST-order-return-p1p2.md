# order-return-p1p2 測試項目 — 退訂單回總倉 P1/P2 修補

**對應 migration:** `supabase/migrations/20260615000020_rpc_order_return_movement_type_restock.sql`
**對應 UI 變更:** `apps/admin/src/components/OrderReturnCreateModal.tsx`、`apps/admin/src/lib/rpcError.ts`
**對應情境 spec:** [docs/TEST-return-scenarios.md](TEST-return-scenarios.md)（A 退貨 / C 少領 / D 損壞 / E 過期；本 doc 只驗 P1/P2 實作面，情境語意對照該 spec）
**範圍:** P1（破損 movement_type 分流）+ P2-C（可退量加店端庫存上限）+ P2-A（取貨後反悔先 inbound 整合）。P0/E 過期支援已在 20260610000020 完成（本 doc 僅 regression）。

---

## 1. Schema / Migration 層

### 1.1 RPC signature
- [ ] 舊 4-arg signature 已 DROP
  ```sql
  SELECT count(*) FROM pg_proc WHERE proname='rpc_create_order_return'
   AND pg_get_function_identity_arguments(oid)='p_order_id bigint, p_lines jsonb, p_reason text, p_operator uuid';
  -- expect 0
  ```
- [ ] 新 6-arg signature 存在（含 `p_movement_type text`, `p_restock_first boolean`）且只有 1 個 overload
  ```sql
  SELECT pg_get_function_identity_arguments(oid)
    FROM pg_proc WHERE proname='rpc_create_order_return';
  -- expect 單行、含 p_movement_type text, p_restock_first boolean
  ```
- [ ] 預設值：`p_movement_type` 預設 `'customer_return'`、`p_restock_first` 預設 `false`
- [ ] `GRANT EXECUTE ... TO authenticated` 對新 signature 存在
- [ ] `COMMENT ON FUNCTION` 有更新（描述 movement_type / restock_first）

### 1.2 不破壞既有約束
- [ ] `stock_movements.movement_type` CHECK 仍只收 11 種；RPC 傳入值只可能是 `customer_return` / `damage`（兩者皆在 CHECK 內），不會違反

---

## 2. RPC 行為（SQL 直測）

### 2.1 預設行為（無新參數）= 回歸 20260610000020
**情境：** 對 shipping/ready 訂單呼叫 `rpc_create_order_return(order, lines, reason)`，不傳 movement_type / restock_first
**預期：** 同舊版 — 建 `return_to_hq` transfer (status=shipped)、每行 outbound `movement_type='customer_return'`、store on_hand 扣 qty、回傳 JSON 含 return_transfer_id

### 2.2 p_movement_type='damage'
**情境：** 同上但傳 `p_movement_type => 'damage'`
**預期：** outbound 的 `stock_movements.movement_type='damage'`（非 customer_return）；transfer.notes 含破損標記；returnable / 扣庫存邏輯不變

### 2.3 p_movement_type 非法值
**情境：** 傳 `p_movement_type => 'foobar'`（或 `'sale'`、`'expired_return'`）
**預期：** RAISE EXCEPTION（不可建單、無 transfer、無 movement）；錯誤訊息可被 rpcError 中文化

### 2.4 p_restock_first=true（取貨後反悔，店端庫存 0）
**情境：** completed 訂單、客戶已取走、店端該 SKU on_hand=0；呼叫帶 `p_restock_first => true`、退 N
**預期：** 先在 store loc 寫 `customer_return` inbound +N（source_doc_type='customer_order', source_doc_id=order）、再 outbound -N（source_doc_type='transfer'）；store on_hand 淨變 0；transfer return_to_hq qty_shipped=N；HQ `rpc_receive_transfer` 後 HQ on_hand +N

### 2.5 p_restock_first=false（預設）對 completed 已取訂單
**情境：** 同 2.4 但不帶 restock_first（店端 on_hand=0）
**預期：** outbound 階段 `Insufficient stock` RAISE（符合 spec A.6）；無殘留 transfer/movement（交易整筆 rollback）

### 2.6 returnable 上限仍生效
**情境：** 訂單某 SKU qty=5、已退 2，退 4（>3 可退）
**預期：** RAISE `qty exceeds returnable`（不論 movement_type / restock_first）

### 2.7 status gate 含 expired（regression P0/E）
**情境：** expired 訂單、店端有貨、退 N（restock_first=false）
**預期：** 成功；訂單 status 維持 `expired`（不被改）

### 2.8 跨 tenant / store-role 限制不變
**情境：** (a) 別 tenant 訂單；(b) store_manager 退別店訂單
**預期：** 各自 RAISE `order ... not found in tenant` / `store role can only return orders for own store`（新參數不繞過）

### 2.9 restock_first inbound 不污染 avg_cost
**情境：** 2.4 的 inbound（unit_cost=0）
**預期：** 該 SKU `stock_balances.avg_cost` 不因 restock inbound 改變（unit_cost=0 → trigger 不重算）

---

## 3. UI 行為（preview 互動）

掛載點：`OrderDetail`（訂單 popup）prefill 模式 + `/wms/transfers` 非 prefill 模式。

### 3.1 退貨類型 radio（P1）
- [ ] modal 顯示「退貨類型」radio：一般退貨 / 破損 / 過期，預設「一般退貨」
- [ ] 選「破損」送出 → RPC 收到 `p_movement_type='damage'`、movement 為 damage
- [ ] 選「一般退貨」/「過期」→ `p_movement_type='customer_return'`
- [ ] 無 console error

### 3.2 店端庫存欄 + 可退上限（P2-C）
- [ ] 表格新增「店端庫存」欄，顯示該 SKU 在取貨店 location 的 on_hand
- [ ] 「可退」= min(訂單量 − 已退, 店端庫存)（restock_first 未勾時）；數字輸入 max 同步收斂
- [ ] 店端庫存 0 且未勾 restock → 該行可退顯示 0、輸入框 disabled，送不出（不會等到 RPC 才被擋）
- [ ] 勾 restock_first → 可退回到「訂單量 − 已退」（不再被店端庫存卡）

### 3.3 取貨後反悔 checkbox（P2-A）
- [ ] modal 顯示「客戶已取貨後退回（先入庫店端再退回總倉）」checkbox + 說明字
- [ ] 選到的訂單 status='completed' → checkbox 預設勾選；其他 status 預設不勾
- [ ] 勾選送出 → RPC 收到 `p_restock_first=true`；完成後店端淨庫存不變、transfer 成立
- [ ] 不勾且店端 0 → 被 §3.2 擋（按鈕 disabled / 提示），不會送出失敗

### 3.4 送出 happy / validation
- [ ] 至少填一行、皆在可退範圍 → 建立成功、onCreated 觸發、列表刷新
- [ ] 全 0 / 超過可退 → 按鈕 disabled 或顯示「不可超過可退量」、不送 RPC
- [ ] RPC 非法 movement_type / Insufficient stock 錯誤 → 顯示中文（rpcError）

---

## 4. Regression
- [ ] 既有預設退訂單（OrderDetail `↩ 退訂單`、不選類型不勾 restock）行為與修補前一致
- [ ] `/wms/transfers` 非 prefill 模式（選店→選單→SKU 表）仍正常
- [ ] [TEST-return-scenarios.md](TEST-return-scenarios.md) §C 少領（partially_completed 退剩餘、restock 不勾）仍可退、扣店端庫存
- [ ] §E 過期 popup 仍出現 `↩ 退訂單`、可退（restock 不勾、店端有貨）
- [ ] §D 破損：reason 文字 + 類型 radio 並存，transfer.notes 仍含 reason
- [ ] 既有 `rpc_reject_transfer` / `rpc_receive_transfer` 對 return_to_hq transfer 行為不變
- [ ] `OrderReturnCreateModal` 其他叫用點（grep `OrderReturnCreateModal`）TS 不破（新 props 皆 optional / 有預設）

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功（migration applied）**、**`pnpm build` + type-check 過** 才可標 done。

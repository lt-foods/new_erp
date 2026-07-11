# TEST — 店家收貨時補貨申請推「已收貨」

Migration：`20260714000080_restock_received_on_transfer_receive.sql`
- `rpc_receive_transfer` 加邏輯 D：linked 補貨申請 shipped→received（batch 版內部呼叫，一併生效）
- `rpc_unreceive_transfer` 加反向：received→shipped
- Backfill：transfer 已收但 restock 卡 shipped 的單

## 測試項目

### 邏輯 D（收貨 → restock received）
- [ ] T1 restock shipped + linked transfer 收貨（單張 rpc_receive_transfer）→ restock 變 received；回傳 `restock_received: 1`。
- [ ] T2 批次收貨（rpc_receive_transfer_batch）含 restock 轉貨單 → 同 T1 生效。
- [ ] T3 收貨的 transfer 沒有 linked restock（一般波次/互助/自由轉）→ `restock_received: 0`，其他行為不變。
- [ ] T4 restock 同掛 TR + PR（如 RESTOCK#18 型）→ TR 收貨即推 received（PR 腿不影響）。
- [ ] T5 legacy：restock 卡 approved_transfer 且 linked_transfer_id 指向本單 → 一樣推 received。

### 反向（退回收貨）
- [ ] T6 對 T1 的 transfer 跑 rpc_unreceive_transfer → restock 退回 shipped；回傳 `restock_reverted: 1`。
- [ ] T7 再收一次 → restock 再變 received（可往復）。

### Backfill
- [ ] T8 套用時已卡住的單（transfer received/closed、restock shipped）全數變 received；RESTOCK#18 在列。
- [ ] T9 未收貨（transfer shipped）的 restock 不受 backfill 影響。

### 迴歸
- [ ] T10 收貨的庫存 inbound、customer_orders 推 ready（邏輯 B/C）、多段接力（邏輯 A）行為與 20260703000000 版一致（本檔僅追加、未改動）。
- [ ] T11 退回收貨的沖銷/守衛行為與 20260711000000 版一致。
- [ ] T12 回傳 JSON 僅「新增」key（restock_received / restock_reverted），既有 key 不變 — 前端 inbound 頁不需改。

### 部署後驗證（prod）
- [ ] T13 `GET /rest/v1/restock_requests?id=eq.18&select=status` → `received`。
- [ ] T14 補貨申請列表「已收貨」分頁出現資料。

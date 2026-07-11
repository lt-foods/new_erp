# TEST — 補貨現貨銷售鏈（內部會員 + 收貨推 ready + 轉手鎖現售價）

Migration：`20260714000090_restock_order_internal_member_and_retail_transfer.sql`
使用者定案流程：補貨 ride-along 單掛【內部】xx店 → 貨到推 ready → 店端「轉手」拆給客人（鎖現售價）→ 客人當場取貨。

## 測試項目

### 建單（rpc_create_restock_request）
- [ ] T1 新建補貨申請 → ride-along 單（RR-<id>）member_id = 該店 store_internal 會員（【內部】xx店），訂單頁可見歸屬。
- [ ] T2 店端(store_manager/staff)建單不被擋（rpc_get_or_create_store_member 無 role gate）。
- [ ] T3 既有行為迴歸：sentinel campaign/channel/item、虛擬 SKU 拒絕、qty 守衛、_jwt_store_ids 自店檢查（20260714000020）全保留。

### 收貨（rpc_receive_transfer 邏輯 D 擴充）
- [ ] T4 補貨轉貨單收貨 → restock=received（#520 行為）且 ride-along 單 pending→ready、ready_at 壓收貨當下。
- [ ] T5 非補貨轉貨單收貨 → 不碰任何 ride-along 單。
- [ ] T6 退回收貨（rpc_unreceive_transfer）→ restock 退 shipped、ride-along 單 ready→pending、ready_at 清空。
- [ ] T7 再收一次 → 兩者再前進（可往復）。

### 轉手鎖現售價（rpc_transfer_order_partial）
- [ ] T8 內部單(ready) 轉給真會員：新單 item 單價 = 當下 prices scope='retail' 最新生效價；來源分店價 snapshot 不外洩到客人單。
- [ ] T9 該 SKU 無現售價 → fallback 來源價（不炸、不寫 0）。
- [ ] T10 內部單 → 另一店內部會員（互助轉手）→ 維持原價（不重定價）。
- [ ] T11 真會員單 → 真會員單（一般轉手）→ 維持原價（不受影響）。
- [ ] T12 同店內部單轉給客人：新單 status mirror 'ready' → 客人立即可取貨；取貨守衛 Path C 由已收補貨轉貨單滿足。
- [ ] T13 部分轉出後：內部單餘量正確遞減；全轉出 → transferred_out。
- [ ] T14 源單非 ready → 擋（既有守衛保留）。

### Backfill
- [ ] T15 存量 order_kind='restock'、member_id IS NULL 的單全數補掛該店內部會員。
- [ ] T16 linked transfer 已 received/closed 的 ride-along 單補推 ready（ready_at=實際收貨時間；RR-18 在列）。
- [ ] T17 transfer 尚未收貨的 ride-along 單不動。

### 端到端（prod 驗證，套用後）
- [ ] T18 RESTOCK#18：RR-18 顯示【內部】松山店、status=ready → 訂單頁開單 → 轉手 modal 選真會員、拆 2 顆水餃 → 新單即 ready、單價=現售價 → 取貨頁完成取貨、店庫存扣減。

> 依賴：建議先套 `20260714000080`（#520）再套本檔；本檔函式全文已含 80 的邏輯 D，
> 但 80 的 restock status backfill 不在本檔。

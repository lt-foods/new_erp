# TEST — 整單轉手鎖現售價（補貨單轉客戶價格修正）

Migration：`20260720000000_transfer_order_full_retail_price.sql`
使用者回報：補貨申請轉單到客戶端，價格顯示是進貨價非售價。
根因：轉手 modal 預設「全選全量」＝整單轉出走 `rpc_transfer_order_to_store`，
該函式照抄來源 item 單價（補貨分店進貨價 snapshot）；20260714000090 的鎖現售價
修法只加在部分轉出（`rpc_transfer_order_partial`）。

## 測試項目

### 整單轉手鎖現售價（rpc_transfer_order_to_store）
- [ ] T1 補貨 ride-along 內部單(ready) 整單轉給真會員：新單 item 單價 = 當下 prices scope='retail' 最新生效價；進貨價 snapshot 不外洩到客人單。
- [ ] T2 該 SKU 無現售價 → fallback 來源價（不炸、不寫 0）。
- [ ] T3 內部單 → 另一店內部會員（互助整單轉手）→ 維持原價（不重定價）。
- [ ] T4 真會員單 → 真會員單（一般整單轉手）→ 維持原價（不受影響）。
- [ ] T5 既有行為迴歸：ready-only 守衛、重複收件人守衛（active-only）、reserved_movement 釋放、空中轉 confirmed / 經總倉 pending / 同店 mirror status 全保留（基底 20260714000010）。
- [ ] T6 與部分轉出（rpc_transfer_order_partial）行為一致：同一張補貨單，整單轉與部分轉給同一真會員，單價相同（皆為現售價）。

### Backfill
- [ ] T7 存量「補貨源整單轉手到真會員」且尚未完成（pending/confirmed/shipping/ready）的 item 改回現售價；套用當下僅 `__INTERNAL_RESTOCK__-TF0093`（165→244）在列。
- [ ] T8 已完成單不回溯改價：`__INTERNAL_RESTOCK__-TF0104`（completed、進貨價 179、現售 239）維持不動 — 已另行回報，是否補差價由業務決定。

### 端到端（prod 驗證，套用後）
- [ ] T9 分店建補貨申請（不指定會員）→ 收貨 → ride-along 單 ready → 訂單頁「轉手」預設全選全量、選真會員送出 → 新客人單單價 = 現售價。

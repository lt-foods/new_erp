# TEST — 轉出訂單「空中轉」勾選

功能：在「轉出訂單」modal 讓操作員勾選**空中轉**（直接店對店、不經總倉），
flag 寫入轉入訂單 `customer_orders.is_air_transfer`，下游 `rpc_ship_aid_order`
依此建 1 段（空中轉）或 2 段（經總倉）transfer chain。

改動檔：
- `supabase/migrations/20260712000000_transfer_order_to_store_air.sql`
  （`rpc_transfer_order_to_store` 加 `p_is_air_transfer`）
- `apps/admin/src/components/OrderTransferModal.tsx`（勾選 UI + 傳參）

---

## Schema / RPC 層

- [ ] **S1** migration 部署後，`rpc_transfer_order_to_store` 簽章為 7 args
      （尾參 `p_is_air_transfer BOOLEAN DEFAULT FALSE`）；舊 6-arg 版已 DROP，
      不存在 overload（`\df rpc_transfer_order_to_store` 只有一列）。
- [ ] **S2** 6 個具名參數呼叫（不帶 `p_is_air_transfer`）仍可執行、預設 `false`。
- [ ] **S3** 整單轉出（跨店）帶 `p_is_air_transfer=true` → 新訂單
      `is_air_transfer=true`、notes 標「(空中轉)」。
- [ ] **S4** 整單轉出帶 `false` → 新訂單 `is_air_transfer=false`、notes 標「(經總倉)」。
- [ ] **S5** 部分轉出（`rpc_transfer_order_partial`）帶 `true` / `false` 同樣正確寫入。
- [ ] **S6** 來源訂單非 `ready` → 兩支 RPC 皆 raise「貨還沒到分店…不可轉單」（F2 保留）。
- [ ] **S7** 同店轉出：即使呼叫端誤傳 `true`，UI 已 guard 成 `false`（見 U5）；
      RPC 層同店仍 mirror source.status（既有行為不變）。

## 下游派貨 chain（rpc_ship_aid_order）

- [ ] **D1** 空中轉訂單 confirmed → 派貨：只建 **1 段** transfer
      （`transfer_type='store_to_store'`, `source=轉出店`, `dest=接收店`,
      `status='shipped'`, `customer_order_id=本單`, `next_transfer_id=NULL`），
      轉出店即時 outbound。**不建 HQ leg**。
- [ ] **D2** 經總倉訂單 confirmed → 派貨：建 **2 段**
      （Leg-1 source→HQ shipped、Leg-2 HQ→dest draft，chained）。
- [ ] **D3** 空中轉：接收店在收貨頁 `rpc_receive_transfer` 收 Leg-1 →
      訂單 `shipping → ready`，**過程無總倉任何動作**。
- [ ] **D4** 經總倉：需總倉收 Leg-1（到倉）→ 自動 ship Leg-2 → 接收店收 Leg-2 → ready。

## UI 層（OrderTransferModal）

- [ ] **U1** 選跨店接收店後才出現「空中轉」勾選框；未選店 / 同店時不顯示。
- [ ] **U2** 勾選後整單轉出 → 送 `p_is_air_transfer=true`；不勾 → `false`。
- [ ] **U3** 勾選後部分轉出（取消勾選部分品項或改量）→ 送 `p_is_air_transfer=true`。
- [ ] **U4** 重新開窗 / 換訂單 → 勾選重置為未勾（`setIsAir(false)`）。
- [ ] **U5** 先選跨店並勾空中轉、再改回同店 → 送出時 `airFlag` 被 guard 成 `false`。
- [ ] **U6** 勾選框文案清楚：勾=直接配送到接收店只需接收店收貨；不勾=經總倉中轉。

## Regression

- [ ] **R1** 既有整單/部分轉出（不勾空中轉）行為完全不變（等同 `false`）。
- [ ] **R2** `tsc --noEmit` 通過（已驗證 ✅）。
- [ ] **R3** mutual-aid 頁沿用同一 modal，勾選框在該頁跨店情境亦正常出現。
- [ ] **R4** 結算：空中轉的成本調整（`20260512000012_settlement_air_transfer_adjustment`）
      不受影響（本次未動結算鏈）。

---

### 驗證狀態（本輪）
- ✅ `tsc --noEmit`（apps/admin）通過
- ✅ SQL 靜態審查：基於最新版 20260629000040 擴寫，保留 F2/同店 mirror/reserved 釋放
- ⏳ S/D 系列需 migration 部署到 DB 後以真資料跑（admin live preview 於沙箱被阻擋，
  走 DB 直驗）

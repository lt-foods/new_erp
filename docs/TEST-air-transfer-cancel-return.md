# TEST — 空中轉/互助單被取消要退回原店

需求：接收店端把轉入的互助單「取消」時,貨要退回原調出店(原店),而不是留在接收店或退回總倉。

現況(本次改動前)：
- 未收貨(pending/confirmed)、在途(shipping)取消 → `rpc_cancel_aid_order`(還原來源單→confirmed)。
- 已收貨(ready)退回 → `rpc_return_aid_order`(反向 transfer 接收店→原店 + 還原來源單),**但只在訂單詳情頁有鈕**。

本次改動：
1. `supabase/migrations/20260713000000_stock_movements_allow_transfer_cancel.sql` — 補 `transfer_cancel` 進 movement_type CHECK,修好在途撤回的 abort bug。
2. `AidOrderStatusActions.tsx` — ready 加「退回原店」動作。
3. `orders/page.tsx`、`pickup/page.tsx` — ready 互助單加「↩ 退回原店」鈕,並把 ready+互助 從「↩ 退貨(回總倉)」排除。

---

## Schema / RPC 層

- [ ] **S1** migration 部署後,`stock_movements_movement_type_check` 允許清單含 `transfer_cancel`(且原有 13 值全保留,只多這一個)。
- [ ] **S2** 在途(shipping)互助單按撤回 → `rpc_cancel_aid_order` 不再撞 CHECK;貨以 `transfer_cancel` movement 退回原調出店 location,來源單 transferred_out→confirmed,aid 單→cancelled。
- [ ] **S3** `transfer_cancel` movement 為正數量、unit_cost=0 → 原店 on_hand 回補、avg_cost 不變。
- [ ] **S4** 已收貨(ready)互助單呼 `rpc_return_aid_order` → 建反向 store_to_store transfer(接收店→原店, status=received)、接收店 outbound + 原店 inbound、aid 單 cancelled、來源單→confirmed;有付儲值金則退回。
- [ ] **S5** 空中轉 vs 經總倉都能退回原店(rpc_return_aid_order 以「該單已收貨的 dest-facing transfer」為錨、不看 chain 形狀)。
- [ ] **S6** `rpc_return_aid_order` 對 pending/confirmed/shipping/completed 皆 RAISE(只認 ready);UI 因此只在 ready 顯示鈕。

## UI 層 — 訂單列表 orders/page.tsx

- [ ] **U1** ready 且 `transferred_from_order_id != null` 的互助單:顯示「↩ 退回原店」,**不**顯示「↩ 退貨(回總倉)」。
- [ ] **U2** ready 的一般單(非互助):維持顯示「↩ 退貨(回總倉)」,不顯示退回原店。
- [ ] **U3** partially_completed / completed / expired:維持原「↩ 退貨(回總倉)」行為(不受本次影響)。
- [ ] **U4** 按「↩ 退回原店」→ prompt 原因 → 呼 `rpc_return_aid_order`;成功後列表 reload、該單消失,並提示(有退儲值金則顯示金額)。
- [ ] **U5** 桌機表格與手機卡片共用 `orderActions`,兩版都出現此鈕。

## UI 層 — 取貨頁 pickup/page.tsx

- [ ] **U6** ready 互助單顯示「↩ 退回原店」、排除「↩ 退貨(回總倉)」;非互助維持「↩ 退貨」。
- [ ] **U7** 退回成功後 reloadTick++,該單因轉 cancelled 離開列表。

## UI 層 — 狀態列 AidOrderStatusActions.tsx（hq/inbox aid 區）

- [ ] **U8** ready 的互助單狀態列出現「退回原店」;pending/confirmed/shipping 維持取消/撤回,不顯示退回原店。
- [ ] **U9** 按下 → prompt 原因 → `rpc_return_aid_order` → onChanged() 重刷。

## Regression

- [ ] **R1** 非互助訂單的取消 / 退貨回總倉流程完全不變。
- [ ] **R2** `tsc --noEmit`(apps/admin)通過(已驗證 ✅)。
- [ ] **R3** 在途撤回(shipping)修好後,一般(經總倉)互助單撤回也一併正常(非空中轉專屬)。

## 已知邊界 / 待產品確認（非本次修）

- [ ] **B1** 結算雙計:`rpc_return_aid_order` 未把「原本已收貨的 transfer」翻成 cancelled,若之後重算 store_monthly_settlement,原 air_in/air_out 仍會計入、退回 transfer(customer_order_id=NULL)為中性 → 淨額未被沖回。與 cancel/reject 一致(刻意),但值得確認。
- [ ] **B2** 退回原店的原店 inbound 用 unit_cost=0(對齊既有 return);若原店曾出清庫存,回補以 0 成本會壓低 avg_cost。
- [ ] **B3** 同店空中轉(若存在)可能無可反向的 received transfer → `rpc_return_aid_order` RAISE;UI 以 alert 呈現錯誤。

---

### 驗證狀態（本輪）
- ✅ `tsc --noEmit`（apps/admin）通過
- ✅ SQL 靜態審查：constraint 為既有清單 + transfer_cancel(純擴大、非破壞)
- ⏳ S 系列需 migration 部署 + 真資料跑(admin live preview 沙箱阻擋,走 DB 直驗)

# TEST — 空中轉全自動派貨 + HQ 收件匣獨立「空中轉」chip

功能：勾「空中轉」轉出 → 系統當下自動派貨（來源店出庫 + 建店→店 leg），貨直接進收件店的收貨佇列；總倉不用「確認」也不用「派貨」，只在收件匣獨立「空中轉」chip 留紀錄，不進待處理。

相關：migration 20260714000020（auto-ship）、20260714000010（air→confirmed 前置）、frontend `hq/inbox/page.tsx`。

---

## 1. Schema / RPC 層

- [ ] **T1.1** `rpc_transfer_order_to_store`（整單）跨店 + `p_is_air_transfer=true`：呼叫後
  - 轉入單 `status='shipping'`（非 pending/confirmed）
  - 產生 1 筆 `transfers`（`transfer_type='store_to_store'`, `status='shipped'`, `customer_order_id`=轉入單, `next_transfer_id IS NULL`）
  - 來源店 location 有 `transfer_out` stock_movement（qty 正確）
  - 來源訂單 `status='transferred_out'`
- [ ] **T1.2** 整單 `p_is_air_transfer=false`（經總倉）：轉入單仍 `status='pending'`、**不**產生 transfer leg（維持要總倉確認+派貨）。
- [ ] **T1.3** 整單同店（p_to = source store）+ air：mirror source.status、**不**自動派貨（rpc_ship 同 location 會擋）。
- [ ] **T1.4** `rpc_transfer_order_partial`（部分）新建單 + air：轉入單 `shipping`、只派**該次轉出的品項**、來源單維持 active（未全轉時）。
- [ ] **T1.5** 部分 air **追加**到既有 active 單（v_appended）：**不**重複派貨（既有單狀態不被 rpc_ship 干擾）。
- [ ] **T1.6** 來源店庫存不足 → `rpc_outbound` RAISE → **整筆轉單 rollback**（轉入單不存在、來源單未 transferred_out）。原子性。
- [ ] **T1.7** dedup 守衛仍在（active-only）；收件店有 cancelled 殘單不擋（regression of PR #494）。

## 2. 下游 / 收貨層

- [ ] **T2.1** auto-ship 產生的 leg 出現在收件店 `wms/inbound` 收貨佇列（跟手動派貨產生的 leg 一致）。
- [ ] **T2.2** 收件店 `rpc_receive_transfer` 收貨後：轉入單 `status='ready'`、可取貨。
- [ ] **T2.3** 空中轉全鏈路完全沒有 HQ location 的 transfer leg（貨不經總倉）。

## 3. UI 層（HQ 收件匣）

- [ ] **T3.1** 來源 chip 列出現獨立「空中轉」chip（label/顏色）。
- [ ] **T3.2** 點「空中轉」chip → 列出 is_air_transfer=true 的轉入單（全階段當紀錄），**無**「確認/派貨」動作鈕（唯讀）。
- [ ] **T3.3** 「互助訂單」chip 的列表與計數**不再含**空中轉（只剩經總倉）。
- [ ] **T3.4** 空中轉 chip badge 計數正確（依 stage）；不與 aid 重複計。
- [ ] **T3.5** 待處理（pending）stage 下，空中轉單**不出現**（已自動 shipping）。
- [ ] **T3.6** search / 日期 / groupBy 在「空中轉」chip 正常。
- [ ] **T3.7** 舊入口（aid 源的「空中轉」下拉）移除或不再重複；不殘留死 UI。

## 4. Regression

- [ ] **R4.1** 經總倉互助單流程（確認→派貨→2 段 chain→總倉收→配送→店收）完全不受影響。
- [ ] **R4.2** 收件匣其他來源（restock/transfer/shortage/picking/exception）計數與列表不變。
- [ ] **R4.3** `tsc` / `next build` admin 通過。
- [ ] **R4.4** 轉單 modal（OrderTransferModal）勾空中轉的送出路徑不變（RPC 參數相容）。

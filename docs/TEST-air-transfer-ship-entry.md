# TEST — 空中轉的「出貨 / 收貨」入口

## 背景（線上災情）

空中轉（店對店直送、不經總倉）的完整流程是：

```
轉出店 ↗轉出此訂單(勾空中轉)  →  轉入單 confirmed
      →  rpc_ship_aid_order(派貨)  →  建 AT- 轉移單(store_to_store, shipped) + 轉出店出庫
      →  轉入單 shipping
      →  接收店在 /wms/inbound 收貨 (rpc_receive_transfer)
      →  轉入單 ready  →  顧客取貨
```

第 2 步（派貨）全站唯一入口是 `AidOrderStatusActions`，而它只掛在 `/hq/inbox`：

- `/hq/inbox` 在 `BRANCH_HIDDEN_HREFS` 裡 → 分店帳號完全看不到這一頁。
- `/hq/inbox` 的 `source=air` 分頁被做成「唯讀，不出任何動作按鈕」（空中轉不經總倉，
  所以不讓總倉動）。

兩件事加起來 = **全站沒有任何人有派貨入口**。線上 5 張空中轉單卡在 `confirmed`、
`transfers` 一張都沒建（最早 2026-08-01）；唯一走完的一張（#42045, 2026-07-01）
是在 air 還併在 aid 分頁、還有按鈕的時候派掉的。

`OrderDetail` 的進度條當時也直說「（空中轉、暫無系統紀錄）」。

## 修法

出貨的正主是**轉出店**（貨從他們手上出去），所以把入口放到轉出店看得到的地方
—— 他們自己那張來源訂單：

- `OrderDetail` 反查 `customer_orders WHERE transferred_from_order_id = 本單
  AND is_air_transfer AND status='confirmed'`，每張秀一顆「✈ 出貨到 XX店」。
  （反查而不是用 `transferred_to_order_id`：部分轉出不會寫那一欄。）
- 接收店那一側改秀「✈ 等 XX店 出貨」，並在進度條補一格「轉出店出貨」。
- `/hq/inbox` 的 air 分頁把動作按鈕加回去當後備。

---

## 轉出店側（來源訂單）

- [ ] **A1** 來源單有一張空中轉轉入單卡在 `confirmed` → 明細出現「✈ 出貨到 XX店」。
- [ ] **A2** 按下去 → `rpc_ship_aid_order` 成功：建 1 張 `AT-O<id>-<epoch>`
      （`transfer_type='store_to_store'`, `status='shipped'`, `customer_order_id=轉入單`,
      `next_transfer_id=NULL`），轉出店 `stock_movements` 出現 `transfer_out`，
      轉入單 → `shipping`。**不建 HQ leg**。
- [ ] **A3** 整單轉出（來源單 `transferred_out`）與部分轉出（來源單仍 `ready`）
      兩種都看得到按鈕。
- [ ] **A4** 同店空中轉不出按鈕（`rpc_ship_aid_order` 會以 source/dest 同 location 擋下）。
- [ ] **A5** 轉入單已 `shipping` / `ready` / `cancelled` → 按鈕消失（只撈 `confirmed`）。
- [ ] **A6** 一張來源單分別空中轉給兩家店 → 兩顆按鈕，各自獨立出貨。
- [ ] **A7** 轉出店庫存不足 → RPC raise `Insufficient stock`，前端跳「出貨失敗：…」，
      訂單狀態不動（整個 transaction rollback）。

## 接收店側（轉入單）

- [ ] **B1** 空中轉轉入單 `confirmed` → 明細出現「✈ 等 XX店 出貨（出貨後本店在「收貨」頁收貨）」，
      **不出**出貨按鈕（避免接收店去扣別人家的庫存）。
- [ ] **B2** 進度條四格：轉出店 ✓ → 轉出店出貨（等 XX店 …）→ 分店收貨（在「收貨」頁收 AT- 轉移單）
      → 顧客取貨；不再出現「暫無系統紀錄」。
- [ ] **B3** 轉出店出貨後重整 → 進度條第 2 格變 done、hint 消失。
- [ ] **B4** `/wms/inbound`（分店帳號）看得到那張 AT- 轉移單（`dest_location` = 本店），
      收貨後轉入單 → `ready`，`/pickup` 可勾品項交貨。
- [ ] **B5** 經總倉（`is_air_transfer=false`）的轉入單完全不受影響：沒有 hint、
      進度條仍是 總倉收到 / 運送中 / 分店收貨 三格。

## HQ 後備

- [ ] **C1** `/hq/inbox?source=air` 每列回到「派貨 / 取消 / 查看訂單」，
      派貨行為與 `source=aid` 一致。
- [ ] **C2** `source=aid` 分頁不含空中轉（維持既有 `is_air_transfer` 分流），計數不重複。

## Regression

- [ ] **R1** `tsc --noEmit`（apps/admin）通過。
- [ ] **R2** eslint 對兩支改動檔沒有新增 error（既有 3 個 `set-state-in-effect`
      是 hq/inbox 原本就有的）。
- [ ] **R3** 一般顧客訂單（非互助）明細完全不變 —— 反查查不到東西時不多打任何 UI。

---

### 驗證狀態（本輪）

- ✅ `tsc --noEmit` 通過
- ✅ eslint 無新增 error（與改動前同樣 3 個既有 error）
- ✅ A1 / B1 / B2：Playwright + fixture（線上真實兩張單 #70214 松山店 →
  #74738 三峽店 的資料）跑過，兩側畫面都如預期
- ⏳ A2 / A7 / B3 / B4 需在真資料上點一次才算數（會動庫存，留給店家操作）

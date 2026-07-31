# TEST：未取退貨扣應收 + 取貨退貨守門

> Migration：`20260731000000_return_deduct_payable_and_pickup_guard.sql`
> 回報案例：訂單 GRP-20260625-018-0015 — 破損退 1 件（$199）後結帳仍收 $1194，應為 $995。
> 情境語意對照 `docs/TEST-return-scenarios.md`、SOP `docs/SOP-收貨後退貨.md`。

## 語意

- **未取退貨**（退貨單 notes header 無 `|取貨後退回`）：貨退回總倉、客人拿不到 → **應收直接扣**。
- **取貨後退回**（`|取貨後退回`）：錢已在取貨時收 → **應收不動**，退款照舊走 `rpc_wallet_partial_refund`（TEST-return-scenarios §E.8）。
- 扣減金額 = 退貨量依品項行序分攤到該 SKU 未取消行 × 該行 `unit_price`。

## A. 應收計算（v_customer_order_summary）

- [ ] **A.1** 回報單 GRP-20260625-018-0015：`payable_amount` = **995**（原 1194 − 199）、`returned_qty`=1、`returned_deduction`=199
- [ ] **A.2** 無退貨訂單：`payable_amount` 與改前完全一致（全庫 diff 應只有帶未取退貨的單變動）
- [ ] **A.3** 「取貨後退回」退貨單：`returned_deduction`=0、應收不變
- [ ] **A.4** 整單退光：`payable_amount`=0；已付儲值金的單 `balance_due`=0（退款仍走人工 partial refund）
- [ ] **A.5** 整單折扣 %：先扣退貨再打折（`(items_total−deduction)×(1−pct)`）
- [ ] **A.6** admin 訂單明細：小計後顯示「− 退貨 $N」、應收 = 扣後金額；LIFF 會員端訂單卡金額同步
- [ ] **A.7** `rpc_wallet_pay_order`：儲值金付款上限 = 扣退貨後應收（多付會被 `wallet pay exceeds balance_due` 擋）

## B. 取貨退貨守門（rpc_record_pickup）

- [ ] **B.1** 訂 3 退 1（未取退貨）→ stale 畫面送整行取 3 → RAISE「已退貨 1 件，本次最多可取 2 件」
- [ ] **B.2** 同上、取 2（部分取）→ 成功，拆行：picked 2 + 剩 1 active；應收 = 扣退貨後金額
- [ ] **B.3** 取貨後退回的退貨**不**擋後續取貨（pool 分流同 `rpc_create_order_return` cap）
- [ ] **B.4** 無退貨訂單取貨行為與改前完全一致
- [ ] **B.5** 前端 PickupDialog 可取量 = 訂購量 − **未取**退貨量（「取貨後退回」不再誤扣可取量）
- [ ] **B.6** 小白單（/pickup/print-list）：品項數量/小計/合計皆扣未取退貨，退過的行印「↩ 已退貨 N 件（不收費）」；回報單情境印 $995 而非 $1194

# 剩餘品項斷貨 → 已取完的訂單自動結單

對應 migration `20260808000000_close_order_when_remaining_items_stockout.sql`。

回報案例：訂單 `GRP-20260712-004-0046`（id=49469，湖口店）4 個品項取了 3 個，
剩下的「滷虱目魚肚」被採購斷貨連動取消，訂單卻永遠停在「部分取貨」結不掉。

---

## 0. 規則

訂單品項被取消（斷貨 / 待補貨取消）之後，單頭重算一次：

| 剩餘待取品項 | 有沒有取過貨 | 訂單 status |
|---|---|---|
| 有（pending/reserved/ready） | — | 不動（照舊 partially_completed / ready …） |
| 沒有 | 有 picked_up | **completed** ← 本次新增 |
| 沒有 | 完全沒取過 + 沒收過錢 | cancelled（既有斷貨連動規則） |
| 沒有 | 完全沒取過 + 收過錢 | 不動（留人工退款） |

「有沒有待取品項」的判定集合 = `status IN ('pending','reserved','ready')`，
與 `rpc_record_pickup` 的 `v_active_remaining` 同一套 → 「先斷貨後取貨」和
「先取貨後斷貨」兩種順序結果一致。

實作在 `_close_orders_all_items_settled(order_ids, operator, at)`，
由 `_stockout_po_items`（採購斷貨核心）與 `rpc_cancel_backorder_items` 呼叫。

---

## A. 採購斷貨（PO 品項 / 整張 PO）

前置：開團訂單 X 有 A、B 兩個品項，A 已取貨（picked_up）、B 還沒到貨（pending）。

- [ ] **A.1** 採購單編輯頁把 B 對應的採購品項標「⛔ 斷貨」（`rpc_stockout_po_item`）
- [ ] **A.2** 訂單 X 的 B 品項顯示「斷貨」（紅標）、status=cancelled + stockout_at
- [ ] **A.3** 訂單 X status → **已完成**，`completed_at` 有值
- [ ] **A.4** /orders「部分取貨」分頁看不到 X；「已完成」分頁看得到
- [ ] **A.5** 整張 PO 斷貨（`rpc_stockout_purchase_order`）走同一核心，結果同 A.3
- [ ] **A.6** 回傳 jsonb 多一個 `orders_completed` 計數

邊界：

- [ ] **A.7** 訂單 X 還有第三個品項 C 沒取也沒斷貨 → X 維持 partially_completed
- [ ] **A.8** 訂單 Y 一件都沒取、全品項斷貨、未付款 → 照舊整單 cancelled（不是 completed）
- [ ] **A.9** 重跑同一支 RPC（冪等）→ `orders_completed` = 0，不重複改狀態

## B. 待補貨確定補不到（少發配貨）

前置：訂單 Z 有 A、B 兩品項，A 已取貨，B 在「少發配貨」被標成待補貨（backorder_at）。

- [ ] **B.1** ⚖️ 少發配貨視窗按「確定補不到 → 取消待補貨」（`rpc_cancel_backorder_items`）
- [ ] **B.2** alert 顯示「…，1 張已取完的訂單結單」
- [ ] **B.3** 訂單 Z status → 已完成

## C. 資料治理（migration 內 DO block）

- [ ] **C.1** 套用 migration 後，下面這條要回 0：

```sql
SELECT count(*) FROM customer_orders co
 WHERE co.status = 'partially_completed'
   AND EXISTS (SELECT 1 FROM customer_order_items x
                WHERE x.order_id = co.id AND x.status = 'picked_up')
   AND NOT EXISTS (SELECT 1 FROM customer_order_items x
                    WHERE x.order_id = co.id
                      AND x.status IN ('pending','reserved','ready'));
```

- [ ] **C.2** 2026-08-08 首次套用時收尾 18 張（PO2607140844 連動 10 張、
      2026-08-06 品項斷貨連動 8 張），全部 payment_status='unpaid'

---

## 已知未處理

訂單「應收」目前**含**已取消／斷貨的品項金額
（`v_customer_order_summary.items_total` = `SUM(qty*unit_price)` 不濾 status），
所以上面例子結單後應收仍是 $283（實取 $218）。這是獨立的計價問題，
本次不動 — 詳見 CLAUDE.md / 交接說明。

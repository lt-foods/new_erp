# TEST — 會員端「未結單金額」只算已訂未領貨

對應 migration：`20260810000000_receivable_exclude_picked_up.sql`
對應程式：`supabase/functions/liff-api/index.ts`（`get_overview` / `list_my_settlements`）、
`apps/member/src/components/SettlementCard.tsx`、`apps/member/src/app/me|overview/page.tsx`

## 背景（回報案例）

團友回報「未到貨總金額跟實際內容出入很大」，4 位會員：

| 會員 | 畫面顯示（舊） | 逐張加總（實際未領） |
|------|---------------|--------------------|
| 528590 | $3,072 | $1,110 |
| 581086 | $6,336 | $1,421 |
| 160806 | $5,280 | $1,808 |
| 091207 | $9,700 | $4,171 |

根因：`get_overview` 用 `payment_status='unpaid'` 當「還沒收錢」的條件，
但這個欄位全站**從來沒有被寫成 `'paid'` 過**（取貨當下收現金，`rpc_record_pickup`
不回寫），等於沒過濾 → 把所有取過貨的舊訂單一路累加。

---

## A — 資料前提（跑之前先確認，這是整個 bug 的根）

| # | SQL | 預期 |
|---|-----|------|
| A-1 | `SELECT payment_status, count(*) FROM customer_orders GROUP BY 1;` | 只有 `unpaid` 一列。**只要這裡沒有 `paid`，任何拿 payment_status 判斷收款的程式都是錯的** |
| A-2 | `SELECT status, count(*) FROM customer_order_items GROUP BY 1;` | 有 `pending` / `picked_up` / `cancelled`（/`ready`）；`picked_up` = 已收現金 |

## B — view 欄位

| # | SQL | 預期 |
|---|-----|------|
| B-1 | `SELECT id, items_total, unpicked_total, payable_amount, outstanding_amount FROM v_customer_order_summary LIMIT 1;` | 4 欄都在，不報錯 |
| B-2 | 挑一張 `status='completed'`（品項全 `picked_up`） | `unpicked_total=0`、`outstanding_amount=0`、`payable_amount` 不變（仍是原訂單金額） |
| B-3 | 挑一張 `status='confirmed'`（品項全 `pending`） | `outstanding_amount = payable_amount` |
| B-4 | 挑一張 `status='partially_completed'` | `0 < outstanding_amount < payable_amount`，且 `unpicked_total` = 未取品項小計 |
| B-5 | `SELECT count(*) FROM v_customer_order_summary WHERE status IN ('cancelled','expired','transferred_out') AND outstanding_amount <> 0;` | `0`（終態一律 0；`transferred_out` 的品項還留在原單且是 `pending`，不歸零會跟新單重複計算） |
| B-6 | `SELECT count(*) FROM v_customer_order_summary WHERE outstanding_amount > payable_amount;` | `0` |
| B-7 | 挑一張「剩下沒取的都退回總倉」的單（`returned_deduction >= unpicked_total`） | `outstanding_amount=0`（貨退了就不該收錢） |

## C — 回歸：4 位回報會員

```sql
SELECT m.id, m.name,
       SUM(v.outstanding_amount) AS new_amt,
       SUM(v.payable_amount) FILTER (
         WHERE v.payment_status='unpaid' AND v.status NOT IN ('cancelled','expired')
       ) AS old_amt
  FROM members m
  JOIN v_customer_order_summary v ON v.member_id = m.id
 WHERE m.id IN (67982, 68270, 67958, 69032)
 GROUP BY 1,2;
```

預期 `new_amt` 分別為 1110 / 1421 / 1808 / 4171（= 上表右欄），
`old_amt` 為 3072 / 6336 / 5280 / 9700（= 團友截圖那些數字）。

## D — Edge Function

| # | 步驟 | 預期 |
|---|------|------|
| D-1 | `POST /functions/v1/liff-api {"action":"get_overview"}`（會員 528590 的 token） | `receivable_amount = 1110` |
| D-2 | 同上 | `active_orders_count = 7` |
| D-3 | `{"action":"list_my_orders","tab":"active"}` 逐張 `payable_amount` 加總 | = D-1 的 `receivable_amount`（**這就是團友做的驗算，兩邊必須一致**） |
| D-4 | `{"action":"list_my_settlements","tab":"unpaid"}` | 只回還有沒領走的貨的單；已全部取貨的舊單不出現 |
| D-5 | 不帶 Authorization | 401 missing authorization（確認函式真的有部署，不是 gateway 404） |

## E — 會員端畫面

| # | 步驟 | 預期 |
|---|------|------|
| E-1 | 會員中心 `/me` | 「未結單金額」= D-1 的數字，下方有一行「已訂購但還沒領走的金額；取貨時付款，領完就不再計入」 |
| E-2 | 點「進行中訂單 N 筆」進 `/orders` | 逐張「應付金額」加總 = E-1 的數字 |
| E-3 | 取貨一張單之後重新整理 `/me` | 未結單金額**下降**該單金額；筆數 −1 |
| E-4 | 部分取貨（partially_completed）後 | 未結單金額只扣掉已取走的那部分 |
| E-5 | `/settlements` 的「待付款」分頁 | 已取貨的單不再出現；卡片上的「已付款 / 未付款」標依「還有沒有貨沒領」判定 |

## 已知限制（不在本次修復範圍）

- `payment_status` 仍然是全站 `unpaid`，本次只是**不再拿它當收款依據**。
  若之後要做「取貨時記錄實收現金」，應在 `rpc_record_pickup` 回寫
  `payment_status` / `paid_at`，屆時 `outstanding_amount` 需再把「已付款但還沒領」
  的情況納入。
- 匯款 / 宅配（`remit_amount`、`shipping_method`）目前線上都是 0 筆使用，
  未取貨即付款的情境沒有實測資料。

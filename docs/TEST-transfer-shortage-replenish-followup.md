# TEST — 收貨短少：標「補出貨」後要追到貨真的補到

對應：`supabase/migrations/20260807000050_hq_exceptions_replenish_followup.sql`
＋ `apps/admin/src/components/TransferShortageResolveModal.tsx`

## 背景（線上事故）

訂單 `GRP-20260714-013-0003`（id=50856，平鎮店）的 `(D)芋頭生乳捲 G01109-04`
永遠卡在「待取」，總倉哪裡都看不到：

| 時間 | 事件 |
| --- | --- |
| 8/3 02:41 | `WAVE-857-S1`（transfer 8597）出貨到平鎮店 |
| 8/3 06:16 | 店家收貨，單頭備註「少收1  (D)芋頭生乳捲沒有來」，`transfer_item 16571` 出 1 收 0 → 異常頁「收貨短少」列出 |
| 8/4 08:35 | 會員取走同單的 `(A)原味`，訂單轉 `partially_completed` |
| 8/4 09:36 | 總倉標 `shortage_resolution='replenish'`（補出貨）→ 該列消失 |
| — | 從此沒有任何補貨 transfer 被建出來 |

「訂單短少」接不住這種單：`v_order_shortage` 是 SKU 累計帳（sku 3168 訂 9 收 9），
帳上不缺貨——貨確實進了總倉也發出去了，只是有 1 件在送到平鎮店的路上不見了。

## 驗證

### 1. 標了 replenish、貨還沒補到 → 異常頁仍看得到

```sql
SELECT row_key, doc_no, reason, extra
  FROM v_hq_exceptions WHERE row_key = 'tshort-16571';
```

預期：

```
tshort-16571 | WAVE-857-S1 | 店家收貨備註：少收1  (D)芋頭生乳捲沒有來
             | 分店少收或運送中遺失 · 已標補出貨,尚未補到
```

UI：`/hq/inbox?source=exception` →「收貨短少」分頁應出現 `WAVE-857-S1`，
原因欄有店家備註、備註欄有「已標補出貨,尚未補到」。

### 2. 其他 resolution 維持標記即結案（不回歸）

```sql
-- accept / cancel_orders / vendor_claim 標記過的短少列不應出現
SELECT COUNT(*) FROM v_hq_exceptions e
  JOIN transfer_items ti ON ti.id = e.transfer_item_id
 WHERE ti.shortage_resolution IN ('accept','cancel_orders','vendor_claim');
-- 預期 0
```

套用當下實測：`transfer_short` 154 → 155 筆（只多出 `tshort-16571`），
其他 4 種型別計數完全不變（po_shortage 3 / po_damage 2 / po_over 34 /
customer_shortage 94）。

### 3. 補到貨會自動下架（自癒）

在該店（`dest_location`）建一張含同 SKU 的 transfer，收貨（`status='received'`、
`received_at` 晚於 `shortage_resolution_at`）且累計實收 ≥ 缺口後：

```sql
SELECT COUNT(*) FROM v_hq_exceptions WHERE row_key = 'tshort-16571';
-- 預期 0（不需要再回異常頁按一次）
```

反向：只補一半（實收 < 缺口）→ 該列仍在。

### 4. 「處理收貨短少」modal 看得到部分取貨的受害訂單

異常頁該列按「處理」→「該店該品項待處理客戶訂單分析」應列出
`GRP-20260714-013-0003`（狀態顯示「部分取貨」、1 件）。

修正前該區塊會顯示「沒有待處理客戶訂單」——查詢的訂單狀態清單漏了
`partially_completed`。同時已取走的行（`coi.status='picked_up'`）不再計入需求量，
避免部分取貨單被重複計算。

對應 SQL 檢查：

```sql
SELECT co.order_no, co.status, coi.status AS item_status, coi.qty
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
 WHERE co.pickup_store_id = 1 AND coi.sku_id = 3168
   AND co.status IN ('pending','confirmed','shipping','ready','partially_completed')
   AND co.transferred_from_order_id IS NULL
   AND coi.status NOT IN ('cancelled','expired','picked_up');
-- 預期 1 列：GRP-20260714-013-0003 / partially_completed / pending / 1
```

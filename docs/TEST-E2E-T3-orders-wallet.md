# TEST-E2E-T3 — 訂單 + Wallet

**範圍：** 後台加單 / LIFF 建單在 admin 顯示 / 訂單轉手 / 88 折 / soft-cancel / 負數訂單 / wallet（topup/spend/refund/adjust/reverse）
**對應 master §：** §3a / §3b / §3c / §3d / §7 / §11 / §14 / §16
**對應 fixture seed：** with-orders.sql (8 orders) + with-wallet-history.sql (3 members × wallet 歷史) + with-mutual-aid (R11d offset 訂單)
**反向情境覆蓋：** R4 / R8 / R10

---

## 既有 docs（直接複跑、勿重寫）

> 跑法：每 doc 用 `run-feature-tests` skill 對著 seeded DB 跑、產 inline `-report.md`

| 既有文件 | 範圍 | 三色 | 動作 |
|---|---|---|---|
| TEST-order-entry-mvp0.md | admin 加單 baseline | 🟡 | 跑 |
| TEST-order-entry-store-internal.md | store_internal member 加單 | 🟢 | relink |
| TEST-order-transfer.md | 跨會員訂單轉手 | 🟢 | relink |
| TEST-order-transfer-button.md | 轉手 UI 按鈕 | 🟡 | 跑 |
| TEST-orders-edit.md | 訂單編輯 / 折扣 / 修價 | 🟡 | 跑 |
| TEST-訂單刪除與負數訂單.md | soft-cancel + 負數 | 🟡 | 跑 |
| TEST-order-expiry-events.md | 取貨逾期 append-only | 🟡 | 跑 |
| TEST-order-shortage-events.md | 缺貨事件 append-only | 🟡 | 跑 |
| TEST-wallet-phase-a.md | wallet 寫入 / refund / adjust / reverse | 🟡 | 跑 |
| TEST-wallet-phase-b.md | wallet phase b | 🟡 | 跑 |
| TEST-wallet-phase-c.md | wallet phase c | 🟡 | 跑 |
| TEST-wallet-phase-d.md | wallet phase d | 🟡 | 跑 |

---

## Gap addendum — 既有 doc 沒 cover 的整合情境

### G3.1 LIFF 建的訂單在 admin /orders 顯示
- [ ] **SQL:** `customer_order_items.source = 'liff'` 的 row 應在 `/orders` 列表帶來源標籤渲染
  ```sql
  SELECT o.order_no, coi.source FROM customer_orders o
   JOIN customer_order_items coi ON coi.order_id = o.id
   WHERE coi.source = 'liff';
  ```
- [ ] **UI (preview):** `/orders` 列表能依 source filter（manual / liff / csv / screenshot_parse）

### G3.2 customer_order_sources 多源類型
- [ ] **SQL:** seed 已建 3 種 source_type（screenshot/manual_paste/csv），`/orders` 詳情頁能顯示
  ```sql
  SELECT cos.source_type, cos.screenshot_url, cos.order_id FROM customer_order_sources cos;
  -- expect: 3 rows for ORD-0001(screenshot), ORD-0002(manual_paste), ORD-0008(csv)
  ```

### G3.3 88 折 + 銀卡雙折扣（ORD-0008）
- [ ] **SQL:** ORD-0008 unit_price = ROUND(campaign_items.unit_price × 0.92 × 0.88, 4) = 65 × 0.8096 = 52.624
  ```sql
  SELECT coi.unit_price, coi.notes FROM customer_orders o
   JOIN customer_order_items coi ON coi.order_id = o.id
   WHERE o.order_no = 'ORD-0008';
  ```
- [ ] **UI:** `/orders/ORD-0008` 顯示折扣計算明細

### G3.4 負數訂單 + wallet refund 串
- [ ] 從 ORD-0005（cancelled）建 offset order
- [ ] **RPC:** `rpc_create_offset_order(p_order_id, ...)` 執行
- [ ] **SQL:** offset order 的 customer_order_items.qty 為負數
- [ ] **SQL:** wallet refund row 對應 offset 金額
- [ ] **驗收：**
  ```sql
  SELECT type, change, balance_after, source_type, source_id, reason
    FROM wallet_ledger
   WHERE source_type = 'customer_order'
     AND source_id IN (SELECT id FROM customer_orders WHERE order_no LIKE 'OFFSET-%')
   ORDER BY id;
  ```

---

## 反向情境驗證（4 維 ripple）

### R4. 訂單缺貨（ORD-0007 partially_completed）

**Seed 起點：** with-orders.sql 灌 ORD-0007 status='partially_completed' + order_shortage_events 1 筆（SKU-009 申請 3 實得 2）

**4 維 ripple 驗證：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 不應有 sale movement（撿貨還沒做、缺貨在訂單確認時就發現）| `SELECT * FROM stock_movements WHERE source_doc_id = (SELECT id FROM customer_orders WHERE order_no='ORD-0007') AND movement_type='sale';` 應 0 rows |
| wallet_ledger | M-TEST-002 wallet **不應**因 ORD-0007 扣款（除非已預扣需 refund）| `SELECT * FROM wallet_ledger WHERE source_type='customer_order' AND source_id=(SELECT id FROM customer_orders WHERE order_no='ORD-0007');` |
| customer_order_items | status='partially_picked_up' + qty=3 unchanged | `SELECT status, qty FROM customer_order_items WHERE order_id=(SELECT id FROM customer_orders WHERE order_no='ORD-0007');` |
| store_monthly_settlement | 不入結算（訂單未完成）| `SELECT * FROM store_monthly_settlement_items smsi JOIN transfers t ON t.id=smsi.transfer_id WHERE ...` |

**額外：** order_shortage_events 1 筆、shortage_qty = 1（GENERATED column）

### R8. 顧客取貨後反悔（ORD-0006）

**Seed 起點：** ORD-0006 status='completed' + order_pickup_events 1 筆（picked_up）+ stock_movement type='customer_return' (+1 SKU-002 @ S001) + wallet_ledger refund +80 給 M-TEST-001

**4 維 ripple 驗證：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 1 筆 customer_return @ S001 location, qty=+1, source_doc_id=ORD-0006 | `SELECT * FROM stock_movements WHERE source_doc_type='customer_order' AND movement_type='customer_return' AND source_doc_id=(SELECT id FROM customer_orders WHERE order_no='ORD-0006');` |
| wallet_ledger | 1 筆 refund +80 給 M-TEST-001（reason 提到 ORD-0006）| `SELECT * FROM wallet_ledger WHERE member_id=(SELECT id FROM members WHERE member_no='M-TEST-001') AND type='refund' AND reason LIKE '%ORD-0006%';` |
| customer_order_items | SKU-002 status='picked_up'（取貨後退、不改 status）| 註：實作上若有 'returned' status 應更新；現狀無 'returned' enum |
| store_monthly_settlement | ORD-0006 是顧客直接交易、不走 hq_to_store transfer、無月結算影響 | — |

**驗收：** wallet_balances M-TEST-001 = 750 (history) + 80 (R8 refund) = 830
```sql
SELECT balance, version FROM wallet_balances
 WHERE member_id = (SELECT id FROM members WHERE member_no = 'M-TEST-001');
```

### R10. Wallet topup reversal（M-TEST-003）

**Seed 起點：** with-wallet-history.sql 給 M-TEST-003 灌 topup +200 → topup +100 (reversed) → reversal -100 → balance=200

**驗證：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| wallet_ledger | 3 rows: topup(+200), topup(+100, reversed_by=L3), reversal(-100, reverses=L2) | `SELECT id, type, change, balance_after, reverses, reversed_by FROM wallet_ledger WHERE member_id=(SELECT id FROM members WHERE member_no='M-TEST-003') ORDER BY id;` |
| wallet_balances | balance=200, version=3 | `SELECT balance, version FROM wallet_balances WHERE member_id=(SELECT id FROM members WHERE member_no='M-TEST-003');` |
| append-only invariant | 直接 `UPDATE wallet_ledger SET reason='x' WHERE ...` 應 RAISE | `BEGIN; UPDATE wallet_ledger SET reason='x' WHERE member_id=...; ROLLBACK;` |
| consistency | 三筆 ledger 累加 = balance | `SELECT SUM(change) FROM wallet_ledger WHERE member_id=(SELECT id FROM members WHERE member_no='M-TEST-003');` 應 = 200 |
| 不能反向 reversal | 對 L3 (reversal) 跑 `rpc_wallet_reverse` 應 RAISE 'cannot reverse a reversal' | 跑 RPC 確認 |

---

## Wallet 全套對齊（含 base + history + R8 refund）

預期最終 balance（reset.sh full-demo --yes 跑完後）：

| Member | base seed | history | R8 refund | 預期 balance |
|---|---|---|---|---|
| M-TEST-001 | 0 | +1000 -300 +50 = 750 | +80 (R8) | **830** |
| M-TEST-002 | +5000 | -500 | — | **4500** |
| M-TEST-003 | 0 | +200 +100 -100 (rev) = 200 | — | **200** |
| M-TEST-INT-001 | 0 | — | — | **0** |

驗證：
```sql
SELECT m.member_no, wb.balance, wb.version,
       (SELECT SUM(change) FROM wallet_ledger wl WHERE wl.member_id = m.id) AS ledger_sum
  FROM members m
  LEFT JOIN wallet_balances wb ON wb.member_id = m.id
 WHERE m.tenant_id = ?::uuid
 ORDER BY m.member_no;
```

預期 `balance = ledger_sum` for all rows（fn_check_wallet_consistency 0 rows）。

---

## Regression / 不應壞

- [ ] 既有 wallet read-only 顯示沒壞
- [ ] 既有「積分流水」tab 不受影響
- [ ] LIFF 顧客端任何頁不受影響（本軌跳過 LIFF UI 測試、但 schema 不應動）
- [ ] admin app `pnpm build` + typecheck 過

---

## 驗收門檻

- [ ] G3.1 ~ G3.4 + R4 + R8 + R10 + Wallet 對齊全勾
- [ ] 既有 12 docs 各跑完 inline report
- [ ] preview 無 console error
- [ ] `fn_check_wallet_consistency()` 回 0 rows
- [ ] 結 `TEST-E2E-T3-orders-wallet-report.md` status: passed
- [ ] [TEST-INDEX.md](TEST-INDEX.md) 此軌標🟢 + 最近驗證日

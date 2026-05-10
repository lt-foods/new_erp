# TEST-E2E-T5 — WMS 出貨（Wave / Pick / Ship / Receive / 逆轉 / 異常）

**範圍：** picking_waves 建立 / 撿貨 / generate_transfer_from_wave / hq_to_store transfer ship / receive / wave 取消 / 撿貨不足 / 異常處理工作台
**對應 master §：** §5a / §5b / §12 / §15 (反向)
**對應 fixture seed：** with-picking-wave.sql（WAVE-0001 picked R5 + WAVE-0002 cancelled R9）+ with-pr-po（GR）+ with-transfers（hq_to_store TF-0002/0005/0006）
**反向情境：** R5 撿貨不足 / R9 wave 整單取消

---

## 既有 docs

| 文件 | 範圍 | 三色 | 動作 |
|---|---|---|---|
| TEST-arrive-and-distribute.md | rpc_arrive_and_distribute 進貨派送 | 🟡 | 跑 |
| TEST-hq-dispatch-ui.md | HQ 派貨 UI | 🟢 | relink |
| TEST-picking-require-po.md | 撿貨需要對應 PO | 🟡 | 跨 T4/T5 |

---

## Gap addendum

### G5.1 stock_movements 鏈完整
- [ ] **SQL:** GR confirmed → 1 筆 purchase_receipt @ HQ
- [ ] **SQL:** wave generate_transfer_from_wave → 對每店建 transfer + transfer_out movement @ HQ + transfer_in movement @ store
- [ ] **驗證鏈:**
  ```sql
  SELECT sm.movement_type, sm.quantity, sm.location_id, sm.source_doc_type, sm.source_doc_id
    FROM stock_movements sm
   WHERE sm.tenant_id = ?::uuid
     AND sm.source_doc_type IN ('purchase_receipt','transfer','customer_order','purchase_return')
   ORDER BY sm.created_at;
  ```

### G5.2 stock_balances 一致性
- [ ] **SQL:** 對每 (location, sku) 的 balance.on_hand = SUM(stock_movements.quantity)
  ```sql
  SELECT sb.location_id, sb.sku_id, sb.on_hand,
         (SELECT SUM(quantity) FROM stock_movements sm
           WHERE sm.tenant_id = sb.tenant_id
             AND sm.location_id = sb.location_id
             AND sm.sku_id = sb.sku_id) AS calc_on_hand
    FROM stock_balances sb
   WHERE sb.on_hand <> (SELECT COALESCE(SUM(quantity),0) FROM stock_movements sm
                         WHERE sm.location_id = sb.location_id AND sm.sku_id = sb.sku_id);
  -- expect 0 rows (full balance reconciliation)
  ```

### G5.3 Wave generate transfers post-condition
- [ ] **SQL:** picking_wave_items.generated_transfer_id 對 picked > 0 都有值
- [ ] **SQL:** transfer count 對應 distinct stores in wave_items

### G5.4 異常處理工作台 `/wms/exceptions`
- [ ] **UI:** 應列出 R5 / R6 / R3 異常 row（從 fixture seed 可見）
- [ ] **UI:** 點 row 後 → 對應 RPC 流程（resolve / 補單 / 退）

### G5.5 收件匣整合（pickers task → /hq/inbox）
- [ ] **驗證：** WAVE-0001 picked 但未 shipped → inbox `pending` tab 有 row
- [ ] **驗證：** WAVE-0002 cancelled → 不在 inbox

---

## 反向情境（4 維 ripple）

### R5. 撿貨不足量 — WAVE-0001 SKU-003

**Seed 起點：** WAVE-0001 status='picked'，picking_wave_items SKU-003（ORD-0002）申請 2 / 撿 1，shortage 1; backorders 1 row pending

**4 維 ripple：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | wave 撿到的 1 個還沒走 sale movement（要等 transfer ship 才會走 transfer_out）| 此時應 0 筆 sale movement for WAVE-0001 |
| wallet_ledger | wave 不直接動 wallet | — |
| customer_order_items | ORD-0002 SKU-003 對應 line 預期狀態：撿不足要怎麼標？（fixture 沒改 status，需確認業務語意）| `SELECT status, qty FROM customer_order_items coi JOIN customer_orders o ON o.id=coi.order_id WHERE o.order_no='ORD-0002';` |
| store_monthly_settlement | hq_to_store transfer 還沒 generate（wave generate 後才有）| — |
| backorders | 1 row pending、qty_pending=1、original_customer_order_item_id 對 ORD-0002 SKU-003 | `SELECT * FROM backorders WHERE original_customer_order_item_id IN (SELECT coi.id FROM customer_order_items coi JOIN customer_orders o ON o.id=coi.order_id WHERE o.order_no='ORD-0002');` |
| picking_wave_audit_log | 'picked_qty_changed' 含 shortage:1 | `SELECT after_value, note FROM picking_wave_audit_log WHERE wave_id=(SELECT id FROM picking_waves WHERE wave_code='WAVE-0001') AND action='picked_qty_changed';` |

### R9. Wave 整單取消 — WAVE-0002

**Seed 起點：** WAVE-0002 status='cancelled'

**4 維 ripple：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 0（wave 還沒走到 transfer 階段就被取消）| — |
| picking_wave_items | picked_qty=NULL、generated_transfer_id=NULL | — |
| customer_order_items | ORD-0003 SKU-008 不受影響（仍可被另一 wave 撿）| — |
| audit log | 1 筆 'wave_cancelled' | `SELECT after_value FROM picking_wave_audit_log WHERE wave_id=(SELECT id FROM picking_waves WHERE wave_code='WAVE-0002') AND action='wave_cancelled';` |

### Wave reverse（派貨後逆轉，per memory `session_resume_2026-04-26_wave12_cleanup.md`）
- [ ] **驗證：** 已 shipped wave 走逆轉 → transfers cancel + stock 反流
- [ ] **驗證：** 對應 customer_order_items 釋放回 reserved

---

## 驗收門檻

- [ ] G5.1 ~ G5.5 全勾
- [ ] R5 / R9 + wave reverse 4 維 ripple 全驗
- [ ] 既有 3 docs 各跑完
- [ ] 結 `TEST-E2E-T5-wms-shipping-report.md` status: passed

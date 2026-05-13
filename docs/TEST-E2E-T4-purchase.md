# TEST-E2E-T4 — 採購 PR / PO / GR + 應付帳款

**範圍：** PR 自動 / 手動建立、PR 拆 PO、PO 發送、GR 收貨、vendor_bills、vendor_payments、purchase_returns
**對應 master §：** §4 / §5a / §10 (反向)
**對應 fixture seed：** with-pr-po.sql（4 PR + 5 PO + 3 GR + 2 bills + 1 payment + 1 return）
**反向情境：** R1 PR 取消 / R2a PO 取消（無 GR）/ R2b PO 取消（部分 GR）/ R3 GR 來貨不足

---

## 既有 docs

| 文件 | 範圍 | 三色 | 動作 |
|---|---|---|---|
| TEST-pr-manual-creation.md | 手動建 PR + 加列 UI | 🟡 | 跑 |
| TEST-picking-require-po.md | 撿貨需有對應 PO | 🟡 | 跨 T4/T5 |

---

## Gap addendum

### G4.1 PR 多 campaign / 多 supplier 拆 PO
- [ ] **SQL:** 從 1 PR 拆出多 PO（每 supplier 一 PO）
  ```sql
  SELECT pr.pr_no, pr.status, COUNT(DISTINCT poi.po_id) AS po_count
    FROM purchase_requests pr
    JOIN purchase_request_items pri ON pri.pr_id = pr.id
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id
   GROUP BY pr.pr_no, pr.status;
  ```
- [ ] **驗證：** PR-0004 拆 PO-0003 (SUP-JP) + PO-0005 (SUP-LOCAL)

### G4.2 vendor_bills 自動產生
- [ ] **SQL:** GR 確認後應自動產 vendor_bill（or 手動觸發）
- [ ] **驗證：** VB-0001 (PO-0002) amount = subtotal × 1.05 = 1500 × 1.05 = 1575 ✓
- [ ] **驗證：** VB-0002 (PO-0004) amount = 7 × 230 × 1.05 = 1690.5（fixture 1697 略差，需確認 tax 邏輯）

### G4.3 vendor_payment + allocation
- [ ] **SQL:** VP-0001 allocate 給 VB-0001 全額 1575
  ```sql
  SELECT vp.payment_no, vp.amount, vpa.bill_id, vpa.allocated_amount, vb.bill_no
    FROM vendor_payments vp
    JOIN vendor_payment_allocations vpa ON vpa.payment_id = vp.id
    JOIN vendor_bills vb ON vb.id = vpa.bill_id;
  ```
- [ ] **驗證：** VB-0001 status='paid'、paid_amount = amount

### G4.4 Approval thresholds 多級
- [ ] **驗證：** 為 SUP-JP 建 PO 金額 < 10000 → owner approval not required（only > 10000 需要）
- [ ] **驗證：** 為 SUP-LOCAL 建 store-scope PO 金額 < 3000 → hq_manager approval

### G4.5 多供應商 cost 比較（同 SKU 不同 supplier 不同 cost）
- [ ] **UI:** /purchase/requests 編輯時應能看到 supplier_skus 多 supplier cost 比較
- [ ] **SQL:** SKU-001 從 SUP-LOCAL=90 / SUP-JP=85 → 應推薦 JP

---

## 反向情境（4 維 ripple）

### R1. PR cancelled (PR-0003)

**Seed 起點：** PR-0003 status='cancelled', notes='R1: PR 取消（HQ 拒絕）'

**4 維 ripple：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 0 (無動到庫存) | `SELECT * FROM stock_movements WHERE source_doc_type='purchase_request' AND source_doc_id=(SELECT id FROM purchase_requests WHERE pr_no='PR-0003');` |
| wallet_ledger | 不影響 | — |
| customer_order_items | 不影響 | — |
| store_monthly_settlement | 不影響 | — |

**額外：** 不應產 vendor_bill / 不應出現在 inbox

### R2a. PO cancelled (no GR) — PO-0003

**Seed 起點：** PO-0003 status='cancelled', qty_ordered=10, qty_received=0

**4 維 ripple：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 0 | `SELECT * FROM stock_movements WHERE source_doc_type='goods_receipt' AND source_doc_id IN (SELECT id FROM goods_receipts WHERE po_id=(SELECT id FROM purchase_orders WHERE po_no='PO-0003'));` |
| 對應 PR | PR-0004 對應 SKU-001 行的 po_item_id 應 NULL or 釋放回 unallocated | `SELECT pri.po_item_id FROM purchase_request_items pri JOIN purchase_requests pr ON pr.id=pri.pr_id WHERE pr.pr_no='PR-0004' AND pri.sku_id=(SELECT id FROM skus WHERE sku_code='SKU-001');` |
| vendor_bill | 不應產 | `SELECT * FROM vendor_bills WHERE source_id=(SELECT id FROM purchase_orders WHERE po_no='PO-0003');` 應 0 rows |

### R2b. PO cancelled (partial GR) — PO-0004

**Seed 起點：** PO-0004 status='cancelled', qty_ordered=10, qty_received=7（GR-0002 confirmed 7 件）

**4 維 ripple：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 1 筆 purchase_receipt @ WH-HQ qty=7 | `SELECT quantity FROM stock_movements WHERE source_doc_type='goods_receipt' AND source_doc_id=(SELECT id FROM goods_receipts WHERE gr_no='GR-0002');` 應 = 7 |
| vendor_bill | VB-0002 status='pending', amount = 7×230×1.05 ≈ 1690 | `SELECT bill_no, status, amount FROM vendor_bills WHERE bill_no='VB-0002';` |
| 剩 3 件 | 不應出現在後續流程（cancelled 部分被丟棄） | — |

### R3. GR shortage — PO-0005 / GR-0003

**Seed 起點：** PO-0005 status='partially_received', qty_ordered=8, qty_received=5; GR-0003 confirmed for 5

**4 維 ripple：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 1 筆 purchase_receipt @ WH-HQ qty=5 SKU-002 | `SELECT * FROM stock_movements WHERE source_doc_type='goods_receipt' AND source_doc_id=(SELECT id FROM goods_receipts WHERE gr_no='GR-0003');` |
| GR variance_reason | 'R3: 來貨不足 5/8 — 短少 3 件，預期成 backorder' | `SELECT variance_reason FROM goods_receipt_items gri JOIN goods_receipts gr ON gr.id=gri.gr_id WHERE gr.gr_no='GR-0003';` |
| backorders | 應有 1 筆對應短少（未來補貨）| `SELECT * FROM backorders WHERE sku_id=(SELECT id FROM skus WHERE sku_code='SKU-002') AND status='pending';` |
| vendor_bill | 應只 bill 5 件（不是 8）| `SELECT amount FROM vendor_bills vb JOIN vendor_bill_items vbi ON vbi.bill_id=vb.id WHERE vbi.sku_id=(SELECT id FROM skus WHERE sku_code='SKU-002');` |

### Purchase return（PRET-0001）

**Seed 起點：** PRET-0001 confirmed, return SKU-004 1 件

**驗證：**
- [ ] **SQL:** stock_movements 1 筆 return_to_supplier @ WH-HQ qty=-1 SKU-004
- [ ] **SQL:** purchase_return_items.movement_id 對應該 movement
- [ ] **SQL:** WH-HQ stock_balances SKU-004 = 100(open) + 10(GR-0001) - 1(return) = 109

---

## Schema invariant

### PR ↔ Campaigns 雙寫一致性（防 PO 撿貨看不到）

**背景：** `purchase_request_items.source_campaign_id` 必須 ↔ `purchase_request_campaigns` join 表同步、否則 `v_picking_demand_by_po` 對該 PO 算不出 demand、撿貨工作站看不到。

詳見 [TEST-pr-campaigns-invariant.md](TEST-pr-campaigns-invariant.md)。E2E 必跑：

- [ ] **SQL:** `SELECT COUNT(*) FROM fn_check_pr_campaigns_consistency();` expect 0
- [ ] **SQL:** trigger `trg_pri_sync_campaigns` 存在且 enabled
- [ ] **負向：** DELETE 一筆 `purchase_request_campaigns` row 後 UPDATE 對應 `pri.source_campaign_id` → trigger 應補回

---

## 驗收門檻

- [ ] G4.1 ~ G4.5 全勾
- [ ] R1 / R2a / R2b / R3 + purchase_return 4 維 ripple 全驗
- [ ] Schema invariant 3 項全勾
- [ ] 既有 2 docs 各跑完
- [ ] 結 `TEST-E2E-T4-purchase-report.md` status: passed

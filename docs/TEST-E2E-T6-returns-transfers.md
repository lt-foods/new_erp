# TEST-E2E-T6 — 退貨 / 轉貨 / 互助 / 月結算

**範圍：** free transfer 店↔店 / 店→總倉退貨（rpc_create_order_return）/ 互助板 offer/request/claim/reply / 88 折出清 / transfer_settlements / store_monthly_settlements
**對應 master §：** §6a / §6b / §13 / §17 / §18 (反向)
**對應 fixture seed：** with-transfers (6 TF + 1 settlement) + with-mutual-aid (3 req + 4 offer + 3 reply + 3 claim) + with-monthly-settlement (2 SMS draft)
**反向情境：** R6a Transfer 拒收 / R6b 運送破損 / R7 過期 write-off / R11a-d 互助 offer 取消 / R12 互助 received 後退單

---

## 既有 docs

| 文件 | 範圍 | 三色 | 動作 |
|---|---|---|---|
| TEST-rpc-receive-transfer.md | rpc_receive_transfer 收貨 | 🟡 | 跑 |
| TEST-transfer-hq-dispatch.md | HQ 派貨 dispatch | 🟢 | relink |
| TEST-mutual-aid-board.md | 互助板 baseline | 🟢 | relink |

---

## Gap addendum

### G6.1 退貨回總倉必須關聯訂單（per memory）
> Memory `feedback_return_to_hq_requires_order.md`：店→總倉走 `rpc_create_order_return`，限 SKU + qty ≤ 已派量 - 已退量

- [ ] **驗證 RPC 存在：** `SELECT proname FROM pg_proc WHERE proname = 'rpc_create_order_return';`
- [ ] **正面測試：** 對 ORD-0006 已派 SKU-002 ×2 → 退 1 件回 HQ
- [ ] **負面測試：** 退超量（已派 2、退 3）→ RAISE
- [ ] **負面測試：** 退非該訂單的 SKU → RAISE
- [ ] **負面測試：** 跨 tenant → RAISE

> ⚠ **若 RPC 不存在：** 標 RED in INDEX，flag 開新 issue

### G6.2 store → store 自由轉貨
- [ ] **正面：** rpc_create_free_transfer S001 → S002 SKU-001 ×2 → 應建 transfer + transfer_items（draft）
- [ ] **負面：** S001 → HQ → 應 RAISE「店→總倉必須走 order return」（符合 memory）

### G6.3 互助板完整流程
- [ ] **rpc_post_aid_board:** offer 必帶 source_customer_order_id（per fixture R11 demo）
- [ ] **rpc_post_aid_board:** request 不能帶 source_customer_order_id
- [ ] **rpc_post_aid_reply:** 對 active board 留言 OK
- [ ] **rpc_close_aid_board:** active → cancelled / exhausted
- [ ] **rpc_claim_aid:** 認領應自動建 transfer + claim row（fixture AID-OFR-001 已 demo）

### G6.4 88 折出清（aid_clearance_offers）
- [ ] **RPC:** `rpc_post_clearance_offer` / `rpc_claim_clearance` / `rpc_convert_clearance_to_demand`
- [ ] **驗證 discount_rate enum：** CHECK IN (0.88, 0.85, 0.80)
- [ ] **驗證流程：** offer → store_claim or convert_to_demand

### G6.5 transfer_settlements 結算
- [ ] **正面：** rpc_generate_transfer_settlement(month) → draft settlements
- [ ] **驗證：** seed 有 1 筆 draft (TF-0003 對 S002↔S004)
- [ ] **rpc_confirm_transfer_settlement:** draft → confirmed → 應產 vendor_bill

### G6.6 store_monthly_settlements 月結
- [ ] **驗證：** seed 2 筆 draft (SMS-S001=1840 / SMS-S002=450)
- [ ] **計算驗證：**
  ```sql
  SELECT sms.store_id, sms.payable_amount,
         (SELECT SUM(qty_received * unit_cost) FROM store_monthly_settlement_items
           WHERE settlement_id = sms.id) AS calc
    FROM store_monthly_settlements sms;
  ```
  payable_amount 應 = SUM(items.line_amount)

---

## 反向情境（4 維 ripple）

### R6a. Transfer 拒收 — TF-0004

**Seed 起點：** TF-0004 status='cancelled', transfer_type='hq_to_store', source=WH-HQ dest=WH-S005, qty_shipped=8, qty_received=0
**stock_movements:** transfer_out -8 + transfer_reject +8 (reverses out)

**4 維 ripple：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 2 筆 (transfer_out -8 + transfer_reject +8)、reverses 連結對 | `SELECT movement_type, quantity, reverses FROM stock_movements WHERE source_doc_id=(SELECT id FROM transfers WHERE transfer_no='TF-0004');` |
| stock_balances | WH-HQ SKU-007 變化淨 0（出 8 + 反流回 8）| WH-HQ SKU-007 應 = 開帳 100（不變）|
| customer_order_items | 不直接影響（hq_to_store transfer 不直接綁訂單）| — |
| store_monthly_settlement | 不入 SMS（status='cancelled'）| 確認 SMS-S005（如有）不含 TF-0004 |

### R6b. 運送遺失/破損 — TF-0005

**Seed 起點：** TF-0005 status='received', source=WH-HQ dest=WH-S001, qty_shipped=10, qty_received=8 (-2 damage)
**stock_movements:** transfer_out -10 + transfer_in +8 + damage -2 (at HQ)

**4 維 ripple：**

| 維度 | 預期 | 驗證 SQL |
|---|---|---|
| stock_movements | 3 筆（out -10 / in +8 / damage -2 全 @ HQ source）| `SELECT movement_type, quantity, location_id FROM stock_movements WHERE source_doc_id=(SELECT id FROM transfers WHERE transfer_no='TF-0005');` |
| stock_balances | WH-HQ SKU-006: 100(open) - 10 - 2 = 88; WH-S001 SKU-006: 20(open) + 8 = 28 | reconcile per G5.2 |
| store_monthly_settlement | SMS-S001 應入 8 件（不是 10）= 8 × 230 = 1840 ✓ | `SELECT line_amount FROM store_monthly_settlement_items smsi JOIN transfers t ON t.id=smsi.transfer_id WHERE t.transfer_no='TF-0005';` 應 = 1840 |
| 損失 2 件帳上 | HQ 損失需有去處（write-off 或保險）— damage movement 已記、後續會計處理 | — |

### R7. 店家發現過期 (write-off)

**Seed 起點：** （未有專屬 fixture，需透過 master 跑時模擬）

**驗證：**
- [ ] **RPC:** `rpc_register_damage` 在 S001 倉對 SKU-XXX 寫 -X 件 type='damage'
- [ ] **stock_movements:** 1 筆 damage @ S001
- [ ] **stock_balances:** S001 SKU-XXX 對應減
- [ ] **月結算:** 該 stock 已過月結 → 不影響本月 SMS（但需確認 credit memo 邏輯）

### R11a/b/c. 互助 offer 取消（fixture R11 chain）

**Seed 起點：**
- AID-OFR-002 status='cancelled', 無 claim
- AID-OFR-003 status='cancelled', 1 claim (claim 留 audit、無 transfer)
- AID-OFR-004 status='cancelled', 1 claim (TF-AID-002 cancelled, transfer_out + transfer_reject 反流)

**4 維 ripple per scenario：**

| 子情境 | stock_movements | wallet_ledger | customer_order | SMS |
|---|---|---|---|---|
| R11a | 0 | 0 | 不影響（source_order ORD-0001 留原狀）| 0 |
| R11b | 0 | 0 | 不影響（source_order ORD-0004 留原狀）| 0 |
| R11c | 2 (out + reject reverse) | 0 | source_order ORD-0003 留原狀（offer 不消耗 order）| 0 |
| R11d | (取貨後退) customer_return + wallet refund | refund row | items.status='returned' | 看月結時點 |

**驗證 SQL：**
```sql
-- 各 R11 board 的 status + claim
SELECT b.note, b.status, b.qty_remaining, c.id AS claim_id, c.resulting_transfer_id
  FROM mutual_aid_board b
  LEFT JOIN mutual_aid_claims c ON c.board_id = b.id
 WHERE b.note LIKE 'R11%' OR b.note LIKE 'AID-OFR%'
 ORDER BY b.note;

-- R11c stock_movements 反流鏈
SELECT sm.movement_type, sm.quantity, sm.reverses, sm.reason
  FROM stock_movements sm
 WHERE sm.source_doc_id = (SELECT id FROM transfers WHERE transfer_no='TF-AID-002')
 ORDER BY sm.created_at;
```

### R12. 互助 received 後對方退單（**RPC gap**）

**情境：** offer 已 claimed → transfer shipped → **received** → 對面店反悔退單
**既有 RPC `rpc_cancel_aid_order` 對 received 階段 RAISE「不能撤」**

**Workaround 流程：**
- B（受方）建 free transfer B → A 反向 1 件 → ship → A receive
- mutual_aid_board.qty_remaining 需手動 +1 回（因為 RPC 沒覆蓋）or 開新 offer

**驗證：**
- [ ] **RAISE 驗證：**
  ```sql
  -- 找一筆 received 階段的 aid order，跑 rpc_cancel_aid_order → 應 RAISE
  SELECT rpc_cancel_aid_order(?::bigint, '退單', ?::uuid);
  -- expect: ERROR — 已 received 的不能撤
  ```
- [ ] **Workaround 驗證：** 建 reverse free transfer，stock 應對得上

> ⚠ **後續 issue：** 考慮新增 `rpc_return_aid_order` 處理 received 階段退單（含 wallet refund + qty_remaining 還原）

---

## 驗收門檻

- [ ] G6.1 ~ G6.6 全勾
- [ ] R6a / R6b / R7 / R11a/b/c / R12 4 維 ripple 全驗
- [ ] 既有 3 docs 各跑完
- [ ] 結 `TEST-E2E-T6-returns-transfers-report.md` status: passed
- [ ] **若 R12 確認 RPC gap：** 開新 issue「Add rpc_return_aid_order for received-aid cancellation」

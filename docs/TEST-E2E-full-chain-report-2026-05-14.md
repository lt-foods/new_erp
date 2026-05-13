---
title: E2E 完整鏈路測試 — 建商品 → 取貨
status: passed (with 1 critical bug found + fixed in same run)
ran_at: 2026-05-14
verified_by: alex.chen + claude (混合 UI + SQL)
db: anfyoeviuhmzzrhilwtm (dev)
marker: E2E-CHAIN-260514
bug_found: rpc_record_pickup 沒寫 stock_movement (已修)
---

## 🚨 跑完發現的 critical bug + 修復

完整鏈路跑完後、分店倉 stock_balances 沒扣（顧客取了 30 件、帳面還有 30 件）。

**根因：** `rpc_record_pickup` 漏寫 `stock_movements` (type='sale') + 漏回填 `customer_order_items.pickup_movement_id`。

**影響範圍：** 所有歷史取貨。

**修法：** [20260614000030_fix_pickup_stock_movement.sql](../supabase/migrations/20260614000030_fix_pickup_stock_movement.sql)
- 改 `rpc_record_pickup` 每件寫 sale movement
- Backfill 歷史 picked_up + NULL pickup_movement_id 的 items
- 加 `fn_check_pickup_movements_consistency()` 防護
- Migration self-check

**修復後驗證 (本鏈路)：** 4 location 全 0、3 sale movements 補上、3 items 都有 pickup_movement_id。

詳見 [TEST-pickup-stock-invariant.md](TEST-pickup-stock-invariant.md)。

---

# E2E 完整鏈路 — 12 步

**Marker：** 所有資料用 `E2E-CHAIN-260514` 開頭命名、方便事後識別 / cleanup。

**路徑：** 混合 — UI（建商品 / 下單 / 撿貨 / 取貨）+ SQL（campaign / PR / PO / GR / transfer）

---

## 環境

- DB: anfyoeviuhmzzrhilwtm.supabase.co (dev pooler)
- Admin user: cktalex@gmail.com (admin, tenant 00000000-...-001)
- Today (台北): 2026-05-14
- 既有 fixture: 不刪、新測試用 marker 隔離

---

## Steps + Results

### Step 1: 建商品 + SKU + 價格 + supplier_skus（UI）

**目標：** 建一個全新商品「E2E 蜂蜜茶」走 /products UI 入口。

- [ ] 1.1 `/products` 開新增、product_name=`E2E-CHAIN-260514 蜂蜜茶`
- [ ] 1.2 加 1 SKU `E2E-CHAIN-260514-SKU` (variant_name='500ml')
- [ ] 1.3 設售價 (retail) / 分店價 (franchise) / 成本價
- [ ] 1.4 設 supplier_skus (preferred supplier + default_unit_cost)

**驗證 SQL：**
```sql
SELECT p.id, p.product_name, s.id AS sku_id, s.sku_code,
       (SELECT price FROM prices WHERE sku_id=s.id AND scope='retail' LIMIT 1) AS retail,
       (SELECT price FROM prices WHERE sku_id=s.id AND scope='franchise' LIMIT 1) AS franchise
  FROM products p JOIN skus s ON s.product_id = p.id
 WHERE p.product_name LIKE 'E2E-CHAIN-260514%';
```

### Step 2: 建 campaign + 加 SKU（SQL）

**目標：** 建一個 closed 狀態的 campaign 含這個 SKU、avoid open/close flow。

- [ ] 2.1 INSERT group_buy_campaigns + campaign_items
- [ ] 2.2 確認 status='closed', end_at=today

### Step 3: 建 3 張顧客訂單（UI order-entry）

**目標：** 用 /campaigns/order-entry 為 3 家不同店建訂單、共 30 件需求。

- [ ] 3.1 給松山店、會員 M-TEST-002、qty=15
- [ ] 3.2 給萬華店、會員 M-TEST-001、qty=10
- [ ] 3.3 給四號店、會員 M-TEST-003、qty=5

### Step 4: 關團 → 自動建 PR + 驗 trigger

**目標：** rpc_close_campaign 自動觸發、建 close_date PR + sync purchase_request_campaigns（昨天剛修的 trigger）。

- [ ] 4.1 RPC rpc_close_campaign
- [ ] 4.2 PR 建立、含 SKU / qty=30 / source_campaign_id 對
- [ ] 4.3 **驗 trigger：** `purchase_request_campaigns` 自動寫入 ✓
- [ ] 4.4 `fn_check_pr_campaigns_consistency()` = 0 orphans

### Step 5: PR 拆 PO + 發送（SQL）

- [ ] 5.1 rpc_approve_purchase_request (PR → approved)
- [ ] 5.2 rpc_split_pr_to_pos (PR → 1 PO @ supplier)
- [ ] 5.3 PO status → sent

### Step 6: GR 收貨（SQL）

- [ ] 6.1 INSERT GR + GR items qty=30
- [ ] 6.2 Confirm GR → stock_movements +30 @ HQ
- [ ] 6.3 PO status → fully_received
- [ ] 6.4 **驗 view：** v_picking_demand_by_po 顯示該 PO + 3 店需求

### Step 7: 撿貨建 wave + 派 transfer（UI workstation）

- [ ] 7.1 開 /wms/picking 找到該 SKU
- [ ] 7.2 點「自動分配」(松山15 / 萬華10 / 四號5)
- [ ] 7.3 提交 wave → 應建 1 wave + 3 transfers
- [ ] 7.4 stock_movements: -30 @ HQ / +15/+10/+5 各店 (in_transit?)

### Step 8: 分店收貨（SQL）

- [ ] 8.1 對 3 張 transfer 各跑 rpc_receive_transfer
- [ ] 8.2 stock_movements: transfer_in 各店 +qty
- [ ] 8.3 transfers status → received

### Step 9: 顧客取貨（UI /pickup）

- [ ] 9.1 開 /pickup 搜索 M-TEST-002 → 顯示松山店訂單 15 件
- [ ] 9.2 點「確認取貨」（用 wallet 或 cash）
- [ ] 9.3 stock_movements: -15 @ 松山店、wallet_ledger -X (如用 wallet)
- [ ] 9.4 order status → completed
- [ ] 9.5 重複給 M-TEST-001 萬華 / M-TEST-003 四號

### Step 10: 最終 invariants + 報告

- [ ] 10.1 `fn_check_pr_campaigns_consistency()` = 0
- [ ] 10.2 `fn_check_wallet_consistency()` = 0
- [ ] 10.3 stock_balances vs SUM(stock_movements) = 0 mismatch
- [ ] 10.4 該 SKU 全鏈路 stock: HQ 0 / 各店 0 / 顧客取走 30
- [ ] 10.5 該 campaign 訂單 3 張全 status='completed'

---

## 反向情境（可選）

留 1 張訂單不取、模擬：
- expired / cancelled → ripple 反向

---

## Cleanup（可選）

跑完留資料當 audit trail、或：
```sql
-- 刪所有 E2E-CHAIN-260514 marker 資料（按 dependency 順序、適合 dev）
-- ... 詳見 cleanup section（先不寫、看跑完結果再決定）
```

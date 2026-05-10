# TEST-E2E-master — 一日營運循環黃金路徑

> 從候選 → 開團 → 訂單 → 採購 → 撿貨 → 派貨 → 退貨 → 月結 整個串。**半手動**：SQL/RPC 驗資料層 + preview MCP 點 admin UI。

**對應 plan：** `C:\Users\Alex\.claude\plans\q1-c-q2-b-expressive-emerson.md`
**對應 INDEX：** [TEST-INDEX.md](TEST-INDEX.md)
**Sub-docs：** T1-T10 共 8 軌、各自 gap addendum 對應到此 master 對應 § 編號

---

## Prerequisites

### 1. seed
```bash
bash scripts/e2e/reset.sh full-demo --yes
```

跑完應看到 row count summary，預期至少：

| table | count (≥) | 來源 |
|---|---|---|
| locations | 6 | 01-master |
| stores | 5 | 01-master |
| products | 10 | 01-master |
| skus | 10 | 01-master |
| sku_packs | 13 | 01-master（10 base + P004/P008/P010 multi）|
| prices | 40 | 01-master（10 retail + 30 tier）|
| supplier_skus | 15 | 01-master（10 LOCAL + 4 JP + 1 XL）|
| line_channels | 3 | 01-master |
| post_templates | 3 | 01-master |
| purchase_approval_thresholds | 5 | 01-master |
| categories | 17 | 01-master（3 level1 + 9 level2 + 5 level3）|
| members | 4 | 02-base |
| member_cards | 4 | 02-base |
| member_line_bindings | 3 | 02-base |
| customer_line_aliases | 4 | 02-base（3 LC-MAIN + 1 LC-VIP）|
| wallet_balances | 4 | 02-base / with-wallet-history |
| wallet_ledger | 7+ | 02-base 1 topup + with-wallet-history 6 |
| group_buy_campaigns | 10 | with-campaign |
| campaign_items | 16 | with-campaign |
| customer_orders | 8 | with-orders |
| customer_order_items | 14+ | with-orders |
| order_shortage_events | 1 | with-orders R4 |
| order_pickup_events | 2 | with-orders（ORD-0004/0006）|
| customer_order_sources | 3 | with-orders |
| stock_balances | 60 | with-stock 觸發 |
| stock_movements | 60+ | with-stock 開帳 + GR + transfer + R8 |
| picking_waves | 2 | with-picking-wave |
| picking_wave_items | 4 | with-picking-wave |
| picking_wave_audit_log | 7 | with-picking-wave |
| backorders | 1 | with-picking-wave R5 |
| purchase_requests | 4 | with-pr-po |
| purchase_orders | 5 | with-pr-po |
| goods_receipts | 3 | with-pr-po |
| vendor_bills | 2 | with-pr-po |
| vendor_payments | 1 | with-pr-po |
| vendor_payment_allocations | 1 | with-pr-po |
| purchase_returns | 1 | with-pr-po |
| transfers | 8 | with-transfers 6 + with-mutual-aid 2 |
| transfer_items | 10+ | |
| transfer_settlements | 1 | with-transfers |
| transfer_settlement_items | 1 | with-transfers |
| store_monthly_settlements | 2 | with-monthly-settlement |
| store_monthly_settlement_items | 2 | with-monthly-settlement |
| mutual_aid_board | 7 | with-mutual-aid（3 req + 4 offer）|
| mutual_aid_replies | 3 | with-mutual-aid |
| mutual_aid_claims | 3 | with-mutual-aid |

抓的指令：
```sql
SELECT 'locations' AS t, COUNT(*) FROM locations UNION ALL
SELECT 'customer_orders', COUNT(*) FROM customer_orders UNION ALL
SELECT 'wallet_ledger', COUNT(*) FROM wallet_ledger UNION ALL
SELECT 'stock_movements', COUNT(*) FROM stock_movements UNION ALL
SELECT 'transfers', COUNT(*) FROM transfers UNION ALL
SELECT 'mutual_aid_board', COUNT(*) FROM mutual_aid_board
ORDER BY 1;
```

### 2. admin auth user
- `cktalex@gmail.com` 已能登入後台、`raw_app_meta_data.tenant_id` 已設

### 3. preview MCP
- `preview_start` 啟 dev server（apps/admin）
- 之後 § 全用 preview_navigate / preview_click / preview_snapshot

---

## Cast（黃金路徑用既有 seed 資料）

| 角色 | 來源 | 用途 |
|---|---|---|
| HQ 經總倉 | location WH-HQ | 採購收貨、派貨源 |
| S001 平鎮店 | stores S001 | 主受貨點 |
| S002 松山店 | stores S002 | 跨店轉貨 / mutual aid |
| 小明 (M-TEST-001) | members | normal tier、wallet 750 |
| 小華 (M-TEST-002) | members | gold tier、wallet 4500 |
| 小芳 (M-TEST-003) | members | silver tier、wallet 200（有 R10 reversal）|
| SUP-LOCAL | suppliers | 主供應商 |
| 多 SKUs | from with-stock | 庫存已開帳 |

---

## § 1. T1 — 主檔基線驗證

**目標：** 確認 seed 跑完後主檔資料完整、4 欄 audit、自動編號規則對。

### SQL 驗證
- [ ] **products / skus 已建 10 個 + 4 audit 欄位齊：**
  ```sql
  SELECT product_code, name, created_by, created_at, updated_by, updated_at
    FROM products WHERE tenant_id = ?::uuid ORDER BY product_code;
  -- expect: 10 rows, created_at IS NOT NULL
  ```
- [ ] **sku_packs 多規格（P004/P008/P010）：**
  ```sql
  SELECT s.sku_code, sp.unit, sp.qty_in_base, sp.is_default_sale
    FROM sku_packs sp JOIN skus s ON s.id = sp.sku_id
   WHERE s.sku_code IN ('SKU-004','SKU-008','SKU-010') ORDER BY s.sku_code, sp.unit;
  -- expect: SKU-004 個+箱(10), SKU-008 個+盒(10), SKU-010 個+箱(6)
  ```
- [ ] **多供應商分配：**
  ```sql
  SELECT s.sku_code, sup.code AS supplier, ss.is_preferred, ss.default_unit_cost
    FROM supplier_skus ss
    JOIN skus s ON s.id = ss.sku_id
    JOIN suppliers sup ON sup.id = ss.supplier_id
   WHERE s.sku_code IN ('SKU-001','SKU-008') ORDER BY s.sku_code, sup.code;
  -- expect: SKU-001 LOCAL(F)+JP(T), SKU-008 LOCAL(F)+XL(T)
  ```
- [ ] **categories 樹狀（3 層）：**
  ```sql
  SELECT level, COUNT(*) FROM categories GROUP BY 1 ORDER BY 1;
  -- expect: 1=3, 2=9, 3=5
  ```
- [ ] **member_line_bindings 已綁 3 會員（M-TEST-001/2/3）：**
  ```sql
  SELECT m.member_no, mlb.line_user_id, mlb.bound_at IS NOT NULL AS bound
    FROM member_line_bindings mlb JOIN members m ON m.id = mlb.member_id ORDER BY m.member_no;
  ```

### UI 驗證 (preview)
- [ ] `/products` 列表渲染 10 SKU、有圖、有規格選單
- [ ] `/members` 列表 4 會員、tier 顯示對、LINE User ID **已馬賽克**（U***）
- [ ] `/members/M-TEST-002/detail` 錢包 tab 顯示 4500、ledger 流水有 1 筆 +5000

---

## § 2. T2 — 候選 → 開團

**目標：** 從候選週曆推 1 個團（CAMP-MASTER-001）→ finalize → 自動觸發 PR。

### SQL 驗證 baseline
- [ ] 既有 10 campaigns（CAMP-001~010）狀態多元（open/closed/ordered/receiving/ready/completed）

### 操作 + 驗證
- [ ] preview 開 `/community-candidates/calendar`
- [ ] 推一個 candidate → 草稿 campaign **CAMP-MASTER-001**
  - 含 SKU-FRESH-001 (生鮮)、SKU-DRY-001 (乾貨) 兩品
  - end_at = NOW + 3 days
- [ ] preview 開 `/campaigns/CAMP-MASTER-001` → 點 finalize
- [ ] **SQL: campaign_no 規則** `GB{YYYYMMDD}-C{padded6}`
  ```sql
  SELECT campaign_no, status FROM group_buy_campaigns
   WHERE campaign_no LIKE 'GB%-C%' ORDER BY created_at DESC LIMIT 1;
  ```
- [ ] **SQL: campaign_audit_log 寫了 finalize 記錄**

---

## § 3. T3 — 訂單流程（4 子段）

### § 3a — 88折促銷單（小明）
- [ ] preview `/campaigns/order-entry?campaign_no=CAMP-MASTER-001`
- [ ] 為 M-TEST-001 開單 O-MASTER-001
  - SKU-FRESH-001 ×2 + SKU-DRY-001 ×1
  - 套 88 折 promo（unit_price × 0.88）
- [ ] **SQL: 訂單明細 unit_price 對**
  ```sql
  SELECT o.order_no, coi.qty, coi.unit_price, coi.notes
    FROM customer_orders o JOIN customer_order_items coi ON coi.order_id = o.id
   WHERE o.order_no = 'O-MASTER-001';
  ```

### § 3b — wallet pay（小華）
- [ ] 為 M-TEST-002 開單 O-MASTER-002（同 campaign）
  - SKU-FRESH-001 ×3
  - 用 wallet 付款（從 4500 扣 X）
- [ ] **SQL: wallet_ledger spend row + balance 更新**
  ```sql
  SELECT type, change, balance_after, source_type, source_id
    FROM wallet_ledger WHERE member_id = (SELECT id FROM members WHERE member_no = 'M-TEST-002')
   ORDER BY id DESC LIMIT 3;
  ```

### § 3c — cross-member transfer（O-MASTER-001 SKU-DRY → O-MASTER-002）
- [ ] preview 開 `/orders/O-MASTER-001` → 點轉手 → 選 O-MASTER-002
- [ ] **SQL: customer_order_items 拆 + transferred_from / transferred_to FK**

### § 3d — soft-cancel + 負數訂單
- [ ] O-MASTER-001 SKU-FRESH 取消 → 整單轉成負數
- [ ] **SQL: order status='cancelled' + offset order created**
- [ ] **SQL: wallet refund 88 折金額（如有預扣）**

---

## § 4. T4 — 採購 PR → PO → 發送

- [ ] §2 finalize 應自動觸發 PR（驗證 PR-MASTER-001 存在）
- [ ] preview `/purchase/requests/[id]/edit` → 補加 SKU-FRESH +5
- [ ] close PR → split PO（PO-MASTER-001 to SUP-LOCAL）
- [ ] preview 點 send → status='sent'、`sent_at` 寫入
- [ ] **SQL: 確認 GENERATED line_subtotal 對**

---

## § 5. T5 — WMS 收貨 + 撿貨 + 派貨

### § 5a 收 PO
- [ ] preview `/wms/receiving` → 收 PO-MASTER-001 全量 → confirm GR
- [ ] **SQL: stock_movements purchase_receipt + stock_balances 對應 +5**

### § 5b Wave + 撿貨 + 派貨
- [ ] preview `/wms/picking` → 為 CAMP-MASTER-001 + S001/S002 建 wave **WAVE-MASTER-001**
- [ ] 撿貨：S001 撿 SKU-FRESH ×2、S002 撿 SKU-FRESH ×3
- [ ] confirm picked → status='picked'
- [ ] generate transfer → 自動建 hq_to_store transfers（每店 1 張）
- [ ] mark shipped
- [ ] **SQL: stock_movements transfer_out 對 + picking_wave_audit_log 完整**

---

## § 6. T6 — 退貨 / 互助（2 子段）

### § 6a — S002 收 transfer
- [ ] preview S002 視角 `/wms/receiving` → 收 wave 派來的 transfer
- [ ] **SQL: stock_movements transfer_in @ S002 location**

### § 6b — S002 缺 SKU-FRESH → 互助板 → S001 提供 → offset
- [ ] preview `/inventory/mutual-aid` → S002 發 request post（SKU-FRESH ×1）
- [ ] S001 認領 → mutual_aid_claims + transfer 自動建立
- [ ] **SQL: mutual_aid_board.qty_remaining 扣減正確**

---

## § 7. T3 收尾 — pickup + wallet refund
- [ ] preview `/pickup` (S002 視角) → 雙會員取貨
- [ ] O-MASTER-002 部分退費 → wallet refund 補回（rpc_wallet_refund）
- [ ] **SQL: order_pickup_events 寫入 + wallet refund row**

---

## § 8. T7 — HQ 收件匣 unified

- [ ] preview `/hq/inbox` → 切 4 個 tab（pending / in_transit / done / 全部）
- [ ] **SQL: rpc_hq_inbox_keys + rpc_inbox_counts 回傳對**
- [ ] 確認 master 跑出來的：CAMP-MASTER-001 close / PR-MASTER-001 / wave / aid post 都在 inbox 出現

---

## § 9. T10 — 安全 RLS + LINE 馬賽克 + audit

### § 9a RLS 矩陣
- [ ] **HQ admin** 連 `customer_orders`：能讀 8+ 筆
- [ ] **S001 branch user** 連 `customer_orders`：只應讀 home_store=S001 的訂單
  ```sql
  SET LOCAL ROLE authenticated;  -- 模擬 branch user
  -- 加上 jwt claims 模擬 store_id=S001
  ```
- [ ] **anonymous** 連 `customer_orders`：0 rows

### § 9b LINE User ID 馬賽克
- [ ] preview HQ 後台 `/members/M-TEST-001/detail` 顯示完整 LINE User ID（HQ 看得到）
- [ ] preview branch user 視角同頁 → 應顯示 `U***xyz`
- [ ] **SQL: 任何 view 不得回 raw line_user_id 給非 HQ role**
  ```sql
  SELECT proname FROM pg_proc WHERE proname LIKE 'rpc_%' AND prosecdef = TRUE;
  ```

### § 9c audit 4 欄位覆蓋
- [ ] 主檔表（products / customer_orders / transfers / purchase_requests / store_monthly_settlements / wallet_balances）created_by/updated_by/created_at/updated_at 4 欄齊
  ```sql
  SELECT table_name FROM information_schema.columns
   WHERE column_name IN ('created_by','created_at','updated_by','updated_at')
   GROUP BY 1 HAVING COUNT(*) = 4 ORDER BY 1;
  ```
- [ ] wallet_ledger / customer_order_sources / order_pickup_events 是 append-only（trigger `forbid_append_only_mutation` / `forbid_ledger_mutation` 仍掛）
  ```sql
  SELECT tgname FROM pg_trigger WHERE NOT tgisinternal AND tgname LIKE 'trg_no_%';
  ```

---

## 驗收門檻

- [ ] §1-§9 全勾、preview 無 console error
- [ ] `fn_check_wallet_consistency()` 回 0 rows（所有 member 的 ledger 累加 = balance）
- [ ] `apps/admin` `pnpm build` 過、`pnpm typecheck` 過
- [ ] 寫 `TEST-E2E-master-report.md`、status: passed
- [ ] 同步回填 [TEST-INDEX.md](TEST-INDEX.md) 軌道狀態 + 最近驗證日

---

## 反向情境驗證（黃金路徑跑完後另跑）

每個反向情境跑「**從 seeded 終態驗 4 維 ripple 對不對**」：

| § | 反向 | 對應軌 sub-doc | seeded 起點 |
|---|---|---|---|
| §10 R1-R3 採購反向 | T4 | T4-purchase | PR-0003 / PO-0003 / PO-0004 / GR-0002 / GR-0003 |
| §11 R4 訂單缺貨 | T3 | T3-orders-wallet | ORD-0007 + order_shortage_events |
| §12 R5 撿貨不足 | T5 | T5-wms-shipping | WAVE-0001 + backorders |
| §13 R6a/R6b 轉貨 | T6 | T6-returns-transfers | TF-0004 / TF-0005 + stock_movements |
| §14 R8 客退 | T3 | T3-orders-wallet | ORD-0006 + customer_return movement + refund |
| §15 R9 wave 取消 | T5 | T5-wms-shipping | WAVE-0002 |
| §16 R10 wallet reversal | T3 | T3-orders-wallet | M-TEST-003 reversal row |
| §17 R11a/b/c aid 取消 | T6 | T6-returns-transfers | AID-OFR-002/3/4 |
| §18 R12 aid 退單（gap）| T6 | T6-returns-transfers | 走 free transfer 反向 workaround |

各軌 sub-doc 會逐項列 4 維 ripple 驗證 SQL。

---

## 附錄：跑完後同步

依使用者偏好（feedback memory）：
- 更新 GitHub Issues（已完成的關掉、新發現的開）
- 更新 Wiki 模組頁 + Home + Sidebar

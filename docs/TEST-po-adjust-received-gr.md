# po-adjust-received-gr 測試項目 — 編輯頁「已收量修正」補收改建 confirmed GR + backfill

**對應 migration:** `supabase/migrations/20260729000020_po_adjust_received_creates_gr.sql`
**對應 UI 變更:** 無（backend-only；`purchase/orders/edit/page.tsx` 呼叫的 RPC 簽名不變）
**背景:** 派貨工作台 `v_picking_demand_by_po` 的 gr_qty 只認 confirmed GR；編輯頁補收原本不建 GR → 工作台看不到（PO2606260632 案例）

## 1. Schema / Migration 層

### 1.1 RPC signature（不變）
- [ ] `rpc_adjust_po_item_received(BIGINT, NUMERIC, UUID)` 存在、SECURITY DEFINER、grant 給 authenticated
  ```sql
  SELECT proname, prosecdef, pg_get_function_identity_arguments(oid)
    FROM pg_proc WHERE proname = 'rpc_adjust_po_item_received';
  ```
- [ ] 無新增 table / column / index / enum（migration 僅 CREATE OR REPLACE FUNCTION + DO backfill）

### 1.2 Backfill 落地
- [ ] backfill GR 可辨識：`goods_receipts.notes LIKE 'backfill 20260729000020%'`、status='confirmed'、items `variance_reason='backfill_po_item_received_adjust'`、`movement_id IS NULL`

## 2. RPC 行為（SQL 直測）

### 2.1 補收（delta > 0）建 GR
**情境：** sent PO、品項訂購 9 已收 0，adjust 至 5
**預期：** 新 confirmed GR（notes 含「已收量修正補收」）+ 1 筆 gri（qty=5、unit_cost=品項成本、po_item_id 正確）；總倉 on_hand +5；stock_movements 為 `purchase_receipt`/`goods_receipt`（非 manual_adjust）；qty_received=5；PO → partially_received；回傳 jsonb 含 gr_no、changed=true

### 2.2 二次補收累加
**情境：** 承 2.1，再 adjust 5 → 9
**預期：** 第二張 delta GR（qty=4）；該 po_item confirmed GR 加總 = 9；PO 狀態隨總量正確

### 2.3 無變化冪等
**情境：** adjust 9 → 9
**預期：** changed=false、不建 GR、不動庫存

### 2.4 調降（delta < 0）維持舊行為
**情境：** 承 2.2，adjust 9 → 7
**預期：** 不建 GR；stock_movements 一筆 `manual_adjust` −2（source_doc_type='po_item_received_adjust'）；on_hand −2；qty_received=7；GR 加總仍 9（**已知不對稱，記錄非 bug**）

### 2.5 調降超過現有庫存 reject
**情境：** 目的倉 on_hand 低於欲扣量（先把庫存派走/調走再下修）
**預期：** RAISE「調降已收需扣庫存…不足」，資料無變

### 2.6 上下限 reject
- [ ] p_new_qty > 訂購量 → RAISE
- [ ] p_new_qty < 已退+已出 → RAISE
- [ ] p_new_qty 負值 / NULL → RAISE

### 2.7 PO 狀態閘 reject
**情境：** PO 為 draft（或 cancelled/closed）
**預期：** RAISE「僅 已發送/部分到貨/全部到貨 可調整已收量」

### 2.8 fully_received 降級
**情境：** 單品項 PO 全收（fully_received）後 adjust 下修
**預期：** PO 回 partially_received（_refresh_po_status 不降級、靠函式第 7 步）

### 2.9 派貨工作台可見（本次修復的驗收核心）
**情境：** 造一張有開團需求的 PO（pri.po_item_id 連結 + campaign 訂單），走編輯頁 adjust 補收
**預期：** `v_picking_demand_by_po` 該 (po,sku)：gr_qty=補收量、has_stock_left=true、整列出現在矩陣過濾（has_stock_left AND has_demand_left）之下；`rpc_create_wave_from_po` 可對該量建 wave 不被守衛擋

### 2.10 Backfill 補建
**情境：** 模擬舊路徑遺留：po_item qty_received=9、無 GR、stock_movements 有 +9 的 `po_item_received_adjust`
**預期：** backfill 後補出 1 張 confirmed GR qty=9；stock_balances / qty_received / PO 狀態皆不變；movement_id NULL

### 2.11 Backfill 不誤傷
- [ ] 正規收貨（GR 齊全、qty_received = GR 加總）的 po_item：不產生 backfill GR
- [ ] 歷史「GR 收過又下修」（GR 加總 > qty_received）：不產生 backfill GR
- [ ] 混合（GR 10、adjust −3）：缺口為負 → 跳過
- [ ] backfill 量 = LEAST(qty_received − GR 加總, adjust 正淨額)，不多補

## 3. UI 行為（preview 互動）

- [ ] 編輯頁已收 spinner 補收 → 儲存成功、reload 後顯示新值、無 console error（RPC 簽名未變，理論上零改動）
- [ ] 收貨頁 GR 歷史清單出現「已收量修正補收（編輯頁）」的 GR 紀錄
- [ ] 派貨工作台矩陣出現剛補收的品項

## 4. Regression

- [ ] 收貨頁正規收貨（rpc_arrive_and_distribute）流程不變：GR 建立、qty_received 累加、工作台可見
- [ ] avg_cost：補收入庫從 manual_adjust 改為 purchase_receipt，兩者皆走 rpc_inbound 同一加權平均邏輯 → 成本結果不變
- [ ] `rpc_po_items_shipped`（已出衍生欄）不受影響
- [ ] v_pr_progress / PO 列表到貨進度（qty_received 語意未變）
- [ ] 對既有 confirmed GR 的 PO 重跑 migration（冪等性）：backfill 不重複補（缺口已為 0）

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**migration 在本機切片容器跑過**、**prod 套用後以 anon REST 驗 PO2606260632 的 view gr_qty=9/9、工作台出現元寶磁吸收納盒** 才可標 done。

---

## Test Run — 2026-07-29

**執行環境：** 拋棄式 `supabase/postgres:17.6.1.134` 容器 + 依賴切片
（product/member/inventory/purchase/sales/stores_order/inventory_v02/picking_waves
+ 20260428120000 + 20260513000000（前段，review_status 之後與本測無關）
+ 20260430120000 + 20260708000000 + 本次 20260729000020），auth stub。

**結果：SQL 直測 30/30 PASS**

- §1.1 簽名/SECDEF/單一 overload ✔；migration 無新增 schema 物件（inspection）✔
- §1.2 backfill GR 可辨識（notes / variance_reason / movement_id NULL）✔（2.10a/b）
- §2.1 補收建 confirmed GR + purchase_receipt 入庫 + 不再 manual_adjust ✔（2.1a–h）
- §2.2 二次補收累加（兩張 GR 加總=9）✔；§2.3 冪等 changed=false ✔
- §2.4 調降維持 manual_adjust 出庫、不建 GR、GR 加總不變（已知不對稱，記錄）✔
- §2.5 調降超庫存 RAISE ✔；§2.6 上下限/負值 RAISE ✔；§2.7 draft PO RAISE ✔
- §2.8 fully_received ↔ partially_received 升降級 ✔
- §2.10 backfill：補 1 張 confirmed GR qty=9、庫存/qty_received/PO 狀態全未動 ✔
- §2.11 不誤傷：GR>received（歷史下修）、adjust 淨額≤0 者皆跳過 ✔
- §4 重跑冪等：第三次套用補 0 筆、仍恰 1 張 backfill GR ✔
- §2.9（view 可見性）⏸ 本機切片無 view 依賴鏈 → prod 套用後以 anon REST 驗
  `v_picking_demand_by_po` PO2606260632 gr_qty=9/9、has_stock_left=true
- §3 UI ⏸ backend-only、RPC 簽名未變 → 留使用者 preview 自審
- §4 收貨頁/avg_cost/rpc_po_items_shipped：本 migration 未觸碰該些函式（inspection）✔
- build/type-check：無前端變更，不適用

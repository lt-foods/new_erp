# 撿貨工作站：要求 PR + PO 已建立才出現

**對應 migration:** `supabase/migrations/20260512000000_picking_demand_view_require_po.sql`（待建）
**對應 view:** `v_picking_demand_by_close_date`
**對應 UI:** `apps/admin/src/app/(protected)/picking/workstation/page.tsx`（無變更，靠 view 過濾）

**需求脈絡（決策來自 2026-04-28 對話）：**
- 撿貨工作站目前只要 customer_orders 存在就出現 SKU，操作者會誤以為「商品到了可以撿」。
- 但實際上 PR / PO 還沒建好之前，貨根本沒下單給供應商，撿貨毫無意義。
- 必須先走完 close → PR → 拆 PO 的採購流程，撿貨清單才該看到該 SKU。

**核心規則：**
- (close_date, sku_id) 在 `purchase_request_items` 找得到對應 row、且 `po_item_id IS NOT NULL`、且 PR.status ≠ 'cancelled' → 才出現於 `v_picking_demand_by_close_date`。
- 否則該 SKU 在撿貨工作站完全消失（連 close_date dropdown 都不會列出）。

---

## 1. Schema / View 層

### 1.1 view 重建
- [ ] `v_picking_demand_by_close_date` 仍存在；GRANT SELECT TO authenticated
- [ ] view comment 更新為「限定已 PR + PO 拆單的 SKU 才出現」
- [ ] columns 不變：tenant_id, close_date, sku_id, sku_label, sku_code, store_id, store_code, store_name, demand_qty, order_count, campaign_ids, received_qty, po_numbers, order_numbers
- [ ] WHERE 多 EXISTS 子句：`purchase_request_items` × `purchase_requests` 配對且 `po_item_id IS NOT NULL`、`pr.status NOT IN ('cancelled')`

### 1.2 SQL 自我驗證
```sql
-- 應該只看到 PR + PO 都建好的 (close_date, sku_id)
SELECT close_date, sku_id, sku_label, sku_code, demand_qty
  FROM v_picking_demand_by_close_date
 ORDER BY close_date DESC, sku_id;

-- 對照：原本 customer_order_items 應該有更多 (close_date, sku_id) 對
SELECT DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') AS close_date, coi.sku_id
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  JOIN group_buy_campaigns gbc ON gbc.id = co.campaign_id
 WHERE gbc.status NOT IN ('cancelled')
   AND co.status NOT IN ('cancelled','expired','transferred_out')
   AND coi.status NOT IN ('cancelled','expired')
 GROUP BY DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei'), coi.sku_id;
-- 兩者差集 = 還沒 PR + PO 的 (close_date, sku_id)
```

---

## 2. 行為情境

### 2.1 close_date 有訂單但無 PR
- [ ] 結單後尚未呼叫 rpc_close_campaign / rpc_create_pr_from_close_date
- [ ] 撿貨工作站 close_date dropdown：**不出現** 該日期
- [ ] view 直接 query：該 (close_date, sku_id) **不出現** 任何 row

### 2.2 close_date 有 PR 但 PR.status = draft（尚未拆 PO）
- [ ] PR 已建（rpc_create_pr_from_close_date 跑完）但所有 `purchase_request_items.po_item_id` 都是 NULL
- [ ] 撿貨工作站：**不出現** 該結單日的任何 SKU
- [ ] 推論：撿貨清單必須等到拆 PO 後才有

### 2.3 close_date 有 PR 且部分 SKU 已拆 PO
- [ ] PR 中 5 個 SKU，3 個已拆進 PO（`po_item_id IS NOT NULL`），2 個還沒
- [ ] 撿貨工作站：**只出現** 那 3 個已拆 PO 的 SKU
- [ ] 還沒拆 PO 的 2 個 SKU：**不出現**

### 2.4 PR 已 cancelled
- [ ] 該 close_date 唯一一筆 PR 被 cancelled（即使 po_item_id 已設）
- [ ] 撿貨工作站：**不出現** 該結單日（因為 EXISTS 排除 cancelled PR）

### 2.5 已進貨完成（happy path）
- [ ] PR + PO 都建好，goods_receipts 也 confirmed
- [ ] 撿貨工作站：**正常出現**，`received_qty` > 0、`po_numbers` 有值

### 2.6 已建 PO 但還沒進貨
- [ ] PR + PO 建好但 goods_receipts 還沒收
- [ ] 撿貨工作站：**正常出現**（出現但 `received_qty = 0`、缺貨警示） — 這是預期行為，操作者要決定要不要先預撿

---

## 3. 回歸（Regression）

### 3.1 既有撿貨單 (picking_waves) 不受影響
- [ ] 已建立的 picking_waves 仍可在歷史頁查看
- [ ] picking_wave_items.sku_id 即便對應的 (close_date, sku_id) 已從 view 消失，wave 自身仍正常顯示

### 3.2 派貨 / 進貨流程獨立
- [ ] arrive 頁（goods_receipts）跟此 view 無關，行為不變
- [ ] transfer / dispatch 流程不受影響

### 3.3 排除規則疊加
- [ ] customer_order.status='transferred_out' 仍排除（既有規則）
- [ ] gbc.status='cancelled' 仍排除（既有規則）
- [ ] coi.status IN ('cancelled','expired') 仍排除（既有規則）

### 3.4 close_date dropdown
- [ ] 前端 page.tsx line 60-93 從 view 拉 distinct close_date → 自動只顯示有 PR + PO 的日期
- [ ] 若該租戶完全沒有 PR + PO → dropdown 為空，下拉只剩「— 選 —」

---

## 4. 效能

### 4.1 EXISTS 子查詢成本
- [ ] EXPLAIN ANALYZE：EXISTS 走 (pr.tenant_id, pr.source_close_date) + (pri.pr_id, pri.sku_id) 應有 index
- [ ] 若 row 數大（10 萬筆 customer_order_items）→ 整體查詢時間應仍 < 500ms（撿貨工作站可接受）

---

## 5. 操作者體驗（Manual UI 驗收）

### 5.1 沒走完採購流程的清單
- [ ] 開兩個 campaign：A 已 close 並建 PR + PO；B 已 close 但 PR 還沒拆 PO
- [ ] 撿貨工作站：**只看到** A 的 SKU；B 的完全不在
- [ ] 換結單日：B 的 close_date 應**不在** dropdown 列表

### 5.2 文字敘述
- [ ] 上方說明仍是「選結單日 → 從左側商品卡加入到右側大表 → 建立撿貨單」
- [ ] 不在這個 fix 範疇加任何「請先建立 PO」之類的提示文字（避免 over-engineer）

---
title: TEST — 派貨工作台「已撿」/「可分配」與 RPC 守衛對齊
module: WMS / Picking workstation
status: pending
ran_at:
verified_by:
---

# 派貨工作台「已撿」/「可分配」與 RPC 守衛對齊

## 背景

使用者截圖回報「派貨工作台 數量怪怪的」：

- G00123-02：UI 顯示 已到 15 / **已撿 3 / 可分配 7**（合計擬分 5）
- 按「建立撿貨單」失敗：「PO2605250317: SKU『G00123-02 包子媽生鮮小舖 A-王董』分配 5 超過可分配量 0.000（**進貨 10.000、已撿 10.000**）」

UI 算的 totalAlreadyWave = 3，但 RPC 守衛 `SUM(picking_wave_items.qty)` per (po, sku) = 10、差距 7。

## 根因

`v_picking_demand_by_po` 的 wave_qty 算法：

```sql
LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id
                     AND wq.sku_id = ps.sku_id
                     AND wq.store_id = sd.store_id   -- ← 強制對齊 store_demand 的 store
```

若 `picking_wave_items` 撿給某 store，但對應的 `customer_orders` 後來 cancel / transferred_out
→ store_demand 不含該 store → view 不會吐這筆 wave_qty。

FE `apps/admin/src/app/(protected)/wms/picking/page.tsx` 從 row 加總 `wave_qty` 算 `totalAlreadyWave`：
- 偏低 → `totalAvailable = totalGr - totalAlreadyWave` 偏高 → UI「可分配」誤報
- FIFO 切貨切到「FE 認為還有空但實際滿了」的 PO → RPC 守衛擋下、報「進貨 X、已撿 X、可分配 0」

`apps/admin/src/app/(protected)/picking/print-pick-list/page.tsx` 同樣模式、同樣偏低。

## 修法

| 改動 | 檔案 |
|---|---|
| view 加欄位 `po_sku_already_wave`（per po_id+sku_id 跨 store 加總 `picking_wave_items`，**不依 sd.store_id**） | `supabase/migrations/20260701000010_v_picking_demand_fix_already_wave.sql` |
| `wms/picking/page.tsx`：`DemandRow` 加 `po_sku_already_wave`；`skuRows` useMemo 用該欄位設 `already_wave_for_sku`、不再 `+= r.wave_qty` | `apps/admin/src/app/(protected)/wms/picking/page.tsx` |
| `print-pick-list/page.tsx`：同上 | `apps/admin/src/app/(protected)/picking/print-pick-list/page.tsx` |

`wave_qty`（per store）欄位保留不動 — by_store 視角 + 「店欄位 small 字」仍用它顯示。

## 驗證

### A. 復現孤兒 wave（SQL）

找實際出問題的 PO×SKU：

```sql
WITH pwi_sum AS (
  SELECT pw.source_po_id AS po_id, pwi.sku_id, SUM(pwi.qty) AS pwi_total
  FROM picking_wave_items pwi
  JOIN picking_waves pw ON pw.id = pwi.wave_id
  WHERE pw.status <> 'cancelled' AND pw.source_po_id IS NOT NULL
  GROUP BY pw.source_po_id, pwi.sku_id
),
view_sum AS (
  SELECT po_id, sku_id, SUM(wave_qty) AS view_total
  FROM v_picking_demand_by_po
  GROUP BY po_id, sku_id
)
SELECT p.po_id, p.sku_id, p.pwi_total, COALESCE(v.view_total,0) AS view_total,
       p.pwi_total - COALESCE(v.view_total,0) AS missing
FROM pwi_sum p
LEFT JOIN view_sum v ON v.po_id = p.po_id AND v.sku_id = p.sku_id
WHERE p.pwi_total <> COALESCE(v.view_total, 0)
ORDER BY missing DESC;
```

修法前：截圖 PO 應該至少出現一筆 `missing > 0`（孤兒 wave）。

### B. 修補後對齊（SQL）

```sql
SELECT
  po_id, sku_id,
  MAX(po_sku_already_wave) AS already_wave_new_column,  -- per (po, sku) 常數
  SUM(wave_qty) AS wave_qty_sum_per_store               -- 可能偏低
FROM v_picking_demand_by_po
WHERE po_id IN (<截圖 PO 們>) GROUP BY po_id, sku_id;
```

`already_wave_new_column` 應該 = `SUM(picking_wave_items.qty)` per (po, sku) — 不受孤兒 wave 影響。

### C. UI 驗收（admin 派貨工作台）

進 `/wms/picking`：

- [ ] G00123-02（或目前出問題的 SKU）「已撿」欄顯示 = SUM(pwi) per (sku)、跨多 PO 加總（如截圖案例：應為 ≥10）
- [ ] 「可分配」 = totalGr - totalAlreadyWave - 已分配。修補後若 PO_A 已滿，可分配只算另一張 PO 剩下的量
- [ ] 分配 < 可分配後按「建立撿貨單」**不再爆**「分配 X 超過可分配量 0」
- [ ] 分配 = 可分配時可成功建立撿貨單
- [ ] 「跨 2 張 PO」tooltip 顯示每張 PO 的「撿」 = per (po, sku) 真值（從 view 新欄位）

### D. UI 驗收（撿貨清單列印）

進 `/picking/print-pick-list`：

- [ ] 已撿總量同 admin 派貨工作台、與 SUM(pwi) per (sku) 對齊

### E. Regression — RPC 守衛仍能擋過量分配

- [ ] 故意把某 SKU 分配 > 可分配 → 仍報錯（中文 message 不變）

## Rollback

```sql
-- view 回 20260614000010 版本（drop 新欄位 po_sku_already_wave）
-- FE 改檔 revert
```

注意：rollback 後 bug 復現、UI 數字繼續對不上。

---
title: TEST — 派貨工作台：已派量納入補貨直派 + 需求派完自動下架
module: WMS / Picking workstation
status: verified (SQL on live)
ran_at: 2026-07-13
verified_by: Claude (session)
---

# 派貨工作台：已派量納入補貨直派 + 需求派完自動下架

## 背景

使用者截圖回報（PO2607070725 / PO2607070726，品項掛 📦補貨標籤）：

> 已經派貨跟收貨 但是工作台一直顯示

線上還原事實鏈（RR-51 / RR-53，龍潭店，各 SKU 申請 1 件）：

1. 補貨申請 → PR#81/#82 → PO#409/#410。採購時數量加碼囤總倉
   （PR 訂 51 / 101 / 11 / 21 … 全部尾數 1 = 補貨 1 件 + 整數囤貨量）。
2. PO 全數到貨（fully_received）。
3. 07-13 03:13–03:40：使用者在派貨工作台對龍潭店連建 **7 輪 1 件的 wave**
   （因為「需 1」一直掛著、列一直不消失）。
4. 07-13 03:41：又走收件匣「派貨」→ `rpc_ship_restock_pr_received` 建直派
   transfer TR2607130188/0189（各 SKU 1 件）→ 門市收貨 → RR 變 `received`。
5. 工作台矩陣**仍然顯示**這些品項，可分配 44 / 94 / 4 / 14。
   同一筆 1 件的補貨，實際出了 8–9 次貨。

## 根因（兩個）

1. **補貨直派沒被算進「已派」**：`v_picking_demand_by_po` 的 per-store
   `wave_qty` 有算 `rr.linked_transfer_id` 直派分支（20260611000020），但
   per (po,sku) 的 `po_sku_already_wave` 與 `rpc_create_wave_from_po` 第 4 步
   守衛都只算 `picking_wave_items` → 「可分配」比總倉真實庫存多
   （G00100-01：view 說可分配 4、總倉 on_hand 只有 3）→ 有超派風險。
2. **矩陣顯示條件純庫存驅動**：`has_stock_left = gr > 已撿`，且格子「需 N」
   顯示原始 `demand_qty`、不扣已派量。補貨帶囤貨的 PO 永遠 gr > 已撿 →
   列永遠不消失、「需 1」永遠掛著 → 邀請使用者重複派貨。

## 修法

| 改動 | 檔案 |
|---|---|
| view `po_sku_already_wave` 加 UNION 分支（補貨直派 transfer，與 per-store wave_qty 第二分支同構）；尾端新增 `has_demand_left`（逐店 GREATEST(0, demand−wave) 加總 > 0） | `supabase/migrations/20260715000010_picking_dispatched_includes_direct_transfer_and_demand_left.sql` |
| `rpc_create_wave_from_po` 第 4 步守衛 already_wave 同步加直派量（view / RPC 對齊原則見 docs/TEST-picking-already-wave-fix.md） | 同上 |
| 矩陣視角 fetch 疊 `.eq("has_demand_left", true)`；格子「需」改顯示未派需求（demand−wave，派完顯示 ✓ 已派）；「⚖ 平均」cap 改未派需求；預設分配改 max(0, demand−wave)（shipped 是 wave 子集合、不再重複扣）；「已撿」欄改名「已派」 | `apps/admin/src/app/(protected)/wms/picking/page.tsx` |
| 列印撿貨清單：加 `demandLeft` 過濾（與矩陣同語意）、「已撿」欄改名「已派」 | `apps/admin/src/app/(protected)/picking/print-pick-list/page.tsx` |

## 驗證（線上 SQL，2026-07-13）

### A. 回報的 PO：已派補上直派量、需求派完 → 下架

```sql
SELECT po_no, sku_code, gr_qty, po_sku_already_wave, has_stock_left, has_demand_left
FROM v_picking_demand_by_po
WHERE po_id IN (409,410)
GROUP BY 1,2,3,4,5,6;
```

結果：8 個 SKU 全部 `po_sku_already_wave` +1（例 F00005-01：7→8，
可分配 44→43 = 總倉 on_hand），全部 `has_demand_left = false`
→ 矩陣、列印清單都不再顯示。✅

### B. 矩陣只剩真正待派的品項

```sql
SELECT COUNT(DISTINCT (po_id, sku_id)) FROM v_picking_demand_by_po
WHERE has_stock_left AND has_demand_left;
```

40 →（套 demand filter 後）**8** 個 (PO×SKU)，逐筆抽查全部
demand_sum > wave_sum 且有庫存 — 沒有誤藏。✅

### C. RPC 守衛已納入直派

```sql
SELECT pg_get_functiondef('public.rpc_create_wave_from_po(bigint,date,jsonb,uuid)'::regprocedure)
       LIKE '%linked_transfer_id%';  -- true ✅
```

## 已知殘留（follow-up，不在本修範圍）

- **收件匣直派路徑不知道 wave 已派過**：`rpc_ship_restock_pr_received` 照
  restock lines 全量建 transfer，不扣已透過工作台 wave 派出的量。工作台這頭
  修好後（派完就下架），反向的重複派貨入口只剩收件匣「派貨」鈕 — 該 RPC
  應改成只派「申請量 − 已 wave 量」或全派完時直接擋下。
- 「依分店（檢視）」分頁維持完整清單（含已派完的列，有 已撿/已派 進度欄），
  未套 demand filter — 屬檢視性質，保留全貌。

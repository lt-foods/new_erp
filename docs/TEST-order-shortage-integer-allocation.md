# TEST — v_order_shortage 短缺分攤改整數貪婪分配

> Migration：`20260807000050_v_order_shortage_integer_allocation.sql`
> 基底：`20260807000000_same_store_transfer_before_arrival.sql` 第 5 節（= 線上現行定義）
> 動機：總倉收件匣「異常 → 訂單短少」的 實際/差額 出現 0.14、-0.86 等小數，
> 操作人員無法解讀；且全網每張 pending 單都被比例攤到一點短缺而列成異常（585 張，多為噪音）。

## 模型摘要

```
SKU 短缺判定：完全不動（採購定案閘門 + stockout_at 閘 + 同店衍生單需求）
末端展開（唯一改動）：
  舊：ROUND(qty × shortage / total_demand, 2) 攤給所有 pending 品項 → 小數
  新：同 SKU 依下單時間「新 → 舊」貪婪整數分配（FIFO：先下單先取得貨）
      每列 = LEAST(order_qty, CEIL(sku_shortage_qty) − 比自己晚下單的量)
      分不到短缺的列（較早下單、供給蓋得住）不再列出
  另：展開排除 qty <= 0 的抵減品項（仍計入淨需求，只是不作為短缺訂單列出）
```

## 驗證項目

### A. 整數性與守恆
- [x] **A.1** view 全表 `demand_unfulfillable = FLOOR(demand_unfulfillable)`（無小數列）
      （prod 部署前 dry-run 2026-08-07：舊 646/653 列含小數 → 新 0/111 列）
- [x] **A.2** 每顆 SKU 的 `SUM(demand_unfulfillable) = CEIL(sku_shortage_qty)`
      （prod dry-run：32 SKU 全數一致，0 筆 mismatch）
- [x] **A.3** SKU 短缺判定不受影響：新舊版列出的 SKU 集合相同（32 = 32）

### B. 分配方向（FIFO：短缺落在最晚下單的訂單）
- [x] **B.1** 同 SKU 內，列出的訂單為 `created_at` 最新的那幾張；更早的單不列
- [ ] **B.2** 邊界列（吸收剩餘短缺的最後一張單）分到的量 < order_qty 時，
      值 = CEIL(shortage) − 更晚訂單量總和（部分短缺）
- [ ] **B.3** 訂 N 件的單最多分到 N（`LEAST(order_qty, …)` 封頂）

### C. 下游相容（欄位同名同序同型別）
- [x] **C.1** `v_hq_exceptions` / `rpc_hq_exceptions`（異常頁）：預期/實際/差額全為整數；
      customer_shortage 列數 585 → 94（= 真正承擔短缺的訂單數）
- [x] **C.2** `rpc_hq_shortage_orders`（收件匣訂單短少分頁）免改可跑，
      `short_items[].demand_unfulfillable`、`total_unfulfillable` 為整數
- [x] **C.3** `v_hq_inbox` shortage 計數照常（DISTINCT order_id，隨列數收斂）
- [ ] **C.4** 前端 `/hq/inbox` 訂單短少卡片顯示「缺 N（M 項）」為整數

### D. 邊界
- [ ] **D.1** 抵減單（offset、qty<0）不出現在短缺清單，但淨需求仍含其負量
- [ ] **D.2** SKU 短缺量若為小數（理論值）→ CEIL 保守取整（缺 0.4 → 顯示缺 1）
- [ ] **D.3** 短缺解除（收貨/到貨）後，被列的訂單自動離開清單（判定層未動，行為同前）

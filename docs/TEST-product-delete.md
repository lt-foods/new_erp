# 測試項目 — 刪除商品（軟刪除 → 停產）

**對應 migration:** `supabase/migrations/20260618000010_rpc_delete_product.sql`
**對應 UI 變更:** `apps/admin/src/app/(protected)/products/page.tsx`

> 設計決策：products / skus 有 `forbid_sku_delete` trigger（`BEFORE DELETE` 一律 raise）且被
> campaign_items / customer_order_items / prices / barcodes 等 10+ 表 FK 參照，**實體刪除不可行**。
> 沿用既有 `rpc_delete_sku` 慣例 → 「刪除商品」= 軟刪除：product + 其所有 sku 設 `status='discontinued'`。
> SKU active→非active 會觸發 `_cleanup_sku_from_draft_campaigns`（自動把該 SKU 從草稿開團移除）。
> 已開團 / 已下訂的歷史不受影響。
>
> **守門（2026-06-18 使用者要求）：**
> 1. 商品「上架中」(`status='active'`) **不可刪除** — 列表鈕隱藏 + RPC raise。
> 2. 商品只要有**任何顧客訂單**（`customer_order_items` 參照其 sku）**不可刪除** — RPC raise。

## 1. RPC 層

### 1.1 函式存在且權限正確
- [ ] `rpc_delete_product(BIGINT)` 存在、`SECURITY DEFINER`
- [ ] `authenticated` 有 EXECUTE、PUBLIC 無

```sql
SELECT proname, prosecdef FROM pg_proc WHERE proname = 'rpc_delete_product';
SELECT has_function_privilege('authenticated','public.rpc_delete_product(bigint)','EXECUTE');
```

### 1.2 正常流程：軟刪除（非上架、無訂單）
- [ ] 對一個 `inactive`（下架）且**無訂單**的商品（含 2 個 sku）呼叫 → 回傳 void、不報錯
- [ ] 商品 `status` 變 `discontinued`，`updated_by` = 呼叫者
- [ ] 該商品所有 sku `status` 全變 `discontinued`
- [ ] `product_audit_log` 新增一筆 `action='delete'`，`before_value`/`after_value` 有值
- [ ] `draft` 商品、`discontinued` 商品（再刪一次，冪等）同樣可呼叫不報錯

### 1.2b 守門：上架中不可刪
- [ ] 對 `status='active'` 商品呼叫 → RAISE `product % is active, cannot delete`
- [ ] 商品狀態 / sku 狀態 / audit log **完全不變**

### 1.2c 守門：有訂單不可刪
- [ ] 商品某 sku 已存在於 `customer_order_items` → 呼叫 RAISE `product % has orders, cannot delete`
- [ ] 即使商品已是 `inactive`/`draft`，只要有訂單仍被擋
- [ ] 商品 / sku / audit **完全不變**

### 1.3 草稿開團連動
- [ ] 商品的某 sku 原本掛在一個 `draft` 開團的 `campaign_items` → 刪除商品後該 `campaign_items` 被自動移除
- [ ] 該 sku 若掛在 `open`/`closed` 開團 → `campaign_items` **保留**（不破壞已開團）

### 1.4 邊界 / 錯誤情境
- [ ] 不存在的 id → RAISE `product % not found`（前端顯示中文）
- [ ] 跨 tenant 的 id → 視為找不到，RAISE，不可動到別 tenant 資料
- [ ] 呼叫後該商品 FK 參照（prices / barcodes / campaign_items(open)）**完全不變**（純軟刪、無實體 DELETE）

## 2. UI 層（商品列表頁）

### 2.1 刪除鈕（僅非上架列顯示）
- [ ] `active`（上架）列：**不顯示**「刪除」鈕（只有「編輯」）
- [ ] `draft` / `inactive` / `discontinued` 列：「編輯」旁顯示紅色「刪除」鈕
- [ ] 點擊跳 `window.confirm`，文案說明「上架中或已有訂單無法刪除；將把商品與規格停產並從草稿開團移除」
- [ ] 取消 confirm → 不執行、無 side effect
- [ ] 確認（無訂單）→ 呼叫 `rpc_delete_product`，成功後列表自動 reload，該商品顯示「停產」badge
- [ ] 確認（有訂單）→ RPC 擋下，`translateRpcError` 顯示「此商品已有顧客訂單，無法刪除。」
- [ ] RPC 失敗 → 錯誤經 `translateRpcError` 顯示中文（非 `[object Object]`）
- [ ] 刪除進行中鈕呈 spinner（純轉圈、無文字 — 依 loading 慣例）

### 2.2 回歸
- [ ] 「編輯」「開團」「批次上架/下架」「清除選取」皆不受影響
- [ ] 將 active 商品「批次下架」後，該列即出現「刪除」鈕（狀態驅動）
- [ ] 狀態篩選選「停產」可篩出被刪除的商品（資料仍在、可追溯）

## 3. 驗證方式
- RPC：上述 SQL 於 Supabase Studio 實跑（auto 模式 agent 無法 push，SQL 交使用者執行）
- UI：`tsc --noEmit` + `next build` 綠；preview 互動由使用者自審（沙箱阻擋登入）

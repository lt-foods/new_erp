# 分店退訂單 (Order Return to HQ) 測試項目

**對應 migration:**
- `20260610000010_rpc_create_order_return.sql` — `rpc_create_order_return(p_order_id, p_lines, p_reason, p_operator)`

**對應 UI 變更:**
- `apps/admin/src/components/FreeTransferCreateForm.tsx` — dest 排除總倉
- `apps/admin/src/components/OrderReturnCreateModal.tsx` — 新增退訂單 modal
- `apps/admin/src/app/(protected)/wms/transfers/page.tsx` — 加 `+ 退訂單` 按鈕

**對應 memory:** `feedback_return_to_hq_requires_order.md`

---

## 1. Schema / RPC 層

### 1.1 RPC 簽名 / 權限
- [ ] `rpc_create_order_return(p_order_id BIGINT, p_lines JSONB, p_reason TEXT, p_operator UUID)` 存在
- [ ] LANGUAGE plpgsql SECURITY DEFINER, search_path=public
- [ ] GRANT EXECUTE TO authenticated
- [ ] 回傳 `JSONB { return_transfer_id, lines: [{sku_id, qty, out_movement_id}] }`

### 1.2 訂單狀態驗證
- [ ] 訂單 status ∈ {shipping, ready, partially_completed, completed} → 允許
- [ ] 訂單 status ∈ {pending, confirmed, cancelled, transferred_out, expired} → RAISE
- [ ] 訂單不存在 → RAISE `order % not found`

### 1.3 SKU / 數量驗證
- [ ] 退的 SKU 必須在 `customer_order_items WHERE order_id = X AND status NOT IN ('cancelled','expired')` 中
- [ ] 退的 SKU 不在訂單清單 → RAISE `sku % is not in order %`
- [ ] 退量 > (訂單量 - already_returned) → RAISE `qty % exceeds returnable %`
- [ ] 退量 ≤ 0 → RAISE
- [ ] p_lines 為空 → RAISE `lines must not be empty`
- [ ] 店端庫存不足 → 由 `rpc_outbound` 擋下（`Insufficient stock`），整個 transaction rollback

### 1.4 重複退驗證
- [ ] 同一訂單建多張退貨單，已退量正確累加（前一張 return_to_hq transfer 的 qty_shipped 算進已退）
- [ ] 全部退完後再呼叫 → RAISE

### 1.5 Tenant 隔離
- [ ] 跨 tenant 訂單 → RAISE `order % not in tenant`
- [ ] 跨 tenant SKU（理論上不會發生）

### 1.6 Transfer / movement 副作用
- [ ] 建出 1 張 transfer 紀錄：`transfer_type='return_to_hq'`, `status='shipped'`, `customer_order_id=p_order_id`, source=店 location, dest=HQ location
- [ ] transfer_no 格式正確（用 `_next_transfer_no()`）
- [ ] 每行建 1 筆 transfer_items（`qty_requested = qty_shipped = p_qty`, `out_movement_id` 已填）
- [ ] 每行寫 1 筆 stock_movements（`movement_type='customer_return'`, `quantity = -qty`, location=店, source_doc_type='transfer'）
- [ ] 店端 stock_balances.on_hand 正確扣減
- [ ] 總倉 stock_balances 不變（要等 HQ 收貨才入帳）

### 1.7 稽核欄位
- [ ] transfers.created_by / updated_by = p_operator
- [ ] transfer_items.created_by / updated_by = p_operator
- [ ] notes 包含 reason（如有給）

---

## 2. UI 層

### 2.1 自由轉貨 modal — dest 排除總倉
- [ ] `/wms/transfers` 點 `+ 建自由轉貨`
- [ ] 來源選任一店 → 目的下拉**不出現「總倉」選項**（central_warehouse type）
- [ ] 來源選總倉 → 目的可選任何店（總倉 → 店仍允許走自由轉貨？看設計，建議也禁，自由轉貨僅店↔店）
- [ ] 直接 hit `/transfers/free` deep link 同樣排除總倉

### 2.2 退訂單 modal — 入口 + 訂單選擇
- [ ] `/wms/transfers` 出現新按鈕 `+ 退訂單`（藍色或橘色，明顯區分自由轉貨）
- [ ] 點開後 modal 標題「↩ 退訂單回總倉」
- [ ] 選店：dropdown 只列 store 類型 location
- [ ] 選店後 → 該店「可退訂單」清單載入（status ∈ {ready/shipping/partially_completed/completed} + pickup_store_id = 該店）
- [ ] 訂單選單顯示 order_no / 客戶 nickname / status / 派貨日

### 2.3 退訂單 modal — SKU 表
- [ ] 選訂單後載入該訂單的 customer_order_items（排除 cancelled/expired）+ 已退量
- [ ] 每行：SKU 名稱 / 訂單量 / 已退量 / 可退量 / **退多少**（input）
- [ ] 預設退量 = 0
- [ ] input 限制 0 ≤ 退量 ≤ 可退量
- [ ] 整張全 0 → 提交按鈕 disabled
- [ ] 含「退貨原因」textarea（選填）

### 2.4 提交
- [ ] 提交 → 呼叫 `rpc_create_order_return`
- [ ] 成功 → modal 關閉、列表 refetch、新 transfer 出現在「退貨回總倉」分頁
- [ ] 失敗 → 顯示 RPC error message
- [ ] 不轉跳頁面（停在 `/wms/transfers`）

### 2.5 列表顯示
- [ ] 「退貨回總倉」分頁包含新建立的 return_to_hq transfer
- [ ] 列表顯示連結的 customer_order order_no（hover 或欄位）

---

## 3. Regression

### 3.1 自由轉貨原本店↔店流程不受影響
- [ ] 來源店 A、目的店 B 建自由轉貨仍可建
- [ ] 已存在的 store_to_store transfer 不變

### 3.2 訂單取消流程不受影響
- [ ] `rpc_cancel_aid_order` 仍可正常逆轉 transfer 鏈
- [ ] 取消已退過部分的訂單不會 double-deduct（現階段先看是否會炸；如有問題再追加 RPC 處理）

### 3.3 互助訂單不受影響
- [ ] `/transfers/aid` 流程未變

---

## 4. 邊界

- [ ] 訂單某行 SKU 已 cancelled / expired → 不出現在可退清單
- [ ] 部分 picked_up 的訂單仍可退（如客戶帶回退）— 由 rpc_outbound 庫存檢查負責擋下店端缺貨
- [ ] 多次退（部分退第一次 5 個、再退 3 個），可退量自動扣（已退量靠 return_to_hq transfer 累加）

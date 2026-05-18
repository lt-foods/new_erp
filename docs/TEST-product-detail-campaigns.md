# product-detail-campaigns 測試項目 — 商品 detail 顯示關聯開團 + 開/關 switch

**對應 UI 變更:**
- 新增 `apps/admin/src/components/ProductCampaignsPanel.tsx`（商品關聯開團清單 + 每列 open/close switch）
- `apps/admin/src/app/(protected)/products/page.tsx`：編輯（detail）modal 於 ProductForm 下方加入 `ProductCampaignsPanel`（僅既有商品 / id != null）

**對應後端:** 無新 migration — 切換狀態複用既有 `rpc_bulk_set_campaign_status(BIGINT[], TEXT)`（單元素陣列）
**對應狀態機（既有，不改）:** `draft →(open)→ open →(closed)→ closed →(cancelled)`；**無 open→draft / closed→open 反向**

> Switch 語意：ON ⇔ status='open'。draft(OFF)→ON 設 open；open(ON)→OFF 設 closed(收單)。closed/cancelled/ordered/receiving/ready/completed 一律 disabled（不可逆 / 已進採購流程）。

## 1. Schema / Migration 層
- [ ] N/A — 無 schema / migration 變更

## 2. RPC 行為（既有 rpc_bulk_set_campaign_status，SQL 直測複核語意）
- [ ] draft→open：有 campaign_items → 成功（回傳 1）；無 items → 跳過（回傳 0）
- [ ] open→closed：成功（回傳 1）
- [ ] closed→open：被 RPC 視為不合法轉換、跳過（回傳 0）— 故 UI 對 closed 必須 disable，不可送這個請求
- [ ] 跨 tenant id → 跳過（回傳 0）
- [ ] p_status 非 draft/open/closed/cancelled → RAISE EXCEPTION（UI 只會送 open/closed，不應觸發）

## 3. UI 行為（preview 互動）

### 3.1 商品 detail（`/products` → 點商品「編輯」開 modal）
- [ ] 頁面 / modal 載入無 console error
- [ ] 既有商品（id != null）modal 在 ProductForm（含 SKU 區）下方出現「關聯開團」面板；新增商品（mode=new）**不**出現
- [ ] 面板載入態為**純 spinner、無「載入中」文字**（依專案慣例）
- [ ] 關聯判定正確：列出所有「含此商品任一 SKU 之 campaign_item」的開團；`__INTERNAL_RESTOCK__` 不列；依 start_at 新→舊排序
- [ ] 無關聯開團時顯示空狀態（簡短、不破版）
- [ ] 每列顯示：團號（mono）、團名、狀態 badge、開團/收單日期、switch

### 3.2 Switch 行為
- [ ] status=open → switch 呈現 ON；status=draft → OFF 且可點
- [ ] status ∈ {closed, cancelled, ordered, receiving, ready, completed} → switch disabled，hover/title 說明原因
- [ ] draft→ON：confirm 後呼叫 rpc('open')，成功後該列變 開團中、switch 變 ON
- [ ] open→OFF：confirm（明示「收單後無法轉回開團中」）後呼叫 rpc('closed')，成功後該列變 已收單、switch 變 OFF 且 disabled
- [ ] 切換進行中 switch 顯示 spinner 並 disable，避免重複點擊
- [ ] RPC 回傳 0（未變更，如 draft 無 items）：顯示簡短提示、列狀態不變、不誤報成功
- [ ] RPC error：顯示後端訊息（不吞錯、不顯示 [object Object]）
- [ ] 取消 confirm → 不送請求、狀態不變

### 3.3 一致性 / 資料同步
- [ ] switch 成功後面板資料 refetch，狀態與 badge 一致
- [ ] 同一商品多 SKU 對應同一開團 → 該開團只出現一列（去重）

## 4. Regression
- [ ] ProductForm 既有欄位 / 上架驗證 / 儲存 / SKU 區（ProductSkuSection）/ 圖片 / 進階設定 完全不受影響
- [ ] 商品列表頁搜尋 / 篩選 / 排序 / 分頁 / 批次上下架 / 開團 modal 不受影響
- [ ] 開團列表頁（`/campaigns`）狀態、批次切換、縮圖（#255/#261）不受影響；本面板與其用同一 `rpc_bulk_set_campaign_status`
- [ ] 會員端 `/shop` 不受影響（後端未動）

## 5. 驗收門檻
全部 §2-§4 勾完、**無 console error**、**build + type-check 過** 才可標 done.（無 migration，dev push 門檻不適用）

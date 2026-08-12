# member-ordered-count-badge 測試項目 — 「已訂購 / 已售出」改為醒目統計數字

**對應 UI 變更:**
- 新增 `apps/member/src/components/OrderedCount.tsx`（共用統計：數字大而粗（深色）＋「已訂購 / 件」小號淡灰，sm/md/lg 三個字級。第一版是火焰 icon + 玫瑰粉 pill，被打回「沒質感」，改純排版層次）
- `apps/member/src/components/CampaignCard.tsx`（grid + hero 改用 OrderedCount）
- `apps/member/src/app/shop/flash/page.tsx`（FlashRow 改用 OrderedCount）
- `apps/member/src/app/shop/c/[id]/page.tsx`（標題旁總訂購量改用 OrderedCount lg；SKU 列表 + BuySheet 的 per-SKU「已售出 N」同樣改數字粗體深色、label 淡灰）

**對應後端 / migration:** 無 — 純前端樣式，顯示條件（`> 0` 才顯示）與數字來源完全未動。

## 1. Schema / Migration 層

- [ ] N/A — 無變更

## 2. RPC 行為

- [ ] N/A — 無變更（`ordered_qty` 仍由 liff-api `list_active_campaigns` / `get_campaign` 回傳）

## 3. UI 行為（preview 互動）

### 3.1 商店列表 grid 卡片（`/shop`）
- [ ] `ordered_qty > 0`：價格右側「已訂購 **N** 件」，數字 15px 粗體深色、label 12px 淡灰
- [ ] `ordered_qty = 0`：整組統計不渲染（不出現「已訂購 0 件」）
- [ ] 兩欄格線不破版：長數字（千分位）與瀏覽數直向堆疊仍對齊右緣
- [ ] 「僅剩 N 份」「已搶購一空」「倒數」chip 均不受影響

### 3.2 限時專區（`/shop/flash`）
- [ ] hero 卡片：統計為 md 字級（數字 17px）、靠右
- [ ] FlashRow 橫列：統計為 sm 字級，與「X 筆訂單」「共 X 項」並存不擠壓

### 3.3 商品詳情頁（`/shop/c/[id]`）
- [ ] 標題右側總訂購量為 lg 統計（數字 20px 粗體，取代原本灰底 rounded-lg）
- [ ] SKU 列表 per-SKU「已售出 N」數字 14px 粗體深色、label 淡灰（維持「已售出」文案，scope 與卡片不同係刻意）
- [ ] BuySheet（選擇規格）內 per-SKU「已售出 N」同上
- [ ] `ordered_qty = 0` 的品項不顯示已售出

### 3.4 一致性
- [ ] 四處統計的字重層次 / 顯示條件一致（卡片與詳情頁標題皆出自 OrderedCount，無各自複製的樣式）

## 4. Regression
- [ ] `/shop` 排序頁籤切換、下拉刷新後徽章隨資料正確
- [ ] `campaignRemaining` / `campaignSoldOut`（用 ordered_qty 計算）數字不變
- [ ] 內部 sentinel 活動（`__` 開頭）仍被濾掉

## 5. 驗收門檻

§3-§4 勾完、無 console error、build + type-check 過。（無 migration，dev push 門檻不適用）

---

## 驗證結果（2026-08-12）

- [x] **Type-check** — `tsc --noEmit` apps/member → exit 0
- [x] **Build** — `next build --webpack` apps/member → exit 0，21 routes（含 `/shop`、`/shop/flash`、`/shop/c/[id]`）全產出
- [x] **顯示條件未動（程式碼審查）** — OrderedCount 內建 `count > 0` gate 與既有四處的外層條件語意相同；`ordered_qty` 數字來源、`campaignRemaining` / `campaignSoldOut` 完全未動，純樣式變更
- [ ] live preview 截圖 — 需有 active 團的環境 + member 登入，交由部署後人工目視

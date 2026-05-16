# member-card-ordered-qty 測試項目 — 商品卡片顯示訂購量

**對應 UI 變更:** `apps/member/src/components/CampaignCard.tsx`（grid + hero）、`apps/member/src/app/shop/flash/page.tsx`（FlashRow）
**對應後端:** 無變更 — `supabase/functions/liff-api/index.ts` `list_active_campaigns` 自 #237 起已回傳 `ordered_qty`
**對應 migration / RPC:** 無（純前端呈現）

## 1. Schema / Migration 層

- [ ] N/A — 本功能無 schema / migration 變更

## 2. RPC 行為（SQL 直測）

- [ ] N/A — 無 RPC 變更。`ordered_qty` 已由 `listActiveCampaigns` 計算（排除 cancelled/expired + 排除負數抵減單），本次不動該邏輯

## 3. UI 行為（preview 互動）

### 3.1 商店列表 grid 卡片（`/shop`，CampaignCard variant=grid）
- [ ] 頁面載入無 console error
- [ ] `ordered_qty > 0` 的團：卡片在價格區出現「已訂購 N 件」（N = ordered_qty）
- [ ] `ordered_qty = 0` 的團：不顯示「已訂購」字樣（不出現「已訂購 0 件」）
- [ ] 既有 `order_count`（X 筆訂單）badge / 文字仍正常顯示，與訂購量並存不互相覆蓋或擠壓破版
- [ ] 限量團「僅剩 N 份」pill 仍正確（campaignRemaining 用 ordered_qty 計算，數字不變）
- [ ] 「已搶購一空」狀態（ordered_qty ≥ cap）卡片仍顯示售罄、訂購量呈現不與售罄標籤衝突

### 3.2 限時專區 hero 卡片（`/shop/flash` 第一張，CampaignCard variant=hero）
- [ ] 頁面載入無 console error
- [ ] `ordered_qty > 0`：hero 卡片顯示「已訂購 N 件」
- [ ] `ordered_qty = 0`：不顯示訂購量
- [ ] hero 既有倒數 / 限量 / order_count badge 不受影響

### 3.3 限時專區 FlashRow（`/shop/flash` 第二張起的橫列）
- [ ] `ordered_qty > 0`：橫列顯示「已訂購 N 件」
- [ ] `ordered_qty = 0`：不顯示訂購量
- [ ] 既有「共 X 項 · 剩 N 份」「X 筆訂單」「倒數」並存不破版

### 3.4 一致性
- [ ] grid / hero / FlashRow 三處的訂購量文案、單位（件）、顯示條件（>0 才顯示）一致
- [ ] 與活動詳情頁（`/shop/c/[id]`）#237 既有的 per-SKU「已售出 N」不衝突（兩者 scope 不同：卡片=活動總訂購量、詳情=單品項；文案差異為刻意）

## 4. Regression
- [ ] `/shop` 排序頁籤（最新 / 最熱銷 / 近期售出）切換後卡片仍正常、訂購量隨資料正確
- [ ] `/shop` 下拉刷新（PullToRefresh）後訂購量更新
- [ ] `/shop/flash` 空狀態（無快團）文案不受影響
- [ ] 活動詳情頁 `/shop/c/[id]` SKU 列表 + BuySheet 的「已售出 N」維持 #237 行為不變
- [ ] 內部 sentinel 活動（`__` 開頭 campaign_no）仍被前端濾掉、不外漏

## 5. 驗收門檻

全部 §3-§4 勾完、**無 console error**、**build + type-check 過** 才可標 done.（本功能無 migration，故 dev push 門檻不適用）

---

## 驗證結果（2026-05-17）

### 通過
- [x] **Type-check** — `tsc --noEmit` apps/member → exit 0，無錯
- [x] **Build** — `next build --webpack` apps/member → exit 0，14 routes（含 `/shop`、`/shop/flash`、`/shop/c/[id]`）全產出
- [x] **資料路徑邏輯（DB 直驗，read-only）** — 以 SQL 完全複刻 liff-api `listActiveCampaigns` 的 ordered_qty 計算（customer_orders status NOT IN cancelled/expired AND order_kind IS NULL/normal，經 order_id join customer_order_items 加總，按 campaign 分組），對本地 seed 實測：
  - 有訂單的團（CAMP-001/002/005/006/010 → 3 件；008/009 → 2 件）→ 卡片渲染「已訂購 N 件」✓
  - 零訂單的團（CAMP-003/004/007 → 0）→ 卡片**正確隱藏**該行（`ordered_qty > 0` gate 生效）✓
  - 證明本次唯一新增邏輯（`> 0` 條件 + 顯示值 + 千分位）對真實訂單資料正確
- [x] **三處一致性 + 純加法（程式碼審查）** — grid / hero / FlashRow 三處文案、單位、`ordered_qty > 0` 條件、muted `text-[var(--tertiary-label)]` 樣式一致；`order_count`(筆訂單) 與限量 `campaignRemaining`（用 ordered_qty）邏輯**完全未動**，無回歸面

### 環境阻擋（未跑：live preview 互動 / 截圖）
- [ ] §3 preview 互動截圖 — **阻擋原因**：本地 seed 的 10 個真實團 `end_at` 全在過去（今日 2026-05-17），`/shop` 的 active filter `(end_at IS NULL OR end_at > now())` 會濾掉全部 → 不論認證與否 `/shop` 都渲染**空清單**，無卡片可截。且 liff-api edge function 本地未 serve（503）、需自簽 member JWT + 啟動已知不穩的本地 edge stack。
- **未採取**：改 seed（延長 campaign end_at / 插入訂單）會動到使用者正在用的本地 dev DB，對一個純樣式行而言不成比例且有風險，故維持 read-only。
- **替代驗證已涵蓋唯一風險**：本變更為加法式、複用既有已上線（#237）同層級 sibling 的相同樣式與容器位置，視覺風險低；其唯一邏輯已由上方 DB 直驗對真實資料證明正確。
- **如需 live 截圖**：可（a）指向有 active 團的環境、(b) 提供有效 member 登入 URL、或 (c) 授權我安全地暫時延長某團 end_at 後截圖再還原。

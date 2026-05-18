# orders-member-search 測試項目 — 訂單列表加會員/編號搜尋 bar

**對應 migration:** 無（純前端，沿用既有查詢）
**對應 UI 變更:** `apps/admin/src/app/(protected)/orders/page.tsx`
**對應 PRD:** `docs/PRD-LIFF前端.md`（銷售/訂單模組）

> 目的：在訂單列表新增關鍵字搜尋（訂單編號 / 會員姓名 / 電話 / 會員編號 / 暱稱），方便快速定位某張訂單後取消。

## 1. Schema / Migration 層

- [ ] 無新增 migration（確認 `git diff` 不含 `supabase/migrations/*`）

## 2. RPC 行為（SQL 直測）

- [ ] 無新增 / 變更 RPC（搜尋走 PostgREST `members` + `customer_orders` 直查）

## 3. UI 行為（preview 互動）

### 3.1 搜尋 bar 渲染
- [ ] 訂單頁載入無 console error
- [ ] filter 列出現第三個欄位：關鍵字輸入框 + 🔍 搜尋鈕（與「全部開團」「全部取貨店」同列）
- [ ] 初始無 `?q=` 時輸入框為空、列表為未套關鍵字的原始結果

### 3.2 以訂單編號搜尋
- [ ] 輸入存在的 `order_no`（或片段）按 Enter / 🔍 → 列表只剩該（些）訂單
- [ ] 輸入不存在編號 → 顯示「沒有符合條件的訂單」空狀態，不報錯

### 3.3 以會員資訊搜尋
- [ ] 輸入會員姓名片段 → 列出該會員所有（符合其他 filter 的）訂單
- [ ] 輸入電話片段 → 同上
- [ ] 輸入會員編號（Mxxxx）→ 同上
- [ ] 輸入暱稱（無會員、僅 `nickname_snapshot`）→ 命中該訂單
- [ ] 關鍵字含 `% , ( )` 等字元不會讓查詢報錯（已 sanitise）

### 3.4 與既有 filter 的 AND 組合
- [ ] 先選某「開團」再搜會員 → 結果為「該開團 ∧ 該會員」交集（非聯集）
- [ ] 選某「取貨店」再搜 → 結果限該店
- [ ] 切換 tab（未取貨/已完成/轉出/取消）關鍵字仍套用，結果為「該 tab ∧ 關鍵字」
- [ ] 套關鍵字後換頁（分頁）→ 關鍵字維持、count/頁碼正確

### 3.5 Tab 數量與關鍵字一致
- [ ] 套關鍵字後，四個 tab 的 (數字) 反映「關鍵字 ∧ 該 tab」筆數，而非全表
- [ ] 清空關鍵字後 tab 數字回到未過濾值

### 3.6 清空 / URL 同步
- [ ] 有關鍵字時出現「清空 / ✕」鈕，按下後輸入框與 filter 皆復原
- [ ] 關鍵字反映在 URL `?q=`，重新整理頁面後仍套用且自動帶入輸入框
- [ ] 從 `/members` 或他頁帶 `?q=` 進入 → 自動套用該關鍵字

### 3.7 取消動線（本功能主要目的）
- [ ] 搜出某張 pending/confirmed/shipping 訂單後，「取消」鈕仍正常運作（沿用 `rpc_cancel_aid_order`）
- [ ] 取消成功後列表 reload，關鍵字仍套用，該訂單轉入「取消」tab

## 4. Regression
- [ ] 未輸入關鍵字時，列表 / KPI 趨勢卡 / tab 數量與改動前一致
- [ ] 「全部開團」多選 picker、取貨店 select、分店帳號鎖店行為不變
- [ ] 既有「取消 / 去取貨」按鈕、訂單明細 Modal、分頁均不受影響
- [ ] KPI 趨勢卡（本月營業額等）不因關鍵字改變（趨勢卡刻意不套關鍵字，需確認仍以 campaign/store 為準）
- [ ] `/pickup`、`/members` 等共用 `customer_orders` 查詢的頁面未受影響

## 5. 驗收門檻

全部 §3-§4 勾完、**無 console error**、**build + type-check 過** 才可標 done。（本功能無 migration / RPC，§1-§2 僅需確認確實無變更。）

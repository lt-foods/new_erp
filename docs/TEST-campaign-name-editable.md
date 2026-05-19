# campaign-name-editable 測試項目 — 後台「編輯開團」可直接編輯團名

**對應 migration:** 無（純前端，後端 `rpc_upsert_campaign` 既有 `name = COALESCE(p_name, name)` 已支援）
**對應 UI 變更:** `apps/admin/src/components/CampaignForm.tsx`
**對應 PRD:** 無（沿用既有開團 CRUD；補上原刻意未開放的團名編輯）

## 1. Schema / Migration 層

- [ ] N/A — 本功能不含任何 migration / enum / 欄位 / index / RPC 簽章變更。
      確認 `git diff main...HEAD --stat` 只有 `apps/admin/...` 與 `docs/TEST-...`，無 `supabase/migrations/*`。

## 2. RPC 行為（SQL 直測）

無新增 / 變更 RPC。僅複用既有 `public.rpc_upsert_campaign`；以下為「確認既有行為仍正確」的回歸性直測：

### 2.1 既有 RPC 仍會寫入 name（UPDATE 分支）
**情境：** 任取一筆 `status IN ('draft','open')` 的開團，記下原 `name`，呼叫 `rpc_upsert_campaign(p_id := <id>, p_name := '手動測試團名', ...其餘帶原值)`。
**預期：** `group_buy_campaigns.name` 變為「手動測試團名」，`updated_by` = 當前 admin，其餘欄位（status / close_type / 時間 / cap / notes）不變。

### 2.2 name 傳 NULL 不會清空（COALESCE 保護）
**情境：** 對同一筆開團呼叫 RPC 但 `p_name := NULL`。
**預期：** `name` 維持上一步的值（COALESCE 命中 `name`），不被設為 NULL。

## 3. UI 行為（preview 互動 / 使用者自審）

> admin live-preview 於 Claude 沙箱被網路阻擋（見專案慣例），§3 以 build + type-check + 碼審為自動驗證，互動項標記給使用者自審。

### 3.1 編輯開團 modal — 團名輸入框渲染
- [ ] 開團列表頁點任一列「編輯」→ modal 開啟，**新增「團名」文字輸入框**且帶入該開團現有名稱（含 legacy `(emoji)` 等原始值，未被前端清洗 — 編輯頁顯示原始 DB 值才能改）。
- [ ] 團名輸入框可正常輸入 / 刪改中文與 emoji；無 maxLength 異常截斷（若加 maxLength 需與後端一致）。
- [ ] 原本那行說明文字不再宣稱「名稱…請至商品編輯頁」（已移除/改寫，描述/取貨等仍維持原說明）。

### 3.2 提交 happy path（既有開團改名）
- [ ] 改團名後按「儲存」→ 無 console error、modal 關閉、列表該列名稱即時更新為新值。
- [ ] 重新整理 / 重開編輯 → 新團名持續存在（DB 已落地，非僅前端 state）。
- [ ] 會員端 LIFF /shop 對應開團卡 / 詳情標題顯示新團名（經 `cleanCampaignText` 仍會刷掉 `(emoji)`，但管理者輸入的乾淨名稱應原樣顯示）。

### 3.3 空團名邊界
- [ ] 團名清空後儲存：沿用既有 `(v.name || "(open campaign)").trim()` 行為 — 不報錯、落地為占位字（確認不是寫入空字串造成列表空白）。或依實作決定改為阻擋空字串並提示，二擇一但需與呈現一致。

### 3.4 建立開團路徑不退化
- [ ] 從商品多選開團（order-entry / 候選池排日期）建立的開團，團名仍正確帶入（單一商品＝商品名；多商品＝既有命名邏輯），新欄位不影響建立流程。

## 4. Regression

- [ ] 開團列表頁（桌機表格 + 手機卡片）名稱欄、modal title `編輯開團 #<no>｜<name>` 仍正常。
- [ ] 行事曆（週/月）視圖點卡片開同一編輯 modal — 共用 `openEdit`，團名欄一致顯示且可編。
- [ ] 單一商品 draft/open 開團：改動「商品名稱」後，trigger `trg_products_sync_campaign_name` 仍把 product.name 同步覆蓋到 campaign.name（**已知且刻意**的既有行為，非本功能 bug；測試僅確認未被破壞）。
- [ ] 多商品開團：改商品名稱**不**覆蓋手動設定的團名（既有刻意行為仍成立）。
- [ ] `closeCampaign` / `finalizeCampaign` / `deleteCampaign` 等列操作不受表單欄位新增影響。

## 5. 驗收門檻

全部 §1–§4 勾完、**無 console error**、**build + type-check 過**（admin `next build`）、且 §3 互動項經使用者自審通過，才可標 done。本功能無 migration，故「Supabase dev push」一項以「確認無 migration 變更」替代。

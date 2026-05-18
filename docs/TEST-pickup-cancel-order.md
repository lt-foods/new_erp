# pickup-cancel-order 測試項目 — 取貨頁加「取消訂單」鈕

**對應 migration:** 無（沿用既有 `rpc_cancel_aid_order`）
**對應 UI 變更:** `apps/admin/src/app/(protected)/pickup/page.tsx`
**對應 PRD:** `docs/PRD-LIFF前端.md`（取貨流程）

> 目的：取貨頁每張訂單列在「通知 / 取貨」旁加「取消訂單」鈕，讓卡在「分店尚未收貨、無法取貨」的訂單能就地取消。沿用訂單頁完全相同的取消流程。

## 1. Schema / Migration 層

- [ ] 無新增 migration（確認 `git diff` 不含 `supabase/migrations/*`）

## 2. RPC 行為（沿用既有，僅複核 guardrail）

> 不新增 RPC。複核 `rpc_cancel_aid_order`（`supabase/migrations/20260510000006_rpc_cancel_aid_order.sql`）既有行為在本入口仍正確：

### 2.1 early cancel（pending / confirmed）
**情境：** 取貨頁對一張 `pending` 且未到貨（`pickup_ready=false`）訂單按「取消訂單」、輸入原因。
**預期：** 訂單 `status=cancelled`、`cancelled_at` 寫入；無庫存逆轉（尚未出庫）。

### 2.2 shipping revoke
**情境：** 對一張 `shipping` 訂單按「取消訂單」。
**預期：** 整條 transfer chain 反向回收已出庫存、相關 transfers 取消、訂單取消（與訂單頁撤回派貨行為一致）。

### 2.3 未登入 / RPC 錯誤
**情境：** 無 session / RPC RAISE。
**預期：** `alert` 顯示經 `translateRpcError` 翻譯後的後端錯誤訊息，不靜默吞錯；訂單仍在列表。

## 3. UI 行為（preview 互動）

### 3.1 按鈕渲染與 gating
- [ ] 取貨頁搜尋某會員後，每張訂單列在「🔔 通知」「✅ 取貨」旁出現「取消訂單」鈕
- [ ] 訂單 status ∈ {pending, confirmed, shipping} → 「取消訂單」鈕**顯示且可按**
- [ ] status ∈ {reserved, ready, partially_ready, partially_completed} → **不顯示**「取消訂單」鈕（與訂單頁 gating 一致，避免取消已部分取貨）
- [ ] 訂單**未到貨 / `pickup_ready=false`**（「⏳ 分店尚未收貨，無法取貨」）時，「取消訂單」鈕**仍可按**（核心需求，不被 `!canPickup` disable）

### 3.2 取消流程
- [ ] 按「取消訂單」→ 跳 `prompt` 要求輸入原因；按取消（prompt 回 null）→ 不送出、無副作用
- [ ] pending/confirmed 訂單：prompt 文案為「取消訂單：{order_no}…」
- [ ] shipping 訂單：prompt 文案為「撤回派貨：{order_no} 會反向回收已出庫存…」
- [ ] 輸入原因送出成功 → `alert("已取消")`
- [ ] 取消成功後自動重跑搜尋（`reloadTick`），該訂單因不在 `ACTIVE_STATUSES` 而從列表消失
- [ ] RPC 失敗 → `alert` 顯示翻譯後錯誤訊息，訂單仍在列表

### 3.3 與其他按鈕共存
- [ ] 「通知」「取貨」按鈕的 disabled 條件、行為不因新增鈕改變
- [ ] 「一次全取 / 取選定的 N 張」批次流程不受影響
- [ ] 取消其中一張後，其餘訂單與勾選狀態正常（reload 後重新查得）

## 4. Regression
- [ ] 訂單頁 `orders/page.tsx` 既有「取消」鈕邏輯**完全未動**、行為不變
- [ ] 取貨頁搜尋、常用顧客快選、通知、PickupDialog 取貨、列印小白單流程不變
- [ ] 取消後 `v_order_pickup_ready` / 列表排序仍正確
- [ ] LINE User ID 等敏感資訊顯示未受影響（本頁本就不顯示）

## 5. 驗收門檻

全部 §2-§4 勾完、**無 console error**、**build + type-check 過** 才可標 done。（本功能無新 migration / RPC，§1 僅需確認確實無變更；§2 為沿用 RPC 的回歸複核。）

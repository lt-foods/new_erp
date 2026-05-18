# 測試項目 — 刪除開團（草稿限定，實體刪除）

**對應 migration:** `supabase/migrations/20260618000020_rpc_delete_campaign.sql`
**對應 UI 變更:** `apps/admin/src/app/(protected)/campaigns/page.tsx`, `apps/admin/src/lib/rpcError.ts`

> 設計決策：開團狀態機嚴格單向（draft→open→closed→cancelled），`cancelled` 為軟取消終態。
> `customer_orders` / `order_waitlist` / `customer_order_sources` / `purchase_request_items`
> 皆以 **無 CASCADE** FK 參照開團 → 任何曾有訂單/PR 的開團實體刪除會被 RESTRICT 擋下。
> 故 **只允許刪除 `draft` 開團**（draft 必無 orders / PR / waitlist），其他狀態要刪請走「批次取消」。
> `campaign_items` / `campaign_channels` / `campaign_audit_log` 為 `ON DELETE CASCADE`；
> 但 `campaign_audit_log` 有 `trg_no_mut_camp_audit` append-only BEFORE DELETE trigger，
> 需仿 `rpc_delete_picking_wave` 暫時 DISABLE 該 trigger 再刪。

## 1. RPC 層

### 1.1 函式存在且權限正確
- [ ] `rpc_delete_campaign(BIGINT, UUID)` 存在、`SECURITY DEFINER`
- [ ] `authenticated` 有 EXECUTE、PUBLIC 無

```sql
SELECT proname, prosecdef FROM pg_proc WHERE proname = 'rpc_delete_campaign';
SELECT has_function_privilege('authenticated','public.rpc_delete_campaign(bigint,uuid)','EXECUTE');
```

### 1.2 正常流程：刪除草稿開團
- [ ] 建一個 `draft` 開團 + 2 個 `campaign_items`（必要時加 1 `campaign_channels`）
- [ ] 編輯數次製造 `campaign_audit_log` 數筆
- [ ] 呼叫 `rpc_delete_campaign(id, operator)` → 不報錯
- [ ] `group_buy_campaigns` 該列消失
- [ ] 對應 `campaign_items` / `campaign_channels` / `campaign_audit_log` 全消失（cascade）
- [ ] `trg_no_mut_camp_audit` 刪除後**已重新 ENABLE**（再對任何 campaign_audit_log 做 UPDATE/DELETE 仍 raise `append-only`）

### 1.3 狀態守門（核心安全）
- [ ] `open` 開團 → RAISE `campaign % is open, only draft can be deleted`
- [ ] `closed` / `ordered` / `receiving` / `ready` / `completed` / `cancelled` → 同樣被擋（各別測 cancelled + 一個中間態）
- [ ] 防禦：draft 但被塞了 customer_orders（人工構造）→ RAISE，不可刪（belt-and-suspenders）

### 1.4 邊界 / 錯誤
- [ ] 不存在 id → RAISE `campaign % not found`
- [ ] 跨 tenant id → 視為找不到，不可動別 tenant
- [ ] 失敗時（任何 EXCEPTION）append-only trigger 一定被 re-enable（測：在 raise 後查 trigger 仍 enabled）
- [ ] 同 tenant 其他開團、訂單、PR 完全不受影響

## 2. UI 層（開團列表頁）

### 2.1 刪除鈕（共用 `campaignActions`，桌機表格 + 手機卡片同步）
- [ ] **僅** `status === 'draft'` 的列/卡片顯示紅色「刪除」鈕；其餘狀態不顯示
- [ ] 點擊跳 `window.confirm`，文案說明「僅草稿可刪、刪除後無法復原」
- [ ] 取消 → 無 side effect
- [ ] 確認 → 呼叫 `rpc_delete_campaign`，成功後列表 reload，該開團消失
- [ ] 失敗 → `translateRpcError` 顯示中文（含「只有草稿可以刪除」規則）
- [ ] 進行中 disabled / spinner（純轉圈）

### 2.2 rpcError 規則
- [ ] `campaign \d+ is \w+, only draft can be deleted` → 中文「此開團目前為「<狀態>」，只有草稿可以刪除。」
- [ ] `campaign \d+ has \d+ orders, cannot delete` → 中文提示先取消訂單

### 2.3 回歸
- [ ] 編輯 / 加單 / 結單 / 結算 鈕邏輯與顯示條件不變
- [ ] 批次開團/結單/取消、月曆 / 週視圖不受影響

## 3. 驗證方式
- RPC：上述 SQL 於 Supabase Studio 實跑（SQL 交使用者執行）
- UI：`tsc --noEmit` + `next build` 綠；preview 互動由使用者自審

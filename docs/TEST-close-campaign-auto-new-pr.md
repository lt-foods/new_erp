# rpc_close_campaign：同日 PR 已鎖時自動為新結單 campaign 建 campaign-type PR

**對應 migration:** `supabase/migrations/20260512000001_close_campaign_auto_new_pr.sql`（待建）
**對應 RPC:** `rpc_close_campaign`（升級行為）+ 重用既有 `rpc_create_pr_from_campaign`
**對應 UI:** 無 — 純 RPC 行為調整

**需求脈絡（決策來自 2026-04-28 對話）：**
- 同日先結 A campaign → auto 建 close_date PR → 操作者 submit / 拆 PO（PR locked）。
- 後續 B campaign 在同一天結單；目前 `rpc_close_campaign` 會回 `skipped_pr_locked`，要求人工處理。
- 但 B 的訂單其實有自己獨立的需求（時序差導致 A 已下單但 B 還沒）→ 應該自動為 B 開一張獨立 campaign-type PR，不需人工。

**核心規則：**
- 同日已有 close_date PR + status='draft' → 仍 append 到該 PR（既有行為，不變）
- 同日已有 close_date PR + status ≠ 'draft' / 'cancelled'（已鎖）→ 自動為當前 campaign 建 campaign-type PR
- 同日無 PR + 還有其他 open campaign → 仍 deferred（既有行為）
- 同日無 PR + 全部結完 → auto-create close_date PR（既有行為）

---

## 1. RPC 行為

### 1.1 close_date PR 在 draft（既有行為，回歸）
- [ ] A close → auto-create close_date PR (action='created')
- [ ] B close → action='appended'，PR.id 同 A
- [ ] A 跟 B 的 demand 都在同一張 PR

### 1.2 close_date PR 已 submitted（新行為核心）
- [ ] A close → close_date PR 建好；操作者 manual UPDATE 設 status='submitted'
- [ ] B close → action='created_secondary'（或類似 tag），新 PR.id ≠ A 的 PR
- [ ] 新 PR.source_type = 'campaign'、source_campaign_id = B 的 id、source_close_date = 該日
- [ ] 新 PR 的 items 只含 B 的 SKU 需求（不混 A）

### 1.3 close_date PR 已 fully_ordered / partially_ordered（新行為一致性）
- [ ] 同 1.2，任何非 draft 非 cancelled 都觸發新建

### 1.4 PR 已 cancelled（不視為已存在）
- [ ] A close → 建 PR；操作者 cancel
- [ ] B close → action='created'（auto-create close_date PR；視同無 PR 存在）

### 1.5 同 campaign 不可重複建 campaign-type PR
- [ ] B 已有 campaign-type PR 存在（status<>'cancelled'）
- [ ] 再次 close B（不可能，campaign status 已 closed）— 但若手動叫 rpc_create_pr_from_campaign 會 RAISE
- [ ] 守衛在 rpc_create_pr_from_campaign 既有，無需重複實作

### 1.6 B campaign 無訂單（degrade）
- [ ] B close、無 customer_orders 對應
- [ ] rpc_create_pr_from_campaign 內 RAISE 'no orders to aggregate for campaign'
- [ ] rpc_close_campaign 內捕捉 → 回 action='create_failed'、reason 帶錯誤訊息（不爆）

---

## 2. 守衛 / 邊界

### 2.1 close_date PR 無 source_close_date（理論上不會發生）
- [ ] 跳過 — schema CHECK 強制 source_type='close_date' → source_close_date NOT NULL

### 2.2 多筆 close_date PR 並存（也不該發生，但若 unique index 損毀）
- [ ] 預期：取 LIMIT 1 那筆作判斷 — 既有行為

### 2.3 跨 tenant
- [ ] gbc.tenant_id 與 PR.tenant_id 必須一致 — 既有 SQL where 已有 tenant_id 過濾

---

## 3. 回歸（Regression）

### 3.1 既有 rpc_close_campaign 路徑不變
- [ ] 唯一 open campaign + 該日 close → auto-create close_date PR (既有 action='created')
- [ ] 同日還有其他 open campaign → action='deferred' (既有行為)
- [ ] PR draft 存在 → action='appended' (既有行為)

### 3.2 rpc_create_pr_from_campaign 不變
- [ ] 直接呼叫該 RPC 行為不受影響
- [ ] 此 migration 只動 rpc_close_campaign

### 3.3 picking workstation view 一致
- [ ] 新建的 campaign-type PR 拆 PO 後，view 應將該 SKU 列入（透過 source_close_date 對齊）

---

## 4. SQL 自我驗證

```sql
-- 找當前 tenant 同一天有多張 PR 的情境
SELECT source_close_date, source_type, COUNT(*) AS pr_count,
       array_agg(id ORDER BY id) AS pr_ids
  FROM purchase_requests
 WHERE source_close_date IS NOT NULL
   AND status <> 'cancelled'
 GROUP BY source_close_date, source_type
 ORDER BY source_close_date DESC;

-- 應看到：close_date 1 張 + 同日 campaign 多張並存
```

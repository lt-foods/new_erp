# PR 手動建立 — A+B 入口測試項目

**對應 migration:** `supabase/migrations/20260505000000_pr_manual_creation.sql`（待建）
**對應 UI 變更:**
- `apps/admin/src/app/(protected)/purchase/requests/page.tsx`（列表頁加 2 顆建單按鈕 + campaign 選擇 modal + source_type 顯示加 'campaign' 標籤）

**需求脈絡（決策來自 2026-04-26 對話）：**
- 同結單日多個團購可能要分開叫貨（不同供應商急迫度、追貨需求）→ A
- 補貨/樣品/總部自訂進貨需要全空白單 → B

**3 項關鍵決策（已確認）：**
1. **共存規則**：campaign PR 與 close_date PR 完全允許共存（不互斥）
2. **B 初始狀態**：全空白草稿、無守衛、直接跳 edit
3. **campaign 狀態**：A 只允許 closed campaign（不允許 open）

---

## 1. Schema / Migration 層

### 1.1 `purchase_requests` 擴充
- [ ] CHECK 約束 `source_type` 增加 `'campaign'` 值（既有 'manual','close_date' 不變）
  ```sql
  SELECT pg_get_constraintdef(oid)
    FROM pg_constraint
   WHERE conrelid = 'purchase_requests'::regclass
     AND conname LIKE '%source_type%';
  -- 應包含: source_type IN ('manual','close_date','campaign')
  ```
- [ ] 新增 `source_campaign_id BIGINT REFERENCES group_buy_campaigns(id)`
- [ ] 重寫 `chk_pr_source_close_date` → `chk_pr_source_consistency`：
  - `close_date` → `source_close_date IS NOT NULL`
  - `campaign` → `source_campaign_id IS NOT NULL`
  - `manual` → 兩者皆可為 NULL
- [ ] Index：`idx_pr_campaign` ON `(tenant_id, source_campaign_id) WHERE source_type='campaign'`

### 1.2 RPC signature
- [ ] 新 RPC `rpc_create_pr_from_campaign(p_campaign_id BIGINT, p_operator UUID) RETURNS BIGINT`
- [ ] 新 RPC `rpc_create_pr_blank(p_operator UUID) RETURNS BIGINT`
- [ ] grant execute 給 authenticated

---

## 2. RPC: `rpc_create_pr_from_campaign`

### 2.1 Happy path
- [ ] 對 closed campaign 呼叫 → 回傳新 PR id；PR.source_type='campaign'、source_campaign_id=該 id、source_close_date=該 campaign 的 close_date
- [ ] items 每行帶 `source_campaign_id` 等於該 campaign id
- [ ] items 含 retail_price / franchise_price snapshot（從 `prices` 抓最新）
- [ ] items 含 unit_cost / suggested_supplier_id（從 `supplier_skus` is_preferred=TRUE）
- [ ] PR.total_amount = SUM(line_subtotal)

### 2.2 守衛
- [ ] open campaign → RAISE `campaign % not in closed status`
- [ ] cancelled campaign → 同上
- [ ] 不存在 campaign → RAISE `campaign % not found`
- [ ] 該 campaign 無未取消訂單 → RAISE `no orders to aggregate for campaign`
- [ ] **同 campaign 已有未取消 PR**（status<>'cancelled'）→ RAISE `campaign % already has PR (id=N)`
- [ ] **共存允許**：同 close_date 已有 close_date PR 不阻擋 campaign PR 建立（重點）

### 2.3 Edge case
- [ ] 同 campaign 之前的 PR 已 cancelled → 允許重建
- [ ] tenant 跨檢查：跨 tenant 看不到別家的 campaign

---

## 3. RPC: `rpc_create_pr_blank`

### 3.1 Happy path
- [ ] 呼叫 → 回傳新 PR id；PR.source_type='manual'、source_close_date=NULL、source_campaign_id=NULL
- [ ] PR.status='draft'、review_status='approved'（沿用 default）
- [ ] PR.total_amount=0
- [ ] purchase_request_items 該 PR 0 筆

### 3.2 守衛
- [ ] 無守衛（隨時可建）
- [ ] tenant 用 `_current_tenant_id()` 取，無權限會 fail

---

## 4. 列表頁 UI（`/purchase/requests`）

### 4.1 兩顆建單按鈕
- [ ] 右上角顯示「+ 空白採購單」「+ 針對團購建單」兩顆按鈕
- [ ] 「+ 空白採購單」點擊 → 直接呼叫 `rpc_create_pr_blank` → 跳 `/purchase/requests/edit?id=N`
- [ ] 「+ 針對團購建單」點擊 → 開 modal 選 closed campaign

### 4.2 Campaign 選擇 modal
- [ ] modal 顯示：過去 60 天 closed campaign 列表
- [ ] 已有未取消 campaign PR 的 campaign → 禁用 + 顯示「已有採購單」
- [ ] 已有同日 close_date PR 的 campaign → 不禁用（共存允許）+ 顯示「同日已有結單日 PR」提示
- [ ] 選一個 → 呼叫 `rpc_create_pr_from_campaign` → 跳 edit page

### 4.3 列表 source_type 顯示
- [ ] `source_type='campaign'` → 顯示「單一團購」
- [ ] `source_type='close_date'` → 顯示「結單日帶入」
- [ ] `source_type='manual'` → 顯示「手動」
- [ ] campaign 來源那行的「結單日」欄顯示 campaign.name 或 source_close_date

---

## 5. 共存性回歸測試

- [ ] 4/28 已有 close_date PR → 對 4/28 某個 campaign 建 campaign PR → 兩張並存
- [ ] 兩張 PR 都能各自送審、拆 PO、不互相干擾
- [ ] `v_pr_progress` 對兩種 source_type 都正確（不報錯）
- [ ] PrPipelineStepper 對 campaign / manual PR 顯示正常（建立 → 編輯 → 送審 → ...）

---

## 6. 既有功能不破

- [ ] 現有結單日 PR 流程 (`rpc_create_pr_from_close_date`) 不變
- [ ] 現有 close_date PR 的「同 close_date 守衛」仍生效（只擋 source_type='close_date'）
- [ ] 現有 PR 的 source_type='manual' 既有資料能正常編輯（向下相容）
- [ ] PR edit page 對所有 source_type 都能 render（不依賴 source_close_date 必填）

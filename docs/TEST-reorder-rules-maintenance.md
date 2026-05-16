# reorder-rules-maintenance 測試項目 — 補貨規則維護子頁

**對應 migration:** `supabase/migrations/20260615000030_reorder_rules_admin_rls_and_rpcs.sql`
**對應 UI 變更:** `apps/admin/src/app/(protected)/inventory/reorder-rules/page.tsx`（新）、`apps/admin/src/app/(protected)/layout.tsx`（側欄）、`apps/admin/src/app/(protected)/inventory/page.tsx`（cross-link）
**關聯:** /inventory 庫存總覽（[TEST-inventory-overview.md](TEST-inventory-overview.md)）— 本功能順帶修復其「只看低於補貨點」filter
**性質:** 後台 HQ 維護頁；mutation 全走 SECURITY DEFINER RPC（避 PostgREST 直寫）

> **背景缺口：** `reorder_rules` RLS ENABLED 但**零 policy** → admin 連讀都被靜默拒（/inventory 低庫存 filter 一直回 0）。本 migration 補 admin SELECT policy + 寫入 RPC。

---

## 1. Schema / Migration 層

### 1.1 RLS policy
- [ ] `reorder_rules` 新增 `hq_admin_read` SELECT policy（TO authenticated）
  ```sql
  SELECT polname, cmd FROM pg_policies WHERE tablename='reorder_rules';
  -- expect 至少 1 行 hq_admin_read / SELECT
  ```
- [ ] policy USING 條件：`tenant_id = jwt tenant` AND role ∈ (owner/admin/hq_manager/purchaser/warehouse/reporter)
- [ ] 未變更既有：reorder_rules 仍 RLS ENABLED；無新增 INSERT/UPDATE/DELETE policy（寫入只走 RPC）

### 1.2 RPC signature + grants
- [ ] `rpc_upsert_reorder_rule(BIGINT,BIGINT,NUMERIC,NUMERIC,NUMERIC,INT,UUID)` 存在、SECURITY DEFINER、RETURNS jsonb
- [ ] `rpc_delete_reorder_rule(BIGINT,BIGINT,UUID)` 存在、SECURITY DEFINER
- [ ] 兩者 `GRANT EXECUTE ... TO authenticated`
  ```sql
  SELECT proname, pg_get_function_identity_arguments(oid), prosecdef
    FROM pg_proc WHERE proname IN ('rpc_upsert_reorder_rule','rpc_delete_reorder_rule');
  -- expect prosecdef = true（兩者）
  ```
- [ ] `COMMENT ON FUNCTION` 有寫

### 1.3 不破壞既有 constraint
- [ ] reorder_rules PK / 兩個 CHECK（reorder_point≥safety_stock、max_stock IS NULL OR ≥reorder_point）/ trg_touch_reorder_rules 仍在；RPC 寫入受其約束

---

## 2. RPC 行為（SQL 直測，admin auth）

### 2.1 upsert — INSERT 路徑
**情境：** 對尚無規則的 (location, sku) 呼叫 `rpc_upsert_reorder_rule`，給齊四欄
**預期：** 新增 1 列；created_by/updated_by = operator；回傳 JSON 含寫入值；該 (tenant,loc,sku) 可被 admin SELECT 到

### 2.2 upsert — UPDATE / ON CONFLICT 路徑
**情境：** 對已存在 (location, sku) 再呼叫、改 reorder_point
**預期：** 同列被更新（非新增）；updated_by 更新、created_by 不變；updated_at 變動（trg_touch）

### 2.3 最小欄位（max_stock / lead_time_days 給 NULL）
**情境：** 只給 safety_stock + reorder_point，max_stock=NULL、lead_time_days=NULL
**預期：** 成功；max_stock / lead_time_days 為 NULL（不違反 CHECK）

### 2.4 CHECK：reorder_point < safety_stock
**情境：** safety_stock=10, reorder_point=5
**預期：** RAISE EXCEPTION（明確中文/英文訊息），無資料寫入

### 2.5 CHECK：max_stock < reorder_point
**情境：** reorder_point=20, max_stock=10
**預期：** RAISE EXCEPTION，無寫入

### 2.6 跨 tenant / 不存在的 location 或 sku
**情境：** location_id 或 sku_id 不屬於本 tenant（或不存在）
**預期：** RAISE EXCEPTION（not in tenant / not found），無寫入

### 2.7 role gate
**情境：** 非 HQ 角色（store_manager / 空 role）呼叫 upsert / delete
**預期：** RAISE permission denied（只有 owner/admin/hq_manager 可寫）

### 2.8 delete
**情境：** 對既有規則呼叫 `rpc_delete_reorder_rule`
**預期：** 該列刪除；再查不到；回傳成功 JSON。對不存在的 (loc,sku) → 安全（回 0/訊息、不報錯或明確訊息）

### 2.9 delete 受 tenant 限制
**情境：** 嘗試刪別 tenant 的規則
**預期：** 不刪到（tenant scoping 生效）

### 2.10 admin SELECT 修復驗證
**情境：** §2.1 寫入後，用 admin auth `SELECT * FROM reorder_rules`
**預期：** 回 ≥1 列（修補前因無 policy 一律 0）

---

## 3. UI 行為（preview 互動）

### 3.1 頁面 + 入口
- [ ] `/inventory/reorder-rules` 開啟、無 console error
- [ ] 側欄「進銷存」群組出現「補貨規則」（庫存總覽之後）、active 高亮正確、不誤亮庫存總覽 / mutual-aid
- [ ] `/inventory` header 有前往「補貨規則」的連結，反向亦可回庫存總覽
- [ ] 列表欄位：商品/SKU、倉別、安全庫存、補貨點、最高量、前置天數、操作；空集合顯示 EmptyRow

### 3.2 篩選
- [ ] 倉別下拉切換 → 列表收斂
- [ ] 商品/SKU 搜尋 → 列表收斂
- [ ] 分店帳號鎖自家倉（useUserBranchStoreId）

### 3.3 新增（happy）
- [ ] 「新增規則」開 modal：倉別 + SKU picker + 4 數值欄
- [ ] 填合法值送出 → rpc_upsert 成功、modal 關、列表出現該列（DB assert）

### 3.4 新增 / 編輯（client 驗證 sad path）
- [ ] reorder_point < safety_stock → 送出前前端擋（提示），不打 RPC
- [ ] max_stock 有值且 < reorder_point → 前端擋
- [ ] 後端 RAISE（繞過前端時）→ 經 rpcError 顯示可讀訊息

### 3.5 編輯 round-trip
- [ ] 既有列「編輯」→ modal 帶入現值；改 reorder_point 存檔 → 列表更新、值正確（ON CONFLICT update）

### 3.6 刪除
- [ ] 列「刪除」→ 確認後 rpc_delete → 列消失（DB assert 該 PK 不存在）

### 3.7 修復 /inventory 低庫存 filter（關鍵跨頁驗證）
- [ ] 新增一條 reorder_point 高於該 (店,SKU) 現有 on_hand 的規則
- [ ] 到 `/inventory` 勾「只看低於補貨點」→ 該列出現（修補前永遠空）；低庫存標記正確

---

## 4. Regression
- [ ] `/inventory` 庫存總覽頁原功能不受影響（表格 / 篩選 / drill-down）；唯低庫存 filter 由壞變好
- [ ] `/inventory/mutual-aid` 仍正常、未被新子路由影響；側欄三者 active 規則互不誤判
- [ ] 既有讀 reorder_rules 的程式（/inventory 低庫存）行為改善而非破壞（新增 SELECT policy 只放寬讀取）
- [ ] 未對 reorder_rules 加任何 broad write policy（寫入僅限 RPC）
- [ ] `tsc` 不破其他 OrderReturnCreateModal / inventory page（共用 lib 無破壞）

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功（migration applied）**、**`pnpm build` + type-check 過** 才可標 done。

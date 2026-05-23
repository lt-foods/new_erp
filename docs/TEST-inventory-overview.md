# inventory-overview 測試項目 — /inventory 庫存總覽頁

**對應 migration:** 無新增（讀既有表；admin 讀取 RLS 已於 `supabase/migrations/20260614000042_stock_admin_read_rls.sql`）
**對應 UI 變更:** `apps/admin/src/app/(protected)/inventory/page.tsx`（新增）、`apps/admin/src/app/(protected)/layout.tsx`（側欄入口）
**對應 PRD:** `docs/DB-庫存模組.md`
**性質:** 唯讀頁面 — 無寫入路徑、不新增 RPC / migration

---

## 1. Schema / Migration 層

本功能不新增 schema。只驗證**既有 admin 讀取 RLS 仍有效**（頁面完全依賴它）。

### 1.1 stock_balances RLS — admin 可讀
- [ ] `hq_admin_read` policy 存在且 admin / hq_manager 角色可 SELECT 本 tenant 全部 rows
  ```sql
  SELECT polname FROM pg_policies
   WHERE tablename='stock_balances' AND polname='hq_admin_read';
  ```
- [ ] 以 admin JWT（app_metadata.role='admin'）查 `stock_balances` 回 > 0 rows（非 0 rows 靜默拒絕）

### 1.2 stock_movements RLS — admin 可讀
- [ ] `hq_full_read` policy 含 admin / hq_manager；admin 查 `stock_movements` 回 > 0 rows
- [ ] `store_read_own` policy 仍只限門市角色看自己 `location_id`

### 1.3 依賴表可讀
- [ ] `skus` / `locations` / `stores` / `reorder_rules` 在 admin JWT 下皆可 SELECT（頁面 join 用）

---

## 2. 資料正確性（SQL 直測，對照 UI 顯示）

### 2.1 結存一致性
**情境：** 任取頁面顯示的一列 (location_id, sku_id)
**預期：** `stock_balances.on_hand` = `SUM(stock_movements.quantity)`（同 tenant/location/sku）；全表 0 mismatch
  ```sql
  SELECT COUNT(*) FROM stock_balances sb
   WHERE sb.on_hand <> COALESCE((
     SELECT SUM(quantity) FROM stock_movements sm
      WHERE sm.tenant_id=sb.tenant_id AND sm.location_id=sb.location_id AND sm.sku_id=sb.sku_id),0);
  -- expect 0
  ```

### 2.2 可用量公式
**情境：** 任一列
**預期：** UI「可用」欄 = `on_hand - reserved`；reserved>0 的列可用 < on_hand

### 2.3 低庫存篩選
**情境：** 勾「只看低於補貨點」
**預期：** 只列出存在 `reorder_rules` 且 `on_hand <= reorder_point` 的 (location,sku)；無 reorder_rule 的列不應出現

### 2.4 倉別篩選
**情境：** 選某分店 / 總倉
**預期：** 只回該 `location_id` 的列；總倉對應 `locations.type='central_warehouse'`，分店經 `stores.location_id` 對映

### 2.5 流水 drill-down
**情境：** 點開某列
**預期：** 顯示該 (location_id, sku_id) 最近 50 筆 `stock_movements`，依 `created_at DESC`；正負量、movement_type、source_doc、reason 正確

---

## 3. UI 行為（preview 互動）

### 3.1 頁面載入
- [ ] `/inventory` 路由可開、無 console error
- [ ] 側欄「進銷存」群組出現「庫存總覽」入口（請購單 / 採購單之後）、點擊導到 `/inventory`、active 高亮正確
- [ ] 表格渲染欄位：商品/SKU、倉別、在庫(on_hand)、保留(reserved)、在途(in_transit_in)、可用、均成本、最後異動
- [ ] 載入中顯示 LoadingRow；無資料顯示 EmptyRow（非空白破版）

### 3.2 篩選
- [ ] 商品/SKU 文字搜尋：輸入 sku_code / product_name / variant_name 片段 → 列表收斂
- [ ] 倉別下拉：含「全部」+ 各分店 + 總倉；切換即重查
- [ ] 「只看低於補貨點」checkbox：勾選後只剩低庫存列、取消還原
- [ ] 多篩選並用（搜尋 + 倉別 + 低庫存）結果為交集
- [ ] 篩選改變時 reset 回第 1 頁

### 3.3 流水 drill-down
- [ ] 點列展開（或 Modal）顯示該 (location,sku) 最近 stock_movements
- [ ] 流水每筆顯示：時間、movement_type（中文標籤）、數量（+入/-出顏色區分）、來源單據、reason
- [ ] 收合 / 關閉正常；切換另一列只顯示該列流水

### 3.4 分頁
- [ ] 列數 > PAGE_SIZE 時出現分頁器；上/下/首/末頁正確；頁碼顯示對
- [ ] 頂部「共 N 筆（x-y）」計數正確

### 3.5 分店帳號鎖定（branch user）
- [ ] 分店帳號登入 → 倉別下拉鎖死自家店（不可選別店）、顯示「(僅本店)」
- [ ] 分店帳號看不到其他 location 的列（RLS + UI 雙重）
- [ ] HQ 帳號可選全部 location，含總倉

### 3.6 LINE User ID 馬賽克（若流水 reason/notes 含）
- [ ] drill-down 任何 LINE User ID 一律 `Uxxxx…xxxx` 馬賽克（用 `lib/maskLineUserId`）

---

## 4. Regression
- [ ] 本頁為唯讀 — 確認頁面無任何 INSERT/UPDATE/RPC 呼叫（不寫 stock_movements / stock_balances）
- [ ] `stock_movements` append-only trigger 未被觸及（無新增 reversal）
- [ ] 既有頁面不受側欄 NAV 改動影響：`/orders`、`/wms/picking`、`/wms/receiving`、`/hq/inbox` 仍正常渲染、active 規則無誤判
- [ ] 既有「互助交流板」(`/inventory/mutual-aid`) 仍可開、未被新 `/inventory` 父路由蓋掉
- [ ] branch user 既有隱藏規則（BRANCH_HIDDEN_HREFS）不被破壞

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev 連線讀取正常（admin 回 > 0 rows）**、**`pnpm build` + type-check 過** 才可標 done。
（本功能無 migration，故「dev push」門檻替換為「admin RLS 讀取驗證通過」。）

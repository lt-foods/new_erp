# stocktake 測試項目 — 盤點 lifecycle

**對應 migration:** `supabase/migrations/20260615000040_stocktake_rls_and_rpcs.sql`
**對應 UI 變更:** `apps/admin/src/app/(protected)/inventory/stocktake/page.tsx`（list，新）、`.../inventory/stocktake/session/page.tsx`（盤點作業，新）、`.../layout.tsx`（側欄）
**關聯:** 第 3 個庫存子功能（接 /inventory #228、/inventory/reorder-rules #230）
**性質:** 多狀態流程；schema 既有（`stocktakes`/`stocktake_items` in 20260422120003）但**零 RPC、零 RLS policy**；mutation 全走 SECURITY DEFINER RPC

> 流程：draft →(存數)→ counting →(提交)→ review →(套用)→ adjusted；任一非 adjusted → cancelled。
> 套用：每筆 diff≠0 寫 `stocktake_gain`/`stocktake_loss` movement，trigger 把 `stock_balances` 對齊 counted。

---

## 1. Schema / Migration 層

### 1.1 helper + sequence
- [ ] `stocktake_no_seq` SEQUENCE 存在；`_next_stocktake_no()` 回 `ST{YYMMDD}{seq4}` 格式
  ```sql
  SELECT public._next_stocktake_no();  -- 形如 ST2606150001
  ```

### 1.2 RLS policy（兩表）
- [ ] `stocktakes` + `stocktake_items` 各有 `hq_admin_read` SELECT policy（TO authenticated）
  ```sql
  SELECT tablename, polname, cmd FROM pg_policies
   WHERE tablename IN ('stocktakes','stocktake_items') ORDER BY tablename;
  ```
- [ ] USING：tenant 相符 AND role ∈ (owner/admin/hq_manager/warehouse/purchaser/reporter)
- [ ] 兩表仍 RLS ENABLED；無新增 broad INSERT/UPDATE/DELETE policy

### 1.3 RPC signature + grants
- [ ] `rpc_create_stocktake(BIGINT,TEXT,BIGINT[],TEXT,UUID)`、`rpc_save_stocktake_counts(BIGINT,JSONB,UUID)`、`rpc_submit_stocktake(BIGINT,UUID)`、`rpc_apply_stocktake(BIGINT,UUID)`、`rpc_cancel_stocktake(BIGINT,TEXT,UUID)` 皆存在、`prosecdef=true`、`GRANT EXECUTE ... authenticated`
  ```sql
  SELECT proname, prosecdef FROM pg_proc
   WHERE proname LIKE 'rpc_%stocktake%';
  ```
- [ ] 每支有 `COMMENT ON FUNCTION`

### 1.4 不破壞既有
- [ ] `stocktakes.status` / `type` CHECK、`stocktake_items.diff_qty` GENERATED、FK CASCADE、trg_touch_* 仍在

---

## 2. RPC 行為（SQL 直測，admin auth）

### 2.1 create — full
**情境：** 某 location 有數個 stock_balances on_hand≠0；`rpc_create_stocktake(loc,'full')`
**預期：** 新 stocktakes status=draft、stocktake_no=ST…、started_at 有值；每個 on_hand≠0 SKU 生 1 stocktake_item、system_qty = 當下 on_hand；回傳 item_count 對

### 2.2 create — partial（指定 SKU）
**情境：** `rpc_create_stocktake(loc,'partial',ARRAY[sku_a,sku_b])`
**預期：** 只生 2 items；無 stock_balances 列的 SKU system_qty=0；partial 但 p_sku_ids 空 → RAISE

### 2.3 create — 驗證/拒絕
**情境：** type 非法值 / location 不屬 tenant / 非 HQ·warehouse 角色
**預期：** 各自 RAISE（type invalid / location not in tenant / permission denied），無 stocktake 建立

### 2.4 save_counts — 正常 + 狀態守門
**情境：** draft stocktake，`rpc_save_stocktake_counts` 帶部分 item 的 counted_qty
**預期：** status→counting；對應 item counted_qty/counted_by/counted_at 寫入；diff_qty 自動算（GENERATED）；非本盤點的 item_id → RAISE；counted_qty<0 → RAISE

### 2.5 save_counts — 已 adjusted/cancelled 不可改
**情境：** 對 adjusted（或 cancelled）stocktake 呼叫 save_counts
**預期：** RAISE（status 不允許）

### 2.6 submit — 未數完阻擋
**情境：** counting，仍有 counted_qty IS NULL 的 item，呼叫 `rpc_submit_stocktake`
**預期：** RAISE 並指出尚未盤點筆數；status 不變

### 2.7 submit — 全數完
**情境：** 所有 item 都有 counted_qty
**預期：** status counting→review

### 2.8 apply — 產調整 movement + 對齊餘額
**情境：** review stocktake，含 diff>0、diff<0、diff=0 三種 item
**預期：**
- diff>0 → 1 筆 `stocktake_gain`（quantity=+diff）；diff<0 → 1 筆 `stocktake_loss`（quantity=−|diff|）；diff=0 → **不產 movement**
- 對應 `stocktake_items.adjustment_movement_id` 回填
- 套用後該 (location,sku) `stock_balances.on_hand` = counted_qty（trigger 對齊）
- status review→adjusted、completed_at 有值；回傳 adjusted_lines / total_gain / total_loss

### 2.9 apply — 狀態守門 + 冪等
**情境：** 對非 review（draft/counting/adjusted）呼叫 apply；以及 apply 後再 apply
**預期：** RAISE（status 不允許）；不重複產 movement

### 2.10 cancel — 允許狀態 + 阻擋
**情境：** 對 draft/counting/review cancel → cancelled；對 adjusted（或已 cancelled）cancel
**預期：** 前者成功 status=cancelled；後者 RAISE（已套用不可取消）

### 2.11 admin SELECT 修復
**情境：** 任一上述建立後，admin auth `SELECT FROM stocktakes / stocktake_items`
**預期：** 回 ≥1 列（修補前因無 policy 一律 0）

### 2.12 tenant scoping
**情境：** 對別 tenant 的 stocktake_id 呼叫 save/submit/apply/cancel
**預期：** RAISE not found（不跨 tenant 操作）

---

## 3. UI 行為（preview 互動）

### 3.1 list `/inventory/stocktake`
- [ ] 載入無 console error；欄位：盤點單號/倉別/類型/狀態/品項數/差異/建立
- [ ] 倉別 + 狀態篩選收斂；空集合 EmptyRow
- [ ] 側欄「進銷存」群「盤點」（補貨規則之後）active 正確；庫存總覽/補貨規則/mutual-aid 不誤亮
- [ ] 分店帳號鎖自家倉

### 3.2 新增盤點 modal
- [ ] 「+ 新增盤點」開 modal：倉別 + 類型 radio（full/partial）
- [ ] 選 partial → 出現 SKU 多選搜尋；未選 SKU 送出被擋
- [ ] full 送出 → rpc_create_stocktake → 導到 session?id=、items = 該倉 on_hand≠0 數

### 3.3 session 盤點作業 `?id=`
- [ ] header 顯示單號/倉別/類型/狀態；items 表（SKU/系統量/盤點量輸入/差異著色）
- [ ] draft/counting：輸入盤點量 → 「儲存盤點數」→ 成功、diff 即時
- [ ] 「提交覆核」未數完 → 顯示中文錯誤（rpcError）、未跳狀態
- [ ] 全數完提交 → status=review、按鈕切換
- [ ] review：「套用調整」confirm → status=adjusted；表變唯讀、顯示調整 movement 連結/ID
- [ ] 套用後跨頁驗證：/inventory 該 (倉,SKU) on_hand = 盤點量
- [ ] 非 adjusted 顯示「取消盤點」→ confirm → status=cancelled
- [ ] adjusted / cancelled：唯讀、無編輯按鈕

### 3.4 錯誤路徑
- [ ] 對已 adjusted 的 session 再按套用（繞 UI）→ rpcError 中文
- [ ] ?id= 不存在 / 別 tenant → 友善訊息非崩潰

---

## 4. Regression
- [ ] `/inventory`、`/inventory/reorder-rules`、`/inventory/mutual-aid` 不受影響；側欄 4 個 inventory 項 active 互斥（regex 不互相誤亮）
- [ ] `stock_balances` 僅由 apply 經 movement 改動；create/save/submit/cancel **不**動庫存
- [ ] 既有讀 stocktakes 的程式（若有）只放寬讀取、未破壞
- [ ] 未對 stocktakes/_items 開 broad write policy（寫入僅 RPC）
- [ ] `tsc` 不破其他 inventory / 共用 lib

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功（migration applied）**、**`pnpm build` + type-check 過** 才可標 done。

# 候選池→草稿商品+草稿開團 / 三層價格 / 角色顯隱 / 開團行事曆 測試項目

**對應 migration（待建）:**
- `supabase/migrations/<ts>_prices_scope_cost_branch.sql`（prices.scope CHECK 加 cost/branch）
- `supabase/migrations/<ts>_rpc_set_cost_branch_price.sql`（兩支價格 wrapper）
- `supabase/migrations/<ts>_rpc_schedule_candidate.sql`（schedule → draft product+sku+campaign+items）
- `supabase/migrations/<ts>_prices_role_rls.sql`（依 role 過濾 cost/branch）

**對應 UI 變更（待建）:**
- `apps/admin/src/app/(protected)/products/edit/page.tsx`（加成本/分店價、依 role 顯隱）
- `apps/admin/src/app/(protected)/products/page.tsx`（status badge / draft filter）
- `apps/admin/src/app/(protected)/community-candidates/page.tsx`（排日期改呼叫新 RPC、移除採用、加跳轉連結）
- `apps/admin/src/app/(protected)/community-candidates/calendar/page.tsx`（**移除**或 redirect → /campaigns）
- `apps/admin/src/app/(protected)/campaigns/page.tsx`（加 7 天 / 月曆視圖、完整度檢查、開團按鈕）
- `apps/admin/src/app/(protected)/layout.tsx`（sidebar 移除「社群選品 → 週曆」項）

**對應 PRD:** `docs/BRIEF-社群商品候選池與商品行事曆.md`

---

## 1. Schema / Migration 層

### 1.1 prices.scope CHECK 擴充
- [ ] `prices.scope` CHECK 接受新值 `'cost'` 和 `'branch'`（既有 retail/store/member_tier/promo 不動）
- [ ] 嘗試 INSERT scope='unknown' 仍被擋
- [ ] 既有 row scope='retail'/'store' 不受影響

**驗證 SQL：**
```sql
-- 確認 CHECK 條件
SELECT pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'prices'::regclass AND contype = 'c';

-- 嘗試合法 INSERT
INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price, created_by)
VALUES (...,'cost',NULL,80,...);   -- 應成功
INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price, created_by)
VALUES (...,'branch',NULL,120,...); -- 應成功

-- 嘗試非法 INSERT
INSERT INTO prices (..., scope, ...) VALUES (...,'foo',...); -- 應被擋
```

### 1.2 RPC signature
- [ ] `rpc_set_cost_price(p_sku_id BIGINT, p_price NUMERIC, p_effective_from TIMESTAMPTZ DEFAULT NOW(), p_reason TEXT DEFAULT NULL)` 存在
- [ ] `rpc_set_branch_price(p_sku_id BIGINT, p_price NUMERIC, p_effective_from TIMESTAMPTZ DEFAULT NOW(), p_reason TEXT DEFAULT NULL)` 存在
- [ ] `rpc_schedule_candidate(p_candidate_id BIGINT, p_scheduled_date DATE, p_product_name TEXT)` 存在
- [ ] 三支都 GRANT TO authenticated

### 1.3 prices RLS policy 加 role 過濾
- [ ] 既有 `read_tenant_prices` 仍存在（同 tenant 才讀）
- [ ] 新增 row-level filter：scope='cost' 只給 role IN ('owner','admin','hq_manager','hq_accountant') 看
- [ ] scope='branch' 給 role IN ('owner','admin','hq_manager','store_manager') 看
- [ ] scope='retail' / 'store' / 'member_tier' / 'promo' 不過濾（既有行為）

**驗證 SQL：**
```sql
-- 切到 store_staff JWT 後 SELECT prices 只能看到 retail/store/promo
-- 切到 store_manager JWT 後 SELECT 應多看到 branch
-- 切到 admin JWT 後 SELECT 應全部
```

### 1.4 既有 rpc_adopt_candidate 處理
- [ ] 決定保留原 RPC 或 deprecate（若新流程完全取代採用按鈕，這支應僅供 idempotent 補救）
- [ ] 若保留，加 COMMENT 標記「legacy: prefer rpc_schedule_candidate」

---

## 2. RPC 行為（SQL 直測）

### 2.1 rpc_set_cost_price — 基本寫入
**情境：** authenticated（admin role）對某 sku 設 cost=80。

**預期：** prices 表多一筆 scope='cost'/scope_id=NULL/price=80 的 row、created_by = auth.uid()、effective_to=NULL。

### 2.2 rpc_set_cost_price — 排程後第二次寫入會關閉舊版
**情境：** 連續呼叫兩次，effective_from 不同。

**預期：** 舊 row.effective_to 被填成新 row.effective_from（沿用 rpc_upsert_price 行為）。

### 2.3 rpc_set_cost_price — 跨 tenant SKU 拒絕
**情境：** sku_id 屬於別 tenant。

**預期：** RAISE EXCEPTION 'sku % not in tenant'。

### 2.4 rpc_set_cost_price — store_staff 角色被擋
**情境：** JWT role='store_staff' 呼叫 rpc_set_cost_price。

**預期：** RAISE EXCEPTION（permission denied 或 RLS 擋寫）。

### 2.5 rpc_set_branch_price — store_manager 可寫
**情境：** JWT role='store_manager' 呼叫 rpc_set_branch_price。

**預期：** 成功寫入 scope='branch'。

### 2.6 rpc_set_branch_price — store_staff 被擋
**情境：** JWT role='store_staff' 呼叫。

**預期：** 拒絕。

### 2.7 rpc_schedule_candidate — happy path
**情境：** candidate.id=X 還沒 adopted/scheduled，呼叫 rpc_schedule_candidate(X, '2026-05-15', '蒜香麵包')。

**預期：**
- products 多一筆 status='draft' / name='蒜香麵包' / 自動 product_code
- skus 多一筆 status='draft' / sku_code = product_code（沿用 rpc_ensure_default_sku 行為）
- group_buy_campaigns 多一筆 status='draft' / scheduled_open_at='2026-05-15' / 自動 campaign 編號
- campaign_items 多一筆 (campaign_id, sku_id) 對應
- candidate.adopted_product_id=新 product / owner_action='scheduled' / scheduled_open_at='2026-05-15' / scheduled_by=auth.uid() / scheduled_at=NOW()
- 回傳 jsonb { product_id, product_code, sku_id, campaign_id, already_scheduled:false }

### 2.8 rpc_schedule_candidate — idempotent
**情境：** 同一 candidate 重呼第二次（已 scheduled、adopted_product_id 有值）。

**預期：** 不重建，回傳既有 product_id/sku_id/campaign_id、already_scheduled=true。

### 2.9 rpc_schedule_candidate — product_name 空白
**情境：** p_product_name = ''.

**預期：** RAISE EXCEPTION 'product_name must not be blank'。

### 2.10 rpc_schedule_candidate — 跨 tenant candidate 拒絕
**情境：** candidate_id 屬於別 tenant。

**預期：** RAISE EXCEPTION 'candidate % not found or cross-tenant'。

### 2.11 rpc_schedule_candidate — role 限制
**情境：** JWT role='store_staff' 呼叫。

**預期：** RAISE EXCEPTION（only owner/admin/hq_manager/assistant 可排程）。

### 2.12 rpc_schedule_candidate — 並行雙呼叫
**情境：** 同 candidate 兩個 transaction 同時 call。

**預期：** 第二個被 FOR UPDATE 鎖、走到 idempotent 分支、不重建。

### 2.13 prices RLS — 非預期 scope 默認可讀
**情境：** 既有 scope='member_tier' / 'promo' 在新 policy 後仍可讀（避免 regression）。

**預期：** retail/store 跟舊 row 都不受影響。

---

## 3. UI 行為（preview 互動）

### 3.1 商品編輯頁 — admin 看到三種價格
- [ ] `/products/edit?id=X` 載入無 console error
- [ ] 看得到三個 input：成本價、零售價、分店價
- [ ] 三個欄位都能輸入並送出，DB 對應 prices scope=cost/retail/branch 各多一筆

### 3.2 商品編輯頁 — store_manager 看到兩種
- [ ] 切到 store_manager JWT 後重載 `/products/edit?id=X`
- [ ] 只看到零售價 + 分店價輸入；成本價區塊不渲染、不在 DOM
- [ ] 嘗試直接呼叫 rpc_set_cost_price（透過 console）被 RLS 擋

### 3.3 商品編輯頁 — store_staff 只看一種
- [ ] 切到 store_staff JWT 後重載
- [ ] 只看到零售價；成本價、分店價區塊都不渲染

### 3.4 商品列表頁 — 草稿狀態 badge
- [ ] `/products` 列表能看到新 status='draft' 的商品（從 candidate schedule 建出來的）
- [ ] draft 列以灰色 badge 顯示
- [ ] 列表頁加上「狀態」filter，可切 draft / active / 全部

### 3.5 商品列表頁 — draft 不可下訂
- [ ] 對 draft 商品的訂單動作（建單、加入活動）UI 上 disabled 或顯示「需補完才能下訂」

### 3.6 候選池頁 — 排日期改呼叫新 RPC
- [ ] 對 owner_action='none' 的 candidate 點「排日期」→ 選 2026-05-15 → 「確定」
- [ ] 預期成功後：
  - candidate row 變綠色 badge「已排程」 + scheduled_open_at 顯示日期
  - DB 中 products / skus / group_buy_campaigns / campaign_items 各多 1 筆 draft
- [ ] 排程失敗時錯誤訊息顯示給使用者

### 3.7 候選池頁 — 採用按鈕已移除
- [ ] candidate row 動作區只剩「補資料 / 排日期 / 收藏 / 忽略 / 還原」，沒有「採用」
- [ ] 點補資料 popup 仍能寫 supplier/cost/sale_price 到 candidate（給排程前的暫存）

### 3.8 候選池頁 — 已排程列加跳轉連結
- [ ] owner_action='scheduled' 或 'adopted' 的 row 出現 「→ 編輯商品」按鈕（連到 /products/edit?id=adopted_product_id）
- [ ] 同 row 出現「→ 編輯開團」按鈕（連到 /campaigns/edit?id=...，campaign_id 從 product → campaign_items 反查）
- [ ] 兩個連結點開後該頁能正確載入對應草稿

### 3.9 候選池週曆頁 — 已移除或 redirect
- [ ] `/community-candidates/calendar` 不存在（404）或 redirect → `/campaigns?view=week`
- [ ] sidebar「社群選品」區組不再有「週曆」子項

### 3.10 開團頁 — 7 天視圖
- [ ] `/campaigns?view=week` 載入無 console error
- [ ] 顯示今天 + 未來 6 天共 7 個欄位
- [ ] 每欄列出該天 scheduled_open_at = 該日 的草稿開團（含從 candidate schedule 建出來的）
- [ ] 每張卡片顯示：商品名 / 來源 candidate（可選）/ status badge / 完整度狀態
- [ ] 卡片可點擊 → 跳到開團詳情編輯頁

### 3.11 開團頁 — 月視圖
- [ ] `/campaigns?view=month` 顯示當月日曆網格
- [ ] 每天格子裡顯示該日 scheduled_open_at 的開團縮卡（>3 個用「+N」摺疊）
- [ ] 上月 / 下月 切換按鈕能用
- [ ] 點縮卡 → 跳到該開團編輯頁

### 3.12 開團頁 — 視圖切換
- [ ] 列表 / 7 天 / 月曆三個 tab 互切無 console error
- [ ] 切換不重打 API（cache 或 URL 狀態保留）

### 3.13 開團編輯頁 — 完整度檢查
- [ ] 草稿開團頁顯示 checklist：「商品已補完 / 成本價已設 / 零售價已設 / 分店價已設 / 開團起訖時間 / 結單日」
- [ ] 全勾 → 「開團」按鈕 enabled；任一未勾 → disabled + tooltip 標出缺什麼
- [ ] 未補完試圖直接 update status='open' 後端 RPC 也應拒絕（防 bypass）

### 3.14 開團編輯頁 — 開團按鈕
- [ ] 點「開團」 → status 從 draft → open
- [ ] 同步將關聯 product status draft → active、sku status draft → active
- [ ] 開完團後 candidate.owner_action 維持 'scheduled'（不改 'adopted'，'adopted' 留給後續另議）

---

## 4. Regression

### 4.1 既有零售價設定不受影響
- [ ] 對既有 sku 呼叫 rpc_set_retail_price，能照常寫入、不被新 RLS 擋

### 4.2 既有 sku_retail_prices view（如有）未崩
- [ ] 商品列表的零售價欄仍正確顯示

### 4.3 既有 group_buy_campaigns 列表
- [ ] 既有 status='open'/'closed'/... 開團在「列表」tab 仍正常顯示
- [ ] 既有開團詳情頁未受影響（campaign_items / channels CRUD 仍可用）

### 4.4 既有候選池其他動作
- [ ] 收藏 / 忽略 / 還原 / 補資料 仍能用

### 4.5 既有 community-bot-ingest Edge Function
- [ ] LINE 機器人 ingest 一筆新 candidate 仍正常寫入（沒被本次改動波及）

### 4.6 既有 rpc_adopt_candidate（若保留）
- [ ] 對舊已 adopted candidate 重呼仍 idempotent 回傳 product 資訊

### 4.7 sidebar 不破
- [ ] 移掉「週曆」子項後，sidebar render 正常、其他 nav 連結未壞

---

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push 成功**、**build + type-check 過** 才可標 done。

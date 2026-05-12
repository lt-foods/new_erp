# 訂單匯入測試項目 — Order Import (樂樂 CSV → external_order_imports → customer_orders)

**對應 migration（待建）：** `supabase/migrations/2026MMDDxxxxxx_order_import.sql`
**對應 UI 變更（待建）：**
- `apps/admin/src/app/(protected)/orders/import/page.tsx`（新頁面）
- `apps/admin/src/app/(protected)/orders/page.tsx`（加「匯入」入口）
- 共用 `apps/admin/src/lib/parseCsv.ts`（與 member-import 共用）

**對應 PRD：**
- `docs/PRD-訂單取貨模組-v0.2-addendum.md`（樂樂 CSV 段）
- `docs/PRD-訂單取貨模組.md` §6（訂單來源）

**既有資產（要利用 / 補完）：**
- `external_order_imports` staging 表 @ `supabase/migrations/20260423120002_picking_waves.sql:88`
- `rpc_import_external_orders` 空殼 @ same file:401（要補完邏輯）
- `customer_orders` UNIQUE `(tenant_id, campaign_id, channel_id, member_id)` → 合併單規則
- `customer_order_sources` 表（append-only，記錄匯入來源）

---

## 1. Schema / Migration 層

### 1.1 ALTER `external_order_imports` 補欄位
- [ ] 加 `channel_id BIGINT REFERENCES line_channels(id)`（同批同 channel；現在 schema 缺）
- [ ] 加 `campaign_id BIGINT REFERENCES group_buy_campaigns(id)`（同上）
- [ ] 加 `parsed_member_id BIGINT REFERENCES members(id)`（match 結果）
- [ ] 加 `parsed_pickup_store_id BIGINT REFERENCES stores(id)`
- [ ] 加 `parsed_nickname TEXT`（樂樂 CSV 可能有 LINE 暱稱）
- [ ] 加 `validation_errors JSONB`
- [ ] 既有欄位（parsed_sku_id / parsed_customer_identifier / parsed_qty / parsed_amount / status / resolved_order_id）不改
- [ ] status CHECK 加值：`('pending','resolved','skipped','error','unresolved_member','unresolved_sku')`
  ```sql
  SELECT pg_get_constraintdef(oid) FROM pg_constraint
   WHERE conrelid='external_order_imports'::regclass AND contype='c';
  ```

### 1.2 Indexes
- [ ] `idx_eoi_campaign` ON `(tenant_id, campaign_id, status)`
- [ ] 既有 `idx_ext_imports_batch / idx_ext_imports_status` 保留

### 1.3 RPC signature
- [ ] 新增 `rpc_stage_external_order_import(p_batch_id TEXT, p_source TEXT, p_campaign_id BIGINT, p_channel_id BIGINT, p_rows JSONB) RETURNS JSONB`
- [ ] 補完既有 `rpc_import_external_orders(p_tenant_id, p_batch_id, p_campaign_id, p_operator)` 邏輯（不變簽名以維持相容）
- [ ] 新增 `rpc_resolve_import_member(p_import_id BIGINT, p_member_id BIGINT) RETURNS BIGINT`（admin 手動綁定 unresolved row）
- [ ] 新增 `rpc_cancel_external_order_import(p_batch_id TEXT) RETURNS JSONB`
- [ ] 全部 SECURITY DEFINER + `GRANT EXECUTE TO authenticated`
  ```sql
  SELECT proname, pg_get_function_arguments(oid)
    FROM pg_proc WHERE proname LIKE 'rpc_%_external_order%' OR proname='rpc_resolve_import_member';
  ```

### 1.4 RLS（HQ-only）
- [ ] 既有 `eoi_hq_all` 涵蓋新欄位
- [ ] 跨 tenant SELECT 取不到資料

---

## 2. RPC 行為（SQL 直測）

### 2.1 `rpc_stage_external_order_import` — 全 ok
**情境：** 樂樂 CSV 3 row，全部 phone 對得到 member、SKU 對得到 campaign_items、pickup_store code 對得到 stores
**預期：** staging 3 筆 status='pending'，parsed_member_id/parsed_sku_id/parsed_pickup_store_id 全填

### 2.2 phone 對不到 member → unresolved_member（不自動建會員）
**情境：** CSV 含一筆陌生 phone='0911999888'
**預期：** staging 該筆 status='unresolved_member'，parsed_member_id=NULL；不在 members 建任何 row

### 2.3 SKU 名稱模糊 match → unresolved_sku
**情境：** CSV 商品名「鳳梨酥10入」，campaign_items 內有「鳳梨酥(10入)」（括號差異）
**預期：** 視 match 策略而定 → 完全 match 失敗時標 'unresolved_sku'，validation_errors 標出原文；admin 可手動 resolve

### 2.4 pickup_store_code 找不到
**情境：** CSV 取貨店 code='STORE_999'
**預期：** status='error'，validation_errors 含 `{ field: 'pickup_store', code: 'not_found' }`

### 2.5 campaign 不在 open/closed 狀態 reject
**情境：** campaign 已 status='completed'，呼叫 stage
**預期：** RAISE EXCEPTION 'campaign is in status completed, cannot import'（沿用既有檢查）

### 2.6 channel 不在 campaign_channels reject
**情境：** channel_id 沒掛在該 campaign
**預期：** RAISE EXCEPTION 'channel not associated with campaign'

### 2.7 數量 / 金額為 0 / 負數 reject
**情境：** parsed_qty=0 或 -1
**預期：** status='error'，validation_errors 含 `{ field: 'qty', code: 'invalid' }`

### 2.8 `rpc_import_external_orders` commit — 新建單 happy path
**情境：** batch 內 3 ok row（member A / B / C），同 campaign + channel
**預期：** 寫入 3 筆 customer_orders（pending）+ 3 筆 customer_order_items + 3 筆 customer_order_sources(source_type='csv')；staging row 標 'resolved' + resolved_order_id 填入

### 2.9 commit — 同會員同活動同頻道合併單（UNIQUE 規則）
**情境：** member A 已有訂單 OD-001 在 campaign X / channel Y；CSV 又匯入 member A 同 campaign 同 channel 的新項目
**預期：** **不**建新 customer_orders；把 customer_order_items append 到 OD-001；staging row resolved_order_id 指向 OD-001

### 2.10 commit — items 內含同 SKU 重複合併數量
**情境：** member A 同訂單兩 row 都是 SKU=S1，qty=2 + qty=3
**預期：** customer_order_items 合併為一筆 qty=5（或兩筆，依設計擇一明確記錄）

### 2.11 commit — unresolved_member rows 跳過
**情境：** batch 含 3 pending + 2 unresolved_member
**預期：** 只 commit 3 筆；unresolved 維持原 status，待 admin 手動 resolve

### 2.12 `rpc_resolve_import_member` — admin 手動綁
**情境：** unresolved_member row + admin 指定 member_id
**預期：** staging row 改 status='pending'、parsed_member_id 填入；下次 commit 會處理它

### 2.13 commit 防重入
**情境：** 同 batch_id commit 兩次
**預期：** 第二次只處理新進的 pending row（resolved 不重做），不重複建單

### 2.14 commit 跨 tenant reject
**情境：** 用 tenant B JWT 呼叫 batch_of_tenant_A
**預期：** 0 rows 命中或 RAISE EXCEPTION

### 2.15 customer_order_sources 寫入正確
**情境：** commit 完查 customer_order_sources
**預期：** source_type='csv'、raw_content 含原 CSV 內容片段、created_by=operator、order_id 對得起來

### 2.16 audit / created_by
**情境：** commit 後查 customer_orders 與 customer_order_items
**預期：** `created_by` 填入 operator UUID；`updated_by` 同上；created_at 在 commit 時間 ±5s

### 2.17 `rpc_cancel_external_order_import` — 取消未 commit 的 batch
**情境：** 未 commit 的 batch 呼叫 cancel
**預期：** staging row 全標 'skipped' 或刪除；commit 拒絕已 cancelled

### 2.18 cancel 已部分 commit 的 batch
**情境：** batch 內已有 resolved row（已建單）+ pending row，呼叫 cancel
**預期：** 已 resolved 的不動（保留 customer_orders）；剩下 pending 標 'skipped'

---

## 3. UI 行為（preview 互動）

### 3.1 `/orders/import` 頁面 mount
- [ ] 路由載入無 console error
- [ ] 標題「訂單匯入（樂樂 CSV）」可見
- [ ] 上方下拉選 campaign（只列 status in open/closed）+ channel（依 campaign 篩 campaign_channels）
- [ ] 「下載範本 CSV」按鈕 → 含正確欄位 header

### 3.2 必須先選 campaign + channel
- [ ] 沒選 campaign 時上傳按鈕 disabled
- [ ] 選了 campaign 後 channel 下拉刷新只列該 campaign 的 channels

### 3.3 檔案上傳 + 客端解析
- [ ] 上傳 CSV → 客端 papaparse 解析 → 顯示預覽（前 20 row + 分頁）
- [ ] xlsx 也可解析（呼叫 xlsx lib）
- [ ] 大檔 5k row 不 freeze

### 3.4 Stage → preview validation 結果
- [ ] 點「上傳到 staging」→ 呼叫 `rpc_stage_external_order_import`
- [ ] 預覽表格 refresh 顯示每 row 的 server-side validation status chip
- [ ] 統計列：「總 X / 可建單 Y / 待手動綁 Z / 錯誤 W」

### 3.5 Unresolved member 手動綁
- [ ] 每 unresolved_member row 旁有「指派會員」按鈕 → 開 modal 搜尋 member（phone / name / member_no）
- [ ] 選定後呼叫 `rpc_resolve_import_member` → row status 變 pending、chip 變綠
- [ ] 預覽刷新

### 3.6 Commit 按鈕
- [ ] 至少有 1 row pending 時 commit enable
- [ ] 點 commit → 二次確認 modal「將建 / 合併 N 筆訂單；M 筆 unresolved 仍留 staging」
- [ ] 確認後呼叫 `rpc_import_external_orders` → toast「已建 X 筆 / 合併到既有 Y 筆」
- [ ] 跳轉 `/orders?campaignId=...` 列表，新訂單可見

### 3.7 合併單視覺提示
- [ ] commit 完，預覽 row 顯示「合併到 OD-001」連結（resolved_order_id 對應）
- [ ] 點連結開 `/orders` 該訂單 detail

### 3.8 Cancel
- [ ] 「取消批次」按鈕 → 確認 → 呼叫 cancel RPC
- [ ] 已 resolved 的 row 保留標示「已建單」；pending 清空

### 3.9 個資遮罩
- [ ] 預覽表格 phone 顯示完整（admin 匯入 flow 需要 cross-check）
- [ ] 但若 row 有 line_user_id 欄位 → **馬賽克**為 `Uxxxxx...xxxxx`（依 memory）
- [ ] 樂樂 CSV 預設不含 line_user_id，但若未來 source='shopee' 含，仍須馬賽克

### 3.10 `/orders` 列表加入口
- [ ] 列表右上角加「批次匯入」按鈕 → 連 `/orders/import?campaignId=`（可帶當前 campaign）
- [ ] 既有訂單入單頁、清單、篩選不變

### 3.11 視覺一致性
- [ ] 用既有 `Table` 元件 + 白底（PR #209 後的規範）
- [ ] 「合併單」chip 用區隔色（如藍色）跟「新建單」chip（綠）區分

---

## 4. Regression

- [ ] `/orders` 列表頁原功能不變（多 campaign 篩選 / 標籤頁 / 取貨狀態）
- [ ] `/campaigns/order-entry` 手動入單頁不變
- [ ] `rpc_create_customer_orders` 不被覆寫
- [ ] `rpc_advance_order_status` 不變
- [ ] `rpc_record_pickup` 不變
- [ ] picking_waves 流程不受影響（匯入的訂單能被既有揀貨波次拉到）
- [ ] `customer_order_sources` append-only trigger 仍有效（嘗試 UPDATE 應 RAISE EXCEPTION）
- [ ] LIFF 顧客端訂單頁仍能看到新匯入的訂單（依 member_id RLS）

---

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**`supabase db push` 成功**、**`pnpm --filter admin build` + type-check 過** 才可標 done。

---

## 附註 — 兩個匯入功能的共用點

| 共用 | 細節 |
|------|------|
| CSV/Excel 解析 lib | `papaparse` + `xlsx` 各裝一次，`apps/admin/src/lib/parseCsv.ts` |
| Batch ID 生成 | client 端 `crypto.randomUUID()` |
| Validation chip 元件 | `apps/admin/src/components/ImportStatusChip.tsx` |
| 範本下載 | client 端組 CSV string 觸發 download |
| Audit | 全 RPC `created_by = auth.uid()` |

如要先實作哪個：建議**會員匯入先**（沒有外部依賴），完成後再做訂單匯入（依賴 member 已存在）。

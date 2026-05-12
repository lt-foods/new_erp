# 會員匯入測試項目 — 樂樂顧客 CSV → members

**對應 migration（待建）：** `supabase/migrations/20260613000010_member_import.sql`
**對應 UI 變更（待建）：**
- `apps/admin/src/app/(protected)/members/import/page.tsx`（新頁面）
- `apps/admin/src/app/(protected)/members/page.tsx`（加「匯入」入口）
- `apps/admin/src/lib/parseLeleMemberCsv.ts`（樂樂 CSV 專用解析）

**對應 PRD：**
- `docs/PRD-會員模組.md`
- `docs/BRIEF-Alex-2026-04-23-session.md` §2「樂樂 CSV 對應」（members.external_id + takeout_store_name_hint）

**參考實作：** `rpc_upsert_member` @ `supabase/migrations/20260425120000_core_crud_rpcs.sql:97`

**範例 CSV：** `C:\Users\Alex\Downloads\顧客管理-樂樂團購訂單管理系統.csv`（12,397 筆會員）

---

## 樂樂顧客 CSV 欄位 mapping

| CSV 欄位 | members 欄位 | 解析規則 |
|---|---|---|
| 顧客代號 | `external_id` | 直接複製字串（內部數字 ID）|
| 名字 | `name` + `notes`（後綴）| regex `^#(\d+)\s*[:：]\s*【(.+?)】\s*(.*)$` → 取 group2 = name；group3 = 後綴存 notes（若有）|
| 標籤 | `takeout_store_name_hint` + 嘗試對 `home_store_id` | 標籤 `—` 視為空；非空時設 hint，模糊比對 `stores.name` like 標籤% 唯一 match → `home_store_id` |
| 加入日期 | `joined_at` | TIMESTAMPTZ parse；`—` → NULL |
| 最後登入 | `last_visit_at` | TIMESTAMPTZ parse；`—` → NULL |
| 其他（錢包餘額 / 未結單 / 區間金額 / 未配單 …）| — | **不匯入**，本次任務 out-of-scope |

**固定值：** `external_source = 'lele'`、`status = 'active'`、phone 留 NULL（樂樂 CSV 不含）。

---

## 1. Schema / Migration 層

### 1.1 ALTER `members` 加欄位
- [ ] `external_source TEXT` (CHECK `IN ('lele','pinduoduo','1688','line_community','manual')`)
  ```sql
  SELECT column_name, data_type
    FROM information_schema.columns
   WHERE table_name='members' AND column_name='external_source';
  ```
- [ ] 既有 `external_id TEXT` 不動（已存在）
- [ ] 既有 `takeout_store_name_hint TEXT` 不動（已存在）

### 1.2 Unique partial index on members
- [ ] `uniq_members_tenant_extsrc_extid` ON `(tenant_id, external_source, external_id) WHERE external_id IS NOT NULL`
  ```sql
  SELECT indexname, indexdef FROM pg_indexes
   WHERE tablename='members' AND indexname LIKE '%external%';
  ```

### 1.3 新增 `member_imports` staging 表
- [ ] 欄位：`id, tenant_id, batch_id, row_index, source, raw_data JSONB, parsed_external_id, parsed_name, parsed_name_suffix, parsed_takeout_store_name_hint, parsed_home_store_id, parsed_joined_at, parsed_last_visit_at, parsed_notes, validation_status, validation_errors JSONB, resolved_member_id, audit columns`
- [ ] `source TEXT NOT NULL DEFAULT 'lele' CHECK (source IN ('lele','pinduoduo','1688','manual'))`
- [ ] `validation_status` CHECK `IN ('pending','ok','duplicate_existing','duplicate_in_batch','error','committed','cancelled','error_at_commit')`
- [ ] UNIQUE `(tenant_id, batch_id, row_index)`
  ```sql
  SELECT column_name, data_type, is_nullable FROM information_schema.columns
   WHERE table_name='member_imports' ORDER BY ordinal_position;
  ```

### 1.4 Indexes
- [ ] `idx_mi_batch (tenant_id, batch_id)`
- [ ] `idx_mi_status (tenant_id, batch_id, validation_status)`
- [ ] `idx_mi_ext (tenant_id, source, parsed_external_id)` WHERE parsed_external_id IS NOT NULL

### 1.5 RLS
- [ ] `mi_hq_all` policy（role in owner/admin/hq_manager）
- [ ] `auth_read_member_imports` 給 authenticated 同 tenant SELECT

### 1.6 RPC signature
- [ ] `rpc_stage_member_import(p_batch_id TEXT, p_source TEXT, p_rows JSONB) RETURNS JSONB`
- [ ] `rpc_commit_member_import(p_batch_id TEXT) RETURNS JSONB`
- [ ] `rpc_cancel_member_import(p_batch_id TEXT) RETURNS JSONB`
- [ ] 全 SECURITY DEFINER + `GRANT EXECUTE TO authenticated`

---

## 2. RPC 行為（SQL 直測）

### 2.1 `rpc_stage_member_import` — 全 ok（樂樂 CSV 典型 row）
**情境：** 3 row 都帶 external_id + 名字（含「【...】」格式）+ 標籤（對得到 store）+ 加入日期
**預期：** 回 `{ total:3, ok:3 }`；staging row parsed_name 正確抽出（如「Doris Wang」），parsed_home_store_id 填上對應 store

### 2.2 名字 regex 解析
**情境：** name 欄分別為：
  - `#18267783 : 【Doris Wang】969616-永和`
  - `#18266831 : 【妞妞】`
  - `#18251224 : 【小褕 🐟 牙牙】小褕 🐟 牙牙880804-平鎮2`
  - `#18217314 : 【868231-南平】`
**預期：** parsed_name = `Doris Wang` / `妞妞` / `小褕 🐟 牙牙` / `868231-南平`；parsed_name_suffix = `969616-永和` / NULL / `小褕 🐟 牙牙880804-平鎮2` / NULL

### 2.3 名字 regex match 失敗 fallback
**情境：** 名字欄為 `亂寫的格式`（沒 `#代號 : 【...】`）
**預期：** parsed_name = 原字串 trim 後；validation_errors 加 warning `name_format_unparsed`（不 fail，仍 ok）

### 2.4 標籤對應 home_store_id 唯一 match
**情境：** 標籤 = `永和`，stores 內有 `永和店`（name LIKE '永和%'）唯一
**預期：** parsed_home_store_id 填上；parsed_takeout_store_name_hint = '永和'

### 2.5 標籤多筆 match → 只填 hint
**情境：** 標籤 = `平鎮`，stores 有 `平鎮店` + `平鎮2店`
**預期：** parsed_home_store_id = NULL；parsed_takeout_store_name_hint = '平鎮'；validation_errors 加 warning `store_ambiguous`

### 2.6 標籤 = `—` （樂樂特殊空值）
**情境：** 標籤 = `—`
**預期：** parsed_takeout_store_name_hint = NULL；parsed_home_store_id = NULL；無 warning

### 2.7 external_id 必填
**情境：** row 沒帶顧客代號
**預期：** status='error'，errors 含 `{field:'external_id', code:'required'}`

### 2.8 dedupe — duplicate_existing（同 external_id 在 DB）
**情境：** members 已有 (tenant, external_source='lele', external_id='18267783')，再 stage 同 external_id
**預期：** status='duplicate_existing'，resolved_member_id = 既有 id

### 2.9 dedupe — duplicate_in_batch
**情境：** 同批兩 row 同 external_id
**預期：** 第一筆 ok，第二筆 duplicate_in_batch

### 2.10 加入日期 / 最後登入 parse
**情境：** `2026-05-12 18:59:33` / `—` / 空字串
**預期：** 第一個 → TIMESTAMPTZ；其餘 → NULL（無 error）

### 2.11 `rpc_commit_member_import` happy path
**情境：** 3 ok rows commit
**預期：** members 新增 3 筆（external_source='lele'、external_id、name、joined_at、last_visit_at、takeout_store_name_hint、home_store_id 全填）；member_no 自動生成；status='active'

### 2.12 commit 自動 member_no
**情境：** 樂樂 CSV 不帶 member_no
**預期：** 每筆 commit 都用 `rpc_next_member_no()` 生成（'M' + lpad）

### 2.13 commit — phone / phone_hash 留 NULL
**情境：** 樂樂 CSV 不含 phone
**預期：** members.phone IS NULL、members.phone_hash IS NULL；不違反任何 unique constraint

### 2.14 commit 防重入
**情境：** 同 batch 第二次 commit
**預期：** 已 committed row 不重做；只處理新進 ok row；回傳 committed=0 若無新 row

### 2.15 commit 觸發 unique violation（race）
**情境：** stage 時不存在的 external_id，commit 前另一 session 寫了同 external_id
**預期：** 該 row 標 'error_at_commit'，validation_errors 加 unique_violation；其他 row 不受影響

### 2.16 跨 tenant reject
**情境：** tenant B JWT 對 tenant A 的 batch 呼叫 commit
**預期：** 0 rows 命中或 RAISE EXCEPTION

### 2.17 `rpc_cancel_member_import`
**情境：** stage 後 cancel
**預期：** validation_status 全改 'cancelled'（已 committed 不動）

### 2.18 大批量壓測（接近實際資料）
**情境：** stage 一批 5,000 row（取樂樂 CSV 前 5k）
**預期：** 完成時間 < 30s；commit 完 members 增加 5,000 筆（若 dev DB 原本無此 external_id）

---

## 3. UI 行為（preview 互動）

### 3.1 `/members/import` 頁面 mount
- [ ] 載入無 console error
- [ ] 標題「會員匯入（樂樂顧客 CSV）」可見
- [ ] 「下載範本 CSV」按鈕 → 下載樂樂格式 header 的空 CSV

### 3.2 檔案上傳
- [ ] 接受 `.csv`
- [ ] 上傳樂樂實際 CSV（12k row）能客端解析（papaparse worker）不 freeze
- [ ] 解析中顯示 progress

### 3.3 預覽表格
- [ ] 顯示前 20 row + 分頁
- [ ] 每 row 顯示：external_id / parsed_name / hint / home_store / joined_at / status chip
- [ ] 統計列：「總 X / 可匯入 Y / 已存在 Z / 錯誤 W」

### 3.4 Stage 按鈕
- [ ] 點「上傳到 staging」→ 分批呼叫 `rpc_stage_member_import`（每批 500 row 避免 timeout）
- [ ] 進度條顯示批次進度
- [ ] 成功後從 staging 重抓資料刷新預覽

### 3.5 Commit 按鈕
- [ ] 至少 1 row ok 才 enable
- [ ] 點 commit → 二次確認 modal「將寫入 N 筆新會員」
- [ ] 確認後呼叫 `rpc_commit_member_import` → toast「成功匯入 N 筆」
- [ ] 跳轉 `/members?ordered=newest`，新會員可見

### 3.6 Cancel
- [ ] 「取消批次」→ 確認 → 呼叫 cancel RPC → staging 清空

### 3.7 個資遮罩
- [ ] 樂樂 CSV 不含 phone / line_user_id，預覽頁無遮罩問題
- [ ] **不允許** UI 顯示 line_user_id 欄位（即使未來 CSV 含也馬賽克）

### 3.8 `/members` 列表加入口
- [ ] 列表右上角加「批次匯入」按鈕 → 連 `/members/import`
- [ ] 既有「新增」按鈕不變

### 3.9 視覺一致性
- [ ] 用既有 `Table` 元件 + 白底
- [ ] chip 用既有 status color tokens

---

## 4. Regression

- [ ] `/members` 列表 / 詳情 / 新增編輯 modal 全部不變
- [ ] `rpc_upsert_member` 不被改 signature
- [ ] `rpc_register_member_via_liff` 不受影響
- [ ] `rpc_resolve_member` 仍可 phone 查（既有 plaintext member）
- [ ] LIFF 顧客端三頁不受影響
- [ ] members.phone_hash partial unique index 不被改回 NOT NULL
- [ ] 新增的 `external_source` + unique index 不影響既有 members（既有 row external_id IS NULL，partial index 不收）

---

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**`supabase db push` 成功**、**`pnpm --filter admin build` + type-check 過**、**用實際樂樂 CSV 完整跑一遍**（12,397 筆 stage + commit）才可標 done。

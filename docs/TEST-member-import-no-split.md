# 樂樂 CSV 匯入 — 名字不切割 / 整段塞入 members.name

**對應 migration（待建）：** `supabase/migrations/20260613000180_member_import_name_no_split.sql`

**動機：** 樂樂 CSV「名字」欄典型內容：

```
#15627428 : 【Vicky Hsu】209785-松山
#15417025 : 【Alex Chen】297810-松山
```

目前 `_parse_lele_name` 用 regex `^#(\d+)\s*[:：]\s*【(.+?)】\s*(.*)$` 切成 `name=Vicky Hsu`、`suffix=209785-松山`，
寫進 `members.name` 後使用者搜尋 `15627428` / `松山` / `209785` 全部都搜不到，違反「會員列表用整段字串搜尋」需求。

**修改：** `_parse_lele_name` 改成 **`name = TRIM(p_raw)`、`suffix = NULL`**（永遠不切割）。
既有 `external_source='lele'` 會員 + `member_imports` 一併回補（只動沒被手動編輯過的）。

---

## 0. 影響範圍

- `_parse_lele_name(TEXT)` immutable function 重新定義
- `rpc_stage_member_import` 不改 signature，但其呼叫 `_parse_lele_name` 後 `v_name = 整段`、`v_name_suffix = NULL`
  - 之後 `parsed_name = 整段` 寫進 staging
  - `parsed_notes = v_name_suffix = NULL`（之前是寫 suffix）
  - 之後 commit 寫進 `members.name = 整段`、`members.notes = NULL`
- 既有 lele 會員 / staging row 用 raw_data 回補
- UI 不動：`/members/import` 預覽 `parsed_name_suffix` 為 null 時自動 hide

---

## 1. Migration / Function 層

### 1.1 `_parse_lele_name` 不切割
- [ ] `SELECT _parse_lele_name('#15627428 : 【Vicky Hsu】209785-松山')` →
      `{"name":"#15627428 : 【Vicky Hsu】209785-松山","suffix":null}`
- [ ] `SELECT _parse_lele_name('  #1 : 【A】suf  ')` → `name = '#1 : 【A】suf'`（外圍空白 trim 掉）
- [ ] `SELECT _parse_lele_name(NULL)` → `{"name":null,"suffix":null}`
- [ ] `SELECT _parse_lele_name('   ')` → `{"name":null,"suffix":null}`
- [ ] `SELECT _parse_lele_name('純文字無格式')` → `{"name":"純文字無格式","suffix":null}`

### 1.2 既有 lele 會員回補
- [ ] 跑前 `SELECT count(*) FROM members WHERE external_source='lele' AND name !~ '^#\\d+'`（被切過的）
- [ ] 跑後同 query → 應降為 0（除非被手動編輯）
- [ ] 抽樣：對既匯入過的 external_id，`members.name` 與 `member_imports.raw_data->>'name_raw'` trim 後相同
- [ ] **未動到** 被手動編輯過的會員（`members.name <> 當初 parsed_name`）
- [ ] 抽樣：跑前後 `members.phone`、`members.member_no` 完全不變

### 1.3 既有 member_imports 回補
- [ ] `SELECT count(*) FROM member_imports WHERE source='lele' AND parsed_name !~ '^#\\d+'`（被切過）
- [ ] 跑後同 query → 應降為 0
- [ ] 抽樣：`parsed_name = TRIM(raw_data->>'name_raw')`、`parsed_name_suffix IS NULL`、`parsed_notes IS NULL`
- [ ] `validation_status` 不被動

### 1.4 不影響非 lele
- [ ] `member_imports WHERE source <> 'lele'` 0 row 被 UPDATE（lele 專用）
- [ ] `members WHERE external_source IS DISTINCT FROM 'lele'` 0 row 被動

---

## 2. RPC 行為（SQL 直測）

### 2.1 stage 新 row：整段塞 parsed_name
**情境：** stage `[{"external_id":"99999001","name_raw":"#99999001 : 【測試】123-松山","label":"松山","joined_at":"2026-05-13","last_visit_at":"","wallet_balance":""}]`
**預期：** `parsed_name = '#99999001 : 【測試】123-松山'`、`parsed_name_suffix IS NULL`、`parsed_notes IS NULL`

### 2.2 stage：name_raw 為空仍標 error
**情境：** `name_raw = ''` / NULL
**預期：** `validation_status='error'`、`validation_errors` 含 `{field:'name',code:'required'}`

### 2.3 commit 新 member：members.name 為整段
**情境：** 接 §2.1 commit
**預期：** `members.name = '#99999001 : 【測試】123-松山'`、`members.notes IS NULL`、`takeout_store_name_hint = '松山'`、`home_store_id` 對應到 / 自動建的 store

### 2.4 commit 更新既有 member（upsert）：name 用整段覆寫
**情境：** 既有 `members.name='Vicky Hsu'`（之前被切過的）+ external_id 衝突，重 stage + commit
**預期：** name 被覆寫為整段 `#... : 【Vicky Hsu】...`

### 2.5 搜尋
**情境：** `/members?q=15627428` / `q=松山` / `q=209785` / `q=Vicky`
**預期：** 全部 hit 同一筆會員

---

## 3. UI 行為（preview 互動，可選）

- [ ] `/members/import` 上傳新檔，預覽欄「姓名」顯示整段，不再出現 `／後綴` 灰字
- [ ] `/members` 列表搜尋 `15627428` 能找到對應會員

---

## 4. Regression

- [ ] `_parse_lele_timestamp` 不動
- [ ] `_resolve_or_create_takeout_store` 不動
- [ ] `rpc_stage_member_import` 其他欄位（external_id / store / joined_at / wallet）行為不變
- [ ] `rpc_commit_member_import` upsert 流程不變（只是 name 改成整段）
- [ ] 非 lele 來源（pinduoduo / 1688 / manual）走 stage 時 `_parse_lele_name` 仍 trim 整段（不影響也不切割）

---

## 5. 驗收門檻

§1-§4 全勾、`supabase db push` 成功、跑一次新樂樂 CSV 端到端確認 `members.name` 整段、`/members` 用 `15627428` / `松山` 搜得到。

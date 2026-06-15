# extend-campaign-deadline 測試項目 — 延長開團結單時間 RPC

**對應 migration:** `supabase/migrations/20260707000050_rpc_extend_campaign_deadline.sql`
**對應 UI 變更:** `apps/admin/src/app/(protected)/campaigns/page.tsx`（「延長結單」按鈕 + datetime modal）

---

## 1. Schema / Migration 層

### 1.1 RPC signature + grants
- [ ] `rpc_extend_campaign_deadline(BIGINT, TIMESTAMPTZ)` 存在、`SECURITY DEFINER`、`RETURNS timestamptz`
  ```sql
  SELECT prosecdef, pg_get_function_result(oid)
    FROM pg_proc WHERE proname = 'rpc_extend_campaign_deadline';
  ```
- [ ] `PUBLIC` 已 REVOKE、`authenticated` 有 EXECUTE
  ```sql
  SELECT grantee, privilege_type FROM information_schema.role_routine_grants
   WHERE routine_name = 'rpc_extend_campaign_deadline';
  ```
- [ ] 無新增 table / enum / index / column（僅 function）

---

## 2. RPC 行為（SQL 直測）

> 每個情境＝交易內 `set_config('request.jwt.claims', …, true)` 切身份 + seed 一筆 campaign，呼叫 RPC，觀察結果，結尾 `ROLLBACK`。

### 2.1 happy path — open 團往後延
**情境：** owner 身份，campaign status='open'、end_at = 明天；呼叫 RPC 把 end_at 改成 後天。
**預期：** 回傳新 end_at；該列 `end_at` = 後天、`updated_by` = 呼叫者 uid、`updated_at` 被刷新。

### 2.2 reject — 非 owner/admin
**情境：** role = 'staff'（或缺 app_metadata.role），open 團，新時間合法。
**預期：** RAISE `權限不足`（SQLSTATE 42501）；end_at 不變。

### 2.3 reject — 活動不存在 / 跨 tenant
**情境：** owner，但 p_campaign_id 屬於別的 tenant（或不存在）。
**預期：** RAISE `找不到開團或不在目前 tenant`；無任何列被改。

### 2.4 reject — status 非 open
**情境：** owner，campaign status='closed'（再測 'draft' / 'cancelled' 各一）。
**預期：** RAISE `僅「開團中」可延長`；end_at 不變（確認 closed 後快照不被動到）。

### 2.5 reject — 新時間在過去
**情境：** owner，open 團，p_new_end_at = 昨天。
**預期：** RAISE `新收單時間必須在未來`；end_at 不變。

### 2.6 reject — 新時間不晚於目前 end_at
**情境：** owner，open 團 end_at = 後天，p_new_end_at = 明天（早於目前但仍在未來）。
**預期：** RAISE `新收單時間必須晚於目前收單時間`；end_at 不變。

### 2.7 reject — p_new_end_at 為 NULL
**情境：** owner，open 團，p_new_end_at = NULL。
**預期：** RAISE `p_new_end_at is required`。

### 2.8 邊界 — 只動到目標那一筆
**情境：** 同 tenant 另有一筆 open 團；對第一筆呼叫 RPC。
**預期：** 第二筆 end_at / updated_at 完全不變（無誤傷）。

---

## 3. UI 行為（preview 互動）

### 3.1 按鈕可見性
- [ ] status='open' 且具 admin 權限 → row 操作區出現「延長結單」（teal 色）
- [ ] status≠open（draft/closed/…）→ 不出現「延長結單」
- [ ] 非 admin 角色 → 不出現（與其他 admin 操作鈕一致）

### 3.2 modal 互動
- [ ] 點「延長結單」開 modal，標題帶活動名稱，datetime 預填目前 end_at
- [ ] 未選時間按「確定延長」→ 顯示「請選擇新的收單時間」、不送出
- [ ] 選一個晚於目前的時間 → 送出成功、modal 關閉、列表 end_at 更新
- [ ] 後端 reject（如選過去時間）→ 錯誤訊息顯示在 modal 內、modal 不關

### 3.3 無 console error
- [ ] 開關 modal、送出全程 console 無 error

---

## 4. Regression
- [ ] campaigns 列表頁正常載入、分頁/篩選不受影響
- [ ] 既有 bulk「批次設定收單時間」modal 仍正常（共用 `fmtDateTime` / `Modal` / `SpinButton`）
- [ ] 結單（rpc_close_campaign）、結算、刪除等同列操作鈕不受影響
- [ ] `rpc_bulk_set_campaign_end_at` 行為不變（本 RPC 為新增、未動既有 function）

---

## 5. 驗收門檻

全部 §1–§4 勾完、**無 console error**、**RPC 已部署 prod 且 anon REST probe 確認存在**、**build + type-check 過** 才可標 done。

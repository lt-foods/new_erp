# campaign-bulk-end-at 測試項目 — 開團列表頁「批次設定收單時間」

**對應 migration:** `supabase/migrations/20260618000040_rpc_bulk_set_campaign_end_at.sql`
**對應 UI 變更:** `apps/admin/src/app/(protected)/campaigns/page.tsx`
**對應決策:** 開團狀態機單向（draft→open→closed→cancelled）— 收單時間僅收單階段可改

> 無新表 / 無 enum / 無 index；僅新增一支 RPC + 沿用既有多選 UI。

## 1. Schema / Migration 層

### 1.1 RPC signature + grants
- [ ] `rpc_bulk_set_campaign_end_at(p_ids BIGINT[], p_end_at TIMESTAMPTZ) RETURNS INTEGER` 存在、`SECURITY DEFINER`
  ```sql
  SELECT proname, prosecdef, pg_get_function_arguments(oid)
    FROM pg_proc WHERE proname = 'rpc_bulk_set_campaign_end_at';
  ```
- [ ] `PUBLIC` 已 REVOKE、`authenticated` 有 EXECUTE
  ```sql
  SELECT grantee, privilege_type FROM information_schema.routine_privileges
   WHERE routine_name = 'rpc_bulk_set_campaign_end_at';
  ```
- [ ] `COMMENT` 已設（說明同 tenant / 僅 draft|open / 回傳變更筆數）
- [ ] Supabase dev push 成功（self-contained：僅依賴 `group_buy_campaigns` + `_current_tenant_id()`）

## 2. RPC 行為（SQL 直測）

### 2.1 draft / open 正常更新
**情境：** 同 tenant，2 個 `draft` + 1 個 `open` 開團，傳三者 id + 未來 `p_end_at`
**預期：** 回傳 `3`；三筆 `end_at` = 傳入值、`updated_by` = caller、`updated_at` 已更新；其餘欄位（name/status/...）不變

### 2.2 非收單階段一律略過
**情境：** 各放一個 `closed` / `ordered` / `receiving` / `ready` / `completed` / `cancelled` 開團，連同一個 `open` 一起傳
**預期：** 回傳 `1`（只有 open 被改）；其餘 6 筆 `end_at` / `updated_at` 不變

### 2.3 跨 tenant / 不存在 id 略過
**情境：** 傳入「他 tenant 的開團 id」+「不存在的 id」+ 本 tenant 1 個 draft
**預期：** 回傳 `1`；他 tenant 開團完全未被觸碰（end_at / updated_at 不變）

### 2.4 p_end_at = NULL 報錯
**情境：** `p_end_at => NULL`
**預期：** `RAISE EXCEPTION`（p_end_at is required）；無任何 UPDATE

### 2.5 空 / NULL p_ids
**情境：** `p_ids => '{}'` 或 `NULL`
**預期：** 回傳 `0`，無副作用

### 2.6 回傳筆數 = 實際變更數
**情境：** 5 個 id，其中 2 個已是同一 `end_at`（值相同）、2 個 draft 改新值、1 個 closed
**預期：** 回傳為「狀態合法且實際執行 UPDATE」筆數（draft/open 一律算，closed 不算）；以 caller 角度可重跑得一致

### 2.7 anon 不可執行
**情境：** 以未登入 / anon role 呼叫
**預期：** 權限被拒（僅 `authenticated`）

## 3. UI 行為（preview 互動）

### 3.1 入口
- [ ] `/campaigns` 列表視圖勾選 ≥1 筆 → bulk bar 出現「批次設定收單時間」按鈕（藍色）
- [ ] 未勾任何項目時 bulk bar 不顯示（按鈕不可達）
- [ ] `bulkBusy`（批次開團/結單/取消進行中）時此按鈕 `disabled`

### 3.2 Modal
- [ ] 點按鈕 → 開「批次設定收單時間」Modal，顯示已選筆數
- [ ] 文案說明「僅草稿/開團中會更新，已收單之後自動略過」
- [ ] `datetime-local` 輸入可選日期時間
- [ ] 未填時間按「確定套用」→ modal 內顯示「請選擇收單時間」，不送出
- [ ] 「取消」關閉 modal、不改資料
- [ ] 確定送出期間按鈕為純 spinner（無「…中」字樣）

### 3.3 送出 happy path
- [ ] 選 draft/open 多筆 → 設時間 → 確定 → modal 關閉、選取清空、列表 reload
- [ ] 列表「收單」欄顯示為新時間
- [ ] 單筆「編輯」開啟確認 end_at 已更新（與 RPC 一致）

### 3.4 部分略過
- [ ] 混選 draft/open + closed/cancelled → 確定後成功；`console.info` 記錄 `changed / skipped`；closed/cancelled 那幾筆時間未變
- [ ] RPC 報錯（如 p_end_at NULL 邊界）→ 錯誤訊息顯示在 modal 內、選取不清空

## 4. Regression
- [ ] 既有「批次開團 / 批次結單 / 批次取消」仍正常（`rpc_bulk_set_campaign_status` 未動）
- [ ] 全選 / 單選 / 清除選取、選取列高亮、跨分頁選取行為不變
- [ ] 單筆編輯 `CampaignForm` 的 `end_at`（datetime-local）仍可存、與 list 一致
- [ ] `rpc_close_campaign` 仍以結單當下 `end_at` 推 PR 連動（closed 後不被批次改動影響）
- [ ] 月曆 / 未來 7 天視圖、搜尋 / 狀態篩選 / 分頁不受影響
- [ ] admin build + type-check 通過；無 console error

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**Supabase dev push（或 prod 貼上）成功**、**build + type-check 過** 才可標 done。
（沙箱無法跑 admin 登入 + 未套用 migration → 執行階段由使用者部署後依此清單自驗。）

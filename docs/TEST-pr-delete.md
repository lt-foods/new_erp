# pr-delete 測試項目 — 請購單(PR)刪除

**對應 migration:** `supabase/migrations/20260706000000_rpc_delete_pr.sql`
**對應 UI 變更:** `apps/admin/src/app/(protected)/purchase/requests/page.tsx`、`apps/admin/src/app/(protected)/purchase/requests/edit/page.tsx`
**基底慣例:** `rpc_delete_campaign`（20260630000020）— 守門 + 實體硬刪 + 殘參照丟可讀訊息

> 決策（使用者拍板）：可刪狀態＝草稿/送審中/已作廢；已拆 PO 一律擋；
> 刪除時**只解鎖團（locked→closed）**，**顧客訂單一律維持 confirmed 不動**。

## 1. Schema / Migration 層

### 1.1 RPC signature
- [ ] `rpc_delete_pr(BIGINT, UUID)` 存在、RETURNS void、SECURITY DEFINER
  ```sql
  SELECT proname, prosecdef, pg_get_function_arguments(oid), pg_get_function_result(oid)
    FROM pg_proc WHERE proname = 'rpc_delete_pr';
  ```
- [ ] 權限：`REVOKE ALL FROM PUBLIC` + `GRANT EXECUTE TO authenticated`
  ```sql
  SELECT grantee, privilege_type FROM information_schema.routine_privileges
   WHERE routine_name = 'rpc_delete_pr';
  -- 預期 authenticated/EXECUTE，無 PUBLIC
  ```

### 1.2 不動 schema
- [ ] 本 migration 不新增/改任何表、欄位、CHECK、index、trigger（純 RPC）
- [ ] 既有 FK 仍在：`purchase_request_items.pr_id` / `purchase_request_campaigns.pr_id` 為 ON DELETE CASCADE
  ```sql
  SELECT conname, confdeltype FROM pg_constraint
   WHERE conrelid IN ('purchase_request_items'::regclass,'purchase_request_campaigns'::regclass)
     AND contype='f' AND confrelid='purchase_requests'::regclass;
  -- confdeltype = 'c' (CASCADE)
  ```

## 2. RPC 行為（SQL 直測）

### 2.1 draft PR 可刪 + items 連帶 CASCADE
**情境：** source_type=manual 的 draft PR，含 2 個 items（po_item_id 皆 NULL），無 campaign 關聯。
**預期：** 呼叫成功；purchase_requests 該列消失；其 purchase_request_items 一併消失（CASCADE）。

### 2.2 submitted PR 可刪
**情境：** status=submitted、review_status=pending_review 或 approved、未拆 PO。
**預期：** 刪除成功、列消失。

### 2.3 cancelled PR 可刪
**情境：** status=cancelled 的 PR。
**預期：** 刪除成功。

### 2.4 已拆 PO 擋下（status 守門）
**情境：** status='partially_ordered'（或 'fully_ordered'）。
**預期：** RAISE，訊息中文表示「已拆 PO 不可刪」；PR 與其 PO 皆不動。

### 2.5 已拆 PO 擋下（po_item_id 雙重保險）
**情境：** 人為把 status 留在 draft 但某 item.po_item_id 指向實際 PO item。
**預期：** 仍 RAISE 擋下（不靠 status 單一條件）。

### 2.6 解鎖團：關聯 locked campaign → closed，訂單不動
**情境：** close_date PR 關聯 2 個 campaign（皆 status='locked'），各有 confirmed 訂單。
**預期：** 刪 PR 後兩 campaign 變回 'closed'；customer_orders 仍為 confirmed（一筆都沒退回 pending）。

### 2.7 解鎖只動 locked，不誤傷其他狀態
**情境：** PR 關聯兩 campaign，一個 locked、一個已被推進到別的狀態（如 finalized/closed）。
**預期：** 只有 locked 那個被改成 closed；另一個維持原狀態。

### 2.8 manual/blank PR（無 campaign 關聯）直接刪
**情境：** rpc_create_pr_blank 建的 PR，purchase_request_campaigns 無列、source_campaign_id NULL。
**預期：** 解鎖步驟影響 0 列、PR 正常刪除、無錯誤。

### 2.9 source_campaign_id（單一團 PR，非 join 表）也解鎖
**情境：** source_type='campaign' 的 PR，campaign 關聯記在 purchase_requests.source_campaign_id（join 表可能無列），該 campaign locked。
**預期：** 該 campaign 一樣被解鎖回 closed（解鎖來源涵蓋 join 表 UNION source_campaign_id）。

### 2.10 restock 來源 PR 擋下
**情境：** restock_requests.linked_pr_id 指向某 PR（補貨審核成 PR）。
**預期：** RAISE，中文訊息引導「從補貨流程處理」；PR 不刪、restock_requests 不受影響。

### 2.11 not found / 跨 tenant
**情境：** 不存在的 p_pr_id；或他 tenant 的 PR id。
**預期：** RAISE「not found」；跨 tenant 視為找不到、不刪到別 tenant 資料。

### 2.12 role 守門
**情境：** JWT app_metadata.role 為 store_staff/store_manager（非 owner/admin/hq_manager 且非空）。
**預期：** RAISE permission denied；PR 不動。（空字串 role 放行，對齊既有 restock RPC pattern）

### 2.13 殘留無 CASCADE 參照 → 可讀訊息
**情境：** 人為製造一筆無 ON DELETE CASCADE 的殘參照指向該 PR（模擬未預期關聯）。
**預期：** 捕捉 foreign_key_violation、RAISE 可讀中文訊息（非原始 FK 錯誤字串）。

## 3. UI 行為（preview 互動）

### 3.1 列表動作欄「刪除」
- [ ] /purchase/requests 載入無 console error
- [ ] draft / submitted / cancelled 列：動作欄出現「刪除」(danger) 鈕
- [ ] partially_ordered / fully_ordered 列、或 progress.po_total>0：**不顯示**刪除鈕
- [ ] 點刪除 → confirm 對話框；取消則不動
- [ ] 確認後呼叫 rpc_delete_pr → 該列從清單消失（reload）、KPI 數字更新
- [ ] 刪除進行中為 spinner、無文字

### 3.2 編輯頁刪除
- [ ] /purchase/requests/edit?id=… 對可刪狀態顯示刪除鈕
- [ ] 刪除成功 → 導回 /purchase/requests 列表
- [ ] 對已拆 PO 的 PR：刪除鈕不顯示（或停用）

### 3.3 錯誤回饋
- [ ] 後端 RAISE（如競態下變成已拆 PO）→ 前端顯示中文錯誤、列表不破版

## 4. Regression
- [ ] PR 審核「通過/退回」(rpc_approve/reject_purchase_request) 照常
- [ ] PR 退回草稿 rpc_pr_reopen 照常
- [ ] 拆 PO rpc_split_pr_to_pos 照常；已拆 PO 的 PR 與其 PO 不被刪除功能影響
- [ ] 解鎖回 closed 的 campaign 可再次被「結單日待開單 / 針對團購建單」重新彙總建 PR
- [ ] 採購單列表 /purchase/orders 不受影響
- [ ] 補貨 inbox（restock）流程不受影響（restock PR 擋在刪除外）

## 5. 驗收門檻

全部 §1-§4 勾完、**無 console error**、**migration 套用成功**、**admin build + type-check 過** 才可標 done。
（§3 UI 受 sandbox 限制時走 build + 碼審 + 使用者自審；§2 在拋棄式切片容器實跑。）

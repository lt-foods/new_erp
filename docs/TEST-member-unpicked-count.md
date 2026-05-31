# member-unpicked-count 測試項目 — 會員列表「已到貨未取貨」欄位 + 排序

**對應 UI 變更:** `apps/admin/src/app/(protected)/members/page.tsx`
**對應後端:** 新 view `public.v_admin_member_list`（members + 聚合 unpicked_order_count）
**對應 migration:** `supabase/migrations/20260701020000_v_admin_member_list.sql`

## 1. Schema / Migration 層

- [ ] migration apply 成功，`v_admin_member_list` view 建立
- [ ] `SELECT column_name FROM information_schema.columns WHERE table_name='v_admin_member_list'` 包含 members 全部欄位 + `unpicked_order_count`
- [ ] view 屬性 `security_invoker = true`（`pg_views` 或 `pg_class.reloptions` 可驗）
- [ ] `GRANT SELECT ON v_admin_member_list TO authenticated, anon` 已賦予（admin 用 anon key + JWT 可讀）

## 2. SQL 層直測

- [ ] `SELECT id, member_no, unpicked_order_count FROM v_admin_member_list ORDER BY unpicked_order_count DESC LIMIT 10` 返回排序正確
- [ ] 對某個有「ready」訂單的會員（已知 id），view 回傳的 `unpicked_order_count` = `SELECT COUNT(*) FROM customer_orders WHERE member_id=X AND status IN ('ready','partially_completed')`
- [ ] 對無訂單的會員 `unpicked_order_count = 0`（不是 NULL）
- [ ] 對只有 pending / confirmed / shipping 訂單的會員 `unpicked_order_count = 0`（貨還沒到店、不算到貨）
- [ ] 對只有 completed/cancelled/expired/transferred_out 訂單的會員 `unpicked_order_count = 0`
- [ ] `EXPLAIN ANALYZE` 對 sort by unpicked_order_count 走得到 `idx_corders_member`（status 為 leftmost prefix 第二欄，可 backward index scan）

## 3. UI 行為

### 3.1 欄位顯示
- [ ] 會員列表頁載入無 console error
- [ ] 表頭出現新欄「已到貨未取貨」（在「訂單數」與「未取貨金額」之間，置中右對齊）
- [ ] 列出的每位會員都顯示一個整數（無未取貨單 = 顯示 `0` 或 `—`）
- [ ] 與「未取貨金額」口徑「不同但更嚴」：本欄只算 ready / partially_completed，金額欄含 pending / confirmed / shipping；本欄 > 0 時金額一定 > 0，反之未必

### 3.2 排序
- [ ] 點欄位 header 一次：依此欄 asc 排序
- [ ] 再點一次：切到 desc
- [ ] desc 結果第一筆會員的未取貨單數 ≥ 第二筆 ≥ … 直到底端
- [ ] 切換到此排序時 page 重置為 1
- [ ] 其他欄位排序（更新、姓名、加入時間…）切換後仍可正常運作（regression）

### 3.3 與 filter / 搜尋共存
- [ ] 選取「全部門市」以外的某店 + 「已到貨未取貨」desc 排序 → 該店會員依未取貨單數降序
- [ ] 搜尋關鍵字 + 此欄排序 → 命中者依未取貨單數排序
- [ ] 共筆數正確（不會因 view 多算重複行）

## 4. Regression

- [ ] 其他欄位（訂單數、未取貨金額、儲值、加入時間、最後登入、更新）數值維持原狀
- [ ] 已合併 (merged) 會員的 chain 翻譯仍正確（搜尋命中舊檔 → 顯示翻譯後新檔）
- [ ] 已刪除 (deleted) 會員仍隱藏
- [ ] 樂樂 / LINE / 通知 三個 badge 仍正常顯示
- [ ] 分頁、查訂單、編輯、新增會員、批次匯入 按鈕仍正常
- [ ] 整頁筆數 (共 N 筆) 與 view 切換前一致（21958 上下）

## 5. 驗收門檻

§1–§4 全綠 + tsc + next build 過 + view 已部署 prod 才標 done。

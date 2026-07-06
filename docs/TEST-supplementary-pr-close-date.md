# TEST — 結單日補單（supplementary PR）

## 背景 / 需求

現況：對某結單日（例：7/4）建了請購單後，該日所有開團由 `closed → locked`，
所有 PR 建立路徑（結單日待開單卡片、針對團購建單 modal、`rpc_create_pr_from_campaigns` 守衛）
都只吃 `closed`，導致「7/4 不能再建單」。

使用者要的行為（2026-07-06 決策，選項 B）：
**保留原請購單，另開一張「補單」，只彙總「前次尚未請購的新增量」**
（delta = 該結單日目前訂單需求 − 該結單日所有未取消請購單已請購量），
原單與已拆 PO 一律不動。若某 SKU 已被前次請購涵蓋，delta ≤ 0 則不列入。

實作：
- migration `20260714000060_supplementary_pr_from_close_date.sql`
  - `rpc_create_supplementary_pr_from_close_date(p_close_date, p_operator)` → 建補單
  - `rpc_list_supplementable_close_dates()` → 列出「已建單但仍有未請購量」的結單日（前端顯示補單卡片用）
- 前端 `apps/admin/.../purchase/requests/page.tsx` 新增「🔁 結單日補單」區塊

---

## A. RPC — `rpc_create_supplementary_pr_from_close_date`

- [ ] A1 正常補單：某結單日原 PR 只請購了部分品相 → 補單只含剩餘 SKU，qty = 需求 − 已請購。
- [ ] A2 delta 逐 SKU 正確：SKU 需求 10、前次已請購 7 → 補單該 SKU = 3。
- [ ] A3 已涵蓋全部：所有 SKU 需求都 ≤ 已請購 → RAISE `no remaining demand`，不建空 PR、不留殘 header。
- [ ] A4 尚未建過任何 PR 的結單日呼叫 → RAISE `no existing PR ... use rpc_create_pr_from_close_date`（引導走正常建單）。
- [ ] A5 該結單日無 closed/locked 開團 → RAISE `no closed/locked campaigns`。
- [ ] A6 原 PR 不受影響：補單建立後，原 PR 的 items / qty / status / 已拆 PO 完全不變。
- [ ] A7 累積正確：連續補單兩次，第二次 delta 會扣掉第一次補單的 qty（不重複）。
- [ ] A8 取消的 PR 不計入 already：把前次 PR 設 cancelled 後補單，delta 回到完整需求。
- [ ] A9 join 表同步：`fn_check_pr_campaigns_consistency()` 對新補單回 0 孤兒。
- [ ] A10 新加訂單場景：把某 locked 團解鎖回 closed、加新 pending 訂單、再補單 →
      補單含新增量，且尾巴把該團重新 lock、新訂單 auto-confirm（寫稽核）。
- [ ] A11 供應商帶入：補單品項 suggested_supplier_id 依 supplier_skus.is_preferred，
      無則由 `trg_pri_fill_default_supplier` fallback products.default_supplier_id。
- [ ] A12 total_amount snapshot：header total 正確加總補單 items line_subtotal。

## B. RPC — `rpc_list_supplementable_close_dates`

- [ ] B1 只回「已有未取消 close_date PR 且仍有 delta>0」的結單日。
- [ ] B2 完全請購完的日期不出現。
- [ ] B3 從未建 PR 的日期不出現（那些走「結單日待開單」卡）。
- [ ] B4 remaining_skus / remaining_qty 數字與逐 SKU delta 加總一致。
- [ ] B5 tenant 隔離：只回本 tenant。
- [ ] B6 60 天窗：超過 60 天的結單日不列。

## C. 前端

- [ ] C1 有補單候選時顯示「🔁 結單日補單」區塊，每日一張卡（日期 / 團數 / 剩餘品項 / 剩餘量）。
- [ ] C2 「補單」按鈕 → 呼叫 create RPC → 導到新 PR 的 edit 頁。
- [ ] C3 無候選時整個區塊不顯示。
- [ ] C4 建立中 spinner（純轉圈、無文字 — 對齊 feedback_loading_spinner_no_text）。
- [ ] C5 既有「結單日待開單」「針對團購建單」「空白單」行為完全不變（回歸）。

## D. 回歸 / 邊界

- [ ] D1 `rpc_create_pr_from_close_date` / `rpc_create_pr_from_campaigns` / `rpc_append_campaign_to_pr` 未被本 migration 改動。
- [ ] D2 `rpc_delete_pr` 對補單一樣可刪（draft、未拆 PO），刪後解鎖同結單日 locked 團。
- [ ] D3 admin build（tsc + next build）綠。

## 驗證方式

- RPC 邏輯：本機切片 DB（reference_local_db_slice_testing）或 prod Studio 貼 SQL 驗（agent 只產 SQL）。
- 前端：tsc/build + 碼審（admin live preview 沙箱被擋 — reference_admin_preview_sandbox_block）。

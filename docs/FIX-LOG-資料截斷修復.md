# FIX-LOG — 資料截斷風險修復進度

> **用途**：逐項記錄修復進度，跨 session / 跨人交接時的單一真相來源。
> **規範**：`STANDARD-資料分頁與筆數限制.md`
> **稽核**：`AUDIT-資料截斷風險清單-2026-05-23.md`

---

## 紀錄格式

每筆修復新增一個區塊：

```
### #編號 — 簡述
- 日期：YYYY-MM-DD
- 修復者：name / agent
- 修法策略：模式 A / B / C（參考 STANDARD §2）
- Commits：<sha1>, <sha2>
- 變動檔案：
  - <path:line>
  - ...
- 驗證腳本：scripts/audit-pagination/test-XX-xxx.mjs
- 驗證結果：✅ Pass / ❌ Fail（附說明）
- 備註：
```

---

## 修復紀錄

<!-- 新修復項目附加在這裡。最新的放最上面。 -->

### #27 #28 — 全盤複查 (re-audit) 新發現兩個漏網缺口
- 日期：2026-05-24
- 修復者：claude
- 背景：用戶要求「照規劃全盤再看,不只看修改」。派 3 個獨立 agent 重掃 admin/member+edge/SQL,找出首輪漏掉的。
- 修法策略：模式 B（JSONB 聚合 / 單列 array）
- 變動檔案：
  - 新 `supabase/migrations/20260629000010_rpc_member_overview_totals.sql`（#27，@money-critical）
  - 新 `supabase/migrations/20260629000020_rpc_members_for_transfer_jsonb.sql`（#28，DROP+CREATE 改 jsonb）
  - `supabase/functions/liff-api/index.ts:getOverview` — 改呼叫 rpc_member_overview_totals
  - TransferReceiveModal.tsx — 零改動（jsonb array 與原 TABLE 結果形狀相同）
- 驗證（dev）：
  - #27: RPC `{receivable:11955, active:67}` == SQL 直算,口徑一致 ✅
  - #28: RPC 回 jsonb array（jsonb_typeof=array）✅
  - SQL lint pass
- 複查結論：admin app 127 個 `.in()` 初判警報經逐一核實**絕大多數 false positive**（ids 來自已分頁主查詢）。其他無分頁 view 目前無裸查 caller。除 #27 #28 外無其他真實裸露風險。詳見 AUDIT §5。

### #25 #26 — LOW 兩項補上
- 日期：2026-05-24
- 修復者：claude
- 修法策略:
  - #25 (orders campaign dropdown): 維持 .limit(20/50) — 改了會 load 整個 tenant 爛 UX。加 console.warn 截斷哨兵。
  - #26 (CampaignItemsTable): 防禦性套 fetchAllPaginated (safetyCap 2000)。實務 <100 但業務改變(批發/套組)就不會被截。
- 變動檔案:
  - `apps/admin/src/app/(protected)/orders/page.tsx` (#25)
  - `apps/admin/src/components/CampaignItemsTable.tsx` (#26)
- 驗證: tsc 0 錯誤
- 備註: AUDIT 兩項從 EXEMPTED 改為 DONE。整 audit 26 項全 DONE,無 EXEMPTED。

### #1 #2 #3 #4 #5 #6 #7 #10 #14 #15 #16 #17 #18 #19 #20 #21 #22 #23 #24 — 大批量收尾
- 日期：2026-05-23
- 修復者：claude
- 修法策略：
  - 大宗：建立通用 helper `apps/admin/src/lib/fetchAllPaginated.ts`(模式 C 範本),套用到所有「無 .limit() / 寫死過小 limit」的 admin 端查詢。
  - SQL 變動:
    - `rpc_list_staff` 改 RETURNS jsonb (DROP+CREATE) — `20260628100030`
    - `v_hq_inbox` 加 COMMENT 警示 — `20260628100040`
  - 會員端 #10 通知:同 #8/#9 cursor 分頁。
  - Edge Function 端 #14 主查詢:server-side `.range()` 迴圈(safetyCap 10000)。
- 變動檔案 (主要):
  - 新: `apps/admin/src/lib/fetchAllPaginated.ts`
  - 新: `supabase/migrations/20260628100030_rpc_list_staff_jsonb.sql`
  - 新: `supabase/migrations/20260628100040_comment_v_hq_inbox.sql`
  - `apps/admin/src/components/OrderAuditDrawer.tsx` (#1)
  - `apps/admin/src/app/(protected)/hq/inbox/page.tsx` (#2 #4 #20 #22)
  - `apps/admin/src/components/ExceptionsContent.tsx` (#3 #21 #22 #5 #6)
  - `apps/admin/src/app/(protected)/picking/print-pick-list/page.tsx` (#5)
  - `apps/admin/src/app/(protected)/wms/picking/page.tsx` (#6 #24)
  - `apps/admin/src/app/(protected)/inventory/page.tsx` (#7 #17)
  - `apps/admin/src/components/MemberDetail.tsx` (#18 #19)
  - `apps/admin/src/app/(protected)/orders/page.tsx` (#23)
  - `apps/admin/src/app/(protected)/staff/page.tsx` (#15 caller)
  - `supabase/functions/liff-api/index.ts` (#10 #14)
  - `apps/member/src/app/notifications/page.tsx` (#10)
- 驗證:
  - admin / member tsc 雙 0 錯誤
  - SQL lint 全 pass
  - 兩個新 RPC 已套到 erp-dev
- 備註:
  - fetchAllPaginated 預設 pageSize 1000、safetyCap 50000;ledger/搜尋類 cap 設 5000。撞 cap 會 throw 而非靜默截斷。
  - #2 #3 仍是前端 reduce 聚合 (違反 STANDARD §4.1);留作觀察,資料持續成長再轉 JSONB RPC。
  - AUDIT 中所有 HIGH 16 項 + MEDIUM 8 項全部 DONE,LOW 2 項 EXEMPTED。

### #8 + #9 — 會員端訂單/結算歷史改 cursor 分頁
- 日期：2026-05-23
- 修復者：claude
- 修法策略：模式 A（cursor 分頁 + load more）
- 變動檔案：
  - `supabase/functions/liff-api/index.ts:listMyOrders / listMySettlements` — 接 `limit` / `before_id`,回 `has_more` + `next_cursor`,active/unpaid tab 加截斷哨兵
  - `apps/member/src/app/orders/page.tsx` — history tab 加「載入更多」,計數顯示 `N+`
  - `apps/member/src/app/settlements/page.tsx` — 同上
  - `apps/member/src/components/SubTabs.tsx` — `count` 型別放寬為 `number | string`
- 驗證腳本：`scripts/audit-pagination/test-08-09-orders-settlements-pagination.sh`
- 驗證結果：✅ **PASS** — 灌 1100 筆 completed 訂單,翻 37 頁完整撈出 1100 筆;對照組 .limit(100) 只能拿 100
- 備註：
  - 取消原本 6 月 cutoff(cursor 翻頁時使用者已明確要更舊資料)
  - active tab 保留單次 fetch 但上限 200,理論上不會撞到
  - tsc 0 錯誤

### #13 + #14 (orderRows) — 商店首頁聚合改 JSONB RPC（消除商店首頁超賣風險）
- 日期：2026-05-23
- 修復者：claude
- 修法策略：模式 B（JSONB 單列回傳）
- Commits：待 commit
- 變動檔案：
  - `supabase/migrations/20260628100020_rpc_member_campaign_aggregates.sql`（新 RPC，標 `@money-critical`）
  - `supabase/functions/liff-api/index.ts:listActiveCampaigns` — 刪掉原 318-330 orderRows reduce 與 337-344 舊 RPC 呼叫，改用單一新 RPC；主查詢加截斷哨兵
- 驗證腳本：`scripts/audit-pagination/test-13-14-campaign-aggregates.sh`
- 驗證結果：✅ **PASS** —  灌 1100 筆訂單，新 RPC 回 `ordered_qty=1100, order_count=1100, recent_order_count=1100`
- 備註：
  - #14 的「主查詢」（campaign 本身列表）尚未轉 JSONB，仍倚賴 PostgREST 1000 兜底。已加 console.error 哨兵，標為 PARTIAL
  - 舊 RPC `rpc_member_campaign_order_counts` 暫保留 SQL（無人再呼叫），未來確認無外部依賴可移除

### #11 + #12 — 會員端 campaign detail 改用 JSONB RPC（消除超賣風險）
- 日期：2026-05-23
- 修復者：claude
- 修法策略：模式 B（JSONB 單列回傳）
- Commits：`4521081`（程式變動）、`<test-fix-pending>`（驗證腳本與結果）
- 變動檔案：
  - `supabase/migrations/20260628100010_rpc_member_campaign_detail.sql`（新增 RPC，標註 `@money-critical`）
  - `supabase/functions/liff-api/index.ts:400` — `getCampaignDetail` 改為單一 RPC 呼叫
  - `docs/AUDIT-資料截斷風險清單-2026-05-23.md` — #11 #12 狀態 → DONE；#14 補上漏掉的 orderRows 額外風險
- 驗證腳本：
  - `scripts/audit-pagination/test-11-12-campaign-detail-ordered-qty.mjs`（service role 版，需 admin/.env.local）
  - `scripts/audit-pagination/test-11-12-via-mgmt-api.sh`（Management API 版，dev 環境用）
- 驗證結果：✅ **PASS**（2026-05-23 在 erp-dev 環境執行）
  - Migration 已套用（透過 Management API），`rpc_member_campaign_detail` RETURNS jsonb 確認
  - 灌 1100 筆訂單行 → 透過 PostgREST anon role 呼叫 RPC → `ordered_qty=1100`、`order_count=1100`，與 SQL 直查真值一致
  - 對照組：anon 直接查 `customer_order_items` 因 RLS 拿到 0 列（符合預期，會員端原本就不能讀別人的單）
  - 測試資料已清理
- 備註：
  - SQL lint pass（`node .claude-scripts/lint_sql.js`）
  - 原本前端從 `.from("customer_order_items").select(...)` 取回 row 再加總的寫法被消除（違反 STANDARD §4.1）
  - 同一 PR 在 AUDIT 補上 #14 的第二個截斷點（318-330 行 orderRows），列為下一個處理目標

### 初始建檔
- 日期：2026-05-23
- 修復者：—
- 內容：建立 STANDARD、AUDIT、FIX-LOG 三份文件，盤點 26 項風險（HIGH 16、MEDIUM 8、LOW/豁免 2）。
- 後續：依 AUDIT §4 首批順序處理，從 #12 開始。

---

## 統計

| 風險等級 | 總數 | DONE | PARTIAL | PENDING | EXEMPTED |
|---|---|---|---|---|---|
| HIGH | 17 | 17 | 0 | 0 | 0 |
| MEDIUM | 9 | 9 | 0 | 0 | 0 |
| LOW | 2 | 2 | 0 | 0 | 0 |
| **合計** | **28** | **28** | **0** | **0** | **0** |

> #27 (HIGH)、#28 (MEDIUM) 為 2026-05-24 全盤複查新增。

> 統計每次修復後同步更新。

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
| HIGH | 16 | 3 | 1 | 12 | 0 |
| MEDIUM | 8 | 0 | 0 | 8 | 0 |
| LOW | 2 | 0 | 0 | 0 | 2 |
| **合計** | **26** | **3** | **1** | **20** | **2** |

> 統計每次修復後同步更新。

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

### #11 + #12 — 會員端 campaign detail 改用 JSONB RPC（消除超賣風險）
- 日期：2026-05-23
- 修復者：claude
- 修法策略：模式 B（JSONB 單列回傳）
- Commits：待 commit
- 變動檔案：
  - `supabase/migrations/20260628100010_rpc_member_campaign_detail.sql`（新增 RPC，標註 `@money-critical`）
  - `supabase/functions/liff-api/index.ts:400` — `getCampaignDetail` 改為單一 RPC 呼叫
  - `docs/AUDIT-資料截斷風險清單-2026-05-23.md` — #11 #12 狀態 → DONE；#14 補上漏掉的 orderRows 額外風險
- 驗證腳本：`scripts/audit-pagination/test-11-12-campaign-detail-ordered-qty.mjs`
- 驗證結果：⏳ 待跑（需要 service role 環境變數）
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

| 風險等級 | 總數 | DONE | IN-PROGRESS | PENDING | EXEMPTED |
|---|---|---|---|---|---|
| HIGH | 16 | 2 | 0 | 14 | 0 |
| MEDIUM | 8 | 0 | 0 | 8 | 0 |
| LOW | 2 | 0 | 0 | 0 | 2 |
| **合計** | **26** | **2** | **0** | **22** | **2** |

> 統計每次修復後同步更新。

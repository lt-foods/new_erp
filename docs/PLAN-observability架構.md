# PLAN — Observability 架構

> 狀態：**規劃中**，尚未實作。這份只定架構與優先順序，Phase 1 動手前請 Alex 過目。

---

## 0. 一句話

這系統沒有維運團隊、也沒有 Grafana/Datadog 這類基礎設施——所有「觀測」目前是
Alex 出事後叫 Claude session 現查 Management API。目標不是導入一整套監控平台，
而是把「現查」的診斷 SQL 常駐成排程，事故**發生當下**就有人（Claude Routine）
先看到，而不是等 Alex 回報或下次剛好有人重跑那支 verify SQL。

---

## 1. 現況（已經有的，不用重做）

| 層 | 現有機制 |
|---|---|
| 前端錯誤 | `client_error_logs` + `ErrorLogger`（僅 apps/member，`20260803000010`） |
| 前端存活 | `bootGuard.ts`（ES5，framework chunk 全滅時的最後防線） |
| 前端相容性 | `check-bundle-browser-support.mjs`、`check-boot-guard-es5.mjs`（build-time gate） |
| 在線人數 | `app_presence` + `rpc_online_stats`（`20260827010000`，admin 儀表板卡片） |
| DB 排程 | 既有 `pg_cron` job 若干（過期團購自動關閉、互助板到期清除…） |
| QPS/API 量 | 不重做，用 Supabase Dashboard → Reports（現成的） |

沒有的：任何一種「線上跟 repo 是否一致」「效能有沒有退化」「業務單據卡住」的
**自動巡檢**——這三類全部是本檔開頭累積的事故根因。

---

## 2. 要接住的事故類型（對應 CLAUDE.md 累積的教訓）

1. **Repo/線上脫鉤**：套過 SQL 沒進 main（PR base 選錯）、或進了 main 沒真的套上線
   （migration 檔頭「已實測」≠ 已部署）。兩次都是脫鉤超過一週才被發現。
2. **效能悄悄退化**：純效能 migration 沒套，症狀只是「慢」，沒人報。9 天後
   把 Micro(1GB) 壓到 OOM，全站當機兩次才被回溯出來。
3. **單據卡住沒人知道**：訂單卡 `confirmed`/`partially_completed` 不動、
   `backorder_at` 沒有自動解除路徑、狀態機某個角色的按鈕被拿掉後沒人推得動。
   這類全部是「畫面上不會報錯，只是安靜地不動」，能卡 6～13 天才被回報。
4. **閘門邏輯的隱性放行**：qty-blind 的豁免路徑（Path A/D/D'）在特定組合下
   會放行不該放行的取貨，只能靠人工回報「怎麼還能取貨」才發現。

四類的共同點：**沒有東西在 blast radius 還小的時候主動說話**，全部靠事後
人工回報或下一次剛好手動查。

---

## 3. 架構：四層巡檢 + 一個通知管道

不新增基礎設施（沒有 Grafana/Prometheus 的操作與帳號成本），全部用現有的
Management API + pg_cron + 既有 LINE OA 推播機制組出來。

```
┌─────────────────────────────────────────────────────────┐
│ Layer A  部署一致性        repo migrations ⇄ 線上 schema  │
│ Layer B  DB 效能回歸       pg_stat_statements 週期採樣     │
│ Layer C  業務健康檢查      stuck-state SQL 集合            │
│ Layer D  前端錯誤          client_error_logs 擴到 admin    │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
              ops_health_checks（結果落地表，存歷史/防重複通知）
                          │
                          ▼
        Claude Routine（daily cron）跑健檢 → 有異常才推播
                          │
                          ▼
          LINE 推給 Alex（複用 admin-line-push 現有機制）
          ＋ /admin/ops-health 頁面（人要細看時才點進去）
```

### Layer A — 部署一致性

新增 `scripts/check-deploy-drift.mjs`：

- 對「近 N 天有變動」的 function / view，用 Management API 查
  `pg_get_functiondef` / `pg_get_viewdef`，跟 repo 裡最新一支相關 migration
  的 `CREATE OR REPLACE` 內文做正規化後比對（去空白/註解後 hash）。
- 對「近 N 天 merge 進 main 的 migration 檔」，反查線上是否真的存在對應物件
  （函式簽章、view 名稱、新表）。
- 兩個方向都要有：**repo 有線上沒有**（進 main 沒套）與
  **線上有 repo 沒有**（套了沒進 main，或直接在 SQL Editor 手改）。

跑法：CI 不行（連不到正式庫），走 daily Routine（見下方通知管道）。

### Layer B — DB 效能回歸

不做即時監控，做「週期採樣＋比對前一次」：

- 排程呼叫 Management API 查 `pg_stat_statements`，取
  `calls / total_exec_time / mean_exec_time`，依 `queryid` 存一份快照。
- 跟上一次快照比，`mean_exec_time` 顯著上升（例如 >2 倍且 calls 夠多、
  排除單筆 outlier）的查詢列出來。
- 目的不是抓單次慢查詢，是抓「這支東西上週 5ms、這週 50ms 但沒人管」——
  正是 8/18 那次 OOM 的模式。

### Layer C — 業務健康檢查

把 CLAUDE.md 裡已經寫死的診斷 SQL（本來就是事後在用的那幾支）改成常駐巡檢，
每支對應一種「安靜卡住」：

| 檢查 | 對應教訓 |
|---|---|
| `confirmed`/`partially_completed` 超過 X 小時未變動，且無對應 transfer/AT 單 | 空中轉沒人能派貨、經總倉單卡 pending 沒人看得到 |
| `backorder_at` 已標超過 X 天未解除，且該 SKU 近期有到貨紀錄 | 少發配貨的旗標沒有自動解除路徑 |
| 取貨閘門 `true` 但 `_pickup_group_available < 0`（且非容器/offset 單） | Path A/D/D' 隱性放行 |
| 斷貨單（`status='cancelled' AND stockout_at IS NOT NULL`）超過 X 天未回復也未關閉 | 斷貨單堆積沒人清 |
| 互助認領 `customer_order_transfer_links.aid_board_id` 為空但來源是認領單 | 認領量沒還導致貼文庫存錯 |

每支查詢的「母體」定義直接抄 CLAUDE.md 裡已經驗證過的版本（例如 Path C 的
qty-blind 陷阱、`ACTIVE_STATUSES` 集合），不要重新發明——那些都是踩過雷校準過的。

結果寫進新表：

```sql
CREATE TABLE ops_health_checks (
  id BIGSERIAL PRIMARY KEY,
  check_name TEXT NOT NULL,
  severity TEXT NOT NULL,        -- info/warn/critical
  hit_count INT NOT NULL,
  sample_ids JSONB,              -- 前 20 筆，方便直接點進 admin 查
  checked_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

只在 `hit_count` 較上次**上升**或首次出現時才推播，避免每天洗版同一批
已知待處理項。

### Layer D — 前端錯誤

`client_error_logs` 的 schema/RPC 已經是通用的（`env` 欄位分 admin/member），
只是 apps/admin 沒接。直接照 `apps/member/src/lib/clientLog.ts` 的模式在
apps/admin 掛一份，不用新設計。

### 通知管道

沒有內部 Slack/Discord，兩個現成選項擇一或並行：

1. **Claude Routine**（本 session 就在用的機制）：daily cron 觸發，跑
   Layer A~C 的查詢，有異常才用一兩句話講重點（不列證據表格，按 CLAUDE.md
   的回覆風格），透過 push notification 或訊息告知 Alex。**這條最低成本，
   不用另外接 LINE token。**
2. `/admin/ops-health` 頁面：讀 `ops_health_checks` 畫成列表，Alex 想細看
   哪一類卡住可以自己點進去，不用等通知。

兩者互補：Routine 負責「有事發生時主動講」，頁面負責「Alex 想看時查得到」。
**不做**額外的 LINE OA 推播給 Alex 本人——那套是給客人用的，channel token
管理增加維運負擔，Routine 已經能推播。

---

## 4. Phase 1（建議先做，成本最低、對應最痛的事故）

1. Layer C 的健檢表 + 5 支 SQL（stuck confirmed、backorder 未解、閘門隱性放行、
   斷貨單堆積、互助量未還）——全部是 CLAUDE.md 裡現成驗證過的查詢，改寫成
   常駐版本工作量最小。
2. 建 `ops_health_checks` 表 + 一支 `rpc_run_health_checks()` 跑全部檢查。
3. 建 daily Routine 呼叫 Management API 跑 `rpc_run_health_checks()`，
   有異常才通知 Alex。
4. Layer D：apps/admin 接 `clientLog.ts` 同款模式。

## 5. Phase 2（次要，实作成本較高）

1. Layer A 部署一致性比對（需要處理 SQL 正規化去噪音，容易誤報）。
2. Layer B 效能回歸採樣（`pg_stat_statements` 快照需要額外一張歷史表，
   而且 Micro tier 上 `pg_stat_statements` 本身也吃資源，要控制採樣頻率）。
3. `/admin/ops-health` 頁面（Phase 1 先靠 Routine 通知就夠用，頁面是錦上添花）。

---

## 6. 不做的

- 不導入 Sentry/Datadog/Grafana 這類第三方 SaaS——現有規模一個人維運，
  多一個帳號多一份要顧的東西，且大多數事故的根因是「業務狀態機卡住」，
  不是「哪支 API 慢」，通用 APM 工具接不住這類問題。
- 不做即時（sub-minute）監控。目前所有事故的教訓都是「幾天內發現就好」，
  daily 巡檢已經比現況（沒有巡檢）快得多，不需要為此養一套即時 pipeline。

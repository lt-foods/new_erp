# PLAN — AI + SRE 工作流程

> 狀態：**規劃中**，尚未實作。依賴 `docs/PLAN-observability架構.md`（PR #868）的
> Layer C 健檢表 `ops_health_checks` 當輸入，這份定「查到異常之後誰做什麼」。

---

## 0. 一句話

這系統唯一的「維運人力」是 Alex 叫 Claude session 現查現修。現況每次都是
從零開始診斷（重新 grep migration 歷史、重新寫驗證 SQL），而且完全靠 Alex
主動開口才會有人去查。這份計畫把「查到 → 分級 → 修 → 驗證 → 部署 → 寫回
CLAUDE.md」定成固定流程，讓例行的、已知模式的問題不用等 Alex 開口，
同時劃清楚「Claude 可以自己動手」跟「一定要先問 Alex」的邊界。

---

## 1. 現況與缺口

已經有的（不用重做）：

- **CI/PR 收斂**：本 session 的 harness 規則本身就是一套 AI SRE 流程——
  `subscribe_pr_activity` 訂閱 PR、CI 紅了自動修、merge conflict 自動處理、
  review comment 自動接。這條**只管「程式碼要不要進 main」**，不管「進了
  main 之後有沒有套上線」。
- **事後寫回 CLAUDE.md**：這個習慣已經在做（本檔開頭一堆「已修」段落），
  只是全部發生在 Alex 主動追問之後，不是流程的固定步驟。
- **診斷工具**：`scripts/check-sql-syntax.cjs`（部署前語法驗證）、
  `pg_get_functiondef`/`pg_get_viewdef` 對線上驗證的習慣、
  `PROD-fix-*.sql` 一次性資料修復的慣例。

缺口：

1. **沒有人主動去查**——都是 Alex 先發現異常才會有 session 去看。
2. **沒有分級**——「可以自己修」跟「要先問」目前純靠當下 session 自己判斷，
   沒有寫下來的標準，容易因為判斷失誤搞出 2026-08-16 那種「以為是 bug、
   實際是母體沒濾」的誤判。
3. **沒有稽核記錄**——自動/半自動修過什麼，除了 git log 沒有集中的地方看。
4. **沒有 runbook**——每次都重新診斷，即使是同一種卡單模式。

---

## 2. 角色分工

| 角色 | 職責 | 對應機制 |
|---|---|---|
| **健檢 Routine** | 排程跑 `ops_health_checks`，把新異常/惡化的項目丟給診斷 session | Claude Code Remote Routine，daily/hourly |
| **診斷－修復 session** | 認領一個異常，跑 runbook 診斷、分級、Tier 1 就直接修，Tier 2 就整理好診斷結果去問 Alex | `create_session` 開一個乾淨 session，帶著異常的 `check_name` + 樣本 id |
| **PR 收斂**（既有機制） | 診斷－修復 session 開的 PR，由既有 steward/babysit 規則帶到綠燈、合併 | `subscribe_pr_activity` |
| **Alex** | 只在 Tier 2（會動到判斷、金流、安全性的事）被問，其餘看每日摘要或 `/admin/ops-health` | 通知 / push notification |

不要把自動修復塞進 Alex 平常聊天的那個 session——診斷是背景工作，
噪音（跑一堆 SQL、讀一堆 migration）不該洗掉 Alex 正在看的對話。
異常和結論才需要出現在 Alex 面前。

---

## 3. 流程五階段

```
① 偵測                ② 分級                ③ 修復                  ④ 驗證與部署          ⑤ 寫回
ops_health_checks  →  對照 runbook /   →  Tier 1: 直接修       →  同一天內：套上線   →  CLAUDE.md
新增/惡化的異常        分級標準（§4）        Tier 2: 整理診斷        + PR 進 main         追加一段
                                            結果，AskUser/推播      + pg_get_*def 讀回
                                            給 Alex 決定             驗證
```

### ① 偵測
沿用 `docs/PLAN-observability架構.md` 的 Layer A~D，不重複定義。

### ② 分級
先查 `docs/RUNBOOK-<check_name>.md` 存不存在：
- **有 runbook 且屬於 Tier 1** → 照 runbook 的修復程序直接做。
- **沒有 runbook，或屬於 Tier 2** → 診斷到有結論為止，寫成給 Alex 的
  精簡摘要（結論＋要他決定什麼，不要證據表格——照 CLAUDE.md 的回覆風格），
  用 `AskUserQuestion`（如果 Alex 就在看）或推播通知，等回覆才動手。
  **診斷本身永遠可以做**，只有「動手改資料/改程式碼」才需要按分級規則卡住。

### ③ 修復
Tier 1 的動作範圍限定在 runbook 裡寫好的**已知修復程序**（例如：套一支已經
存在、已經在別的情境驗證過的 helper function；或依照 `_settle_*`/`_restore_*`
這類既有的「收斂」函式模式新增一個小 migration）。不即興發揮新的資料修復邏輯——
即興修復是 Tier 2 的事，因為出錯的代價（2026-08 曾經因為母體沒濾對錯把好資料
當壞資料處理）比多等 Alex 一輪確認高。

### ④ 驗證與部署
完全照 CLAUDE.md 既有規則，不另立新規則：
1. `node scripts/check-sql-syntax.cjs` 過語法。
2. Management API 套上正式庫。
3. `pg_get_functiondef`/`pg_get_viewdef` 讀回驗證，不是只看「有沒有報錯」。
4. Migration 檔當天 commit、push、開 PR，base 選 main。
5. `subscribe_pr_activity` 交給既有 steward 流程帶到合併——
   `git log origin/main -- <檔名>` 查得到才算收工。

### ⑤ 寫回
不管 Tier 1 自動修好、還是 Tier 2 跟 Alex 討論後修好，**收尾前都要回頭把
根因、修法、（如果有）已知殘留寫進 CLAUDE.md**，格式比照現有段落
（一句話結論起頭、含具體數字、標明對應 migration 版本）。這步不是可選的——
現有的 CLAUDE.md 之所以有用，是因為每次事故都被壓縮成「不寫進來就會再犯」
的一條規則；自動化修復如果跳過這步，下次同類異常又要重新診斷一次。

---

## 4. 分級標準

**Tier 1（可以自動動手）** 必須同時符合：

- 有對應 runbook，且 runbook 標記「安全可自動化」。
- 修復是**可逆**的（新增 migration 可 rollback、或只是把已知安全的 helper
  函式套用到多一批資料，不是刪除）。
- 不碰金流（`payment_status`、`wallet_transactions`、訂單金額欄位）、
  不碰 RLS/權限（`policy`、`role` 判斷）、不碰跨租戶資料。
- 影響範圍在診斷時就能算出精確筆數（不是「大概」）。

**Tier 2（一定要先問 Alex）**，符合任一項就是：

- 沒有現成 runbook——代表這是新模式，比照 §3③ 的理由，先不要即興發揮。
- 動到金流、安全性判斷、跨租戶。
- 修復需要刪除資料，或需要覆蓋掉別人已經做的操作（例如取消一張已確認的訂單）。
- 診斷過程中發現「表面異常、但可能是母體定義錯誤」（見本檔 CLAUDE.md
  §「收斂前後對拍」那條教訓）——這類永遠要先跟 Alex 對過母體定義，
  不要自己認定是 bug 就動手改資料。
- 需要動 UI/前端邏輯，且會改變某個角色能不能操作某個按鈕
  （對照「把某個角色的動作按鈕拿掉之前」那條教訓——這類改動即使看起來只是
  拿掉一顆按鈕，也可能讓某個狀態變成沒有人推得動，必須讓 Alex 確認正主是誰）。

---

## 5. Runbook 庫慣例

新開 `docs/RUNBOOK-<check_name>.md`，`<check_name>` 對齊
`ops_health_checks.check_name`（例如 `RUNBOOK-stuck-confirmed-no-transfer.md`）。
固定格式：

```md
# RUNBOOK — <check_name>

## 症狀
（health check 撈到什麼）

## 根因類別
（對應 CLAUDE.md 哪一條教訓，或全新模式）

## 診斷查詢
```sql
-- 貼可以直接跑的 SQL
```

## 修復程序
- Tier: 1 / 2
- （Tier 1 才需要）具體步驟，含要套用哪支既有 helper function

## 驗證查詢
```sql
-- 修完之後怎麼確認真的解決了
```
```

每次 Tier 2 事故收尾、確定是「以後還會再發生」的模式時，順手把它升級成
一份 runbook，下次同類異常就能自動處理，分級標準自然往 Tier 1 移動。
**不要一開始就寫一大批 runbook**——沒有實際發生過的模式寫出來的診斷/修復
程序多半是猜的，等真的遇到再補，比較準。

---

## 6. 稽核記錄

```sql
CREATE TABLE ops_actions_log (
  id BIGSERIAL PRIMARY KEY,
  check_name TEXT NOT NULL,
  tier INT NOT NULL,                 -- 1 或 2
  action TEXT NOT NULL,              -- 'auto_fixed' / 'escalated' / 'diagnosed_no_action'
  migration_file TEXT,               -- Tier 1 且產生了 migration 時填
  affected_count INT,
  summary TEXT,                      -- 給 Alex 事後回顧用的一句話
  session_ref TEXT,                  -- 對應的 Claude session id，方便回頭找完整過程
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

`/admin/ops-health` 頁面（Observability 計畫 Phase 2）除了顯示
`ops_health_checks` 的異常，也顯示這張表——Alex 想確認「上週那次自動修的
到底做了什麼」時查得到，不用回頭挖 git log 或聊天記錄。

---

## 7. 排程機制

用 Claude Code Remote 的 Routine，不另外接第三方排程：

1. `sre-health-scan`（cron，例如每 4 小時）：`create_new_session_on_fire=true`，
   跑 `rpc_run_health_checks()`（Observability 計畫 Phase 1 產物），
   對每一筆新增/惡化的異常，`create_session` 開一個診斷 session 帶著
   `check_name` + 樣本 id 過去。
2. 診斷 session 依 §3 走完流程，Tier 1 自己收尾，Tier 2 用 push notification
   或訊息把摘要交給 Alex，等回覆。
3. Tier 2 的討論**留在跟 Alex 對話的主 session**（不是背景 session），
   因為那類問題本來就需要 Alex 的判斷輸入，不是純執行。

## 8. 跟既有 PR 流程銜接

Tier 1 修復如果需要新 migration，走的還是「先套上線、當天進 main」那條規則
（見 CLAUDE.md 開頭），不是先開 PR 等合併才套用。開出的 PR 一律
`subscribe_pr_activity` 交給既有 steward/babysit 規則帶到綠燈——這條本來就
存在，AI SRE 流程不用另外重做一套 CI 收斂邏輯，只需要在 §3④ 最後一步接上它。

---

## 9. 護欄（Never）

- 不刪除資料、不下 `DROP`/`TRUNCATE`，即使 Tier 1 也一樣——回復用「標記
  取消/歸零」而不是刪除，這是整個系統既有的一貫作法（斷貨/取消都是狀態轉換，
  不是刪列）。
- 不繞過「套上線當天進 main」的規則，不管多小的修復。
- 不在沒有 runbook 的情況下自動修復——沒有 runbook 就是 Tier 2。
- 不因為「看起來很像」上次的異常就套用舊 runbook——先確認 `check_name`
  完全對應，母體定義變過的話 runbook 要跟著更新，不是硬套。
- 一律不動用 `--force`/`git push --force`/`rm -rf` 這類破壞性操作，
  即使是自動化流程；卡住了就升級成 Tier 2 讓 Alex 決定。

---

## 10. 建議的實作順序

1. 先落地 Observability 計畫 Phase 1（`ops_health_checks` + 5 支健檢 SQL）——
   這份的 §3① 完全依賴它。
2. 建 `ops_actions_log` 表（§6，成本很低，跟健檢表一起建掉）。
3. 挑 CLAUDE.md 裡**已經發生過至少兩次**的模式先寫 runbook（例如「migration
   進 main 沒套上線」「backorder_at 未解除」），這兩類最容易被誤觸也最好驗證。
4. 接 `sre-health-scan` Routine，先只做「發現異常就通知 Alex」（等於全部
   Tier 2），確認通知的頻率跟品質沒問題之後，再挑第 3 步寫好 runbook 的
   項目升級成 Tier 1 自動修復。

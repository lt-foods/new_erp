# TEST — 月結送審撤銷（sent → draft，總倉發起）

來源：Alex（2026-08-05）：「月結送審可以撤消，由總倉發起撤銷。」

情境：總部按了「送店家線上核對」之後才發現送錯月份 / 漏加人工調整 / 估價要再修。
撤銷前唯一的回頭路是等店家提爭議（disputed），但店家一按同意就 confirmed
鎖住並產生應收單，來不及攔。

Migration：`20260805000020_rpc_revoke_settlement_send.sql`
- 新 RPC `rpc_revoke_settlement_send(p_settlement_id, p_operator, p_reason DEFAULT NULL)`：
  status **僅 sent** 可撤 → 回 draft；清 `sent_at` / `sent_by`；撤銷軌跡
  （時間＋原因）append 進 `notes`。
- 角色 gate：`_settlement_caller_is_hq()`（20260715000120，`''` = legacy admin）。
  店家不能自己退回 draft。
- disputed（球已在總部、估價/調整本來就能改）與 confirmed / remitted / settled
  （已鎖定、已產生應收單）一律擋下 —— 鎖定後動金額仍走爭議 / 應收單流程。

狀態機（新增一條回頭邊）：

```
draft ──送單──▶ sent ──店家全同意──▶ confirmed ──▶ remitted ──▶ settled
  ▲              │ │店家提爭議
  └──撤銷送審────┘ ▼
     （總倉）    disputed ──爭議全處理+重送──▶ sent
```

UI：`/transfers/settlement/detail?id=`（HQ 明細頁）
- status=sent → 底部固定動作列出現「↩ 撤銷送審（退回草稿）」；確認列帶
  選填的撤銷原因輸入框（沿用既有頁內確認列，不跳瀏覽器對話框）。
- sent 的流程狀態列補一句提示（店家未回應前總部可收回）。
- 新增「備註／軌跡」區塊顯示 `notes`（撤銷紀錄看得到；此前 notes 有抓沒顯示）。

## 測試項目

### RPC（線上 DO block + RAISE 強制 rollback，2026-08-05，settlement #479）
- [x] T1 sent → 撤銷成功：status=draft、`sent_at`/`sent_by` 清成 NULL、
      notes append `[撤銷送審 YYYY-MM-DD HH:MI]（原因）`、回傳 `was=sent`。
- [x] T2 draft 再撤一次 → 擋「狀態 draft 不可撤銷送審（僅 sent…）」。
- [x] T3 confirmed → 擋（已鎖定不從這裡開後門）。
- [x] T4 不存在的 id → `settlement % not found`。
- [ ] T5 店家帳號（store_manager JWT）呼叫 → 應擋「僅總部帳號可撤銷送審」。
      未單獨驗；共用 `_settlement_caller_is_hq()`，與送單／人工調整同一支 gate。

### UI（Playwright + fixture，10/10 通過）
- [x] T6 status=sent 出現「撤銷送審（退回草稿）」鈕；sent 不出現「送店家線上核對」。
- [x] T7 點擊 → 頁內確認列文案 +「撤銷原因（選填，會記進備註）」輸入框。
- [x] T8 送出 → `rpc_revoke_settlement_send` 帶 `p_settlement_id` /
      `p_reason` / `p_operator`（登入者 uid）。
- [x] T9 撤銷後畫面回 draft：狀態顯示「草稿」、送單鈕回來、撤銷送審鈕消失。
- [x] T10 「備註／軌跡」顯示撤銷紀錄。
- [x] T11 tsc 乾淨。

### 連鎖效果（既有行為，不需另外改；本次未重跑）
- 店家端 `StoreSettlementReview` 只列 `sent` 起 → 撤銷後該單從店家清單消失。
- `rpc_store_review_settlement` 守門 `status='sent'` → 店家手上開著的舊分頁
  按同意／送爭議會被擋。
- `rpc_settlement_action_count` 店家口徑算 sent+confirmed → 側欄 badge 自動 -1。
- 生成器 `rpc_generate_hq_to_store_settlement` 重算範圍含 draft → 撤銷後改來源
  資料會自動重算，人工調整（錨月份+店）也會重新套用。

## 待辦 / 已知限制
- [ ] 撤銷不會通知店家（沒推播）。店家若正在核對頁，會在按下同意時才吃到
      「狀態 draft 不可核對」錯誤，而不是當場被踢出。
- [ ] 只能撤 sent。若店家已提爭議（disputed）想整張重來，仍需逐筆標記已處理
      後重送，或直接改資料再重送。

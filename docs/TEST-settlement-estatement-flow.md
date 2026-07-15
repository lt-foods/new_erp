# TEST — 月結電子對帳流程（線上送單／畫押／爭議／匯款／結案）

來源：1688 群組拍板（Alex + 楊小胖，2026-07-15）：「還是不要列印了，都電子化」。
流程：總部核對無誤線上送單 → 店家線上核對（不同意款項排最上方給備註）→
店家送出爭議申請 → 總部 review 修正 → 兩邊都按同意就鎖住 → 店家按已匯款 →
總部按收到款項就結案。

Migration：`20260715000120_settlement_estatement_flow.sql`
- status 擴充：draft → **sent** → (disputed ⇄ sent) → confirmed → **remitted** → settled。
- 新表 `store_settlement_disputes`（錨 transfer_item_id、item_snapshot、open/resolved；
  RLS：HQ 全 tenant 讀、店家只讀自己店；寫入只走 RPC）。
- 新 RPC：`rpc_send_settlement_to_store` / `rpc_store_review_settlement` /
  `rpc_resolve_settlement_dispute` / `rpc_mark_settlement_remitted` /
  `rpc_settle_store_monthly_settlement`；
  角色 gate：`_settlement_caller_is_hq()`（app_metadata.role ∈ HQ tier，'' = legacy admin）、
  `_settlement_caller_in_store()`（store_manager/store_staff × `_jwt_store_ids()`）。
- 生成器 v4：重算範圍 draft → **draft/sent/disputed**（鎖定前跟著來源資料走），
  跳過 confirmed/settled/remitted/cancelled（順修舊版 disputed/cancelled 列會
  NULL-crash 的潛在 bug）。
- confirm v2：接受 draft（總部直接確認）與 sent（店家畫押）。
- 估價修正 v2：鎖定判斷改 confirmed/remitted/settled（sent/disputed 仍可修）。
- 結案時應收單同步：未收餘額經 `rpc_record_store_receivable_payment` 一次入帳。

## 測試項目

### RPC 全生命週期（線上 DO block + RAISE 強制 rollback，2026-07-15，永和店 #47 實資料）
- [x] T1 送單 draft→sent、sent_at/sent_by 記錄。
- [x] T2 他店 store_manager JWT（中和店）核對永和店單 → 擋（僅該分店或總部）。
- [x] T3 店家（永和店 JWT）提出爭議 → disputed、dispute row 建立（快照+原因）。
- [x] T4 有 open 爭議不能重送 →「尚有 1 筆爭議未處理」。
- [x] T5 disputed 狀態修自由轉貨估價（$250→$280）→ 兩邊重算
      （payable 18,229.5→18,199.5）、status 保持 disputed、爭議行存活（錨 transfer_item_id）。
- [x] T6 標記已處理 → open_remaining=0 → 重新送單成功。
- [x] T7 店家同意畫押 sent→confirmed：store_agreed_at 記錄、產生應收單
      SR-202607-40-1 金額 = 修正後 18,199.5。
- [x] T8 鎖定後改估價 → 擋「已鎖定…請走爭議流程」。
- [x] T9 鎖定後生成器重跑 → 跳過（金額/狀態不變）。
- [x] T10 店家按已匯款 confirmed→remitted（備註後五碼）；店家不能結案（僅總部）。
- [x] T11 總部結案 remitted→settled：應收單自動全額入帳
      （payment SRP-…、status=paid、paid=18,199.5）。

### UI（Playwright fixture，23/23 通過）
- [x] T12 HQ draft：modal 有「送店家線上核對」＋「直接確認（跳過店家核對）」。
- [x] T13 HQ disputed：爭議面板（原因/快照/未處理計數）、「標記已處理」帶說明、
      重送鈕鎖住顯示剩餘筆數、行內「改估價」仍可用（draft/sent/disputed）。
- [x] T14 HQ remitted：顯示匯款備註、「確認收款結案」呼叫結案 RPC。
- [x] T15 分店帳號（store_manager+stores 店名）進 /transfers/settlement →
      自動切「月結對帳」店家介面；只列自己店、狀態 sent 起（看不到 draft）。
- [x] T16 店家核對 modal：**全版面無「成本」字樣**（單價/小計＝分店價）；
      逐行「有問題」+ 原因必填才能送出；送出爭議 RPC 參數
      [{transfer_item_id, reason}] 正確。
- [x] T17 無標記行時「同意畫押」→ p_agree=true。
- [x] T18 disputed：爭議行排最上方、顯示總部處理註記。
- [x] T19 confirmed：「我已匯款」帶備註呼叫 remit RPC。
- [x] T20 分店帳號開列印頁 `?view=internal` 仍強制分店版、無切換鈕（canSeeCost gate）。

### 迴歸
- [x] T21 tsc --noEmit 通過；eslint 僅既有 5 筆 baseline finding（無新增）。
- [x] T22 rollback 測試後線上無殘留（#47 仍 draft、無 dispute/receivable rows）。
- [x] T23 HQ 直接確認（跳過核對）路徑保留（confirm v2 接受 draft）。

## 待辦 / 已知限制
- [ ] 送單後無推播通知店家（現有 notifications 表是 member/LIFF 導向；店家開
      月結對帳頁看到「待核對」）。要推播需另做 staff 通知管道。
- [ ] store_monthly_settlement_items 的 RLS 仍 tenant 全讀（歷史政策 auth_read_smsi），
      分店帳號技術上可從 REST 讀到 unit_cost 欄位——UI 已全面隱藏，
      要 API 層鎖成本欄需另開 column-level view migration。

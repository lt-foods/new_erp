# TEST — 分店端「每日進貨對帳」

需求（2026-08-03，楊小胖 / 1688 群組）：店家當天問「今日進貨的總金額多少？」，
紙本出貨單只有品名數量沒有金額，系統裡也只有月結對帳單送出後才看得到分店價。
要讓分店隨時查「當日所有品項的分店價 + 當日總金額」，不用等月結。

Migration：`20260803000000_store_daily_inbound.sql`（全新函式，不覆寫既有物件）
- helper `_store_inbound_lines(store_id, from, to)`：某店期間內的分店價分錄逐行。
  六種 entry_type 與 `rpc_generate_hq_to_store_settlement` v4（`20260801000000`）
  **逐項對齊**：hq_inbound / air_in（+，`_branch_price_at`）、air_out / return_out
  （−，`_branch_price_at`）、free_in（+`estimated_amount`）/ free_out（−）。
  不對外開放（`REVOKE ALL … FROM PUBLIC`），只給下面兩支 RPC 內部用。
- `rpc_store_inbound_daily_summary(store_id, month)` → `{days:[{date,line_count,amount}],
  month_amount, month_lines}`（日期倒序）。
- `rpc_store_inbound_day_items(store_id, date)` → 當日逐行（品項/類別/數量/分店價/
  小計/單號）＋ `total`；`missing_price` 標出貨款行卻抓不到分店價的品項。
- 權限：SECURITY DEFINER + in-RPC gate `_settlement_caller_is_hq() OR
  _settlement_caller_in_store(store_id)`（沿用 `20260715000120`）——
  分店只查得到自己店、HQ 可查任一店。
- **日界用 Asia/Taipei**（店家認知的「今天」，對齊 repo 既有
  `DATE(x AT TIME ZONE 'Asia/Taipei')` 慣例）。月結生成器的月界是 DB session tz
  （UTC）—— 跨月當天 00:00–08:00（台北）收的貨，日曆歸屬會與月結差一天。
  現網全量 7439 筆 transfers 只有 2 筆落在此窗，本次不動月結生成器。

前端（apps/admin）：
- 新頁 `/transfers/settlement/daily`：今日金額 / 本月累計兩張數字卡、每日金額列表
  （點「看明細」展開當日逐品項；今天有貨預設展開）、月份切換、HQ 可切分店。
  負數（空中轉出／退貨沖回）寫成 `-$130` 並用綠字。
- 入口：分店版「月結對帳」與總部版「月結算」頁 header 各加一顆按鈕。
- `StoreSettlementReview` 金額欄：`$0` 且有明細 → 加註「進貨與退貨相抵」；
  負數 → 綠字「總倉應退 $x」（原本一律紅字 `$-11,720`，店家看不懂）。

## 測試項目

### 線上 DB（Management API，2026-08-03）
- [x] T1 部署成功、3 個函式建立完成。
- [x] T2 **口徑對帳**：2026-07 全 15 家有帳的店，
      `rpc_store_inbound_daily_summary(...)->>'month_amount'`
      與 `store_monthly_settlements.branch_amount` 逐店 diff 皆為 `0.0000`。
- [x] T3 龍潭店 2026-06（截圖那張 $0 的單）：每日彙總得 `2026-06-24` 一天、
      2 行、金額 0 —— 同日 `hq_inbound +130` 與 `return_out −130` 相抵，
      與 `store_monthly_settlement_items` 完全一致（$0 是正確結果，非計價 bug）。
- [x] T4 `rpc_store_inbound_day_items(龍潭, 2026-06-24)` 回 2 行、
      帶 sku_code / 品名 / 規格 / 單號（WAVE-16-S47、TR2606240104）、total 0。
- [x] T5 近期（2026-07-01 ~ 2026-08-03）全店貨款行 `missing_price` 掃描 = 0 筆。

### UI（Playwright + fixture，`store_manager` / 綁定「龍潭店」）
- [x] T6 `/transfers/settlement/daily`：兩張數字卡、每日列表、今天列自動展開明細、
      「未設分店價」紅標、當日合計列；無 console error。
- [x] T7 收合今天 → 展開其他日期，明細正確重抓。
- [x] T8 只綁一家店的帳號看不到分店下拉（鎖定自己店）。
- [x] T9 `/transfers/settlement`：新按鈕「查每日進貨金額」出現；
      `$0` 列顯示「進貨與退貨相抵」、負數列顯示綠字「總倉應退 $11,720」。

### 待辦 / 已知限制
- [ ] 跨月當天凌晨（台北 00:00–08:00）收貨的月份歸屬，日曆與月結會差一天；
      要對齊須另開 migration 把生成器月界改成 Asia/Taipei（會動到既有 draft 金額）。
- [ ] 分店價缺漏（`prices` scope=branch 沒設）的品項會以 $0 入帳，
      目前只在每日明細標紅提醒；總部端沒有主動告警。

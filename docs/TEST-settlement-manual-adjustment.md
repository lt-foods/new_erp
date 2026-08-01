# TEST — 月結人工調整（增減金額＋必填原因）

需求（2026-08-01）：月結功能要可以增加/減少金額並寫原因 —— 明細行以外的
加減項（運費分攤、破損折讓、活動補貼、上月尾差沖抵…）總部要能直接調整
單一分店單一月份的應付金額，店家核對與列印對帳單都看得到金額與原因。

Migration：`20260801000000_settlement_manual_adjustment.sql`
- 新表 `store_settlement_adjustments`：帶正負號金額（正=加收、負=減收）＋
  必填原因；**錨定 (tenant, 月份, store)** 而非 settlement_id —— 生成器重算
  DELETE/重建 draft 後調整自動重新套用、不失聯。只能作廢（voided）不能改，
  留完整軌跡。RLS 只開同 tenant SELECT（比照 auth_read_sms），寫入全走
  SECURITY DEFINER RPC。
- `store_monthly_settlements.adjustment_amount`（active 調整合計）；
  **payable_amount = branch_amount + adjustment_amount**。branch/cost 維持
  純貨款口徑，毛利顯示（branch − cost）不受調整影響。
- 新 RPC：`rpc_add_settlement_adjustment(settlement_id, amount, operator, reason)`、
  `rpc_void_settlement_adjustment(adjustment_id, operator, reason?)`；
  角色 gate `_settlement_caller_is_hq()`；僅鎖定前（draft/sent/disputed）可加/廢，
  confirmed 起擋下（對齊估價修正 v2 的鎖定判斷）。
- 生成器 v4（基底 `20260715000120` 逐字保留）：加 G) 調整段，重算時把
  active 調整合計加回 payable；「該月無調撥活動但有 active 調整」不再砍
  draft（純收費月份成立）；回傳加 `total_adjustment`。

前端（apps/admin）：
- 總部明細頁 `/transfers/settlement/detail`：「金額調整」區塊 —— 新增
  （方向加收/減收＋金額＋必填原因）、作廢（帶作廢原因）、清單含已作廢
  軌跡；合計列「貨款＋調整＝應付」；header 應付改標「含調整」、加
  「人工調整合計」卡（非 0 才顯示）。
- 店家核對頁 `/transfers/settlement/review`：「總部金額調整」唯讀清單
  （原因＋金額，只列 active）＋「商品合計＋調整＝應付總部」組成列。
- 列印對帳單 `/finance/receivables/print`：金額調整表（日期/原因/金額/
  調整合計）＋「商品合計＋調整＝應付金額」總結列（分店版/內部版都有）。

## 測試項目

### 線上 DB（Management API DO block + RAISE 強制 rollback，2026-08-01）
- [x] T1 部署後物件齊備：2 支新 RPC、調整表、adjustment_amount 欄位、
      RLS policy、生成器 v4（含 total_adjustment）。
- [x] T2 對未鎖定 settlement（#114）加 −150 減收 → adjustment_amount −150、
      payable_amount = branch_amount + adjustment_amount 同步。
- [x] T3 作廢該筆 → adjustment_amount / payable_amount 還原原值。
- [x] T4 全程 rollback，無殘留（adj_rows=0）。

### 待驗（上線後首次實際使用時勾）
- [ ] T5 金額 0 / 原因空白 → RPC 擋（「調整金額不可為 0」「必須填原因」）。
- [ ] T6 confirmed/remitted/settled 狀態加調整或作廢 → 擋「已鎖定」。
- [ ] T7 店家帳號（store_manager JWT）呼叫 add/void → 擋「僅總部帳號」。
- [ ] T8 加調整後重跑生成器 → 調整保留、payable 重算仍含調整；
      sent/disputed 列重算後調整不掉。
- [ ] T9 店家核對頁看得到調整原因與金額、應付組成列一致；
      畫押後應收單金額 = 含調整之 payable。
- [ ] T10 列印對帳單（分店版）含金額調整表與總結列。

### UI（Playwright fixture）
- 見 `apps/admin` verify 流程；本次驗證：明細頁調整區塊（新增表單、
  作廢流、合計列）、核對頁唯讀調整清單、列印頁調整表。

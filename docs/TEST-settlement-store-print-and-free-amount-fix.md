# TEST — 月結對帳單分店版＋自由轉貨估價修正＋應付口徑補正

來源：永和店 2026-07 月結對帳回報（LINE 群）：
1. 給店家的對帳單印出「我們的實際成本」（成本單價/成本小計欄）。
2. 自由轉貨行金額是店端轉貨時手填的估價，跟實際分店價對不上，要能事後修正。
3. 列印出來頁數太多（類型欄被擠成直排、每列高四行）。

Migrations：
- `20260715000100_settlement_payable_branch_basis.sql` — 補 repo/線上落差：
  線上 `rpc_generate_hq_to_store_settlement` 已改 `payable = 分店價口徑`
  （賣斷制、跟分店收分店價），但當時只打了 Management API 沒留 migration。
  本檔函式本體逐字取自線上 pg_get_functiondef，對線上套用為 no-op。
- `20260715000110_rpc_update_free_transfer_amount.sql` — 自由轉貨估價事後修正。

## 測試項目

### rpc_update_free_transfer_amount（線上 DO block + RAISE 強制 rollback 驗證，2026-07-15）
- [x] T1 修正 item 8350（TR2607040153「阿美嬤紅茶奶-紅茶牛奶」$250→$280）：
      transfer_items.estimated_amount 更新、notes append「[估價修正 …] $250 → $280（原因）」。
- [x] T2 兩邊鏡像分錄一起重算：free_in +250→+280、free_out −250→−280；
      出貨店（永和）payable 18,229.5→18,199.5、收貨店 67,342.14→67,372.14（差額 ±30）。
- [x] T3 護欄：該月任一邊已 confirmed/settled → EXCEPTION
      「2026-07 月結算已確認：永和店（confirmed）…」。
- [x] T4 護欄：非自由轉貨行（hq_to_store）→ EXCEPTION「不是自由轉貨」。
- [x] T5 未收貨的行只改估價、不觸發月結重算（settlements_regenerated=false）。
      （程式路徑；received_at IS NULL 分支）
- [x] T6 confirmed/settled 的其他店 draft 不受重算影響（生成器本來就跳過）。

### 列印對帳單（finance/receivables/print）— Playwright fixture 驗證 25/25 通過
- [x] T7 預設「分店版（給店家）」：整張不出現任何「成本」字樣、無成本欄，
      單價/小計＝分店價口徑；自由轉貨行單價顯示「—」、品名帶描述。
- [x] T8 「內部版（含成本）」切換：成本單價/成本小計欄、表頭
      應付總倉金額（分店價口徑）＋成本口徑＋總部毛利；`?view=internal` 直開。
- [x] T9 表頭標籤修正：應付金額不再誤標「成本價口徑」（線上 payable 已是分店價，
      舊標籤造成兩個口徑顯示同數字的困惑）。
- [x] T10 列印壓縮：類型/日期/調撥單/金額欄 nowrap（修直排爆高）、
      print 字級 10px + padding 2/4px、@page margin 12mm→10mm、
      thead 跨頁重複、tr break-inside avoid。

### 月結算頁（transfers/settlement）
- [x] T11 列表欄名：「應付總倉（分店價）」＋「成本口徑（參考）」（原第二欄顯示
      branch_amount 與 payable 恆同值，改顯 cost_amount）；footer 合計同步。
- [x] T12 明細 modal 統計卡：應付金額（分店價口徑）／成本口徑金額（參考）／
      口徑差額（總部毛利）。
- [x] T13 draft 狀態自由轉入/轉出行有「改估價」鈕（其他類型無）；面板送出
      rpc_update_free_transfer_amount（帶 transfer_item_id/新估價/原因），
      成功後明細與表頭金額重抓、列表 reload；confirmed/settled 無鈕。
- [x] T14 產生結果訊息改「應付合計（分店價口徑）$X／成本口徑 $Y」。

### 迴歸
- [x] T15 tsc --noEmit 通過；eslint 與 HEAD 基線相同（無新增 finding）。
- [x] T16 確認 RPC（rpc_confirm_store_monthly_settlement）不動：入
      store_receivables 金額仍 = payable_amount（現＝分店價口徑）。

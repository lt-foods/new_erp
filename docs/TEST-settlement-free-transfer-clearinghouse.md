# TEST — 月結清算中心（自由轉貨兩邊記帳 + 退貨回總倉沖回）

Migration：`20260714000100_settlement_free_transfer_and_return.sql`
公式：`payable = hq_inbound + air_in − air_out + free_in − free_out − return_out`

## 測試項目

### 分錄產生（rpc_generate_hq_to_store_settlement）
- [ ] T1 自由轉貨（店A→店B、已收貨、估價 $100）→ 店B 月結 `free_in +100`、店A 月結 `free_out −100`；兩邊鏡像同額（總倉淨額 0）。
- [ ] T2 估價空值的自由轉貨行 → 兩邊各記 0 元分錄（金額不動、明細可見）。
- [ ] T3 草稿/已出貨未收貨的自由轉貨 → 不入帳（只認 received/closed、received_at 落在該月）。
- [ ] T4 退貨回總倉（店→HQ、HQ 已收）→ 該店 `return_out` 負分錄，金額 = qty_received × 出庫 unit_cost（與 hq_inbound 同基準）。
- [ ] T5 互助/轉手腿（store_to_store 有訂單 FK）仍走 air_in/air_out，**不會**同時被 free 系列重複計（customer_order_id IS NULL 互斥）。
- [ ] T6 既有 hq_inbound / air_in / air_out 金額與 20260512000012 版完全一致（迴歸）。
- [ ] T7 該店該月只有自由轉出（無其他活動）→ 仍產生月結（負額 = 貸方餘額），不會被「無活動 skip」誤刪。
- [ ] T8 confirmed/settled 的月結不被重算；draft 重跑生成器 → 金額更新、items 重建。

### 明細
- [ ] T9 free_in/free_out 明細列帶 description（自由轉貨的描述），unit_cost=0、line_amount=±估價。
- [ ] T10 return_out 明細列為真 SKU、line_amount 為負。
- [ ] T11 transfer_count / item_count 含自由轉貨與退貨腿。

### UI（transfers/settlement）
- [ ] T12 明細表新 chip：自由轉入(sky)/自由轉出(violet)/退貨沖回(rose)；負額顯示既有 amber 樣式。
- [ ] T13 自由轉貨行「商品」欄顯示描述文字（不再是 MISC 雜項）。
- [ ] T14 合計 = 各分錄加總 = 表頭應付金額。

### 約束
- [ ] T15 entry_type CHECK 換新版（六值）；舊三值資料不受影響。
- [ ] T16 items.description 欄新增成功、既有列為 NULL。

### 部署後（prod）
- [ ] T17 對 7 月重跑生成器（draft 範圍），抽一張有自由轉貨的店對帳：free_in/free_out 對得上內部調撥頁的估價。

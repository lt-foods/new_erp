# TEST — 進貨/撿貨同一動作 (rpc_arrive_and_distribute + UI)

## 目標
驗證從 PO 列表「進貨」按鈕進入進貨/撿貨頁，一次完成 GR + picking_wave + 入庫。

## 前置
- migration `20260430120000_arrive_and_distribute.sql` apply
- 一張 status='sent' 的 PO，且其來源 PR 是 `source_type='close_date'`（這樣才能反查到分店訂單）
- 該結單日有 customer_orders（status not cancelled/expired）

---

## T1 — RPC 結構

| # | 步驟 | 預期 |
|---|------|------|
| T1-1 | `SELECT proname FROM pg_proc WHERE proname='rpc_arrive_and_distribute';` | 1 列 |
| T1-2 | `SELECT * FROM v_po_demand_by_store WHERE po_id=<id> LIMIT 1;` | 該 PO 對應分店需求列出 |

## T2 — RPC happy path

| # | 步驟 | 預期 |
|---|------|------|
| T2-1 | `SELECT rpc_arrive_and_distribute(<po_id>, '[{"po_item_id":...,"sku_id":...,"qty_received":<full>,"unit_cost":...,"allocations":[{"store_id":...,"qty":...}]}]'::jsonb, <op>);` | 回 `{gr_id, gr_no, wave_id, wave_code, close_date}` |
| T2-2 | 查 goods_receipts 該列 status | `confirmed` |
| T2-3 | 查 picking_waves 該列 status | `picked` |
| T2-4 | 查 picking_wave_items 該 wave 的 (sku, store) qty | 與 allocations 一致 |
| T2-5 | 查 stock_movements `source_doc_id=<gr_id>` | 1 列、`movement_type=purchase_receipt`、qty 與 received 一致 |
| T2-6 | 查 purchase_orders 該列 status | `fully_received`（若 PO 收完）或 `partially_received` |

## T3 — RPC guards

| # | 步驟 | 預期 |
|---|------|------|
| T3-1 | PO status='draft'/'fully_received' 時呼叫 | RAISE `must be sent/partially_received` |
| T3-2 | allocations 合計 > qty_received | RAISE `allocation total ... exceeds received` |
| T3-3 | 呼叫不存在 PO id | RAISE `PO ... not found` |
| T3-4 | 沒 allocations 的 SKU | 仍入總倉、wave_items 無該 sku × store 列、不報錯 |

## T4 — UI 進貨頁

| # | 步驟 | 預期 |
|---|------|------|
| T4-1 | 在 PO 列表，sent/partially_received 的 PO 列右側 | 顯示綠色「進貨」按鈕 |
| T4-2 | draft / fully_received / cancelled 的 PO 列 | 不顯示「進貨」按鈕 |
| T4-3 | 點「進貨」進入 `/purchase/orders/receive?po=<id>` | 載入 PO header + 各 SKU + 分店需求 |
| T4-4 | 預設「實到 = 訂量 - 已收量」、各分店分配 = 各分店需求 | 對 |
| T4-5 | 修改實到數，點「按需求比例自動分配」 | 各分店分配按比例重算 |
| T4-6 | 已分配 vs 到貨可用差為 0 → 綠字、不為 0 → 黃字 | 對 |
| T4-7 | 按「確認進貨／撿貨」 | alert 顯示 GR 號 + 撿貨號，回 PO 列表 |
| T4-8 | PO 列表中該 PO status 變 `partially_received` 或 `fully_received` | 對 |

## T5 — 多次到貨

| # | 步驟 | 預期 |
|---|------|------|
| T5-1 | 第一次進貨輸入 < PO 總量 | PO 變 `partially_received`，產生 GR1 + Wave1 |
| T5-2 | 第二次進貨 PO 列表「進貨」按鈕仍可見 | 對 |
| T5-3 | 第二次進貨頁預設實到 = 剩餘量 (po.qty_ordered - poi.qty_received) | 對 |
| T5-4 | 完成第二次後 PO 變 `fully_received`，產生 GR2 + Wave2 | 對 |

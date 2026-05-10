-- ============================================================
-- fixture: full-demo
-- 串接所有情境：庫存 + 團購 + 訂單 + 採購 + 撿貨 + 轉撥 + 互助 + 月結算
-- 適合給人 demo、跨情境整合測試、E2E 黃金路徑與反向情境驗證。
--
-- 依賴順序：
--   with-stock              （庫存開帳，stock_movements + 自動 stock_balances）
--   with-orders             （內部 \ir with-campaign；建 8 筆 customer_orders 含反向）
--   with-wallet-history     （依賴 02-base 的 members；wallet_ledger + R10 reversal）
--   with-pr-po              （獨立；R1 PR 取消 / R2 PO 取消 / R3 GR 短少 + vendor_bills + purchase_returns）
--   with-picking-wave       （依賴 with-orders + with-campaign；R5 撿貨不足 / R9 wave 取消）
--   with-transfers          （獨立；R6a transfer 拒收 / R6b 運送破損 + transfer_settlements）
--   with-mutual-aid         （依賴 with-orders 的 customer_orders；R11a/b/c offer 取消 + replies/claims）
--   with-monthly-settlement （依賴 with-transfers 的 hq_to_store）
-- ============================================================
\set ON_ERROR_STOP on

\ir with-stock.sql
\ir with-wallet-history.sql
\ir with-orders.sql
\ir with-pr-po.sql
\ir with-picking-wave.sql
\ir with-transfers.sql
\ir with-mutual-aid.sql
\ir with-monthly-settlement.sql

\echo 'fixture full-demo seeded.'

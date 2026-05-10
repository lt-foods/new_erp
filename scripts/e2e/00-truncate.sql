-- ============================================================
-- E2E reset · step 00 · TRUNCATE
-- 清空 public schema 全部資料表（保留 auth schema / schema 結構 / RPC）
-- 重置全部 sequence
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

-- 一次列出所有資料表，CASCADE 自動處理 FK 順序、RESTART IDENTITY 重置 BIGSERIAL。
TRUNCATE TABLE
  -- product
  promotion_skus, promotions, prices, sku_aliases, sku_suppliers, supplier_skus,
  pending_barcodes, internal_barcode_sequence, barcodes, sku_packs, skus, products,
  brands, categories, product_audit_log,
  -- member
  member_tags, points_ledger, member_points_balance, wallet_ledger, wallet_balances,
  member_audit_log, member_merges, member_cards,
  customer_line_aliases, member_line_bindings, members, member_tiers,
  -- inventory
  reorder_rules,
  stocktake_items, stocktakes,
  store_monthly_settlement_items, store_monthly_settlements,
  transfer_items, transfers,
  transfer_settlement_items, transfer_settlements,
  stock_movements, stock_balances,
  mutual_aid_replies, mutual_aid_claims, mutual_aid_board, aid_clearance_offers,
  demand_requests, backorders,
  -- purchase
  purchase_return_items, purchase_returns,
  goods_receipt_items, goods_receipts,
  purchase_order_items, purchase_orders,
  purchase_request_items, purchase_requests,
  external_purchase_imports, purchase_approval_thresholds,
  suppliers,
  -- sales / customer
  invoices, sales_return_items, sales_returns,
  sales_delivery_items, sales_deliveries,
  sales_order_items, sales_orders,
  customer_tier_prices, customers,
  -- AP / petty / expense
  expenses, petty_cash_transactions, petty_cash_accounts,
  vendor_payment_allocations, vendor_payments,
  vendor_bill_items, vendor_bills,
  expense_categories,
  -- xiaolan
  xiaolan_arrivals, xiaolan_returns, xiaolan_purchases,
  xiaolan_order_tracking, xiaolan_piaopiao, xiaolan_settings,
  -- order / pickup / picking / events
  picking_wave_items, picking_wave_audit_log, picking_waves,
  order_pickup_events, order_expiry_events, order_shortage_events,
  customer_order_items, customer_order_sources, order_waitlist, customer_orders,
  external_order_imports, lele_order_imports,
  -- campaign
  campaign_audit_log, campaign_channels, campaign_items, group_buy_campaigns,
  -- POS
  pos_sale_items, pos_sales, payments, receivables,
  employee_meals,
  -- store + line
  post_templates, line_channels, stores,
  -- location
  locations
RESTART IDENTITY CASCADE;

COMMIT;

\echo 'truncate done.'

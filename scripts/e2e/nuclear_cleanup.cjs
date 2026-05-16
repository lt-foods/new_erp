// ⚠️⚠️⚠️ NUCLEAR cleanup — 清光 dev DB 所有 transactional 資料
//
// 清：
//   - customer_orders / items / pickup events
//   - purchase_requests / items / campaigns_link
//   - purchase_orders / items
//   - goods_receipts / items
//   - picking_waves / items / audit_log
//   - transfers / items
//   - stock_movements (全表 truncate-like)
//   - stock_balances 全表
//   - wallet_ledger
//   - group_buy_campaigns / campaign_items
//   - products / skus / prices / supplier_skus
//
// 保留：
//   - stores / locations / suppliers / line_channels / members / auth.users
//   - wallet_balances (per user request — 保留會員儲值金 row 結構)
//   - tenant + schema 結構
//
// 用法：
//   node scripts/e2e/nuclear_cleanup.cjs           # dry-run
//   node scripts/e2e/nuclear_cleanup.cjs --yes     # 真砍
//
// ⚠️ 只能對 dev DB 跑 (anfyoeviuhmzzrhilwtm)。
const { Client } = require('pg');

const YES = process.argv.includes('--yes');
const TENANT = '00000000-0000-0000-0000-000000000001';

const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com',
  port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm',
  password: '@Ss0929283575',
  database: 'postgres',
  ssl: { rejectUnauthorized: false },
});

const TABLES_TO_PURGE = [
  // 順序按 FK dependency: 子在前、父在後
  // 1. order chain
  'order_pickup_events',
  'customer_order_items',
  'customer_orders',
  // 2. wallet
  'wallet_ledger',
  // 3. picking / transfer chain
  'picking_wave_audit_log',
  'picking_wave_items',
  'picking_waves',
  'transfer_items',
  'transfers',
  // 4. stock
  'stock_movements',
  'stock_balances',
  // 5. GR
  'goods_receipt_items',
  'goods_receipts',
  // 6. vendor bill / return (跟 PO 相關的)
  'vendor_bill_items',
  'vendor_bills',
  'vendor_payments',
  'purchase_return_items',
  'purchase_returns',
  // 7. PO / PR
  'purchase_order_items',
  'purchase_orders',
  'purchase_request_items',
  'purchase_request_campaigns',
  'purchase_requests',
  // 8. campaign + items
  'campaign_items',
  'group_buy_campaigns',
  // 9. backorder / shortage
  'backorders',
  'order_shortage_events',
  'order_expiry_events',
  // 10. mutual aid
  'mutual_aid_claims',
  'mutual_aid_replies',
  'mutual_aid_board',
  // 11. settlement
  'store_monthly_settlement_items',
  'store_monthly_settlements',
  // 12. restock
  'restock_request_lines',
  'restock_requests',
  // 13. price / sku / product
  'prices',
  'supplier_skus',
  'skus',
  'products',
];

async function preview() {
  console.log('\n--- Preview (rows to delete per table) ---');
  for (const t of TABLES_TO_PURGE) {
    try {
      const r = await c.query(`SELECT COUNT(*) FROM ${t}`);
      const n = Number(r.rows[0].count);
      if (n > 0) console.log(`  ${t.padEnd(45)} ${n}`);
    } catch (e) {
      console.log(`  ${t}: SKIP (${e.message.slice(0, 60)})`);
    }
  }
}

async function purge() {
  console.log('\n--- Purging (bypass triggers via session_replication_role) ---');
  await c.query('BEGIN');
  await c.query(`SET LOCAL session_replication_role = 'replica'`);
  for (const t of TABLES_TO_PURGE) {
    try {
      const r = await c.query(`DELETE FROM ${t}`);
      console.log(`  ✓ ${t}: ${r.rowCount} deleted`);
    } catch (e) {
      console.log(`  ✗ ${t}: ${e.message.slice(0, 80)}`);
    }
  }
  await c.query('COMMIT');
}

async function main() {
  console.log('⚠️⚠️⚠️  NUCLEAR CLEANUP', YES ? '(--yes, REAL DELETE)' : '(dry-run)');
  console.log('   Target: anfyoeviuhmzzrhilwtm (dev pooler)');
  console.log('   Tables:', TABLES_TO_PURGE.length);
  if (!YES) console.log('   ℹ️  Dry-run — add --yes to actually delete.');

  await c.connect();
  try {
    await preview();
    if (YES) {
      await purge();
      console.log('\n--- After cleanup ---');
      await preview();

      // 重要 schema invariant check
      const i1 = await c.query(`SELECT COUNT(*) FROM fn_check_pr_campaigns_consistency()`);
      const i2 = await c.query(`SELECT COUNT(*) FROM fn_check_pickup_movements_consistency()`);
      const i3 = await c.query(`SELECT COUNT(*) FROM fn_check_wallet_consistency()`);
      console.log('\n--- Invariants after nuke ---');
      console.log(`  fn_check_pr_campaigns_consistency      : ${i1.rows[0].count}`);
      console.log(`  fn_check_pickup_movements_consistency  : ${i2.rows[0].count}`);
      console.log(`  fn_check_wallet_consistency             : ${i3.rows[0].count}`);
    }
  } finally {
    await c.end();
  }
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

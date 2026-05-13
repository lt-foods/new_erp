// Step 10: Final invariants + audit
const { newClient } = require('./_db.cjs');

async function main() {
  const c = newClient();
  await c.connect();
  console.log('==== Step 10: Final invariants ====');

  let failures = 0;

  // 1. PR ↔ Campaigns invariant
  const inv1 = await c.query(`SELECT COUNT(*) AS c FROM fn_check_pr_campaigns_consistency()`);
  console.log(`1. PR↔Campaigns orphans: ${inv1.rows[0].c} ${inv1.rows[0].c === '0' ? '✓' : '✗ FAIL'}`);
  if (inv1.rows[0].c !== '0') failures++;

  // 2. Pickup ↔ stock_movements invariant
  const inv2 = await c.query(`SELECT COUNT(*) AS c FROM fn_check_pickup_movements_consistency()`);
  console.log(`2. Pickup-movement orphans: ${inv2.rows[0].c} ${inv2.rows[0].c === '0' ? '✓' : '✗ FAIL'}`);
  if (inv2.rows[0].c !== '0') failures++;

  // 3. Wallet consistency
  const inv3 = await c.query(`SELECT COUNT(*) AS c FROM fn_check_wallet_consistency()`);
  console.log(`3. Wallet consistency mismatches: ${inv3.rows[0].c} ${inv3.rows[0].c === '0' ? '✓' : '✗ FAIL'}`);
  if (inv3.rows[0].c !== '0') failures++;

  // 4. stock_balances vs Σ movements
  const inv4 = await c.query(`
    SELECT COUNT(*) AS c FROM stock_balances sb
     WHERE sb.on_hand <> COALESCE((SELECT SUM(quantity) FROM stock_movements WHERE location_id=sb.location_id AND sku_id=sb.sku_id), 0)
  `);
  console.log(`4. stock_balances vs Σ movements mismatches: ${inv4.rows[0].c} ${inv4.rows[0].c === '0' ? '✓' : '✗ FAIL'}`);
  if (inv4.rows[0].c !== '0') failures++;

  // 5. E2E chain state
  console.log('\n=== E2E chain state ===');
  const camp = await c.query(`SELECT id, status FROM group_buy_campaigns WHERE id=18`);
  console.log(`Campaign 18: ${camp.rows[0]?.status} ${camp.rows[0]?.status === 'closed' ? '✓' : '✗'}`);
  const pr = await c.query(`SELECT id, status FROM purchase_requests WHERE id=13`);
  console.log(`PR 13: ${pr.rows[0]?.status} ${pr.rows[0]?.status === 'fully_ordered' ? '✓' : '✗'}`);
  const po = await c.query(`SELECT id, status FROM purchase_orders WHERE id=17`);
  console.log(`PO 17: ${po.rows[0]?.status} ${po.rows[0]?.status === 'fully_received' ? '✓' : '✗'}`);
  const tf = await c.query(`SELECT COUNT(*) AS c FROM transfers WHERE transfer_no LIKE 'WAVE-13-S%' AND status='received'`);
  console.log(`Transfers received: ${tf.rows[0].c}/3 ${tf.rows[0].c === '3' ? '✓' : '✗'}`);
  const o = await c.query(`SELECT COUNT(*) AS c FROM customer_orders WHERE campaign_id=18 AND status='completed'`);
  console.log(`Orders completed: ${o.rows[0].c}/3 ${o.rows[0].c === '3' ? '✓' : '✗'}`);

  // 6. SKU 16 stock 應全 0 (取完了)
  const sb = await c.query(`
    SELECT l.name AS loc, sb.on_hand FROM stock_balances sb JOIN locations l ON l.id=sb.location_id
     WHERE sku_id=16 ORDER BY sb.location_id`);
  console.log('\n=== SKU 16 stock (expect all 0) ===');
  sb.rows.forEach(r => console.log(`  ${r.loc}: ${r.on_hand}`));
  const nonZero = sb.rows.filter(r => Number(r.on_hand) !== 0);
  if (nonZero.length > 0) {
    console.log(`✗ ${nonZero.length} location(s) non-zero`);
    failures++;
  } else {
    console.log('✓ All 0');
  }

  await c.end();

  console.log(`\n${failures === 0 ? '✅ ALL CHECKS PASSED' : `✗ ${failures} CHECK(S) FAILED`}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

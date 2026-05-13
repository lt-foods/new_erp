// ⚠️ DESTRUCTIVE — Cleanup E2E full-chain test data
//
// 預設 dry-run (只列出要砍的、不執行)、加 --yes 才真砍。
//
// 用法：
//   node scripts/e2e/full_chain/99_cleanup.cjs           # dry-run
//   node scripts/e2e/full_chain/99_cleanup.cjs --yes     # 真砍
//
// 限制：
//   - 只能對 dev DB 跑 (anfyoeviuhmzzrhilwtm)、production 不該執行
//   - 用 session_replication_role='replica' bypass append-only trigger + 防刪 trigger
//   - DELETE 順序按 FK dependency
//   - 不反向 wallet_ledger / 不重算 stock_balances — 假設 cleanup 後也清掉相關記憶
//
// 擴充：
//   未來新加測試 chain 的 marker、把對應 marker pattern 加進 MARKERS 陣列即可。
const { newClient, TENANT } = require('./_db.cjs');

// 要清的 marker 集 (未來加新 chain 在這裡 push)
const MARKERS = [
  'E2E-CHAIN-260514',
];

const YES = process.argv.includes('--yes');

async function preview(c, marker) {
  console.log(`\n--- Preview for marker "${marker}" ---`);
  const stats = await c.query(`
    SELECT
      (SELECT COUNT(*) FROM products WHERE name LIKE $1) AS products,
      (SELECT COUNT(*) FROM skus s JOIN products p ON p.id=s.product_id WHERE p.name LIKE $1) AS skus,
      (SELECT COUNT(*) FROM group_buy_campaigns WHERE name LIKE $1) AS campaigns,
      (SELECT COUNT(*) FROM customer_orders WHERE order_no LIKE $1) AS orders,
      (SELECT COUNT(*) FROM customer_order_items coi JOIN customer_orders co ON co.id=coi.order_id WHERE co.order_no LIKE $1) AS order_items,
      (SELECT COUNT(*) FROM order_pickup_events WHERE order_id IN (SELECT id FROM customer_orders WHERE order_no LIKE $1)) AS pickup_events,
      (SELECT COUNT(*) FROM purchase_requests pr JOIN purchase_request_campaigns prc ON prc.pr_id=pr.id JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id WHERE gbc.name LIKE $1) AS prs,
      (SELECT COUNT(*) FROM purchase_orders po WHERE po.id IN (SELECT poi.po_id FROM purchase_order_items poi JOIN purchase_request_items pri ON pri.po_item_id=poi.id JOIN purchase_requests pr ON pr.id=pri.pr_id JOIN purchase_request_campaigns prc ON prc.pr_id=pr.id JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id WHERE gbc.name LIKE $1)) AS pos,
      (SELECT COUNT(*) FROM picking_waves WHERE wave_code LIKE 'WV%' AND source_po_id IN (
         SELECT poi.po_id FROM purchase_order_items poi JOIN purchase_request_items pri ON pri.po_item_id=poi.id JOIN purchase_requests pr ON pr.id=pri.pr_id JOIN purchase_request_campaigns prc ON prc.pr_id=pr.id JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id WHERE gbc.name LIKE $1
      )) AS waves,
      (SELECT COUNT(*) FROM stock_movements sm WHERE sm.sku_id IN (SELECT s.id FROM skus s JOIN products p ON p.id=s.product_id WHERE p.name LIKE $1)) AS movements,
      (SELECT COUNT(*) FROM wallet_ledger wl WHERE wl.source_id IN (SELECT id FROM customer_orders WHERE order_no LIKE $1)) AS wallet_rows
  `, [`${marker}%`]);
  const row = stats.rows[0];
  console.log('  products :', row.products);
  console.log('  skus     :', row.skus);
  console.log('  campaigns:', row.campaigns);
  console.log('  orders   :', row.orders, `(+items ${row.order_items}, pickup_events ${row.pickup_events})`);
  console.log('  PRs      :', row.prs);
  console.log('  POs      :', row.pos);
  console.log('  waves    :', row.waves);
  console.log('  movements:', row.movements);
  console.log('  wallet_ledger rows:', row.wallet_rows);
  return row;
}

async function cleanup(c, marker) {
  console.log(`\n--- Cleaning marker "${marker}" ---`);
  await c.query(`BEGIN`);
  // Bypass append-only trigger + product/sku 防刪 trigger
  await c.query(`SET LOCAL session_replication_role = 'replica'`);

  const m = `${marker}%`;

  // 1. wallet_ledger (append-only) — 對應到該 chain 的 order ledger
  await c.query(`DELETE FROM wallet_ledger WHERE source_type='customer_order' AND source_id IN (SELECT id FROM customer_orders WHERE order_no LIKE $1)`, [m]);

  // 2. order_pickup_events (append-only)
  await c.query(`DELETE FROM order_pickup_events WHERE order_id IN (SELECT id FROM customer_orders WHERE order_no LIKE $1)`, [m]);

  // 3. stock_movements 對應 customer_order + transfers + GRs + waves
  await c.query(`DELETE FROM stock_movements WHERE source_doc_type='customer_order' AND source_doc_id IN (SELECT id FROM customer_orders WHERE order_no LIKE $1)`, [m]);

  // 4. customer_order_items + customer_orders
  await c.query(`DELETE FROM customer_order_items WHERE order_id IN (SELECT id FROM customer_orders WHERE order_no LIKE $1)`, [m]);
  await c.query(`DELETE FROM customer_orders WHERE order_no LIKE $1`, [m]);

  // 5. transfers + items (對應 wave)
  const waveIds = (await c.query(`
    SELECT id FROM picking_waves WHERE source_po_id IN (
      SELECT poi.po_id FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id=poi.id
        JOIN purchase_requests pr ON pr.id=pri.pr_id
        JOIN purchase_request_campaigns prc ON prc.pr_id=pr.id
        JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id
       WHERE gbc.name LIKE $1
    )`, [m])).rows.map(r => Number(r.id));
  for (const wid of waveIds) {
    await c.query(`DELETE FROM stock_movements WHERE source_doc_type='transfer' AND source_doc_id IN (SELECT id FROM transfers WHERE transfer_no LIKE 'WAVE-' || $1 || '-S%')`, [wid]);
    await c.query(`DELETE FROM transfer_items WHERE transfer_id IN (SELECT id FROM transfers WHERE transfer_no LIKE 'WAVE-' || $1 || '-S%')`, [wid]);
    await c.query(`DELETE FROM transfers WHERE transfer_no LIKE 'WAVE-' || $1 || '-S%'`, [wid]);
    await c.query(`DELETE FROM picking_wave_audit_log WHERE wave_id=$1`, [wid]);
    await c.query(`DELETE FROM picking_wave_items WHERE wave_id=$1`, [wid]);
  }
  await c.query(`
    DELETE FROM picking_waves WHERE source_po_id IN (
      SELECT poi.po_id FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id=poi.id
        JOIN purchase_requests pr ON pr.id=pri.pr_id
        JOIN purchase_request_campaigns prc ON prc.pr_id=pr.id
        JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id
       WHERE gbc.name LIKE $1
    )`, [m]);

  // 6. GRs + items + 對應 stock_movements
  await c.query(`
    DELETE FROM stock_movements WHERE source_doc_type='goods_receipt' AND source_doc_id IN (
      SELECT gr.id FROM goods_receipts gr
        JOIN purchase_orders po ON po.id=gr.po_id
        JOIN purchase_order_items poi ON poi.po_id=po.id
        JOIN purchase_request_items pri ON pri.po_item_id=poi.id
        JOIN purchase_request_campaigns prc ON prc.pr_id=pri.pr_id
        JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id
       WHERE gbc.name LIKE $1
    )`, [m]);
  await c.query(`
    DELETE FROM goods_receipt_items WHERE gr_id IN (
      SELECT gr.id FROM goods_receipts gr
        JOIN purchase_orders po ON po.id=gr.po_id
        JOIN purchase_order_items poi ON poi.po_id=po.id
        JOIN purchase_request_items pri ON pri.po_item_id=poi.id
        JOIN purchase_request_campaigns prc ON prc.pr_id=pri.pr_id
        JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id
       WHERE gbc.name LIKE $1
    )`, [m]);
  await c.query(`
    DELETE FROM goods_receipts WHERE id IN (
      SELECT gr.id FROM goods_receipts gr
        JOIN purchase_orders po ON po.id=gr.po_id
        JOIN purchase_order_items poi ON poi.po_id=po.id
        JOIN purchase_request_items pri ON pri.po_item_id=poi.id
        JOIN purchase_request_campaigns prc ON prc.pr_id=pri.pr_id
        JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id
       WHERE gbc.name LIKE $1
    )`, [m]);

  // 7. POs + items
  await c.query(`
    DELETE FROM purchase_order_items WHERE po_id IN (
      SELECT DISTINCT poi.po_id FROM purchase_order_items poi
        JOIN purchase_request_items pri ON pri.po_item_id=poi.id
        JOIN purchase_request_campaigns prc ON prc.pr_id=pri.pr_id
        JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id
       WHERE gbc.name LIKE $1
    )`, [m]);
  await c.query(`
    DELETE FROM purchase_orders WHERE id NOT IN (SELECT DISTINCT po_id FROM purchase_order_items)
      AND id IN (
        SELECT po.id FROM purchase_orders po
        WHERE po.id::text = ANY (SELECT poi.po_id::text FROM purchase_order_items poi WHERE 1=0) -- noop guard, real delete below
      )`, []);
  // 上面 noop、真正 cleanup: 找出該 marker 對應 PO id 集
  await c.query(`
    DELETE FROM purchase_orders WHERE id IN (
      SELECT DISTINCT po.id FROM purchase_orders po
        WHERE po.po_no LIKE $1 OR po.id IN (
          SELECT poi.po_id FROM purchase_order_items poi WHERE 1=0
        ) OR EXISTS (
          SELECT 1 FROM purchase_requests pr
            JOIN purchase_request_campaigns prc ON prc.pr_id=pr.id
            JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id
           WHERE gbc.name LIKE $1 AND pr.id = ANY (
             SELECT pri2.pr_id FROM purchase_request_items pri2 WHERE pri2.po_item_id IN (
               SELECT poi2.id FROM purchase_order_items poi2 WHERE poi2.po_id = po.id
             )
           )
        )
    )`, [m]);

  // 8. PR + items + campaigns join
  await c.query(`
    DELETE FROM purchase_request_items WHERE pr_id IN (
      SELECT pr_id FROM purchase_request_campaigns prc
        JOIN group_buy_campaigns gbc ON gbc.id=prc.campaign_id
       WHERE gbc.name LIKE $1
    )`, [m]);
  await c.query(`
    DELETE FROM purchase_request_campaigns WHERE campaign_id IN (SELECT id FROM group_buy_campaigns WHERE name LIKE $1)`, [m]);
  await c.query(`
    DELETE FROM purchase_requests WHERE source_campaign_id IN (SELECT id FROM group_buy_campaigns WHERE name LIKE $1)
       OR id IN (SELECT DISTINCT pr_id FROM purchase_request_campaigns WHERE 1=0) -- noop
       OR id NOT IN (SELECT DISTINCT pr_id FROM purchase_request_items)
       OR source_close_date IS NOT NULL AND pr_no LIKE $1`, [m]);

  // 9. campaign + items
  await c.query(`DELETE FROM campaign_items WHERE campaign_id IN (SELECT id FROM group_buy_campaigns WHERE name LIKE $1)`, [m]);
  await c.query(`DELETE FROM group_buy_campaigns WHERE name LIKE $1`, [m]);

  // 10. stock_movements 殘留 (any 沒砍到的 sku-related)
  await c.query(`
    DELETE FROM stock_movements WHERE sku_id IN (
      SELECT s.id FROM skus s JOIN products p ON p.id=s.product_id WHERE p.name LIKE $1
    )`, [m]);
  // stock_balances rows for marker sku
  await c.query(`
    DELETE FROM stock_balances WHERE sku_id IN (
      SELECT s.id FROM skus s JOIN products p ON p.id=s.product_id WHERE p.name LIKE $1
    )`, [m]);

  // 11. prices / supplier_skus / skus / products
  await c.query(`DELETE FROM prices WHERE sku_id IN (SELECT s.id FROM skus s JOIN products p ON p.id=s.product_id WHERE p.name LIKE $1)`, [m]);
  await c.query(`DELETE FROM supplier_skus WHERE sku_id IN (SELECT s.id FROM skus s JOIN products p ON p.id=s.product_id WHERE p.name LIKE $1)`, [m]);
  await c.query(`DELETE FROM skus WHERE product_id IN (SELECT id FROM products WHERE name LIKE $1)`, [m]);
  await c.query(`DELETE FROM products WHERE name LIKE $1`, [m]);

  await c.query(`COMMIT`);
  console.log(`  ✓ cleanup done`);
}

async function main() {
  console.log('⚠️  E2E full-chain CLEANUP', YES ? '(--yes, REAL DELETE)' : '(dry-run)');
  console.log('   Target DB: anfyoeviuhmzzrhilwtm (dev)');
  console.log('   Markers:', MARKERS.join(', '));
  if (!YES) {
    console.log('\n   ℹ️  This is a dry-run. Add --yes to actually delete.');
  }

  const c = newClient();
  await c.connect();
  try {
    for (const marker of MARKERS) {
      const stats = await preview(c, marker);
      const total = Object.values(stats).reduce((s, v) => s + Number(v), 0);
      if (total === 0) {
        console.log('  (no data for this marker, skip)');
        continue;
      }
      if (YES) {
        await cleanup(c, marker);
        // Re-preview to confirm
        console.log('\n--- After cleanup ---');
        await preview(c, marker);
      }
    }
  } finally {
    await c.end();
  }
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

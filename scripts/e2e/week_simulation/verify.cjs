// Week simulation verify — invariants + chain traceability sampling
const { newClient, TENANT } = require('./_db.cjs');
const { makeRng } = require('./_rng.cjs');

const MARKER_PATTERN = 'E2E-WEEK-260514%';
const SAMPLE_SIZE = Number(process.env.SAMPLE || 30);

async function main() {
  const c = newClient();
  await c.connect();
  console.log('==== Week Simulation Verify ====\n');

  let failures = 0;

  // 1. Invariants
  console.log('--- Invariants ---');
  const inv1 = (await c.query(`SELECT COUNT(*) FROM fn_check_pr_campaigns_consistency()`)).rows[0].count;
  console.log(`  PR↔Campaigns orphans       : ${inv1} ${inv1 === '0' ? '✓' : '✗'}`); if (inv1 !== '0') failures++;
  const inv2 = (await c.query(`SELECT COUNT(*) FROM fn_check_pickup_movements_consistency()`)).rows[0].count;
  console.log(`  Pickup-movement orphans    : ${inv2} ${inv2 === '0' ? '✓' : '✗'}`); if (inv2 !== '0') failures++;
  const inv3 = (await c.query(`SELECT COUNT(*) FROM fn_check_wallet_consistency()`)).rows[0].count;
  console.log(`  Wallet consistency         : ${inv3} ${inv3 === '0' ? '✓' : '✗'}`); if (inv3 !== '0') failures++;
  const inv4 = (await c.query(`
    SELECT COUNT(*) FROM stock_balances sb
     WHERE sb.on_hand <> COALESCE((SELECT SUM(quantity) FROM stock_movements WHERE location_id=sb.location_id AND sku_id=sb.sku_id), 0)
  `)).rows[0].count;
  console.log(`  Stock_balances vs movements: ${inv4} ${inv4 === '0' ? '✓' : '✗'}`); if (inv4 !== '0') failures++;

  // 2. Summary stats — marker scope
  console.log('\n--- Marker scope summary ---');
  const stats = await c.query(`
    WITH
      camps AS (SELECT id FROM group_buy_campaigns WHERE name LIKE $1),
      orders AS (
        SELECT id FROM customer_orders
         WHERE campaign_id IN (SELECT id FROM camps)
      ),
      prs AS (
        SELECT DISTINCT pr_id FROM purchase_request_campaigns WHERE campaign_id IN (SELECT id FROM camps)
      ),
      pos AS (
        SELECT DISTINCT po.id FROM purchase_orders po
         WHERE po.id IN (
           SELECT poi.po_id FROM purchase_order_items poi
            JOIN purchase_request_items pri ON pri.po_item_id=poi.id
           WHERE pri.pr_id IN (SELECT pr_id FROM prs)
         )
      ),
      grs AS (SELECT id FROM goods_receipts WHERE po_id IN (SELECT id FROM pos)),
      waves AS (SELECT id FROM picking_waves WHERE source_po_id IN (SELECT id FROM pos))
    SELECT
      (SELECT COUNT(*) FROM camps) AS campaigns,
      (SELECT COUNT(*) FROM camps WHERE id IN (SELECT id FROM group_buy_campaigns WHERE status='closed')) AS campaigns_closed,
      (SELECT COUNT(*) FROM orders) AS orders,
      (SELECT COUNT(*) FROM customer_orders co WHERE co.id IN (SELECT id FROM orders) AND co.status='completed') AS orders_completed,
      (SELECT COUNT(*) FROM customer_order_items coi WHERE coi.order_id IN (SELECT id FROM orders)) AS order_items,
      (SELECT COUNT(*) FROM customer_order_items coi WHERE coi.order_id IN (SELECT id FROM orders) AND coi.status='picked_up') AS items_picked_up,
      (SELECT COUNT(*) FROM prs) AS prs,
      (SELECT COUNT(*) FROM pos) AS pos,
      (SELECT COUNT(*) FROM grs) AS grs,
      (SELECT COUNT(*) FROM waves) AS waves
  `, [MARKER_PATTERN]);
  const s = stats.rows[0];
  console.log(`  campaigns       : ${s.campaigns} (closed: ${s.campaigns_closed})`);
  console.log(`  orders          : ${s.orders} (completed: ${s.orders_completed})`);
  console.log(`  order_items     : ${s.order_items} (picked_up: ${s.items_picked_up})`);
  console.log(`  PRs / POs / GRs / Waves: ${s.prs} / ${s.pos} / ${s.grs} / ${s.waves}`);

  // 3. Aggregate verification: order qty == GR qty == sale movement qty (per SKU)
  console.log('\n--- Aggregate match per SKU ---');
  const agg = await c.query(`
    WITH camps AS (SELECT id FROM group_buy_campaigns WHERE name LIKE $1),
         orders AS (SELECT id FROM customer_orders WHERE campaign_id IN (SELECT id FROM camps)),
         o_qty AS (
           SELECT sku_id, SUM(qty) AS qty FROM customer_order_items
            WHERE order_id IN (SELECT id FROM orders) GROUP BY sku_id
         ),
         po_qty AS (
           SELECT poi.sku_id, SUM(poi.qty_ordered) AS qty FROM purchase_order_items poi
            WHERE poi.po_id IN (
              SELECT poi2.po_id FROM purchase_order_items poi2
               JOIN purchase_request_items pri ON pri.po_item_id=poi2.id
              WHERE pri.pr_id IN (SELECT pr_id FROM purchase_request_campaigns WHERE campaign_id IN (SELECT id FROM camps))
            )
           GROUP BY poi.sku_id
         ),
         gr_qty AS (
           SELECT gri.sku_id, SUM(gri.qty_received) AS qty FROM goods_receipt_items gri
            JOIN goods_receipts gr ON gr.id=gri.gr_id
            WHERE gr.status='confirmed' AND gr.po_id IN (
              SELECT poi.po_id FROM purchase_order_items poi
               JOIN purchase_request_items pri ON pri.po_item_id=poi.id
              WHERE pri.pr_id IN (SELECT pr_id FROM purchase_request_campaigns WHERE campaign_id IN (SELECT id FROM camps))
            )
           GROUP BY gri.sku_id
         ),
         sale_qty AS (
           SELECT sm.sku_id, SUM(-sm.quantity) AS qty FROM stock_movements sm
            WHERE sm.movement_type='sale' AND sm.source_doc_type='customer_order'
              AND sm.source_doc_id IN (SELECT id FROM orders) GROUP BY sm.sku_id
         )
    SELECT
      COALESCE(o.sku_id, po.sku_id, gr.sku_id, sa.sku_id) AS sku_id,
      o.qty AS order_qty,
      po.qty AS po_qty,
      gr.qty AS gr_qty,
      sa.qty AS sale_qty
    FROM o_qty o
    FULL OUTER JOIN po_qty po ON po.sku_id = o.sku_id
    FULL OUTER JOIN gr_qty gr ON gr.sku_id = o.sku_id
    FULL OUTER JOIN sale_qty sa ON sa.sku_id = o.sku_id
    ORDER BY sku_id
  `, [MARKER_PATTERN]);
  for (const r of agg.rows) {
    const ok = String(r.order_qty) === String(r.po_qty) && String(r.po_qty) === String(r.gr_qty) && String(r.gr_qty) === String(r.sale_qty);
    console.log(`  sku ${r.sku_id}: order ${r.order_qty} / po ${r.po_qty} / gr ${r.gr_qty} / sale ${r.sale_qty} ${ok ? '✓' : '⚠ partial'}`);
    if (!ok && !(r.order_qty == r.gr_qty && r.gr_qty == r.sale_qty)) failures++;
  }

  // 4. Chain traceability sample
  console.log('\n--- Chain traceability sample ---');
  const rng = makeRng('verify-260514');
  const orders = (await c.query(`
    SELECT id, order_no FROM customer_orders
     WHERE campaign_id IN (SELECT id FROM group_buy_campaigns WHERE name LIKE $1)
       AND status='completed'
     ORDER BY id`, [MARKER_PATTERN])).rows;
  console.log(`  Completed orders total: ${orders.length}, sampling ${Math.min(SAMPLE_SIZE, orders.length)}`);
  const sample = rng.pickN(orders, Math.min(SAMPLE_SIZE, orders.length));
  let traceFailures = 0;
  for (const o of sample) {
    const trace = await traceOrder(c, o.id);
    if (!trace.ok) {
      traceFailures++;
      console.log(`  ✗ order ${o.order_no} (id=${o.id}): ${trace.reason}`);
    }
  }
  console.log(`  Chain traces: ${sample.length - traceFailures}/${sample.length} ✓`);
  if (traceFailures > 0) failures++;

  await c.end();
  console.log(`\n${failures === 0 ? '✅ ALL CHECKS PASSED' : `✗ ${failures} CHECK(S) FAILED`}`);
  process.exit(failures === 0 ? 0 : 1);
}

// Trace one order through the full chain
async function traceOrder(c, orderId) {
  // Steps:
  // 1. order exists + completed
  // 2. items exist + picked_up + pickup_movement_id NOT NULL
  // 3. campaign linked + has campaign_items
  // 4. PR exists for campaign (via purchase_request_campaigns)
  // 5. PR items have po_item_id (split)
  // 6. PO sent
  // 7. GR confirmed
  // 8. Wave has matching wave_items
  // 9. Transfer from wave received
  // 10. Stock movements: purchase_receipt (HQ +), transfer_out (HQ -), transfer_in (store +), sale (store -)
  // 11. pickup_event exists

  const o = (await c.query(`SELECT * FROM customer_orders WHERE id=$1`, [orderId])).rows[0];
  if (!o || o.status !== 'completed') return { ok: false, reason: 'order not completed' };
  const items = (await c.query(`SELECT * FROM customer_order_items WHERE order_id=$1`, [orderId])).rows;
  for (const it of items) {
    if (it.status !== 'picked_up') return { ok: false, reason: `item ${it.id} not picked_up` };
    if (!it.pickup_movement_id) return { ok: false, reason: `item ${it.id} no pickup_movement_id` };
  }
  // campaign
  const camp = (await c.query(`SELECT id, status FROM group_buy_campaigns WHERE id=$1`, [o.campaign_id])).rows[0];
  if (!camp || camp.status !== 'closed') return { ok: false, reason: 'campaign not closed' };
  // PR via prc
  const prRows = (await c.query(`SELECT pr_id FROM purchase_request_campaigns WHERE campaign_id=$1`, [o.campaign_id])).rows;
  if (prRows.length === 0) return { ok: false, reason: 'no PR linked to campaign' };
  // PR has split po_item_ids
  const poItemIds = (await c.query(`SELECT po_item_id FROM purchase_request_items WHERE pr_id = ANY($1) AND sku_id = ANY($2) AND po_item_id IS NOT NULL`,
    [prRows.map(r => r.pr_id), items.map(it => it.sku_id)])).rows.map(r => r.po_item_id);
  if (poItemIds.length === 0) return { ok: false, reason: 'no po_item_id from PR items' };
  // PO sent / fully_received
  const pos = (await c.query(`SELECT DISTINCT po.id, po.status FROM purchase_orders po JOIN purchase_order_items poi ON poi.po_id=po.id WHERE poi.id = ANY($1)`, [poItemIds])).rows;
  if (pos.length === 0) return { ok: false, reason: 'no PO for po_items' };
  for (const po of pos) {
    if (!['sent', 'partially_received', 'fully_received'].includes(po.status)) return { ok: false, reason: `PO ${po.id} status ${po.status}` };
  }
  // GR
  const grRows = (await c.query(`SELECT gr.id, gr.status FROM goods_receipts gr WHERE gr.po_id = ANY($1) AND gr.status='confirmed'`, [pos.map(p => p.id)])).rows;
  if (grRows.length === 0) return { ok: false, reason: 'no confirmed GR' };
  // Wave + wave_items
  const waves = (await c.query(`
    SELECT pw.id, pwi.sku_id, pwi.store_id, pwi.qty
      FROM picking_waves pw JOIN picking_wave_items pwi ON pwi.wave_id=pw.id
     WHERE pw.source_po_id = ANY($1) AND pwi.store_id = $2
       AND pwi.sku_id = ANY($3)`, [pos.map(p => p.id), o.pickup_store_id, items.map(it => it.sku_id)])).rows;
  if (waves.length === 0) return { ok: false, reason: 'no wave_items for order store + sku' };
  // Transfers received (對 wave)
  const tfs = (await c.query(`
    SELECT t.id, t.status FROM transfers t
     WHERE t.transfer_no LIKE ANY($1) AND t.status='received'`, [waves.map(w => `WAVE-${w.id}-S${o.pickup_store_id}`)])).rows;
  if (tfs.length === 0) return { ok: false, reason: 'no received transfer to store' };
  // Stock sale movements for order
  const saleMv = (await c.query(`
    SELECT sm.id, sm.sku_id, sm.quantity FROM stock_movements sm
     WHERE sm.movement_type='sale' AND sm.source_doc_type='customer_order' AND sm.source_doc_id=$1`, [orderId])).rows;
  if (saleMv.length !== items.length) return { ok: false, reason: `expected ${items.length} sale movements, got ${saleMv.length}` };
  // Pickup event
  const ev = (await c.query(`SELECT id FROM order_pickup_events WHERE order_id=$1`, [orderId])).rows;
  if (ev.length === 0) return { ok: false, reason: 'no pickup event' };

  return { ok: true };
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

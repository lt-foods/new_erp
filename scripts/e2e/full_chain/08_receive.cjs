// Step 8: 分店收貨 — rpc_receive_transfer 對 3 張 transfer
const { newClient, setJwt: setJwtRaw, ADMIN_UID } = require('./_db.cjs');

const WAVE_ID = 13;
const c = newClient();
async function setJwt() { return setJwtRaw(c); }

async function main() {
  await c.connect();
  console.log('==== Step 8: Receive transfers ====');

  const tfs = await c.query(`SELECT id, transfer_no, dest_location, status FROM transfers WHERE transfer_no LIKE 'WAVE-' || $1 || '-S%' ORDER BY id`, [WAVE_ID]);
  for (const t of tfs.rows) {
    if (t.status === 'received' || t.status === 'closed') {
      console.log(`${t.transfer_no} already ${t.status}, skip`);
      continue;
    }
    const items = await c.query(`SELECT id, sku_id, qty_requested FROM transfer_items WHERE transfer_id=$1`, [t.id]);
    // lines: [{ transfer_item_id, qty_received }, ...]
    const lines = items.rows.map(it => ({
      transfer_item_id: Number(it.id),
      qty_received: Number(it.qty_requested),
    }));
    await c.query(`BEGIN`);
    await setJwt();
    try {
      await c.query(`SELECT rpc_receive_transfer($1, $2, $3, $4)`,
        [t.id, JSON.stringify(lines), ADMIN_UID, 'E2E auto-receive']);
      console.log(`✓ ${t.transfer_no} received`);
    } catch (e) {
      console.log(`${t.transfer_no} error:`, e.message);
    }
    await c.query(`COMMIT`);
  }

  // 驗 transfers status
  const tfsAfter = await c.query(`SELECT transfer_no, status, received_at FROM transfers WHERE transfer_no LIKE 'WAVE-' || $1 || '-S%' ORDER BY id`, [WAVE_ID]);
  console.log('\nTransfers after:', JSON.stringify(tfsAfter.rows, null, 2));

  // 驗 stock_balances 各店 (sku 16)
  const sb = await c.query(`
    SELECT sb.location_id, l.name AS loc, sb.on_hand
      FROM stock_balances sb JOIN locations l ON l.id=sb.location_id
     WHERE sb.sku_id=16 ORDER BY sb.location_id
  `);
  console.log('\nStock balances (sku=16):', JSON.stringify(sb.rows, null, 2));

  // 驗 customer_orders status (should be 'ready' since stock received)
  const orders = await c.query(`
    SELECT id, order_no, status, pickup_store_id
      FROM customer_orders WHERE campaign_id=18 ORDER BY id
  `);
  console.log('\nCustomer orders:', JSON.stringify(orders.rows, null, 2));

  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

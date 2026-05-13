// Step 7: 撿貨建 wave + 派 transfer (SQL via rpc_create_wave_from_po)
const { newClient, setJwt: setJwtRaw, TENANT, ADMIN_UID } = require('./_db.cjs');

const PO_ID = 17;
const SKU_ID = 16;
const ALLOCATIONS = { [SKU_ID]: { 2: 15, 36: 10, 37: 5 } };

const c = newClient();
async function setJwt() { return setJwtRaw(c); }

async function main() {
  await c.connect();
  console.log('==== Step 7: Create picking wave from PO ====');

  // 派貨日 = 後天
  const d = new Date(); d.setDate(d.getDate() + 2);
  const waveDate = d.toISOString().slice(0, 10);

  // allocations 格式: rpc 預期 [{ sku_id, store_id, qty }]
  const allocs = [];
  for (const [skuId, stores] of Object.entries(ALLOCATIONS)) {
    for (const [storeId, qty] of Object.entries(stores)) {
      allocs.push({ sku_id: Number(skuId), store_id: Number(storeId), qty });
    }
  }

  // idempotent: 若該 PO 已有 wave、直接用既有的
  const existing = await c.query(`SELECT id FROM picking_waves WHERE source_po_id=$1 AND status <> 'cancelled' ORDER BY id DESC LIMIT 1`, [PO_ID]);
  let waveId;
  if (existing.rows[0]) {
    waveId = Number(existing.rows[0].id);
    console.log('Reused existing wave:', waveId);
  } else {
    await c.query(`BEGIN`);
    await setJwt();
    const r = await c.query(`SELECT rpc_create_wave_from_po($1, $2, $3, $4) AS result`,
      [PO_ID, waveDate, JSON.stringify(allocs), ADMIN_UID]);
    const result = r.rows[0].result;
    console.log('✓ create_wave_from_po result:', JSON.stringify(result));
    waveId = Number(result.wave_id);
    await c.query(`COMMIT`);
  }

  // 驗 wave + items
  const wave = await c.query(`SELECT id, wave_code, status, wave_date, source_po_id FROM picking_waves WHERE id=$1`, [waveId]);
  console.log('Wave:', JSON.stringify(wave.rows[0]));
  const items = await c.query(`SELECT sku_id, store_id, qty, campaign_id FROM picking_wave_items WHERE wave_id=$1 ORDER BY store_id`, [waveId]);
  console.log('Wave items:', JSON.stringify(items.rows, null, 2));

  // 驗 stock_movements (HQ -30 拆 3 筆 or 1 筆?)
  const mv = await c.query(`
    SELECT movement_type, location_id, sku_id, quantity, source_doc_type, source_doc_id
      FROM stock_movements WHERE source_doc_type='picking_wave' AND source_doc_id=$1
     ORDER BY id`, [waveId]);
  console.log('stock_movements from wave:', JSON.stringify(mv.rows, null, 2));

  // wave 還是 draft 要先 confirm picked、然後 generate transfer
  await c.query(`BEGIN`);
  await setJwt();
  const status = (await c.query(`SELECT status FROM picking_waves WHERE id=$1`, [waveId])).rows[0].status;
  if (status === 'draft') {
    await c.query(`SELECT rpc_confirm_picked($1, $2)`, [waveId, ADMIN_UID]);
    console.log('✓ rpc_confirm_picked → wave status:',
      (await c.query(`SELECT status FROM picking_waves WHERE id=$1`, [waveId])).rows[0].status);
  } else {
    console.log('Wave already', status);
  }
  await c.query(`COMMIT`);

  // generate transfer (HQ -> stores)
  const hqLoc = (await c.query(`SELECT id FROM locations WHERE tenant_id=$1 ORDER BY id LIMIT 1`, [TENANT])).rows[0].id;
  await c.query(`BEGIN`);
  await setJwt();
  try {
    const gen = await c.query(`SELECT generate_transfer_from_wave($1, $2, $3) AS result`, [waveId, hqLoc, ADMIN_UID]);
    console.log('✓ generate_transfer_from_wave result:', JSON.stringify(gen.rows[0].result));
  } catch (e) {
    console.log('generate_transfer_from_wave error:', e.message);
  }
  await c.query(`COMMIT`);

  // mark orders shipping (status: shipping)
  await c.query(`BEGIN`);
  await setJwt();
  try {
    await c.query(`SELECT rpc_mark_orders_shipping_for_wave($1, $2)`, [waveId, ADMIN_UID]);
    console.log('✓ rpc_mark_orders_shipping_for_wave done');
  } catch (e) {
    console.log('mark_shipping error:', e.message);
  }
  await c.query(`COMMIT`);

  // 驗 transfers 建立 (應該每店一張、共 3 張)
  const tfs = await c.query(`
    SELECT id, transfer_no, transfer_type, source_location, dest_location, status
      FROM transfers WHERE transfer_no LIKE 'WAVE-' || $1 || '-S%' ORDER BY id`, [waveId]);
  console.log('Transfers:', JSON.stringify(tfs.rows, null, 2));

  // 驗 stock_movements
  const mv2 = await c.query(`
    SELECT movement_type, location_id, sku_id, quantity
      FROM stock_movements WHERE source_doc_type='picking_wave' AND source_doc_id=$1
     ORDER BY id`, [waveId]);
  console.log('stock_movements (wave):', JSON.stringify(mv2.rows, null, 2));

  console.log('\n==== Step 7 done. wave_id=' + waveId + ' ====');
  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

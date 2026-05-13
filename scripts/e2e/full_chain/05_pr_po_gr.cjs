// Step 5+6: PR submit/approve → split to PO → send → GR confirm
const { newClient, setJwt: setJwtRaw, TENANT, ADMIN_UID } = require('./_db.cjs');

const PR_ID = 13;
const c = newClient();
async function setJwt() { return setJwtRaw(c); }

async function main() {
  await c.connect();
  console.log('==== Step 5+6: PR → PO → GR ====');

  // PR draft 要先填 supplier / cost / 售價 / 分店價 才能 submit
  // 我們 setup 時 supplier_skus has supplier_id=1, default_unit_cost=100
  // 但 PR items 是 close_campaign 自動建、預設沒填 retail/franchise — 補填
  await c.query(`BEGIN`);
  await setJwt();
  await c.query(`
    UPDATE purchase_request_items
       SET unit_cost = 100,
           retail_price = 180,
           franchise_price = 140,
           suggested_supplier_id = 1
     WHERE pr_id = $1
  `, [PR_ID]);
  await c.query(`
    UPDATE purchase_requests SET total_amount = (SELECT COALESCE(SUM(line_subtotal),0) FROM purchase_request_items WHERE pr_id=$1)
     WHERE id = $1
  `, [PR_ID]);
  await c.query(`COMMIT`);
  console.log('✓ PR items filled (cost=100 retail=180 franchise=140)');

  // 5.1 submit (idempotent)
  const before = (await c.query(`SELECT status FROM purchase_requests WHERE id=$1`, [PR_ID])).rows[0];
  if (before.status === 'draft') {
    await c.query(`BEGIN`);
    await setJwt();
    await c.query(`SELECT rpc_submit_pr($1, $2)`, [PR_ID, ADMIN_UID]);
    await c.query(`COMMIT`);
  }
  console.log('✓ PR status:',
    (await c.query(`SELECT status, review_status FROM purchase_requests WHERE id=$1`, [PR_ID])).rows[0]);

  // 5.2 approve (skip if already approved by auto-threshold)
  const prState = (await c.query(`SELECT status, review_status FROM purchase_requests WHERE id=$1`, [PR_ID])).rows[0];
  if (prState.review_status !== 'approved') {
    await c.query(`BEGIN`);
    await setJwt();
    await c.query(`SELECT rpc_approve_purchase_request($1, $2, $3)`, [PR_ID, 'E2E auto-approve', ADMIN_UID]);
    await c.query(`COMMIT`);
    console.log('✓ rpc_approve_purchase_request → status:',
      (await c.query(`SELECT status, review_status FROM purchase_requests WHERE id=$1`, [PR_ID])).rows[0]);
  } else {
    console.log('PR already auto-approved (amount below threshold)');
  }

  // 5.3 split to POs
  // dest_location_id: 用 tenant 內第一個 location (應該是 HQ)
  const loc = await c.query(`SELECT id, code, name FROM locations WHERE tenant_id=$1 ORDER BY id LIMIT 1`, [TENANT]);
  const destLoc = loc.rows[0].id;
  console.log('Dest location:', destLoc, loc.rows[0].name);

  await c.query(`BEGIN`);
  await setJwt();
  const split = await c.query(`SELECT rpc_split_pr_to_pos($1, $2, $3) AS result`, [PR_ID, destLoc, ADMIN_UID]);
  await c.query(`COMMIT`);
  console.log('✓ rpc_split_pr_to_pos result:', JSON.stringify(split.rows[0].result));

  // 5.4 找出新建的 POs
  const pos = await c.query(`
    SELECT po.id, po.po_no, po.status, po.supplier_id, COUNT(poi.id) AS items
      FROM purchase_orders po
      JOIN purchase_order_items poi ON poi.po_id = po.id
     WHERE poi.id IN (SELECT po_item_id FROM purchase_request_items WHERE pr_id=$1 AND po_item_id IS NOT NULL)
     GROUP BY po.id, po.po_no, po.status, po.supplier_id
  `, [PR_ID]);
  console.log('New POs:', JSON.stringify(pos.rows, null, 2));

  if (pos.rows.length === 0) throw new Error('no POs split');
  const poId = pos.rows[0].id;

  // 5.5 send PO
  await c.query(`BEGIN`);
  await setJwt();
  await c.query(`SELECT rpc_send_purchase_order($1, $2, $3)`, [poId, 'phone', ADMIN_UID]);
  await c.query(`COMMIT`);
  console.log('✓ rpc_send_purchase_order → PO status:',
    (await c.query(`SELECT status FROM purchase_orders WHERE id=$1`, [poId])).rows[0].status);

  // ===== Step 6: GR =====
  // INSERT GR + GR items + 跑 rpc_confirm_gr
  await c.query(`BEGIN`);
  await setJwt();
  const grNo = `E2E-CHAIN-260514-GR-${poId}`;
  // 取 PO items
  const poItems = await c.query(`SELECT id, sku_id, qty_ordered, unit_cost FROM purchase_order_items WHERE po_id=$1`, [poId]);
  const grIns = await c.query(`
    INSERT INTO goods_receipts (tenant_id, gr_no, po_id, supplier_id, dest_location_id, status,
                                receive_date, received_by, created_by, updated_by)
    VALUES ($1, $2, $3, (SELECT supplier_id FROM purchase_orders WHERE id=$3), $4, 'draft',
            CURRENT_DATE, $5, $5, $5)
    RETURNING id, gr_no
  `, [TENANT, grNo, poId, destLoc, ADMIN_UID]);
  const grId = grIns.rows[0].id;
  console.log('Created GR:', grId, grIns.rows[0].gr_no);

  for (const it of poItems.rows) {
    await c.query(`
      INSERT INTO goods_receipt_items (gr_id, po_item_id, sku_id, qty_expected, qty_received, unit_cost, created_by, updated_by)
      VALUES ($1, $2, $3, $4, $4, $5, $6, $6)
    `, [grId, it.id, it.sku_id, it.qty_ordered, it.unit_cost, ADMIN_UID]);
  }
  console.log('✓ GR items inserted:', poItems.rows.length);

  await c.query(`SELECT rpc_confirm_gr($1, $2)`, [grId, ADMIN_UID]);
  await c.query(`COMMIT`);
  console.log('✓ rpc_confirm_gr → GR status:',
    (await c.query(`SELECT status FROM goods_receipts WHERE id=$1`, [grId])).rows[0].status);

  // 6.1 驗 PO status (should be fully_received)
  const poFinal = await c.query(`SELECT status FROM purchase_orders WHERE id=$1`, [poId]);
  console.log('PO final status:', poFinal.rows[0].status);

  // 6.2 驗 stock_movements
  const mv = await c.query(`
    SELECT movement_type, location_id, sku_id, quantity, source_doc_type, source_doc_id
      FROM stock_movements
     WHERE source_doc_type = 'goods_receipt' AND source_doc_id = $1
  `, [grId]);
  console.log('stock_movements for GR:', JSON.stringify(mv.rows, null, 2));

  // 6.3 驗 v_picking_demand_by_po — PO 應出現含 3 store demand
  const view = await c.query(`
    SELECT po_no, sku_code, gr_qty, demand_qty, store_id, store_name
      FROM v_picking_demand_by_po WHERE po_id=$1 ORDER BY store_name
  `, [poId]);
  console.log('\n=== v_picking_demand_by_po for new PO ===');
  console.log(JSON.stringify(view.rows, null, 2));

  console.log('\n==== Step 5+6 done. po_id=' + poId + ', gr_id=' + grId + ' ====');

  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

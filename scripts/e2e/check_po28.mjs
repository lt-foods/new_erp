import { Client } from 'pg';
if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com', port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm', password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres', ssl: { rejectUnauthorized: false },
});
await c.connect();

// PO 本身狀態
const po = await c.query(`
  SELECT id, po_no, status, supplier_id FROM purchase_orders WHERE po_no = 'PO2604290028'
`);
console.log('PO2604290028:', po.rows[0]);

if (po.rows.length === 0) { await c.end(); process.exit(0); }
const poId = po.rows[0].id;

// PO items + GR 量
const items = await c.query(`
  SELECT poi.id, poi.sku_id, sku.sku_code,
         poi.qty_ordered,
         COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status='confirmed'), 0) AS gr_qty
    FROM purchase_order_items poi
    JOIN skus sku ON sku.id = poi.sku_id
    LEFT JOIN goods_receipt_items gri ON gri.po_item_id = poi.id
    LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id
   WHERE poi.po_id = $1
   GROUP BY poi.id, sku.sku_code
`, [poId]);
console.log('\nPO items:');
items.rows.forEach(it => console.log(`  poi#${it.id} ${it.sku_code} ordered=${it.qty_ordered} gr_qty=${it.gr_qty}`));

// PR 來源（看 PR 對應 campaigns）
const prs = await c.query(`
  SELECT DISTINCT pr.id AS pr_id, pr.pr_no, pr.source_type, pr.source_close_date,
         array_agg(DISTINCT prc.campaign_id) AS campaigns
    FROM purchase_request_items pri
    JOIN purchase_requests pr ON pr.id = pri.pr_id
    LEFT JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
   WHERE pri.po_item_id IN (SELECT id FROM purchase_order_items WHERE po_id = $1)
   GROUP BY pr.id, pr.pr_no, pr.source_type, pr.source_close_date
`, [poId]);
console.log('\nPRs:');
prs.rows.forEach(p => console.log(`  PR#${p.pr_id} ${p.pr_no} type=${p.source_type} date=${p.source_close_date} campaigns=${p.campaigns}`));

// 看 v_picking_demand_by_po
const view = await c.query(`SELECT * FROM v_picking_demand_by_po WHERE po_id = $1`, [poId]);
console.log(`\nv_picking_demand_by_po (${view.rows.length} rows):`);
view.rows.forEach(r => console.log(`  sku=${r.sku_code} store=${r.store_name ?? '(null)'} gr=${r.gr_qty} demand=${r.demand_qty} wave=${r.wave_qty} shipped=${r.shipped_qty}`));

await c.end();

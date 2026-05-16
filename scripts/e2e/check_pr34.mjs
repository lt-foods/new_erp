import { Client } from 'pg';
if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com', port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm', password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres', ssl: { rejectUnauthorized: false },
});
await c.connect();

const pr = await c.query(`
  SELECT id, pr_no, status, review_status, source_type, source_close_date, source_campaign_id
    FROM purchase_requests WHERE pr_no = 'PR2604290034'
`);
console.log('PR2604290034:', pr.rows[0]);

if (pr.rows.length === 0) { await c.end(); process.exit(0); }
const prId = pr.rows[0].id;

// PR items
const items = await c.query(`SELECT id, sku_id, qty_requested, po_item_id FROM purchase_request_items WHERE pr_id = $1`, [prId]);
console.log(`\nItems (${items.rows.length}):`);
items.rows.forEach(it => console.log(`  pri#${it.id} sku=${it.sku_id} qty=${it.qty_requested} → poi=${it.po_item_id}`));

// PR campaigns join
const prc = await c.query(`SELECT * FROM purchase_request_campaigns WHERE pr_id = $1`, [prId]);
console.log(`\nPR campaigns join (${prc.rows.length}):`);
prc.rows.forEach(p => console.log(`  campaign=${p.campaign_id}`));

// v_pr_progress
const view = await c.query(`SELECT * FROM v_pr_progress WHERE pr_id = $1`, [prId]);
console.log(`\nv_pr_progress:`, view.rows[0]);

// 同 close_date 的所有 PR
const sameDate = await c.query(`
  SELECT id, pr_no, status, source_type, source_campaign_id
    FROM purchase_requests
   WHERE source_close_date = $1 AND status <> 'cancelled'
`, [pr.rows[0].source_close_date]);
console.log(`\n同 close_date PR (${sameDate.rows.length}):`);
sameDate.rows.forEach(p => console.log(`  PR#${p.id} ${p.pr_no} type=${p.source_type} campaign=${p.source_campaign_id}`));

await c.end();

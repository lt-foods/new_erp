import { Client } from 'pg';
if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com', port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm', password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres', ssl: { rejectUnauthorized: false },
});
await c.connect();

// 看 order 7
const o = await c.query(`
  SELECT id, order_no, status, pickup_store_id
    FROM customer_orders WHERE id = 7
`);
console.log('Order #7:');
console.log(o.rows[0]);

// 看 order 7 的 items
const items = await c.query(`
  SELECT id, order_id, sku_id, qty, status, campaign_item_id
    FROM customer_order_items WHERE order_id = 7
`);
console.log('\nOrder #7 items:');
items.rows.forEach(it => console.log(`  item #${it.id} sku=${it.sku_id} qty=${it.qty} status=${it.status} campaign_item=${it.campaign_item_id}`));

// 看 GRP-20260428-004-0001 是什麼 order_id
const o4 = await c.query(`
  SELECT id, order_no, status, pickup_store_id
    FROM customer_orders WHERE order_no = 'GRP-20260428-004-0001'
`);
console.log('\nGRP-20260428-004-0001:');
console.log(o4.rows[0]);

const items4 = await c.query(`
  SELECT id, order_id, sku_id, qty, status FROM customer_order_items WHERE order_id = $1
`, [o4.rows[0]?.id]);
console.log('\nGRP-20260428-004-0001 items:');
items4.rows.forEach(it => console.log(`  item #${it.id} sku=${it.sku_id} qty=${it.qty} status=${it.status}`));

await c.end();

import { Client } from 'pg';
if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com', port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm', password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres', ssl: { rejectUnauthorized: false },
});
await c.connect();

// 找 GRP-20260428-007-TF0003
const o = await c.query(`
  SELECT id, order_no, status, pickup_store_id, transferred_from_order_id, is_air_transfer
    FROM customer_orders WHERE order_no LIKE '%007-TF%'
`);
console.log('TF orders:');
o.rows.forEach(r => console.log(`  #${r.id} ${r.order_no} status=${r.status} from=${r.transferred_from_order_id} store=${r.pickup_store_id} air=${r.is_air_transfer}`));

// 看每筆對應的 transfers
for (const ord of o.rows) {
  const t = await c.query(`
    SELECT id, transfer_no, transfer_type, status, customer_order_id
      FROM transfers WHERE customer_order_id = $1
  `, [ord.id]);
  console.log(`\n  Order #${ord.id} 對應 transfers:`);
  t.rows.forEach(r => console.log(`    transfer #${r.id} ${r.transfer_no} [${r.transfer_type}/${r.status}]`));
}

// 同时也看 GRP-20260428-007-0002
const o2 = await c.query(`
  SELECT id, order_no, status FROM customer_orders WHERE order_no = 'GRP-20260428-007-0002'
`);
console.log('\nGRP-20260428-007-0002:', JSON.stringify(o2.rows[0]));

await c.end();

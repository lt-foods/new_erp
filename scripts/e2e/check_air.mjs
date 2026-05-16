import { Client } from 'pg';
if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com', port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm', password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres', ssl: { rejectUnauthorized: false },
});
await c.connect();

// 詳查 transfer #16 的 source/dest + items + cost
const t16 = await c.query(`
  SELECT t.*, src.code as src_code, src.name as src_name,
         dst.code as dst_code, dst.name as dst_name,
         srcs.id as src_store_id, srcs.code as src_store_code, srcs.name as src_store_name,
         dsts.id as dst_store_id, dsts.code as dst_store_code, dsts.name as dst_store_name
    FROM transfers t
    LEFT JOIN locations src ON src.id = t.source_location
    LEFT JOIN locations dst ON dst.id = t.dest_location
    LEFT JOIN stores srcs ON srcs.location_id = t.source_location
    LEFT JOIN stores dsts ON dsts.location_id = t.dest_location
   WHERE t.id = 16
`);
console.log('=== Transfer #16 詳細 ===');
const t = t16.rows[0];
if (t) {
  console.log(`  ${t.transfer_no} [${t.transfer_type}/${t.status}]`);
  console.log(`  src loc: ${t.src_code} ${t.src_name} → store: ${t.src_store_code} ${t.src_store_name} (id=${t.src_store_id})`);
  console.log(`  dst loc: ${t.dst_code} ${t.dst_name} → store: ${t.dst_store_code} ${t.dst_store_name} (id=${t.dst_store_id})`);
  console.log(`  customer_order_id: ${t.customer_order_id}`);
  console.log(`  shipped_at: ${t.shipped_at}`);
  console.log(`  received_at: ${t.received_at}`);
}

const items = await c.query(`
  SELECT ti.*, sm_out.unit_cost as out_cost, sm_in.unit_cost as in_cost,
         sk.sku_code, sk.product_name
    FROM transfer_items ti
    LEFT JOIN stock_movements sm_out ON sm_out.id = ti.out_movement_id
    LEFT JOIN stock_movements sm_in ON sm_in.id = ti.in_movement_id
    LEFT JOIN skus sk ON sk.id = ti.sku_id
   WHERE ti.transfer_id = 16
`);
console.log(`  items (${items.rows.length}):`);
items.rows.forEach(it => console.log(`    ${it.sku_code} qty_received=${it.qty_received} qty_shipped=${it.qty_shipped} out_cost=${it.out_cost} in_cost=${it.in_cost}`));

console.log('\n');

// 看所有 air transfer 訂單
const air = await c.query(`
  SELECT id, order_no, status, is_air_transfer, transferred_from_order_id,
         pickup_store_id, created_at::timestamp as ct, updated_at::timestamp as ut
    FROM customer_orders
   WHERE is_air_transfer = true OR order_no LIKE '%TF%'
   ORDER BY id DESC LIMIT 10
`);
console.log('=== 所有空中轉 / 轉移訂單 ===');
air.rows.forEach(o => {
  console.log(`  #${o.id} ${o.order_no} status=${o.status} air=${o.is_air_transfer} from=${o.transferred_from_order_id} store=${o.pickup_store_id} updated=${o.ut}`);
});

// 看 air=true 訂單對應的所有 transfers
const airTx = await c.query(`
  SELECT t.id, t.transfer_no, t.transfer_type, t.status,
         t.customer_order_id, t.source_location, t.dest_location,
         co.order_no, co.is_air_transfer
    FROM transfers t
    LEFT JOIN customer_orders co ON co.id = t.customer_order_id
   WHERE co.is_air_transfer = true
   ORDER BY t.id DESC
`);
console.log('\n=== 空中轉相關 transfers ===');
console.log(`共 ${airTx.rows.length} 筆`);
airTx.rows.forEach(t => console.log(`  #${t.id} ${t.transfer_no} [${t.transfer_type}/${t.status}] co=${t.customer_order_id} (${t.order_no})`));

await c.end();

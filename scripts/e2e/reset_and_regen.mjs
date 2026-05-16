import { Client } from 'pg';
if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com', port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm', password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres', ssl: { rejectUnauthorized: false },
});
await c.connect();

// 1. 把 confirmed settlements + 對應 vendor_bills 一起砍回 draft（測試用）
console.log('=== Step 1: Reset confirmed settlements 回 draft ===');
const before = await c.query(`
  SELECT s.id, s.store_id, s.payable_amount, s.status, s.generated_vendor_bill_id,
         st.code, st.name
    FROM store_monthly_settlements s
    JOIN stores st ON st.id = s.store_id
   WHERE s.settlement_month = '2026-04-01'
   ORDER BY s.store_id
`);
console.log('改之前:');
before.rows.forEach(r => console.log(`  ${r.code} ${r.name}: $${r.payable_amount} ${r.status} bill=${r.generated_vendor_bill_id}`));

// 砍 vendor_bills (test only)
await c.query(`
  DELETE FROM vendor_bills
   WHERE id IN (SELECT generated_vendor_bill_id FROM store_monthly_settlements
                 WHERE settlement_month = '2026-04-01' AND generated_vendor_bill_id IS NOT NULL)
`);

// items 是 append-only、暫停 trigger 砍掉重建（測試用）
await c.query(`ALTER TABLE store_monthly_settlement_items DISABLE TRIGGER trg_no_mut_smsi`);
await c.query(`DELETE FROM store_monthly_settlement_items WHERE settlement_id IN (SELECT id FROM store_monthly_settlements WHERE settlement_month = '2026-04-01')`);
await c.query(`
  UPDATE store_monthly_settlements
     SET status = 'draft', confirmed_at = NULL, confirmed_by = NULL, generated_vendor_bill_id = NULL
   WHERE settlement_month = '2026-04-01'
`);
await c.query(`ALTER TABLE store_monthly_settlement_items ENABLE TRIGGER trg_no_mut_smsi`);
console.log('  ✓ 已 reset 成 draft\n');

// 2. 拿 admin user id
const userR = await c.query(`SELECT id FROM auth.users WHERE email = 'cktalex@gmail.com' LIMIT 1`);
const opId = userR.rows[0].id;

// 3. 重跑 generate
console.log('=== Step 2: 重跑 rpc_generate_hq_to_store_settlement ===');
const gen = await c.query(`SELECT rpc_generate_hq_to_store_settlement('2026-04-01', $1) as r`, [opId]);
console.log('  結果:', JSON.stringify(gen.rows[0].r));

// 4. 看結果
console.log('\n=== Step 3: 結算結果 ===');
const after = await c.query(`
  SELECT s.id, s.store_id, s.payable_amount, s.transfer_count, s.item_count, s.status,
         st.code, st.name
    FROM store_monthly_settlements s
    JOIN stores st ON st.id = s.store_id
   WHERE s.settlement_month = '2026-04-01'
   ORDER BY s.store_id
`);
let total = 0;
after.rows.forEach(r => {
  console.log(`  ${r.code} ${r.name}: $${r.payable_amount} (${r.transfer_count} 張 / ${r.item_count} 行) ${r.status}`);
  total += Number(r.payable_amount);
});
console.log(`  總額: $${total}`);

// 5. 看 items 明細
console.log('\n=== Step 4: 平鎮店 / 松山店 明細 ===');
for (const storeCode of ['S001', 'S002']) {
  const sIdR = await c.query(`SELECT id, name FROM stores WHERE code = $1`, [storeCode]);
  const items = await c.query(`
    SELECT smi.entry_type, smi.line_amount, smi.qty_received, smi.unit_cost,
           t.transfer_no, sk.sku_code, sk.product_name
      FROM store_monthly_settlement_items smi
      JOIN store_monthly_settlements s ON s.id = smi.settlement_id
      JOIN transfers t ON t.id = smi.transfer_id
      JOIN skus sk ON sk.id = smi.sku_id
     WHERE s.settlement_month = '2026-04-01'
       AND s.store_id = $1
     ORDER BY smi.entry_type, smi.received_at
  `, [sIdR.rows[0].id]);
  console.log(`  --- ${sIdR.rows[0].name} ---`);
  items.rows.forEach(it => console.log(`    [${it.entry_type}] ${it.transfer_no} ${it.sku_code} qty=${it.qty_received} cost=$${it.unit_cost} → $${it.line_amount}`));
}

await c.end();

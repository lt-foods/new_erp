import { Client } from 'pg';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = 'D:/project/new_erp/.claude/worktrees/distracted-payne-fb600a/supabase/migrations';
const files = [
  '20260429160000_stores_liff_overview_columns.sql',
  '20260429160001_customer_orders_payment_shipping_columns.sql',
  '20260429160002_v_customer_order_summary.sql',
];

if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com',
  port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm',
  password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres',
  ssl: { rejectUnauthorized: false },
});

await c.connect();
console.log('connected');

for (const f of files) {
  const sql = readFileSync(join(root, f), 'utf8');
  console.log(`\n=== applying ${f} ===`);
  try {
    await c.query(sql);
    console.log('  ok');

    // record in supabase_migrations.schema_migrations so supabase CLI knows
    const version = f.split('_')[0];
    const name = f.replace(/^[0-9]+_/, '').replace(/\.sql$/, '');
    await c.query(
      `INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
       VALUES ($1, $2, $3)
       ON CONFLICT (version) DO NOTHING`,
      [version, name, [sql]],
    );
    console.log(`  recorded in schema_migrations: ${version}`);
  } catch (e) {
    console.error(`  FAIL: ${e.message}`);
    process.exit(1);
  }
}

console.log('\n=== verifying ===');
const r = await c.query(
  `SELECT column_name FROM information_schema.columns
    WHERE table_name='stores' AND column_name='banner_url'`,
);
console.log('stores.banner_url exists:', r.rows.length > 0);

const r2 = await c.query(
  `SELECT column_name FROM information_schema.columns
    WHERE table_name='customer_orders' AND column_name='payment_status'`,
);
console.log('customer_orders.payment_status exists:', r2.rows.length > 0);

const r3 = await c.query(`SELECT count(*) as c FROM v_customer_order_summary`);
console.log('v_customer_order_summary row count:', r3.rows[0].c);

await c.end();
console.log('\ndone');

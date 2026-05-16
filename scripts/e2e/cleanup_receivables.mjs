import { Client } from 'pg';
if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com', port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm', password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres', ssl: { rejectUnauthorized: false },
});
await c.connect();

await c.query(`DROP TABLE IF EXISTS store_receivable_payments CASCADE`);
await c.query(`DROP TABLE IF EXISTS store_receivables CASCADE`);
await c.query(`ALTER TABLE store_monthly_settlements DROP COLUMN IF EXISTS generated_receivable_id`);
await c.query(`DROP FUNCTION IF EXISTS public.rpc_record_store_receivable_payment(BIGINT, NUMERIC, TEXT, DATE, UUID, TEXT)`);

// 把 migration 紀錄移除（讓它能再 apply）
await c.query(`DELETE FROM supabase_migrations.schema_migrations WHERE version = '20260512000015'`);

console.log('cleanup done');
await c.end();

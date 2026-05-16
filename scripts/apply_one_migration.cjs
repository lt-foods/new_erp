const { Client } = require('pg');
const fs = require('fs');
const path = process.argv[2];
if (!path) { console.error('usage: node scripts/apply_one_migration.cjs <sql_path>'); process.exit(2); }
if (!process.env.SUPABASE_DB_PASSWORD) { console.error('Set SUPABASE_DB_PASSWORD env var'); process.exit(2); }
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com',
  port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm',
  password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres',
  ssl: { rejectUnauthorized: false }
});
(async () => {
  await c.connect();
  const sql = fs.readFileSync(path, 'utf8');
  console.log('Applying ' + path + ' (' + sql.length + ' chars)');
  await c.query(sql);
  console.log('OK');
  await c.end();
})().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

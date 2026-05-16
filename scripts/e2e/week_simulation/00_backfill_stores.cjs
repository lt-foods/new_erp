// Idempotent backfill: stores 的 location_id + store_short_code
//
// - location_id: 若 NULL,自動建 location (code='WH-<store_code>') 並 link
// - store_short_code: 若 NULL,設為 's' + zero-padded 3-digit store id (e.g., 's001')
//
// 跑法: node scripts/e2e/week_simulation/00_backfill_stores.cjs
// 重跑安全; 未來加新 store 也 work
const { Client } = require('pg');

const TENANT = '00000000-0000-0000-0000-000000000001';
const ADMIN = '39fd694d-3af6-4978-beab-6e826dff7246';

if (!process.env.SUPABASE_DB_PASSWORD) {
  console.error('Set SUPABASE_DB_PASSWORD env var');
  process.exit(2);
}
const c = new Client({
  host: 'aws-1-ap-southeast-1.pooler.supabase.com',
  port: 5432,
  user: 'postgres.anfyoeviuhmzzrhilwtm',
  password: process.env.SUPABASE_DB_PASSWORD,
  database: 'postgres',
  ssl: { rejectUnauthorized: false },
});

function shortCodeOf(id) {
  return `s${String(id).padStart(3, '0')}`;
}

async function main() {
  await c.connect();
  console.log('==== Backfill stores: location_id + store_short_code ====');

  const all = await c.query(`
    SELECT id, code, name, location_id, store_short_code FROM stores
     WHERE tenant_id=$1 AND is_active=true
     ORDER BY id
  `, [TENANT]);
  console.log(`Active stores: ${all.rows.length}`);

  let locFilled = 0;
  let codeFilled = 0;
  let skipped = 0;

  for (const s of all.rows) {
    // ===== location_id =====
    if (!s.location_id) {
      const locCode = `WH-${s.code}`;
      const locName = `${s.name}倉`;
      let loc = await c.query(`SELECT id FROM locations WHERE tenant_id=$1 AND code=$2`, [TENANT, locCode]);
      let locId;
      if (loc.rows[0]) {
        locId = loc.rows[0].id;
      } else {
        const ins = await c.query(`
          INSERT INTO locations (tenant_id, code, name, type, is_active, created_by, updated_by)
          VALUES ($1, $2, $3, 'store', true, $4, $4) RETURNING id
        `, [TENANT, locCode, locName, ADMIN]);
        locId = ins.rows[0].id;
      }
      await c.query(`UPDATE stores SET location_id=$1, updated_by=$2 WHERE id=$3`, [locId, ADMIN, s.id]);
      locFilled++;
      console.log(`  ✓ ${s.code} ${s.name}: location → ${locId}`);
    }

    // ===== store_short_code =====
    const wantedCode = shortCodeOf(s.id);
    if (s.store_short_code === wantedCode) {
      skipped++;
      continue;
    }
    if (s.store_short_code && s.store_short_code !== wantedCode) {
      // 已有自訂短碼,不覆蓋
      console.log(`  ↪ ${s.code} ${s.name}: 既有 short_code='${s.store_short_code}',保留`);
      skipped++;
      continue;
    }
    // 設新短碼
    try {
      await c.query(`UPDATE stores SET store_short_code=$1, updated_by=$2 WHERE id=$3`, [wantedCode, ADMIN, s.id]);
      codeFilled++;
      console.log(`  ✓ ${s.code} ${s.name}: short_code → '${wantedCode}'`);
    } catch (e) {
      console.log(`  ✗ ${s.code} ${s.name}: ${e.message.slice(0, 80)}`);
    }
  }

  console.log(`\nSummary:`);
  console.log(`  location_id filled : ${locFilled}`);
  console.log(`  store_short_code filled: ${codeFilled}`);
  console.log(`  skipped (already set): ${skipped}`);

  // 確認最終狀態
  const missing = await c.query(`
    SELECT id, code, name FROM stores
     WHERE tenant_id=$1 AND is_active=true
       AND (location_id IS NULL OR store_short_code IS NULL)
     ORDER BY id
  `, [TENANT]);
  if (missing.rows.length > 0) {
    console.log(`\n⚠ ${missing.rows.length} stores still missing:`);
    for (const r of missing.rows) console.log(`  - ${r.code} ${r.name}`);
  } else {
    console.log(`\n✅ All active stores have location_id + store_short_code`);
  }

  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

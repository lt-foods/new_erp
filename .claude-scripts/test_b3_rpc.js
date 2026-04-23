#!/usr/bin/env node
// §2 RPC behavior tests for B3 — each case in its own BEGIN/ROLLBACK.
// The RPC executes as authenticated role (with mocked JWT claims) to match real call path;
// setup + audit log verification use postgres role.
const { Client } = require('pg');
const DB_URL = process.env.SUPABASE_DB_URL;
if (!DB_URL) { console.error('SUPABASE_DB_URL not set'); process.exit(2); }

const TENANT = '00000000-0000-0000-0000-000000000001';
const OTHER_TENANT = '11111111-1111-1111-1111-111111111111';

const results = [];
function log(name, ok, evidence = '') {
  results.push({ name, ok });
  console.log(`${ok ? '[PASS]' : '[FAIL]'} ${name}${evidence ? `\n        ${evidence}` : ''}`);
}

async function asAuthenticated(c, userId) {
  await c.query(`SELECT set_config('request.jwt.claims', $1, true)`,
    [JSON.stringify({ sub: userId, tenant_id: TENANT, role: 'authenticated' })]);
  await c.query(`SET LOCAL ROLE authenticated`);
}
async function asAdmin(c) { await c.query(`RESET ROLE`); }

async function runCase(c, userId, name, fn) {
  await c.query('BEGIN');
  try {
    let err = null, evidence = null, ok = false;
    const ctx = {
      async call(sql, params=[]) {
        await asAuthenticated(c, userId);
        try { return await c.query(sql, params); }
        finally { await asAdmin(c); }
      },
      async callExpectError(sql, params=[]) {
        await asAuthenticated(c, userId);
        try { await c.query(sql, params); return null; }
        catch (e) { return e.message; }
        finally {
          // rollback partial state + clear aborted txn
          await c.query('ROLLBACK');
          await c.query('BEGIN');
        }
      },
      admin: async (sql, params=[]) => c.query(sql, params),
      pass: (msg) => { ok = true; evidence = msg; },
      fail: (msg) => { ok = false; evidence = msg; },
    };
    await fn(ctx);
    log(name, ok, evidence || '');
    if (err) throw err;
  } finally {
    await c.query('ROLLBACK');
  }
}

(async () => {
  const c = new Client({
    connectionString: DB_URL.replace(/[?&]sslmode=[^&]*/g, ''),
    ssl: { rejectUnauthorized: false },
  });
  await c.connect();

  const userQ = await c.query(`SELECT id FROM auth.users WHERE email='cktalex@gmail.com' LIMIT 1`);
  if (userQ.rows.length === 0) { console.error('admin user not found'); process.exit(2); }
  const userId = userQ.rows[0].id;
  console.log(`(test user ${userId})\n`);

  // 2.1 INSERT all fields + audit
  await runCase(c, userId, '§2.1 INSERT all fields round-trip + audit create log', async ({ call, admin, pass, fail }) => {
    const r = await call(`SELECT public.rpc_upsert_product(
      NULL, 'TEST-B3-21', '測 2.1', 'T21', NULL, NULL, 'desc', 'active', '[]'::jsonb,
      'refrigerated'::product_storage_type, 'CID-1', '客製七字內OK', 'A-01-03',
      NULL, 20, NOW() + INTERVAL '1 day', '內部', '公開', FALSE, TRUE,
      'preorder'::product_sale_mode, 3::smallint, 't21') AS id`);
    const id = r.rows[0].id;
    const row = (await admin(`SELECT storage_type, customized_id, customized_text, storage_location,
      count_for_start_sale, user_note, user_note_public, stop_shipping, is_for_shop,
      sale_mode, vip_level_min FROM products WHERE id=$1`, [id])).rows[0];
    const audit = (await admin(`SELECT count(*)::int AS n FROM product_audit_log
      WHERE entity_type='product' AND entity_id=$1 AND action='create'`, [id])).rows[0].n;
    const ok = row.storage_type === 'refrigerated' && row.customized_id === 'CID-1' &&
               row.customized_text === '客製七字內OK' && row.storage_location === 'A-01-03' &&
               row.count_for_start_sale === 20 && row.user_note === '內部' &&
               row.user_note_public === '公開' && row.stop_shipping === false &&
               row.is_for_shop === true && row.sale_mode === 'preorder' &&
               row.vip_level_min === 3 && audit === 1;
    (ok ? pass : fail)(JSON.stringify(row) + ` audit=${audit}`);
  });

  // 2.2 INSERT minimum → defaults
  await runCase(c, userId, '§2.2 INSERT minimum → defaults applied', async ({ call, admin, pass, fail }) => {
    const r = await call(`SELECT public.rpc_upsert_product(
      NULL,'TEST-B3-22','測最小',NULL,NULL,NULL,NULL,'draft','[]'::jsonb) AS id`);
    const id = r.rows[0].id;
    const row = (await admin(`SELECT stop_shipping, is_for_shop, sale_mode, vip_level_min,
      storage_type, count_for_start_sale, limit_time FROM products WHERE id=$1`, [id])).rows[0];
    const ok = row.stop_shipping === false && row.is_for_shop === true &&
               row.sale_mode === 'preorder' && row.vip_level_min === 0 &&
               row.storage_type === null && row.count_for_start_sale === null;
    (ok ? pass : fail)(JSON.stringify(row));
  });

  // 2.3 UPDATE partial
  await runCase(c, userId, '§2.3 UPDATE partial + audit update log', async ({ call, admin, pass, fail }) => {
    const ins = await call(`SELECT public.rpc_upsert_product(
      NULL,'TEST-B3-23','測更新',NULL,NULL,NULL,NULL,'active','[]'::jsonb,
      NULL,NULL,NULL,NULL,NULL,10,NOW(),NULL,NULL,FALSE,TRUE,'preorder'::product_sale_mode,0::smallint,NULL) AS id`);
    const id = ins.rows[0].id;
    await call(`SELECT public.rpc_upsert_product(
      $1,'TEST-B3-23','測更新',NULL,NULL,NULL,NULL,'active','[]'::jsonb,
      NULL,NULL,NULL,NULL,NULL,25,NOW()+INTERVAL '2 day',NULL,NULL,FALSE,TRUE,
      'preorder'::product_sale_mode,0::smallint,'bump')`, [id]);
    const count = (await admin(`SELECT count_for_start_sale FROM products WHERE id=$1`,[id])).rows[0].count_for_start_sale;
    const aud = (await admin(`SELECT count(*)::int AS n FROM product_audit_log
      WHERE entity_type='product' AND entity_id=$1 AND action='update'`,[id])).rows[0].n;
    (count === 25 && aud === 1 ? pass : fail)(`count=${count} audit_updates=${aud}`);
  });

  // 2.4 Cross-tenant supplier reject
  await runCase(c, userId, '§2.4 cross-tenant supplier rejected', async ({ callExpectError, admin, pass, fail }) => {
    const other = await admin(`INSERT INTO suppliers(tenant_id,code,name) VALUES($1,'OTHER','other') RETURNING id`, [OTHER_TENANT]);
    const otherId = other.rows[0].id;
    const err = await callExpectError(`SELECT public.rpc_upsert_product(
      NULL,'TEST-B3-24','X',NULL,NULL,NULL,NULL,'draft','[]'::jsonb,
      NULL,NULL,NULL,NULL,$1,NULL,NULL,NULL,NULL,FALSE,TRUE,'preorder'::product_sale_mode,0::smallint,NULL)`, [otherId]);
    (!!err && /supplier .* not in tenant/i.test(err) ? pass : fail)(err || 'no error');
  });

  // 2.5 customized_text > 7 chars
  await runCase(c, userId, '§2.5 customized_text 8 chars rejected', async ({ callExpectError, pass, fail }) => {
    const err = await callExpectError(`SELECT public.rpc_upsert_product(
      NULL,'TEST-B3-25','X',NULL,NULL,NULL,NULL,'draft','[]'::jsonb,
      NULL,NULL,'12345678',NULL,NULL,NULL,NULL,NULL,NULL,FALSE,TRUE,
      'preorder'::product_sale_mode,0::smallint,NULL)`);
    (!!err && /chk_products_customized_text_len|customized_text/i.test(err) ? pass : fail)(err || 'no error');
  });

  // 2.6a vip -1
  await runCase(c, userId, '§2.6a vip_level_min -1 rejected', async ({ callExpectError, pass, fail }) => {
    const err = await callExpectError(`SELECT public.rpc_upsert_product(
      NULL,'TEST-B3-26a','X',NULL,NULL,NULL,NULL,'draft','[]'::jsonb,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,FALSE,TRUE,
      'preorder'::product_sale_mode,(-1)::smallint,NULL)`);
    (!!err && /vip_level_min/i.test(err) ? pass : fail)(err || 'no error');
  });

  // 2.6b vip 11
  await runCase(c, userId, '§2.6b vip_level_min 11 rejected', async ({ callExpectError, pass, fail }) => {
    const err = await callExpectError(`SELECT public.rpc_upsert_product(
      NULL,'TEST-B3-26b','X',NULL,NULL,NULL,NULL,'draft','[]'::jsonb,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,FALSE,TRUE,
      'preorder'::product_sale_mode,11::smallint,NULL)`);
    (!!err && /vip_level_min/i.test(err) ? pass : fail)(err || 'no error');
  });

  // 2.7 storage_type enum invalid
  await runCase(c, userId, '§2.7 storage_type "cold" rejected (invalid enum)', async ({ callExpectError, pass, fail }) => {
    const err = await callExpectError(`SELECT public.rpc_upsert_product(
      NULL,'TEST-B3-27','X',NULL,NULL,NULL,NULL,'draft','[]'::jsonb,
      'cold'::product_storage_type,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,FALSE,TRUE,
      'preorder'::product_sale_mode,0::smallint,NULL)`);
    (!!err && /invalid input value for enum|product_storage_type/i.test(err) ? pass : fail)(err || 'no error');
  });

  await c.end();
  const passed = results.filter(r => r.ok).length, failed = results.length - passed;
  console.log(`\n§2 summary: ${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch(e => { console.error(e); process.exit(3); });

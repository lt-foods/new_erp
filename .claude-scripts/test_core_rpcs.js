const { Client } = require('pg');
const DB = process.env.SUPABASE_DB_URL.replace(/[?&]sslmode=[^&]*/g, '');
const TENANT = '00000000-0000-0000-0000-000000000001';

(async () => {
  const c = new Client({ connectionString: DB, ssl: { rejectUnauthorized: false } });
  await c.connect();
  const u = (await c.query(`SELECT id FROM auth.users WHERE email='cktalex@gmail.com' LIMIT 1`)).rows[0].id;

  await c.query('BEGIN');
  try {
    await c.query(`SELECT set_config('request.jwt.claims', $1, true)`,
      [JSON.stringify({ sub: u, tenant_id: TENANT, role: 'authenticated' })]);
    await c.query('SET LOCAL ROLE authenticated');

    // 1. campaign upsert
    const r1 = await c.query(`SELECT public.rpc_upsert_campaign(
      NULL,'GB-TEST-26','測試團',NULL,NULL,'draft','regular',NULL,NULL,NULL,NULL,NULL,NULL) AS id`);
    const cid = r1.rows[0].id;
    console.log('campaign id =', cid);

    // 2. supplier upsert
    const r2 = await c.query(`SELECT public.rpc_upsert_supplier(
      NULL,'SUP-TEST-26','測試供應商',NULL,'王','02-1','a@b','',NULL,7,TRUE,NULL) AS id`);
    console.log('supplier id =', r2.rows[0].id);

    // 3. member upsert
    const r3 = await c.query(`SELECT public.rpc_upsert_member(
      NULL,'M9999','0912000000','測試',NULL,NULL,NULL,NULL,NULL,'active',NULL) AS id`);
    console.log('member id =', r3.rows[0].id);

    // 4. duplicate phone should fail
    try {
      await c.query(`SELECT public.rpc_upsert_member(
        NULL,'M99992','0912000000','測試2',NULL,NULL,NULL,NULL,NULL,'active',NULL)`);
      console.log('[FAIL] duplicate phone not rejected');
    } catch (e) {
      console.log('[PASS] duplicate phone rejected:', e.message.slice(0, 80));
    }

    // 5. relaxed read RLS
    await c.query('SET LOCAL ROLE authenticated');
    const qMem = await c.query(`SELECT COUNT(*)::int AS n FROM members`);
    console.log('members readable =', qMem.rows[0].n);
    const qSup = await c.query(`SELECT COUNT(*)::int AS n FROM suppliers`);
    console.log('suppliers readable =', qSup.rows[0].n);
    const qCamp = await c.query(`SELECT COUNT(*)::int AS n FROM group_buy_campaigns`);
    console.log('campaigns readable =', qCamp.rows[0].n);

  } finally {
    await c.query('ROLLBACK');
  }
  await c.end();
})().catch(e => { console.error(e); process.exit(1); });

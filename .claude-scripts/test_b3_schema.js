#!/usr/bin/env node
// §1 Schema / Migration verification for B3 (products extension).
// Usage: node .claude-scripts/test_b3_schema.js
const { Client } = require('pg');
const DB_URL = process.env.SUPABASE_DB_URL;
if (!DB_URL) { console.error('SUPABASE_DB_URL not set'); process.exit(2); }

const expectedEnums = {
  product_storage_type: ['room_temp','refrigerated','frozen','meal_train'],
  product_sale_mode:    ['preorder','in_stock_only','limited'],
};

const expectedColumns = [
  // name, data_type, is_nullable, default (string contains or null)
  ['storage_type',         'USER-DEFINED','YES', null],
  ['customized_id',        'text',        'YES', null],
  ['customized_text',      'text',        'YES', null],
  ['storage_location',     'text',        'YES', null],
  ['default_supplier_id',  'bigint',      'YES', null],
  ['count_for_start_sale', 'integer',     'YES', null],
  ['limit_time',           'timestamp with time zone','YES', null],
  ['user_note',            'text',        'YES', null],
  ['user_note_public',     'text',        'YES', null],
  ['stop_shipping',        'boolean',     'NO',  'false'],
  ['is_for_shop',          'boolean',     'NO',  'true'],
  ['sale_mode',            'USER-DEFINED','NO',  'preorder'],
  ['vip_level_min',        'smallint',    'NO',  '0'],
];

const expectedIndexes = ['idx_products_default_supplier','idx_products_limit_time'];

(async () => {
  const url = DB_URL.replace(/[?&]sslmode=[^&]*/g, '');
  const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
  await c.connect();
  let pass = 0, fail = 0;
  const log = (ok, msg, evidence='') => { (ok ? pass++ : fail++); console.log(`${ok?'[PASS]':'[FAIL]'} ${msg}${evidence?`\n        ${evidence}`:''}`); };

  // 1.1 enum
  for (const [t, labels] of Object.entries(expectedEnums)) {
    const r = await c.query(`SELECT enumlabel FROM pg_type t JOIN pg_enum e ON t.oid=e.enumtypid WHERE t.typname=$1 ORDER BY enumsortorder`, [t]);
    const got = r.rows.map(x => x.enumlabel);
    const ok = JSON.stringify(got) === JSON.stringify(labels);
    log(ok, `§1.1 enum ${t} = [${labels.join(',')}]`, ok ? '' : `got=[${got.join(',')}]`);
  }

  // 1.2 columns
  for (const [col, dtype, nullable, dflt] of expectedColumns) {
    const r = await c.query(
      `SELECT data_type, is_nullable, column_default
         FROM information_schema.columns
        WHERE table_schema='public' AND table_name='products' AND column_name=$1`, [col]);
    if (r.rows.length === 0) { log(false, `§1.2 column ${col} exists`, 'column missing'); continue; }
    const row = r.rows[0];
    const dtOk = row.data_type === dtype;
    const nlOk = row.is_nullable === nullable;
    const dfOk = dflt === null ? true : (row.column_default || '').includes(dflt);
    log(dtOk && nlOk && dfOk, `§1.2 column ${col}`, `data_type=${row.data_type} nullable=${row.is_nullable} default=${row.column_default}`);
  }

  // 1.2b CHECK constraints
  const checks = await c.query(`
    SELECT conname, pg_get_constraintdef(oid) AS def
      FROM pg_constraint
     WHERE conrelid = 'public.products'::regclass
       AND contype = 'c'
       AND conname IN ('chk_products_customized_text_len','chk_products_count_for_start_sale_non_negative','products_vip_level_min_check')
  `);
  const checkDefs = Object.fromEntries(checks.rows.map(r => [r.conname, r.def]));
  log(!!checkDefs.chk_products_customized_text_len, '§1.2 CHECK customized_text ≤ 7', checkDefs.chk_products_customized_text_len || 'not found');
  log(!!checkDefs.chk_products_count_for_start_sale_non_negative, '§1.2 CHECK count_for_start_sale ≥ 0', checkDefs.chk_products_count_for_start_sale_non_negative || 'not found');
  log(!!checkDefs.products_vip_level_min_check, '§1.2 CHECK vip_level_min 0-10', checkDefs.products_vip_level_min_check || 'not found');

  // 1.2c FK default_supplier_id
  const fk = await c.query(`
    SELECT conname, pg_get_constraintdef(oid) AS def
      FROM pg_constraint
     WHERE conrelid = 'public.products'::regclass AND contype='f'
       AND pg_get_constraintdef(oid) ILIKE '%default_supplier_id%'
  `);
  log(fk.rows.length === 1 && /suppliers\(id\)/i.test(fk.rows[0].def), '§1.2 FK default_supplier_id → suppliers(id)', fk.rows[0]?.def || 'not found');

  // 1.3 indexes
  for (const idx of expectedIndexes) {
    const r = await c.query(`SELECT indexdef FROM pg_indexes WHERE schemaname='public' AND indexname=$1`, [idx]);
    log(r.rows.length === 1, `§1.3 index ${idx}`, r.rows[0]?.indexdef || 'not found');
  }

  // 1.4 RPC signature — new one exists w/ 23 args, old 10-arg gone
  const r = await c.query(`
    SELECT p.proname, pg_get_function_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS ret
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='rpc_upsert_product'
  `);
  log(r.rows.length === 1, '§1.4 exactly one rpc_upsert_product overload', `count=${r.rows.length}`);
  if (r.rows.length === 1) {
    const argCount = r.rows[0].args.split(',').length;
    log(argCount === 23, '§1.4 rpc_upsert_product has 23 args', `args=${argCount}, sig=${r.rows[0].args.slice(0,120)}...`);
  }

  // grant
  const grant = await c.query(`
    SELECT has_function_privilege('authenticated','public.rpc_upsert_product(
      BIGINT, TEXT, TEXT, TEXT, BIGINT, BIGINT, TEXT, TEXT, JSONB,
      product_storage_type, TEXT, TEXT, TEXT, BIGINT, INTEGER, TIMESTAMPTZ,
      TEXT, TEXT, BOOLEAN, BOOLEAN, product_sale_mode, SMALLINT, TEXT
    )','EXECUTE') AS granted
  `);
  log(grant.rows[0].granted === true, '§1.4 GRANT EXECUTE TO authenticated');

  console.log(`\n§1 summary: ${pass} passed, ${fail} failed`);
  await c.end();
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error(e); process.exit(3); });

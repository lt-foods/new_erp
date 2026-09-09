#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Client } = require('pg');

const DB_RE = /^return_disposition_test_[A-Za-z0-9_]+$/;
const HOST = '127.0.0.1';
const PORT = 56427;
const USER = 'returnlocal';

function usage() {
  console.error('usage: node tests/return-disposition-review/source-available-runtime.cjs --db-name return_disposition_test_<name> [--case name[,name...]]');
  process.exit(2);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i += 1) {
    if (argv[i] === '--db-name') out.dbName = argv[++i];
    else if (argv[i] === '--case') {
      if (!argv[i + 1] || argv[i + 1].startsWith('--')) usage();
      out.caseNames = argv[++i];
    } else usage();
  }
  if (!out.dbName || !DB_RE.test(out.dbName)) throw new Error(`拒絕連線：--db-name 必須符合 ${DB_RE}`);
  return out;
}

function id() { return crypto.randomUUID(); }
function code() { return `bf_${Date.now()}_${crypto.randomBytes(4).toString('hex')}`; }

async function connect(dbName) {
  const c = new Client({ host: HOST, port: PORT, user: USER, database: dbName });
  await c.connect();
  c.__dbName = dbName;
  const got = await c.query('select current_database() as db, current_user as usr, inet_server_addr()::text as host, inet_server_port() as port');
  assert.equal(got.rows[0].db, dbName);
  assert.equal(got.rows[0].usr, USER);
  assert.ok(String(got.rows[0].host).startsWith(HOST));
  assert.equal(Number(got.rows[0].port), PORT);
  return c;
}

async function q1(c, sql, params = []) {
  const r = await c.query(sql, params);
  return r.rows[0];
}

async function tx(c, name, fn) {
  await c.query('begin');
  try {
    await c.query(`set local statement_timeout = '3000ms'`);
    await fn();
    console.log(`ok - ${name}`);
  } finally {
    await c.query('rollback');
  }
}

async function setAuth(c, tenantId, userId = id(), appRole = 'owner', pgRole = 'authenticated') {
  await c.query(`set local role ${pgRole}`);
  const claims = {
    sub: userId,
    tenant_id: tenantId,
    role: appRole,
    app_metadata: { role: appRole },
    user_metadata: { tenant_id: tenantId },
    store_ids: [],
  };
  await c.query('select set_config($1, $2, true)', ['request.jwt.claim.sub', userId || '']);
  await c.query('select set_config($1, $2, true)', ['request.jwt.claims', JSON.stringify(claims)]);
}

async function resetRole(c) {
  await c.query('reset role');
}

async function preflight(c, cases) {
  const required = new Set();
  if (cases.some((tc) => tc.name.startsWith('b_'))) {
    required.add('public._hq_return_source_on_ti()');
  }
  if (cases.some((tc) => tc.name.startsWith('f_'))) {
    required.add('public.rpc_create_store_return(bigint,jsonb,text,uuid)');
    required.add('public.rpc_create_wave_from_restock(bigint,date,jsonb,uuid)');
  }
  const missing = [];
  for (const sig of required) {
    const row = await q1(c, 'select to_regprocedure($1) as oid', [sig]);
    if (!row.oid) missing.push(sig);
  }
  assert.deepEqual(missing, [], `fixture 缺函式：${missing.join(', ')}`);
}

async function applyFInTransaction(c) {
  await c.query(fs.readFileSync(path.join(process.cwd(), 'supabase/migrations/20260612000060_relax_restock_check_for_wave_flow.sql'), 'utf8'));
  await c.query(fs.readFileSync(path.join(process.cwd(), 'supabase/migrations/20260907040000_hq_return_disposition_available.sql'), 'utf8'));
}

async function applyOldRestockWaveInTransaction(c) {
  await c.query(fs.readFileSync(path.join(process.cwd(), 'supabase/migrations/20260612000060_relax_restock_check_for_wave_flow.sql'), 'utf8'));
  const sql = fs.readFileSync(path.join(process.cwd(), 'supabase/migrations/20260715000020_restock_dispatch_dedup_guards.sql'), 'utf8');
  const m = sql.match(/CREATE OR REPLACE FUNCTION public\.rpc_create_wave_from_restock[\s\S]*?COMMENT ON FUNCTION public\.rpc_create_wave_from_restock[\s\S]*?;/);
  assert.ok(m, '找不到 20260715000020 的 rpc_create_wave_from_restock 定義');
  await c.query(m[0]);
}

async function seed(c, opts = {}) {
  const suffix = opts.suffix || code();
  const tenant = opts.tenant || id();
  const operator = opts.operator || id();
  const otherTenant = opts.otherTenant || id();
  const hq = (await q1(c, `
    insert into locations (tenant_id, code, name, type, created_by)
    values ($1,$2,$3,'central_warehouse',$4) returning id
  `, [tenant, `${suffix}_hq`, `${suffix} 總倉`, operator])).id;
  const storeLoc = (await q1(c, `
    insert into locations (tenant_id, code, name, type, created_by)
    values ($1,$2,$3,'store',$4) returning id
  `, [tenant, `${suffix}_store_loc`, `${suffix} 店倉`, operator])).id;
  const store = (await q1(c, `
    insert into stores (tenant_id, code, name, location_id, created_by)
    values ($1,$2,$3,$4,$5) returning id
  `, [tenant, `${suffix}_store`, `${suffix} 店`, storeLoc, operator])).id;
  const otherStoreLoc = (await q1(c, `
    insert into locations (tenant_id, code, name, type, created_by)
    values ($1,$2,$3,'store',$4) returning id
  `, [tenant, `${suffix}_other_store_loc`, `${suffix} 其他店倉`, operator])).id;
  const otherStore = (await q1(c, `
    insert into stores (tenant_id, code, name, location_id, created_by)
    values ($1,$2,$3,$4,$5) returning id
  `, [tenant, `${suffix}_other_store`, `${suffix} 其他店`, otherStoreLoc, operator])).id;
  const product = (await q1(c, `
    insert into products (tenant_id, product_code, name, status, created_by)
    values ($1,$2,$3,'active',$4) returning id
  `, [tenant, `${suffix}_p`, `${suffix} 商品`, operator])).id;
  const sku = (await q1(c, `
    insert into skus (tenant_id, product_id, sku_code, status, product_name, created_by)
    values ($1,$2,$3,'active',$4,$5) returning id
  `, [tenant, product, `${suffix}_sku`, `${suffix} 商品`, operator])).id;
  const otherProduct = (await q1(c, `
    insert into products (tenant_id, product_code, name, status, created_by)
    values ($1,$2,$3,'active',$4) returning id
  `, [otherTenant, `${suffix}_op`, `${suffix} 別租戶商品`, operator])).id;
  const otherSku = (await q1(c, `
    insert into skus (tenant_id, product_id, sku_code, status, product_name, created_by)
    values ($1,$2,$3,'active',$4,$5) returning id
  `, [otherTenant, otherProduct, `${suffix}_osku`, `${suffix} 別租戶商品`, operator])).id;
  return { suffix, tenant, otherTenant, operator, hq, storeLoc, store, otherStoreLoc, otherStore, sku, otherSku };
}

async function transferItem(c, s, type, sourceLoc, destLoc, qty = 10) {
  const transfer = (await q1(c, `
    insert into transfers (tenant_id, transfer_no, source_location, dest_location, transfer_type, status, requested_by, created_by, notes)
    values ($1,$2,$3,$4,$5,'shipped',$6,$6,$7) returning id
  `, [s.tenant, `${code()}_tr`, sourceLoc, destLoc, type, s.operator, `${type} notes`])).id;
  const item = (await q1(c, `
    insert into transfer_items (transfer_id, sku_id, qty_requested, qty_shipped, qty_received, created_by)
    values ($1,$2,$3,$3,$4,$5) returning id
  `, [transfer, s.sku, qty, type === 'return_to_hq' ? qty : 0, s.operator])).id;
  return { transfer, item };
}

async function movement(c, s, loc, qty, type, transfer, operator = s.operator) {
  return (await q1(c, `
    insert into stock_movements
      (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type, source_doc_type, source_doc_id, operator_id, notes)
    values ($1,$2,$3,$4,12.3456,$5,'transfer',$6,$7,$8) returning id
  `, [s.tenant, loc, s.sku, qty, type, transfer, operator, `${type} source`])).id;
}

async function expectReject(c, label, fn, re) {
  await c.query(`savepoint ${label.replace(/[^a-z0-9_]/gi, '_')}`);
  let err;
  try { await fn(); } catch (e) { err = e; }
  await c.query(`rollback to savepoint ${label.replace(/[^a-z0-9_]/gi, '_')}`);
  await c.query(`release savepoint ${label.replace(/[^a-z0-9_]/gi, '_')}`);
  assert.ok(err, `${label} 應拒絕但成功`);
  assert.match(String(err.message), re, `${label} 錯誤訊息不符：${err.message}`);
}

async function testBStoreReturn(c) {
  await tx(c, 'B store_return 一批、人工/系統與 source_doc 鎖定', async () => {
    const s = await seed(c);
    const t = await transferItem(c, s, 'return_to_hq', s.storeLoc, s.hq, 10);
    const mov = await movement(c, s, s.hq, 10, 'transfer_in', t.transfer, s.operator);
    await c.query('update transfer_items set in_movement_id=$1 where id=$2', [mov, t.item]);
    await c.query('update transfer_items set in_movement_id=$1 where id=$2', [mov, t.item]);
    let rows = await c.query('select source_kind,total_qty::text,auto_flag,created_by from hq_return_batches where source_movement_id=$1', [mov]);
    assert.equal(rows.rowCount, 1);
    assert.equal(rows.rows[0].source_kind, 'store_return');
    assert.equal(rows.rows[0].total_qty, '10.000');
    assert.equal(rows.rows[0].auto_flag, 'manual');
    assert.equal(rows.rows[0].created_by, s.operator);

    const zero = '00000000-0000-0000-0000-000000000000';
    const t2 = await transferItem(c, s, 'return_to_hq', s.storeLoc, s.hq, 3);
    const mov2 = await movement(c, s, s.hq, 3, 'transfer_in', t2.transfer, zero);
    await c.query('update transfer_items set in_movement_id=$1 where id=$2', [mov2, t2.item]);
    rows = await c.query('select auto_flag,created_by from hq_return_batches where source_movement_id=$1', [mov2]);
    assert.equal(rows.rowCount, 1);
    assert.equal(rows.rows[0].auto_flag, 'system');
    assert.equal(rows.rows[0].created_by, zero);

    const wrong = await transferItem(c, s, 'return_to_hq', s.storeLoc, s.hq, 2);
    const other = await transferItem(c, s, 'return_to_hq', s.storeLoc, s.hq, 2);
    const badMov = await movement(c, s, s.hq, 2, 'transfer_in', other.transfer, s.operator);
    await expectReject(c, 'B return source_doc 錯單', () => c.query('update transfer_items set in_movement_id=$1 where id=$2', [badMov, wrong.item]), /source|transfer|document|matching|單/i);
  });
}

async function testBShortage(c) {
  await tx(c, 'B shortage restock_hq/redispatch 回帳只建一批且鎖 source_doc', async () => {
    const s = await seed(c);
    const t = await transferItem(c, s, 'hq_to_store', s.hq, s.storeLoc, 15);
    await c.query('update transfer_items set qty_received=5 where id=$1', [t.item]);
    const mov = await movement(c, s, s.hq, 10, 'transfer_cancel', t.transfer, s.operator);
    await c.query(`
      update transfer_items
         set shortage_resolution='restock_hq',
             shortage_resolution_by=$1,
             shortage_resolution_notes='short 10',
             shortage_restock_movement_id=$2
       where id=$3
    `, [s.operator, mov, t.item]);
    await c.query('update transfer_items set shortage_restock_movement_id=$1 where id=$2', [mov, t.item]);
    const rows = await c.query('select source_kind,total_qty::text,auto_flag,created_by from hq_return_batches where source_movement_id=$1', [mov]);
    assert.equal(rows.rowCount, 1);
    assert.equal(rows.rows[0].source_kind, 'shortage');
    assert.equal(rows.rows[0].total_qty, '10.000');
    assert.equal(rows.rows[0].auto_flag, 'manual');
    assert.equal(rows.rows[0].created_by, s.operator);

    const wrong = await transferItem(c, s, 'hq_to_store', s.hq, s.storeLoc, 8);
    await c.query('update transfer_items set qty_received=3, shortage_resolution=$1, shortage_resolution_by=$2 where id=$3', ['restock_hq', s.operator, wrong.item]);
    const other = await transferItem(c, s, 'hq_to_store', s.hq, s.storeLoc, 8);
    const badMov = await movement(c, s, s.hq, 5, 'transfer_cancel', other.transfer, s.operator);
    await expectReject(c, 'B shortage source_doc 錯單', () => c.query('update transfer_items set shortage_restock_movement_id=$1 where id=$2', [badMov, wrong.item]), /source|transfer|document|matching|單/i);
  });
}

async function seedRestock(c, qty = 10, opts = {}) {
  const s = await seed(c);
  await c.query('insert into stock_balances (tenant_id, location_id, sku_id, on_hand, reserved) values ($1,$2,$3,$4,$5)', [s.tenant, s.hq, s.sku, opts.onHand ?? 15, opts.reserved ?? 5]);
  const rr = (await q1(c, `
    insert into restock_requests (tenant_id, requesting_store_id, status, requested_by, approved_by, approved_at, created_by)
    values ($1,$2,'approved_transfer',$3,$3,now(),$3) returning id
  `, [s.tenant, s.store, s.operator])).id;
  await c.query(`
    insert into restock_request_lines (tenant_id, request_id, sku_id, qty, unit_price, created_by)
    values ($1,$2,$3,$4,1,$5)
  `, [s.tenant, rr, s.sku, qty, s.operator]);
  return { ...s, rr };
}

async function wave(c, s, allocations) {
  const row = await q1(c, `
    select public.rpc_create_wave_from_restock($1,current_date,$2::jsonb,$3) as result
  `, [s.rr, JSON.stringify(allocations), s.operator]);
  return row.result;
}

async function sleep(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForLockWait(observer, pid, label) {
  for (let i = 0; i < 30; i += 1) {
    const row = await q1(observer, `
      select wait_event_type, wait_event, state
        from pg_stat_activity
       where pid = $1
    `, [pid]);
    if (row && row.wait_event_type === 'Lock') return row;
    await sleep(50);
  }
  throw new Error(`${label} 沒觀察到 row lock 等待`);
}

async function testFRestockAvailable(c) {
  await tx(c, 'F 補貨可派量用 on_hand-reserved，draft 不加 reserved', async () => {
    await applyFInTransaction(c);
    const s = await seedRestock(c, 15);
    const view = await q1(c, 'select gr_qty::text from v_picking_demand_no_po where restock_request_id=$1 and sku_id=$2', [s.rr, s.sku]);
    assert.equal(Number(view.gr_qty), 10);
    await expectReject(c, 'F draft 不可吃 reserved 的 5 件', () => wave(c, s, [{ sku_id: s.sku, store_id: s.store, qty: '15' }]), /可派量|reserved|保留|庫存/i);
    const before = await q1(c, 'select reserved::text from stock_balances where tenant_id=$1 and location_id=$2 and sku_id=$3', [s.tenant, s.hq, s.sku]);
    const made = await wave(c, s, [{ sku_id: s.sku, store_id: s.store, qty: '10' }]);
    assert.ok(made.wave_id);
    const after = await q1(c, 'select reserved::text from stock_balances where tenant_id=$1 and location_id=$2 and sku_id=$3', [s.tenant, s.hq, s.sku]);
    assert.equal(after.reserved, before.reserved, 'draft wave 不應增加 reserved');
    await expectReject(c, 'F 已建 10 後剩餘申請 5 不可再配 6', () => wave(c, s, [{ sku_id: s.sku, store_id: s.store, qty: '6' }]), /剩餘申請量|已撿|超過/i);
  });
}

async function testFRestockInputs(c) {
  await tx(c, 'F 補貨非法 qty/SKU/store 與重複行累加', async () => {
    await applyFInTransaction(c);
    const s = await seedRestock(c, 10);
    await expectReject(c, 'F qty 四位小數拒絕', () => wave(c, s, [{ sku_id: s.sku, store_id: s.store, qty: '1.0001' }]), /有限正數|3 位小數|數量/i);
    await expectReject(c, 'F qty NaN 拒絕', () => wave(c, s, [{ sku_id: s.sku, store_id: s.store, qty: 'NaN' }]), /有限正數|3 位小數|數量/i);
    await expectReject(c, 'F 錯 tenant SKU 拒絕', () => wave(c, s, [{ sku_id: s.otherSku, store_id: s.store, qty: '1' }]), /找不到 SKU|不屬於/i);
    await expectReject(c, 'F 錯店拒絕', () => wave(c, s, [{ sku_id: s.sku, store_id: s.otherStore, qty: '1' }]), /申請分店|其他店|不可派/i);
    const made = await wave(c, s, [
      { sku_id: s.sku, store_id: s.store, qty: '4' },
      { sku_id: s.sku, store_id: s.store, qty: '6' },
    ]);
    const item = await q1(c, 'select qty::text from picking_wave_items where wave_id=$1 and sku_id=$2 and store_id=$3', [made.wave_id, s.sku, s.store]);
    assert.equal(Number(item.qty), 10);
  });
}

async function testFOldRestockAvailableBaseline(c) {
  await tx(c, 'F 舊補貨可派量 baseline 會把 reserved 當可派', async () => {
    await applyOldRestockWaveInTransaction(c);
    const s = await seedRestock(c, 15);
    const made = await wave(c, s, [{ sku_id: s.sku, store_id: s.store, qty: '15' }]);
    assert.ok(made.wave_id, '舊版用 on_hand 當供給，15 帳 / 5 reserved 仍會建 draft15；新版測試應抓住這個錯');
  });
}

async function testFRestockBalanceRace(c) {
  const dbName = c.__dbName;
  const holder = await connect(dbName);
  const racer = await connect(dbName);
  const observer = await connect(dbName);
  try {
    const s = await seedRestock(c, 15, { onHand: 15, reserved: 0 });

    await holder.query('begin');
    await holder.query(`set local statement_timeout = '3000ms'`);
    await holder.query(
      'update stock_balances set reserved = reserved + 5 where tenant_id=$1 and location_id=$2 and sku_id=$3',
      [s.tenant, s.hq, s.sku],
    );

    await racer.query('begin');
    await racer.query(`set local statement_timeout = '3000ms'`);
    const racePromise = wave(racer, s, [{ sku_id: s.sku, store_id: s.store, qty: '15' }])
      .then((value) => ({ ok: true, value }))
      .catch((error) => ({ ok: false, error }));

    await waitForLockWait(observer, racer.processID, 'F 建 wave 與 reserved 更新併發');
    await holder.query('commit');
    const result = await racePromise;
    assert.equal(result.ok, false, 'reserved 併發增加後，建 wave 不應照舊吃 15 件');
    assert.match(String(result.error.message), /可派量|reserved|保留|庫存/i);
    await racer.query('rollback');
  } finally {
    await holder.query('rollback').catch(() => undefined);
    await racer.query('rollback').catch(() => undefined);
    await holder.end().catch(() => undefined);
    await racer.end().catch(() => undefined);
    await observer.end().catch(() => undefined);
  }
}

async function testFStoreReturn(c) {
  await tx(c, 'F 通用退貨擋少收且不破壞三個合法原因', async () => {
    await applyFInTransaction(c);
    const s = await seed(c);
    await c.query('insert into stock_balances (tenant_id, location_id, sku_id, on_hand, reserved) values ($1,$2,$3,20,5)', [s.tenant, s.storeLoc, s.sku]);
    await setAuth(c, s.tenant, s.operator, 'owner');
    await expectReject(c, 'F 一般退貨少收拒絕', () => q1(c, 'select public.rpc_create_store_return($1,$2::jsonb,$3,$4) as result', [s.store, JSON.stringify([{ sku_id: s.sku, qty: '1' }]), '少收', s.operator]), /少收|修改實收|原派貨單/i);
    for (const reason of ['破損', '過期', '客人退']) {
      const r = await q1(c, 'select public.rpc_create_store_return($1,$2::jsonb,$3,$4) as result', [s.store, JSON.stringify([{ sku_id: s.sku, qty: '1' }]), reason, s.operator]);
      assert.equal(r.result.stock_moved, false);
      assert.equal(r.result.reason, reason);
    }
    const failures = [];
    const check = async (label, qty, re) => {
      try {
        await expectReject(c, label, () => q1(c, 'select public.rpc_create_store_return($1,$2::jsonb,$3,$4) as result', [s.store, JSON.stringify([{ sku_id: s.sku, qty }]), '破損', s.operator]), re);
      } catch (e) {
        failures.push(`${label}: ${e.message}`);
      }
    };
    await check('F 一般退貨 qty 四位小數應拒絕', '1.0001', /數量|3|有限|不完整/i);
    await check('F 一般退貨 qty NaN 應拒絕', 'NaN', /數量|finite|NaN|有限|不完整/i);
    await check('F 一般退貨 qty Infinity 應拒絕', 'Infinity', /數量|finite|Infinity|有限|不完整/i);
    if (failures.length > 0) throw new Error(failures.join(' | '));
  });
}

const CASES = [
  { name: 'b_store_return', fn: testBStoreReturn },
  { name: 'b_shortage', fn: testBShortage },
  { name: 'f_restock_available', fn: testFRestockAvailable },
  { name: 'f_restock_inputs', fn: testFRestockInputs },
  { name: 'f_old_restock_available_baseline', fn: testFOldRestockAvailableBaseline },
  { name: 'f_restock_balance_race', fn: testFRestockBalanceRace },
  { name: 'f_store_return', fn: testFStoreReturn },
];

function selected(caseNames) {
  if (!caseNames || caseNames === 'all') return CASES;
  if (caseNames === 'list') {
    console.log(CASES.map((c) => c.name).join('\n'));
    process.exit(0);
  }
  const names = caseNames.split(',').map((s) => s.trim()).filter(Boolean);
  if (names.length === 0) throw new Error('--case 不可為空');
  const missing = names.filter((n) => !CASES.some((c) => c.name === n));
  if (missing.length) throw new Error(`未知 --case：${missing.join(', ')}`);
  return CASES.filter((c) => names.includes(c.name));
}

async function main() {
  const { dbName, caseNames } = parseArgs(process.argv);
  const picked = selected(caseNames);
  const c = await connect(dbName);
  const results = [];
  try {
    await preflight(c, picked);
    for (const tc of picked) {
      try {
        await tc.fn(c);
        console.log(`PASS ${tc.name}`);
        results.push({ name: tc.name, ok: true });
      } catch (e) {
        console.error(`FAIL ${tc.name}: ${e.message}`);
        results.push({ name: tc.name, ok: false, message: e.message });
      } finally {
        await resetRole(c).catch(() => undefined);
      }
    }
  } finally {
    await c.end();
  }
  console.log('source_available_summary');
  for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'} ${r.name}${r.ok ? '' : ` :: ${r.message}`}`);
  if (results.some((r) => !r.ok)) process.exit(1);
}

main().catch((e) => {
  console.error(e.stack || e.message);
  process.exit(1);
});

#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Client } = require('pg');

const DB_RE = /^return_disposition_test_[A-Za-z0-9_]+$/;
const HOST = '127.0.0.1';
const PORT = 56427;
const USER = 'returnlocal';
const OWNER = '00000000-0000-0000-0000-000000000000';

function usage() {
  console.error('usage: node tests/return-disposition-review/core-runtime.cjs --db-name return_disposition_test_<name>');
  process.exit(2);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i += 1) {
    if (argv[i] === '--db-name') out.dbName = argv[++i];
    else usage();
  }
  if (!out.dbName || !DB_RE.test(out.dbName)) {
    throw new Error(`拒絕連線：--db-name 必須符合 ${DB_RE}`);
  }
  return out;
}

function id() {
  return crypto.randomUUID();
}

function code() {
  return `rt_${Date.now()}_${crypto.randomBytes(4).toString('hex')}`;
}

function client(dbName) {
  return new Client({ host: HOST, port: PORT, user: USER, database: dbName });
}

async function connect(dbName) {
  const c = client(dbName);
  await c.connect();
  const got = await c.query('select current_database() as db, current_user as usr, inet_server_addr()::text as host, inet_server_port() as port');
  assert.equal(got.rows[0].db, dbName, '連到的資料庫名稱不符');
  assert.equal(got.rows[0].usr, USER, '連線使用者不符');
  assert.ok(String(got.rows[0].host).startsWith(HOST), '連線主機不符');
  assert.equal(Number(got.rows[0].port), PORT, '連線 port 不符');
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

async function setAuth(c, tenantId, userId, appRole = 'owner', pgRole = 'authenticated') {
  assert.match(pgRole, /^(authenticated|anon)$/);
  await c.query(`set local role ${pgRole}`);
  const claims = {
    sub: userId,
    tenant_id: tenantId,
    role: appRole,
    app_metadata: { role: appRole },
    user_metadata: { tenant_id: tenantId },
  };
  await c.query('select set_config($1, $2, true)', ['request.jwt.claim.sub', userId || '']);
  await c.query('select set_config($1, $2, true)', ['request.jwt.claims', JSON.stringify(claims)]);
}

async function resetRole(c) {
  await c.query('reset role');
}

async function preflight(c) {
  const requiredTables = [
    'products',
    'skus',
    'locations',
    'stock_balances',
    'stock_movements',
    'transfers',
    'transfer_items',
    'hq_return_batches',
    'hq_return_events',
  ];
  const missingTables = [];
  for (const t of requiredTables) {
    const row = await q1(c, 'select to_regclass($1) as oid', [`public.${t}`]);
    if (!row.oid) missingTables.push(t);
  }
  assert.deepEqual(missingTables, [], `fixture 缺表：${missingTables.join(', ')}`);

  const requiredRoutines = [
    'public._hq_hold_return(uuid,bigint,bigint,bigint,bigint,text,text,numeric,uuid,text)',
    'public.rpc_dispose_hq_return(bigint,uuid,numeric,numeric,numeric,text,text,boolean,text)',
    'public.rpc_outbound(uuid,bigint,bigint,numeric,text,text,bigint,uuid,boolean,numeric)',
  ];
  const missingRoutines = [];
  for (const sig of requiredRoutines) {
    const row = await q1(c, 'select to_regprocedure($1) as oid', [sig]);
    if (!row.oid) missingRoutines.push(sig);
  }
  assert.deepEqual(missingRoutines, [], `fixture 缺函式：${missingRoutines.join(', ')}`);

  const roles = await c.query(`select rolname from pg_roles where rolname in ('authenticated','anon')`);
  assert.deepEqual(roles.rows.map((r) => r.rolname).sort(), ['anon', 'authenticated'], 'fixture 必須建立 authenticated/anon 角色，才能真驗 RLS/GRANT');
}

async function seedBasic(c, opts = {}) {
  const suffix = opts.suffix || code();
  const tenant = opts.tenant || id();
  const operator = opts.operator || id();
  const otherTenant = opts.otherTenant || id();

  const hq = (await q1(c, `
    insert into locations (tenant_id, code, name, type, created_by)
    values ($1,$2,$3,'central_warehouse',$4) returning id
  `, [tenant, `${suffix}_hq`, `${suffix} 總倉`, operator])).id;
  const store = (await q1(c, `
    insert into locations (tenant_id, code, name, type, created_by)
    values ($1,$2,$3,'store',$4) returning id
  `, [tenant, `${suffix}_store`, `${suffix} 店`, operator])).id;
  const otherHq = (await q1(c, `
    insert into locations (tenant_id, code, name, type, created_by)
    values ($1,$2,$3,'central_warehouse',$4) returning id
  `, [otherTenant, `${suffix}_other_hq`, `${suffix} 別租戶總倉`, operator])).id;
  const product = (await q1(c, `
    insert into products (tenant_id, product_code, name, status, created_by)
    values ($1,$2,$3,'active',$4) returning id
  `, [tenant, `${suffix}_p`, `${suffix} 商品`, operator])).id;
  const sku = (await q1(c, `
    insert into skus (tenant_id, product_id, sku_code, status, product_name, created_by)
    values ($1,$2,$3,'active',$4,$5) returning id
  `, [tenant, product, `${suffix}_sku`, `${suffix} 商品`, operator])).id;
  const transfer = (await q1(c, `
    insert into transfers (tenant_id, transfer_no, source_location, dest_location, transfer_type, status, requested_by, created_by, notes)
    values ($1,$2,$3,$4,'return_to_hq','shipped',$5,$5,$6) returning id
  `, [tenant, `${suffix}_tr`, store, hq, operator, `${suffix} return_to_hq`])).id;
  const item = (await q1(c, `
    insert into transfer_items (transfer_id, sku_id, qty_requested, qty_shipped, qty_received, created_by)
    values ($1,$2,$3,$3,$3,$4) returning id
  `, [transfer, sku, opts.qty || 10, operator])).id;

  return { suffix, tenant, otherTenant, operator, hq, store, otherHq, product, sku, transfer, item };
}

async function inboundMovement(c, s, qty, loc = s.hq, sku = s.sku, item = s.item, type = 'transfer_in') {
  const row = await q1(c, `
    insert into stock_movements
      (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type, source_doc_type, source_doc_id, source_doc_line_id, operator_id, notes)
    values ($1,$2,$3,$4,12.3456,$5,'transfer',$6,$7,$8,$9)
    returning id
  `, [s.tenant, loc, sku, qty, type, s.transfer, item, s.operator, `${s.suffix} inbound`]);
  await c.query('update transfer_items set in_movement_id = $1 where id = $2', [row.id, s.item]);
  return row.id;
}

async function rawInboundMovement(c, s, qty, loc = s.hq, sku = s.sku, item = s.item, type = 'transfer_in') {
  const row = await q1(c, `
    insert into stock_movements
      (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type, source_doc_type, source_doc_id, source_doc_line_id, operator_id, notes)
    values ($1,$2,$3,$4,12.3456,$5,'transfer',$6,$7,$8,$9)
    returning id
  `, [s.tenant, loc, sku, qty, type, s.transfer, item, s.operator, `${s.suffix} inbound raw`]);
  return row.id;
}

async function hold(c, s, qty = 10, sourceMovementId = s.sourceMovement, item = s.item, loc = s.hq, sku = s.sku) {
  const row = await q1(c, `
    select public._hq_hold_return($1,$2,$3,$4,$5,'store_return','review fixture',$6,$7,'manual') as id
  `, [s.tenant, loc, sku, sourceMovementId, item, qty, s.operator]);
  return row.id;
}

async function seedHeldBatch(c, qty = 10) {
  const s = await seedBasic(c, { qty });
  s.sourceMovement = await inboundMovement(c, s, qty);
  const existing = await q1(c, 'select id from hq_return_batches where source_movement_id = $1', [s.sourceMovement]);
  s.batch = existing?.id || await hold(c, s, qty);
  return s;
}

async function snapshot(c, batchId) {
  const row = await q1(c, `
    select
      b.id, b.tenant_id::text, b.location_id, b.sku_id, b.total_qty::text,
      b.qty_good::text, b.qty_damaged::text, b.qty_lost::text, b.qty_revoked::text,
      b.status, coalesce(sb.on_hand,0)::text as on_hand, coalesce(sb.reserved,0)::text as reserved,
      (select count(*)::int from hq_return_events e where e.batch_id = b.id) as events,
      (select coalesce(sum(abs(m.quantity)),0)::text from stock_movements m where m.source_doc_type='hq_return_batch' and m.source_doc_id=b.id and m.quantity < 0) as hq_neg_qty
    from hq_return_batches b
    left join stock_balances sb on sb.tenant_id=b.tenant_id and sb.location_id=b.location_id and sb.sku_id=b.sku_id
    where b.id = $1
  `, [batchId]);
  assert.ok(row, `找不到 batch ${batchId}`);
  return row;
}

async function ownerSnapshot(c, batchId, restoreAuth = null) {
  await resetRole(c);
  const snap = await snapshot(c, batchId);
  if (restoreAuth) await setAuth(c, restoreAuth.tenant, restoreAuth.user, restoreAuth.appRole, restoreAuth.pgRole || 'authenticated');
  return snap;
}

async function dispose(c, batchId, requestId, good, damaged, lost, damageReason, lossReason, confirmed, notes) {
  const row = await q1(c, `
    select public.rpc_dispose_hq_return($1,$2,$3::numeric,$4::numeric,$5::numeric,$6,$7,$8,$9) as result
  `, [batchId, requestId, good, damaged, lost, damageReason, lossReason, confirmed, notes]);
  return row.result;
}

let sp = 0;
async function expectReject(c, label, beforeFn, fn, messageRe) {
  const name = `sp_${sp += 1}`;
  const before = await beforeFn();
  await c.query(`savepoint ${name}`);
  let err;
  try {
    await fn();
  } catch (e) {
    err = e;
  }
  assert.ok(err, `${label} 應該拒絕，但實際成功`);
  assert.match(String(err.message), messageRe, `${label} 錯誤訊息不符合預期`);
  await c.query(`rollback to savepoint ${name}`);
  const after = await beforeFn();
  assert.deepEqual(after, before, `${label} 失敗後狀態不應改變`);
  await c.query(`release savepoint ${name}`);
}

async function expectNoRowsOrPermission(c, label, sql, params = []) {
  const name = `sp_${sp += 1}`;
  await c.query(`savepoint ${name}`);
  let result;
  let err;
  try {
    result = await c.query(sql, params);
  } catch (e) {
    err = e;
  }
  if (err) {
    await c.query(`rollback to savepoint ${name}`);
    assert.equal(err.code, '42501', `${label} 只能接受權限錯誤 42501，不接受任意錯誤：${err.message}`);
    await c.query(`release savepoint ${name}`);
    return;
  }
  assert.equal(result.rows.length, 0, label);
  await c.query(`release savepoint ${name}`);
}

async function testDisposeHappyAndSplit(c) {
  await tx(c, '10 件分 7 好 2 破 1 失，並支援分次', async () => {
    const s = await seedHeldBatch(c, 10);
    await setAuth(c, s.tenant, s.operator, 'hq_manager');
    const r1 = await dispose(c, s.batch, id(), 4, 0, 0, null, null, true, 'first good');
    assert.equal(r1.idempotent, false);
    assert.equal(r1.new_status, 'partial');
    let snap = await ownerSnapshot(c, s.batch, { tenant: s.tenant, user: s.operator, appRole: 'hq_manager' });
    assert.equal(snap.qty_good, '4.000');
    assert.equal(snap.reserved, '6.000');
    assert.equal(snap.on_hand, '10.000');

    const r2 = await dispose(c, s.batch, id(), 3, 2, 1, '破損', '遺失', true, 'finish');
    assert.equal(r2.new_status, 'completed');
    snap = await ownerSnapshot(c, s.batch, { tenant: s.tenant, user: s.operator, appRole: 'hq_manager' });
    assert.equal(snap.qty_good, '7.000');
    assert.equal(snap.qty_damaged, '2.000');
    assert.equal(snap.qty_lost, '1.000');
    assert.equal(snap.reserved, '0.000');
    assert.equal(snap.on_hand, '7.000');
    assert.equal(snap.hq_neg_qty, '3.000');
  });
}

async function testSourceValidation(c) {
  await tx(c, '來源數量、地點、品項、原單行不符要拒絕', async () => {
    const s = await seedBasic(c, { qty: 10 });
    s.sourceMovement = await inboundMovement(c, s, 10);
    const before = () => q1(c, 'select count(*)::int as batches from hq_return_batches');

    await expectReject(c, 'hold qty 大於來源 movement', before, () => hold(c, s, 11), /qty|quantity|source|exceed|來源|數量/i);
    await expectReject(c, 'hold location 不等於來源 movement location', before, () => hold(c, s, 10, s.sourceMovement, s.item, s.otherHq), /location|source|movement|地點/i);

    const product2 = (await q1(c, `
      insert into products (tenant_id, product_code, name, status, created_by)
      values ($1,$2,$3,'active',$4) returning id
    `, [s.tenant, `${s.suffix}_p2`, `${s.suffix} 商品2`, s.operator])).id;
    const sku2 = (await q1(c, `
      insert into skus (tenant_id, product_id, sku_code, status, product_name, created_by)
      values ($1,$2,$3,'active',$4,$5) returning id
    `, [s.tenant, product2, `${s.suffix}_sku2`, `${s.suffix} 商品2`, s.operator])).id;
    await expectReject(c, 'hold sku 不等於來源 movement sku', before, () => hold(c, s, 10, s.sourceMovement, s.item, s.hq, sku2), /sku|source|movement|品項/i);

    const wrongItem = (await q1(c, `
      insert into transfer_items (transfer_id, sku_id, qty_requested, qty_shipped, qty_received, created_by)
      values ($1,$2,10,10,10,$3) returning id
    `, [s.transfer, s.sku, s.operator])).id;
    await expectReject(c, 'hold transfer_item 不等於來源 movement source_doc_line_id', before, () => hold(c, s, 10, s.sourceMovement, wrongItem), /item|line|source|transfer|原單/i);
  });
}

async function testIdempotencyAndBadNumbers(c) {
  await tx(c, '重送、不同 payload、NULL/NaN/Infinity/四位小數', async () => {
    const s = await seedHeldBatch(c, 10);
    await setAuth(c, s.tenant, s.operator, 'hq_manager');
    const req = id();
    const first = await dispose(c, s.batch, req, 7, 2, 1, '破損', '遺失', true, 'same');
    const snap = await ownerSnapshot(c, s.batch, { tenant: s.tenant, user: s.operator, appRole: 'hq_manager' });
    const second = await dispose(c, s.batch, req, 7, 2, 1, '破損', '遺失', true, 'same');
    assert.equal(second.idempotent, true);
    assert.deepEqual(await ownerSnapshot(c, s.batch, { tenant: s.tenant, user: s.operator, appRole: 'hq_manager' }), snap);
    await expectReject(c, '同 request_id 不同 reason/notes 不能算同一包', () => ownerSnapshot(c, s.batch, { tenant: s.tenant, user: s.operator, appRole: 'hq_manager' }), () => dispose(c, s.batch, req, 7, 2, 1, '另一個破損原因', '遺失', true, 'changed'), /request_id|payload|different|reason|notes/i);

    await resetRole(c);
    const s2 = await seedHeldBatch(c, 10);
    await setAuth(c, s2.tenant, s2.operator, 'hq_manager');
    await expectReject(c, 'NULL 數量拒絕', () => ownerSnapshot(c, s2.batch, { tenant: s2.tenant, user: s2.operator, appRole: 'hq_manager' }), () => dispose(c, s2.batch, id(), null, 0, 0, null, null, true, 'null'), /quantity|數量|null|non-negative/i);
    await expectReject(c, '四位小數拒絕', () => ownerSnapshot(c, s2.batch, { tenant: s2.tenant, user: s2.operator, appRole: 'hq_manager' }), () => dispose(c, s2.batch, id(), 0.0001, 0, 0, null, null, true, 'scale'), /scale|precision|小數|3/i);
    await expectReject(c, 'NaN 拒絕', () => ownerSnapshot(c, s2.batch, { tenant: s2.tenant, user: s2.operator, appRole: 'hq_manager' }), () => c.query(`
      select public.rpc_dispose_hq_return($1,$2,'NaN'::numeric,0,0,null,null,true,'nan')
    `, [s2.batch, id()]), /numeric|NaN|invalid|finite|數字/i);
    await expectReject(c, 'Infinity 拒絕', () => ownerSnapshot(c, s2.batch, { tenant: s2.tenant, user: s2.operator, appRole: 'hq_manager' }), () => c.query(`
      select public.rpc_dispose_hq_return($1,$2,'Infinity'::numeric,0,0,null,null,true,'inf')
    `, [s2.batch, id()]), /numeric|Infinity|invalid|finite|數字/i);
  });
}

async function testPendingGuardAndGoodStock(c) {
  await tx(c, 'pending 不可派，但既有好貨仍可派', async () => {
    const s = await seedHeldBatch(c, 5);
    await c.query(`
      insert into stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type, operator_id, notes)
      values ($1,$2,$3,20,12.3456,'manual_adjust',$4,'既有好貨')
    `, [s.tenant, s.hq, s.sku, s.operator]);

    const bal = await q1(c, 'select on_hand::text, reserved::text from stock_balances where tenant_id=$1 and location_id=$2 and sku_id=$3', [s.tenant, s.hq, s.sku]);
    assert.equal(bal.on_hand, '25.000');
    assert.equal(bal.reserved, '5.000');

    await c.query('savepoint good_stock');
    await q1(c, `select public.rpc_outbound($1,$2,$3,20,'transfer_out','review',1,$4,false,12.3456) as id`, [s.tenant, s.hq, s.sku, s.operator]);
    await c.query('rollback to savepoint good_stock');

    await expectReject(c, '派第 21 件應擋住', () => snapshot(c, s.batch), () => q1(c, `
      select public.rpc_outbound($1,$2,$3,21,'transfer_out','review',1,$4,false,12.3456) as id
    `, [s.tenant, s.hq, s.sku, s.operator]), /insufficient|available|stock|庫存|不足/i);

    await expectReject(c, 'p_allow_negative 仍不得吃 pending', () => snapshot(c, s.batch), () => q1(c, `
      select public.rpc_outbound($1,$2,$3,21,'transfer_out','review',1,$4,true,12.3456) as id
    `, [s.tenant, s.hq, s.sku, s.operator]), /pending|guard|退回|待處理|reserved/i);

    await expectReject(c, '直接負 movement 不得吃 pending', () => snapshot(c, s.batch), () => c.query(`
      insert into stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type, operator_id, notes)
      values ($1,$2,$3,-21,12.3456,'manual_adjust',$4,'direct negative bypass')
    `, [s.tenant, s.hq, s.sku, s.operator]), /pending|guard|退回|待處理|reserved/i);
  });
}

async function testTenantRoleAndAnon(c) {
  await tx(c, 'RLS/GRANT：店家、跨租戶、匿名都不能讀或處理', async () => {
    const s = await seedHeldBatch(c, 3);
    const hqUser = id();
    const storeUser = id();
    const crossUser = id();

    await setAuth(c, s.tenant, hqUser, 'hq_manager');
    const hqVisible = await c.query('select id from v_hq_return_batches_list where id = $1', [s.batch]);
    assert.equal(hqVisible.rows.length, 1, 'HQ 角色應該讀得到同 tenant 待處理批次；否則不能把「看不到」當成安全');

    await resetRole(c);
    await setAuth(c, s.tenant, storeUser, 'store_manager');
    await expectNoRowsOrPermission(c, '店家角色不應讀到總倉待處理批次', 'select id from v_hq_return_batches_list where id = $1', [s.batch]);
    await expectReject(c, '店家角色不能處理', () => ownerSnapshot(c, s.batch, { tenant: s.tenant, user: storeUser, appRole: 'store_manager' }), () => dispose(c, s.batch, id(), 1, 0, 0, null, null, true, 'store'), /permission|role|denied|權限/i);

    await resetRole(c);
    await setAuth(c, s.otherTenant, crossUser, 'hq_manager');
    await expectNoRowsOrPermission(c, '跨租戶不應讀到別人的批次', 'select id from v_hq_return_batches_list where id = $1', [s.batch]);
    await expectReject(c, '跨租戶不能處理', () => ownerSnapshot(c, s.batch, { tenant: s.otherTenant, user: crossUser, appRole: 'hq_manager' }), () => dispose(c, s.batch, id(), 1, 0, 0, null, null, true, 'cross'), /tenant|not found|permission|different|租戶|權限/i);

    await resetRole(c);
    await setAuth(c, s.tenant, null, '', 'anon');
    await expectNoRowsOrPermission(c, '匿名不應讀到批次', 'select id from v_hq_return_batches_list where id = $1', [s.batch]);
    await expectReject(c, '匿名不能處理', () => ownerSnapshot(c, s.batch, { tenant: s.tenant, user: null, appRole: '', pgRole: 'anon' }), () => dispose(c, s.batch, id(), 1, 0, 0, null, null, true, 'anon'), /auth|permission|role|JWT|登入|權限/i);
  });
}

function noteRaceTenant(tenant) {
  console.warn(`race fixture retained for audit; tenant_id=${tenant}`);
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitUntilBlocked(observer, pid, label) {
  for (let i = 0; i < 40; i += 1) {
    const row = await q1(observer, `
      select wait_event_type, wait_event, state
      from pg_stat_activity
      where pid = $1
    `, [pid]);
    if (row && row.wait_event_type === 'Lock') return row;
    await wait(25);
  }
  throw new Error(`${label}：未觀察到第二連線等待 Lock，不能把固定等待當併發證據`);
}

async function testRaceSameRequest(dbName) {
  const c0 = await connect(dbName);
  const c1 = await connect(dbName);
  const c2 = await connect(dbName);
  let tenant;
  try {
    const s = await seedHeldBatch(c0, 10);
    tenant = s.tenant;
    await c1.query('begin');
    await c1.query(`set local statement_timeout = '3000ms'`);
    await setAuth(c1, s.tenant, s.operator, 'hq_manager');
    const req = id();
    const first = dispose(c1, s.batch, req, 10, 0, 0, null, null, true, 'race').catch((e) => { throw e; });
    await first;

    await c2.query('begin');
    await c2.query(`set local statement_timeout = '1500ms'`);
    await setAuth(c2, s.tenant, s.operator, 'hq_manager');
    const second = dispose(c2, s.batch, req, 10, 0, 0, null, null, true, 'race').catch((e) => e);
    await waitUntilBlocked(c0, c2.processID, 'same request dispose 等待第一個交易');
    await c1.query('commit');
    const r2 = await second;
    if (r2 instanceof Error) throw r2;
    assert.equal(r2.idempotent, true, '同 request 併發重送應回冪等結果，不應多扣或 already completed');
    await c2.query('commit');
    console.log('ok - 兩連線同 request 併發');
  } catch (e) {
    await c1.query('rollback').catch(() => undefined);
    await c2.query('rollback').catch(() => undefined);
    throw e;
  } finally {
    if (tenant) noteRaceTenant(tenant);
    await c0.end();
    await c1.end();
    await c2.end();
  }
}

async function testRaceHoldVsNegative(dbName) {
  const c0 = await connect(dbName);
  const c1 = await connect(dbName);
  const c2 = await connect(dbName);
  let tenant;
  try {
    const s = await seedBasic(c0, { qty: 5 });
    tenant = s.tenant;
    await c0.query(`
      insert into stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type, operator_id, notes)
      values ($1,$2,$3,20,12.3456,'manual_adjust',$4,'既有好貨')
    `, [s.tenant, s.hq, s.sku, s.operator]);

    await c1.query('begin');
    await c1.query(`set local statement_timeout = '3000ms'`);
    const source = await rawInboundMovement(c1, s, 5);
    await c1.query('update transfer_items set in_movement_id = $1 where id = $2', [source, s.item]);

    await c2.query('begin');
    await c2.query(`set local statement_timeout = '1500ms'`);
    const out = c2.query(`
      insert into stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type, operator_id, notes)
      values ($1,$2,$3,-21,12.3456,'manual_adjust',$4,'race direct negative')
    `, [s.tenant, s.hq, s.sku, s.operator]).catch((e) => e);
    await waitUntilBlocked(c0, c2.processID, 'hold vs negative 等待第一個交易');
    await c1.query('commit');

    const err = await out;
    assert.ok(err, 'hold 併發建立後，直接負異動吃 pending 應拒絕');
    assert.ok(err instanceof Error, 'hold 併發建立後，直接負異動應回錯誤物件');
    assert.match(String(err.message), /pending|guard|退回|待處理|reserved/i);
    await c2.query('rollback');
    console.log('ok - 兩連線 hold vs 直接負異動');
  } catch (e) {
    await c1.query('rollback').catch(() => undefined);
    await c2.query('rollback').catch(() => undefined);
    throw e;
  } finally {
    if (tenant) noteRaceTenant(tenant);
    await c0.end();
    await c1.end();
    await c2.end();
  }
}

async function main() {
  const { dbName } = parseArgs(process.argv);
  const c = await connect(dbName);
  try {
    await preflight(c);
    await testDisposeHappyAndSplit(c);
    await testSourceValidation(c);
    await testIdempotencyAndBadNumbers(c);
    await testPendingGuardAndGoodStock(c);
    await testTenantRoleAndAnon(c);
  } finally {
    await c.end();
  }
  await testRaceSameRequest(dbName);
  await testRaceHoldVsNegative(dbName);
  console.log('core_runtime_ok');
}

main().catch((e) => {
  console.error(e.stack || e.message);
  process.exit(1);
});

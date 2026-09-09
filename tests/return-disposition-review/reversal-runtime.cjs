#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { Client } = require('pg');

const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--db-name' || !/^return_disposition_test_[A-Za-z0-9_]+$/.test(args[1])) {
  console.error('usage: node tests/return-disposition-review/reversal-runtime.cjs --db-name return_disposition_test_<name>');
  process.exit(2);
}

const dbName = args[1];
const tenantId = '11111111-1111-1111-1111-111111111111';
const operatorId = '22222222-2222-2222-2222-222222222222';
const month = '2026-09-01';

function client() {
  return new Client({ host: '127.0.0.1', port: 56427, user: 'returnlocal', database: dbName });
}

async function q1(c, sql, params = []) {
  return (await c.query(sql, params)).rows[0];
}

async function setAuth(c) {
  await c.query("select set_config('request.jwt.claim.sub',$1,true)", [operatorId]);
  await c.query("select set_config('request.jwt.claims',$1,true)", [
    JSON.stringify({ tenant_id: tenantId, role: 'owner', app_metadata: { role: 'owner' } }),
  ]);
}

async function lockSettlement(c) {
  await c.query(
    "select pg_advisory_xact_lock(hashtext('settlement:' || $1::text || ':' || $2::date::text))",
    [tenantId, month],
  );
}

async function createReturn(c, lines = [{ sku_id: 101, qty: 10 }]) {
  const row = await q1(c, "select rpc_create_store_return(1,$1::jsonb,'破損',$2) as result", [
    JSON.stringify(lines),
    operatorId,
  ]);
  const transferId = row.result.transfer_id;
  await c.query("select rpc_receive_transfer($1,null,$2,'review reversal runtime',false)", [transferId, operatorId]);
  const items = (await c.query(
    'select id, sku_id, in_movement_id from transfer_items where transfer_id=$1 order by id',
    [transferId],
  )).rows;
  return { transferId, items };
}

async function createReturnWithNullCost(c) {
  const transfer = await q1(c, `
    insert into transfers (
      tenant_id, transfer_no, source_location, dest_location, status, transfer_type,
      shipped_by, shipped_at, received_by, received_at, created_by, updated_by
    )
    values (
      $1, 'RETURN-NULL-COST-' || txid_current(), 20, 10, 'received', 'return_to_hq',
      $2, now(), $2, now(), $2, $2
    )
    returning id
  `, [tenantId, operatorId]);
  const movement = await q1(c, `
    insert into stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost,
      movement_type, source_doc_type, source_doc_id, operator_id
    )
    values ($1, 20, 101, -1, null, 'transfer_out', 'transfer', $2, $3)
    returning id
  `, [tenantId, transfer.id, operatorId]);
  await c.query(`
    insert into transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped, qty_received,
      out_movement_id, created_by, updated_by
    )
    values ($1, 101, 1, 1, 1, $2, $3, $3)
  `, [transfer.id, movement.id, operatorId]);
  return transfer.id;
}

async function stockAndBatches(c, transferId) {
  return q1(c, `
    select
      (
        select coalesce(jsonb_agg(to_jsonb(b) order by b.id), '[]')
          from hq_return_batches b
         where b.source_transfer_item_id in (
           select ti.id from transfer_items ti where ti.transfer_id=$1
         )
      ) as batches,
      (
        select coalesce(jsonb_agg(to_jsonb(ti) order by ti.id), '[]')
          from transfer_items ti
         where ti.transfer_id=$1
      ) as items,
      (
        select coalesce(jsonb_agg(to_jsonb(sb) order by sb.location_id, sb.sku_id), '[]')
          from stock_balances sb
         where sb.tenant_id=$2
           and sb.location_id=10
           and sb.sku_id in (
             select ti.sku_id from transfer_items ti where ti.transfer_id=$1
           )
      ) as balances
  `, [transferId, tenantId]);
}

async function testGeneratorSharesCAdvisoryLock() {
  const holder = client();
  const contender = client();
  const observer = client();
  await holder.connect();
  await contender.connect();
  await observer.connect();
  let holderOpen = false;
  let contenderOpen = false;
  try {
    await holder.query('begin');
    holderOpen = true;
    await holder.query("set local statement_timeout='5000ms'");
    await lockSettlement(holder);

    await contender.query('begin');
    contenderOpen = true;
    await contender.query("set local statement_timeout='5000ms'");
    let finished = false;
    let result;
    const pending = contender
      .query('select public.rpc_generate_hq_to_store_settlement($1::date,$2::uuid)', [month, operatorId])
      .then((r) => {
        finished = true;
        result = r;
        return r;
      }, (e) => {
        finished = true;
        result = e;
        return e;
      });

    let sawAdvisoryWait = false;
    for (let i = 0; i < 30; i += 1) {
      const row = await q1(observer, `
        select
          exists (
            select 1 from pg_locks
             where pid=$1 and locktype='advisory' and granted=false
          ) as waiting_advisory,
          coalesce(max(wait_event), '') as wait_event
        from pg_stat_activity
        where pid=$1
      `, [contender.processID]);
      if (row.waiting_advisory || String(row.wait_event).toLowerCase().includes('advisory')) {
        sawAdvisoryWait = true;
        break;
      }
      if (finished) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.ok(
      sawAdvisoryWait,
      `月結產生器沒有等待 C 使用的 settlement advisory lock；finished=${finished} result=${result instanceof Error ? `${result.code}:${result.message}` : 'completed'}`,
    );

    await holder.query('rollback');
    holderOpen = false;
    const releasedResult = await pending;
    if (releasedResult instanceof Error) throw releasedResult;
    assert.equal(releasedResult.rowCount, 1, '放鎖後真正月結產生器應完成，不可只靠逾時假通過');
  } finally {
    if (contenderOpen) await contender.query('rollback').catch(() => undefined);
    if (holderOpen) await holder.query('rollback').catch(() => undefined);
    await contender.end();
    await holder.end();
    await observer.end();
  }
}

async function testGeneratorCompletesTwice() {
  const c = client();
  await c.connect();
  try {
    await c.query('begin');
    await c.query("set local statement_timeout='5000ms'");
    await c.query('update prices set effective_from = now() - make_interval(days => 30)');
    const first = await q1(c, 'select public.rpc_generate_hq_to_store_settlement($1::date,$2::uuid) as result', [month, operatorId]);
    const afterFirst = await q1(c, 'select count(*)::int as n from store_monthly_settlement_items');
    const second = await q1(c, 'select public.rpc_generate_hq_to_store_settlement($1::date,$2::uuid) as result', [month, operatorId]);
    const afterSecond = await q1(c, 'select count(*)::int as n from store_monthly_settlement_items');
    assert.equal(first.result.month, '2026-09');
    assert.equal(second.result.month, '2026-09');
    assert.ok(afterFirst.n > 0, '第一次產生月結應建立真明細');
    assert.equal(afterSecond.n, afterFirst.n, '第二次重建 draft 不應被舊 immutable trigger 擋住或重複膨脹');
  } finally {
    await c.query('rollback').catch(() => undefined);
    await c.end();
  }
}

async function testBusyMonthRejectsCWithoutSideEffects() {
  const setup = client();
  const holder = client();
  const worker = client();
  await setup.connect();
  await holder.connect();
  await worker.connect();
  let setupOpen = false;
  let holderOpen = false;
  let workerOpen = false;
  try {
    await setup.query('begin');
    setupOpen = true;
    await setup.query("set local statement_timeout='5000ms'");
    await setAuth(setup);
    await setup.query("select rpc_inbound($1,20,101,20,100,'purchase_receipt','review',null,$2)", [tenantId, operatorId]);
    const doc = await createReturn(setup);
    await setup.query('commit');
    setupOpen = false;
    const before = await stockAndBatches(setup, doc.transferId);

    await holder.query('begin');
    holderOpen = true;
    await lockSettlement(holder);

    await worker.query('begin');
    workerOpen = true;
    await worker.query("set local statement_timeout='1200ms'");
    await setAuth(worker);
    const started = Date.now();
    let error;
    try {
      await worker.query(
        "select rpc_adjust_received_transfer($1,$2::jsonb,$3,'busy month review')",
        [doc.transferId, JSON.stringify([{ transfer_item_id: doc.items[0].id, qty_received: 8 }]), operatorId],
      );
    } catch (e) {
      error = e;
    }
    const elapsed = Date.now() - started;
    assert.ok(error, 'C 遇到忙月鎖應快速拒絕，不可等鎖後偷偷成功');
    assert.notEqual(error.code, '57014', 'C 忙月鎖應回業務拒絕，不應拖到 statement_timeout');
    assert.ok(elapsed < 1000, `C 忙月鎖拒絕太慢：${elapsed}ms`);
    await worker.query('rollback');
    workerOpen = false;

    assert.deepEqual(await stockAndBatches(setup, doc.transferId), before, '忙月鎖拒絕後，庫存/批次/item 不能留下半套');
  } finally {
    if (workerOpen) await worker.query('rollback').catch(() => undefined);
    if (holderOpen) await holder.query('rollback').catch(() => undefined);
    if (setupOpen) await setup.query('rollback').catch(() => undefined);
    await setup.end();
    await holder.end();
    await worker.end();
  }
}

async function testTryLockReentrantMultiItem() {
  const c = client();
  await c.connect();
  try {
    await c.query('begin');
    await c.query("set local statement_timeout='5000ms'");
    await setAuth(c);
    await c.query("select rpc_inbound($1,20,101,10,100,'purchase_receipt','review',null,$2)", [tenantId, operatorId]);
    await c.query("select rpc_inbound($1,20,102,10,80,'purchase_receipt','review',null,$2)", [tenantId, operatorId]);
    const doc = await createReturn(c, [{ sku_id: 101, qty: 4 }, { sku_id: 102, qty: 3 }]);
    const payload = doc.items.map((item) => ({
      transfer_item_id: item.id,
      qty_received: item.sku_id === 101 ? 2 : 1,
    }));
    await c.query("select rpc_adjust_received_transfer($1,$2::jsonb,$3,'multi item trylock review')", [
      doc.transferId,
      JSON.stringify(payload),
      operatorId,
    ]);
    await c.query('set constraints all immediate');
    const rows = (await c.query(`
      select sku_id, status, count(*)::int as n
      from hq_return_batches
      where source_transfer_item_id = any($1::bigint[])
      group by sku_id,status
      order by sku_id,status
    `, [doc.items.map((item) => item.id)])).rows;
    assert.deepEqual(rows.map((r) => `${r.sku_id}:${r.status}:${r.n}`), [
      '101:pending:1',
      '101:revoked:1',
      '102:pending:1',
      '102:revoked:1',
    ]);
  } finally {
    await c.query('rollback').catch(() => undefined);
    await c.end();
  }
}

async function testReturnOutUnknownCostStaysNull() {
  const c = client();
  await c.connect();
  try {
    await c.query('begin');
    await c.query("set local statement_timeout='5000ms'");
    await setAuth(c);
    await c.query('update prices set effective_from = now() - make_interval(days => 30)');
    const transferId = await createReturnWithNullCost(c);

    await c.query('select public.rpc_generate_hq_to_store_settlement($1::date,$2::uuid)', [month, operatorId]);
    const row = await q1(c, `
      select unit_cost::text as unit_cost, line_amount::text as line_amount
      from store_monthly_settlement_items
      where entry_type='return_out'
        and transfer_id=$1
    `, [transferId]);
    assert.deepEqual(
      row,
      { unit_cost: null, line_amount: null },
      'return_out 未知成本不可被 COALESCE 成 0',
    );
  } finally {
    await c.query('rollback').catch(() => undefined);
    await c.end();
  }
}

async function verifyIdentity() {
  const c = client();
  await c.connect();
  try {
    const identity = await q1(c, 'select current_database() db,current_user usr,inet_server_addr()::text host,inet_server_port() port');
    assert.equal(identity.db, dbName);
    assert.equal(identity.usr, 'returnlocal');
    assert.match(identity.host, /^127\.0\.0\.1(?:\/32)?$/);
    assert.equal(identity.port, 56427);
  } finally {
    await c.end();
  }
}

const tests = [
  ['settlement_generator_shares_c_advisory_lock', testGeneratorSharesCAdvisoryLock],
  ['settlement_generator_completes_twice', testGeneratorCompletesTwice],
  ['busy_month_rejects_c_without_side_effects', testBusyMonthRejectsCWithoutSideEffects],
  ['trylock_reentrant_multi_item', testTryLockReentrantMultiItem],
  ['return_out_unknown_cost_stays_null', testReturnOutUnknownCostStaysNull],
];

(async () => {
  await verifyIdentity();
  for (const [name, fn] of tests) {
    await fn();
    console.log(`PASS ${name}`);
  }
})().catch((e) => {
  console.error(`FAIL reversal-runtime: ${e.code || 'assert'} ${e.message}`);
  process.exitCode = 1;
});

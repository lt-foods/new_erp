#!/usr/bin/env node
'use strict';

// CEO 的本機真 RPC 抽驗；不取代不同模型阿審的正式審查。
// 固定專用假庫連線，所有案例 BEGIN/ROLLBACK，不讀環境或真資料。
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { Client } = require('pg');
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--db-name' || !/^return_disposition_test_[A-Za-z0-9_]+$/.test(args[1])) {
  console.error('usage: node tests/return-disposition/flow-smoke.cjs --db-name return_disposition_test_<name>');
  process.exit(2);
}
const db = args[1];
const tenant = '11111111-1111-1111-1111-111111111111';
const operator = '22222222-2222-2222-2222-222222222222';
const c = new Client({ host: '127.0.0.1', port: 56427, user: 'returnlocal', database: db });
const cases = [];
const test = (name, run) => cases.push({ name, run });
const one = async (sql, values = []) => (await c.query(sql, values)).rows[0];
async function stock() {
  const row = await one('SELECT on_hand,reserved FROM stock_balances WHERE tenant_id=$1 AND location_id=10 AND sku_id=101', [tenant]);
  return { on_hand: Number(row.on_hand), reserved: Number(row.reserved) };
}
async function batches(item) {
  return (await c.query('SELECT * FROM hq_return_batches WHERE source_transfer_item_id=$1 ORDER BY id', [item])).rows;
}
async function receive(id) {
  return one("SELECT rpc_receive_transfer($1,NULL,$2,'local flow smoke',FALSE) AS result", [id, operator]);
}
async function createReturn(qty = 10) {
  const row = await one("SELECT rpc_create_store_return(1,$1::jsonb,'破損',$2) AS result", [JSON.stringify([{ sku_id: 101, qty }]), operator]);
  const id = row.result.transfer_id;
  await receive(id);
  const item = await one('SELECT id,in_movement_id FROM transfer_items WHERE transfer_id=$1', [id]);
  return { id, item: item.id, movement: item.in_movement_id };
}
async function adjust(doc, qty) {
  return one("SELECT rpc_adjust_received_transfer($1,$2::jsonb,$3,'local flow correction') AS result", [doc.id, JSON.stringify([{ transfer_item_id: doc.item, qty_received: qty }]), operator]);
}
async function unreceive(doc) {
  return one("SELECT rpc_unreceive_transfer($1,$2,'local flow unreceive') AS result", [doc.id, operator]);
}
async function snapshot() {
  const out = {};
  for (const table of ['stock_balances', 'stock_movements', 'transfers', 'transfer_items', 'hq_return_batches', 'hq_return_events', 'picking_waves', 'picking_wave_items']) {
    out[table] = (await one(`SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]') AS data FROM public.${table} x`)).data;
  }
  return out;
}
async function rejectAtomic(label, fn) {
  const before = await snapshot();
  await c.query('SAVEPOINT expected_rejection');
  let error;
  try {
    await fn();
    // 舊撤收 RPC 可先歸零再撤短少：數量一致性可能延後到交易末驗。
    // 測試會 ROLLBACK，必須主動強制跑，不能因此漏掉延後的守門。
    await c.query('SET CONSTRAINTS ALL IMMEDIATE');
  } catch (e) { error = e; }
  await c.query('ROLLBACK TO SAVEPOINT expected_rejection');
  await c.query('RELEASE SAVEPOINT expected_rejection');
  assert.ok(error, `${label}: 應拒絕，卻成功`);
  assert.equal(error.code, 'P0001', `${label}: 不是業務守門錯誤，而是 ${error.code}: ${error.message}`);
  assert.deepEqual(await snapshot(), before, `${label}: 失敗交易不能留下副作用`);
}
async function dispose(batch, good, damaged = 0, lost = 0) {
  return one("SELECT rpc_dispose_hq_return($1,$2,$3,$4,$5,'包裝破裂','清點找不到',TRUE,'local flow disposition') result", [batch.id, randomUUID(), good, damaged, lost]);
}
async function lockMonth(status = 'confirmed') {
  await c.query(`INSERT INTO store_monthly_settlements
    (tenant_id,settlement_month,store_id,payable_amount,transfer_count,item_count,status,confirmed_at,confirmed_by,created_by,updated_by)
    VALUES($1,date_trunc('month',NOW() AT TIME ZONE 'Asia/Taipei')::date,1,0,0,0,$2,NOW(),$3,$3,$3)`, [tenant, status, operator]);
}
async function directReverse(movement, item, quantity) {
  return c.query(`INSERT INTO stock_movements
    (tenant_id,location_id,sku_id,quantity,unit_cost,movement_type,source_doc_type,source_doc_id,source_doc_line_id,reverses,reason,operator_id)
    SELECT tenant_id,location_id,sku_id,COALESCE($3,-quantity),unit_cost,'reversal',source_doc_type,source_doc_id,$2,id,'local direct reversal',$4
    FROM stock_movements WHERE id=$1`, [movement, item, quantity ?? null, operator]);
}

test('人工退貨只建一批；帳上與凍結同步增加', async () => {
  const before = await stock(); const doc = await createReturn(); const list = await batches(doc.item);
  assert.equal(list.length, 1); assert.equal(Number(list[0].total_qty), 10);
  assert.equal(list[0].source_kind, 'store_return'); assert.equal(list[0].auto_flag, 'manual');
  assert.equal(list[0].created_by, operator);
  assert.deepEqual(await stock(), { on_hand: before.on_hand + 10, reserved: before.reserved + 10 });
});
test('未處理10更正8：舊批撤10、新批待確認8', async () => {
  const before = await stock(); const doc = await createReturn(); await adjust(doc, 8);
  const list = await batches(doc.item); assert.equal(list.length, 2);
  assert.equal(list[0].status, 'revoked'); assert.equal(Number(list[0].qty_revoked), 10);
  assert.equal(list[1].status, 'pending'); assert.equal(Number(list[1].total_qty), 8);
  assert.deepEqual(await stock(), { on_hand: before.on_hand + 8, reserved: before.reserved + 8 });
});
test('未處理更正0：只撤舊批，不能留幽靈凍結', async () => {
  const before = await stock(); const doc = await createReturn(); await adjust(doc, 0);
  const list = await batches(doc.item); assert.equal(list.length, 1); assert.equal(list[0].status, 'revoked');
  assert.deepEqual(await stock(), before);
});
test('撤收再收：只一批有效且店庫不能再扣一次', async () => {
  const before = await stock(); const doc = await createReturn();
  const store = await one('SELECT on_hand FROM stock_balances WHERE location_id=20 AND sku_id=101');
  await unreceive(doc); assert.deepEqual(await stock(), before);
  assert.equal((await one('SELECT status FROM transfers WHERE id=$1', [doc.id])).status, 'shipped');
  await receive(doc.id); const list = await batches(doc.item);
  assert.equal(list.length, 2); assert.equal(list.filter(x => x.status === 'pending').length, 1);
  assert.equal(list.filter(x => x.status === 'revoked').length, 1);
  assert.deepEqual(await stock(), { on_hand: before.on_hand + 10, reserved: before.reserved + 10 });
  assert.deepEqual(await one('SELECT on_hand FROM stock_balances WHERE location_id=20 AND sku_id=101'), store);
});
test('短少回帳再撤銷：撤凍結且取消沖帳子單', async () => {
  const before = await stock();
  await c.query("SELECT rpc_resolve_transfer_item_shortage(9000,'restock_hq','local smoke',$1)", [operator]);
  const item = await one('SELECT shortage_return_transfer_id FROM transfer_items WHERE id=9000');
  const list = await batches(9000); assert.equal(list.length, 1); assert.equal(list[0].source_kind, 'shortage');
  assert.equal(Number(list[0].total_qty), 2); assert.deepEqual(await stock(), { on_hand: before.on_hand + 2, reserved: before.reserved + 2 });
  await c.query("SELECT rpc_undo_transfer_item_shortage(9000,$1,'local smoke undo')", [operator]);
  assert.equal((await batches(9000))[0].status, 'revoked'); assert.deepEqual(await stock(), before);
  assert.equal((await one('SELECT status FROM transfers WHERE id=$1', [item.shortage_return_transfer_id])).status, 'cancelled');
});
test('部分已處理後更正或撤收：整筆拒絕', async () => {
  const doc = await createReturn(); await dispose((await batches(doc.item))[0], 1);
  await rejectAtomic('partial adjust', () => adjust(doc, 8));
  await rejectAtomic('partial unreceive', () => unreceive(doc));
});
test('禁止直接清來源、改短少基準或假反向數量', async () => {
  const doc = await createReturn();
  await rejectAtomic('clear source', () => c.query('UPDATE transfer_items SET in_movement_id=NULL WHERE id=$1', [doc.item]));
  await rejectAtomic('fake reversal amount', () => directReverse(doc.movement, doc.item, -1));
  await c.query("SELECT rpc_resolve_transfer_item_shortage(9000,'restock_hq','local smoke',$1)", [operator]);
  await rejectAtomic('change shortage source qty', () => c.query('UPDATE transfer_items SET qty_shipped=6 WHERE id=9000'));
});
test('撤回必須有真操作者與同公司身分', async () => {
  const doc = await createReturn();
  await rejectAtomic('missing operator identity', async () => {
    await c.query("SELECT set_config('request.jwt.claim.sub','',true)");
    await directReverse(doc.movement, doc.item);
  });
  await rejectAtomic('impersonated operator', async () => {
    await c.query("SELECT set_config('request.jwt.claim.sub',$1,true)", [randomUUID()]);
    await directReverse(doc.movement, doc.item);
  });
  for (const claims of [{ app_metadata: { role: 'owner' } }, { tenant_id: randomUUID(), app_metadata: { role: 'owner' } }]) {
    await rejectAtomic('missing or different tenant', async () => {
      await c.query("SELECT set_config('request.jwt.claims',$1,true)", [JSON.stringify(claims)]);
      await directReverse(doc.movement, doc.item);
    });
  }
});
for (const status of ['confirmed', 'settled', 'remitted']) {
  test(`真退貨${status}月鎖：更正、撤收、跨月、直接反向都擋`, async () => {
    const doc = await createReturn(); await lockMonth(status);
    await rejectAtomic('locked adjust', () => adjust(doc, 8));
    await rejectAtomic('locked unreceive', () => unreceive(doc));
    await rejectAtomic('locked month change', () => c.query("UPDATE transfers SET received_at=received_at+INTERVAL '1 month' WHERE id=$1", [doc.id]));
    await rejectAtomic('locked direct reversal', () => directReverse(doc.movement, doc.item));
  });
}
test('短少沖帳子單鎖月：撤銷與直接反向都擋', async () => {
  await c.query("SELECT rpc_resolve_transfer_item_shortage(9000,'restock_hq','local smoke',$1)", [operator]);
  const item = await one('SELECT shortage_restock_movement_id FROM transfer_items WHERE id=9000'); await lockMonth();
  await rejectAtomic('locked shortage undo', () => c.query("SELECT rpc_undo_transfer_item_shortage(9000,$1,'local smoke')", [operator]));
  await rejectAtomic('locked shortage direct', () => directReverse(item.shortage_restock_movement_id, 9000));
});
test('破損與遺失處理異動不能私自反向洗掉', async () => {
  const doc = await createReturn(); const batch = (await batches(doc.item))[0]; await dispose(batch, 0, 1, 1);
  const event = await one('SELECT damage_movement_id,loss_movement_id FROM hq_return_events WHERE batch_id=$1', [batch.id]);
  await rejectAtomic('damage reversal', () => directReverse(event.damage_movement_id, batch.id));
  await rejectAtomic('loss reversal', () => directReverse(event.loss_movement_id, batch.id));
});

(async () => {
  await c.connect();
  try {
    const identity = await one('SELECT current_database() db,current_user usr,inet_server_addr()::text host,inet_server_port() port');
    assert.equal(identity.db, db); assert.equal(identity.usr, 'returnlocal');
    assert.match(identity.host, /^127\.0\.0\.1(?:\/32)?$/); assert.equal(identity.port, 56427);
    let failures = 0;
    for (const entry of cases) {
      await c.query('BEGIN');
      try {
        await c.query("SET LOCAL statement_timeout='5000ms'");
        await c.query("SELECT set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)", [operator, JSON.stringify({ tenant_id: tenant, app_metadata: { role: 'owner' }, role: 'owner' })]);
        await entry.run();
        await c.query('SET CONSTRAINTS ALL IMMEDIATE');
        console.log(`PASS ${entry.name}`);
      } catch (e) { failures += 1; console.error(`FAIL ${entry.name}: ${e.code || 'assert'} ${e.message}`); }
      finally { await c.query('ROLLBACK'); }
    }
    console.log(`flow_smoke_summary: ${cases.length - failures}/${cases.length} PASS (all transactions rolled back)`);
    if (failures) process.exitCode = 1;
  } finally { await c.end(); }
})().catch(e => { console.error(e); process.exitCode = 1; });

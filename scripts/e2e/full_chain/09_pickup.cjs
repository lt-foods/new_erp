// Step 9: 顧客取貨 (SQL fallback for orders 31, 32; order 30 通常用 UI 跑)
// Order 30 (M-TEST-002 松山): UI /pickup 跑 → wallet
// Order 31 (M-TEST-001 萬華): SQL → wallet
// Order 32 (M-TEST-003 四號): SQL → cash (因為 M-TEST-003 是 merged 會員)
const { newClient, setJwt, TENANT, ADMIN_UID } = require('./_db.cjs');

const ORDER_IDS_FOR_SQL = [31, 32]; // 30 留給 UI 跑

async function main() {
  const c = newClient();
  await c.connect();
  console.log('==== Step 9: Pickup (SQL fallback for orders 31/32) ====');

  for (const oid of ORDER_IDS_FOR_SQL) {
    const items = await c.query(
      `SELECT id, qty, unit_price FROM customer_order_items WHERE order_id=$1 AND status='pending'`,
      [oid],
    );
    if (items.rows.length === 0) {
      console.log(`Order ${oid}: no pending items, skip`);
      continue;
    }
    const itemIds = items.rows.map(i => Number(i.id));
    const total = items.rows.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0);
    console.log(`Order ${oid}: items=${itemIds.length}, total=${total}`);

    await c.query('BEGIN');
    await setJwt(c);
    try {
      // 先試 wallet pay
      await c.query(`SELECT rpc_wallet_pay_order($1, $2, $3)`, [oid, total, ADMIN_UID]);
      console.log(`  ✓ wallet paid`);
    } catch (e) {
      if (e.message.includes('merged') || e.message.includes('insufficient')) {
        // Fallback: cash
        await c.query(`
          UPDATE customer_orders SET payment_status='paid', payment_method='cash',
                 remit_amount=$2, remit_at=NOW(), paid_at=NOW(), updated_by=$3
           WHERE id=$1
        `, [oid, total, ADMIN_UID]);
        console.log(`  ✓ cash settled (${e.message.slice(0, 40)})`);
      } else {
        throw e;
      }
    }
    try {
      await c.query(`SELECT rpc_record_pickup($1, $2, $3, $4)`,
        [oid, itemIds, ADMIN_UID, 'E2E full-chain auto-pickup']);
      console.log(`  ✓ pickup recorded`);
    } catch (e) {
      console.log(`  ERR record_pickup:`, e.message);
    }
    await c.query('COMMIT');
  }

  const o = await c.query(
    `SELECT id, order_no, status, payment_method, payment_status, wallet_paid_amount, remit_amount, completed_at
       FROM customer_orders WHERE id IN (30, 31, 32) ORDER BY id`,
  );
  console.log('\nAll orders:', JSON.stringify(o.rows, null, 2));

  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

// 把所有 ready 但未取貨的訂單跑完 chain (現金結帳 + rpc_record_pickup)
// 跑完 simulator 主要時、用此 script drain 殘留訂單
const { newClient, setJwt, TENANT, ADMIN_UID } = require('./_db.cjs');

const BATCH_SIZE = Number(process.env.BATCH_SIZE || 100);

async function main() {
  const c = newClient();
  await c.connect();
  console.log('==== Finish pickups for ready orders ====');

  let totalDone = 0;
  let totalSkipped = 0;
  let totalErr = 0;

  while (true) {
    // 找下一批 ready 但未取的 orders (限 marker scope)
    const batch = (await c.query(`
      SELECT co.id, co.order_no
        FROM customer_orders co
        JOIN group_buy_campaigns gbc ON gbc.id=co.campaign_id
       WHERE gbc.name LIKE 'E2E-WEEK-260514%'
         AND co.status NOT IN ('completed','cancelled','expired','transferred_out')
         AND is_order_pickup_ready(co.id) = true
       ORDER BY co.id
       LIMIT $1
    `, [BATCH_SIZE])).rows;
    if (batch.length === 0) break;

    for (const o of batch) {
      const items = (await c.query(
        `SELECT id, qty, unit_price FROM customer_order_items WHERE order_id=$1 AND status IN ('pending','reserved','ready')`,
        [o.id],
      )).rows;
      if (items.length === 0) { totalSkipped++; continue; }
      const itemIds = items.map(i => Number(i.id));
      const total = items.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0);

      try {
        await c.query('BEGIN');
        await setJwt(c);
        await c.query(`
          UPDATE customer_orders SET payment_status='paid', payment_method='cash',
                 remit_amount=$2, remit_at=NOW(), paid_at=NOW(), updated_by=$3
           WHERE id=$1
        `, [o.id, total, ADMIN_UID]);
        await c.query(`SELECT rpc_record_pickup($1, $2, $3, $4)`,
          [o.id, itemIds, ADMIN_UID, 'sim finish-pickups']);
        await c.query('COMMIT');
        totalDone++;
      } catch (e) {
        try { await c.query('ROLLBACK'); } catch {}
        totalErr++;
        if (totalErr <= 5) console.log(`  ! ${o.order_no}: ${e.message.slice(0, 120)}`);
      }
    }
    if (totalDone % 500 === 0 || batch.length < BATCH_SIZE) {
      console.log(`  done=${totalDone} err=${totalErr} skipped=${totalSkipped} (batch ${batch.length})`);
    }
  }

  console.log(`\nDone: ${totalDone} | Err: ${totalErr} | Skipped: ${totalSkipped}`);
  // Remaining stuck check
  const stuck = (await c.query(`
    SELECT COUNT(*) FROM customer_orders co
     JOIN group_buy_campaigns gbc ON gbc.id=co.campaign_id
     WHERE gbc.name LIKE 'E2E-WEEK-260514%'
       AND co.status NOT IN ('completed','cancelled','expired','transferred_out')`)).rows[0].count;
  console.log(`Remaining active orders: ${stuck}`);
  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

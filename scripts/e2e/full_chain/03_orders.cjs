// Step 3: 建 3 顧客訂單 (idempotent: reuse if existing)
// M-TEST-002 松山 15、M-TEST-001 萬華 10、M-TEST-003 四號 5、共 30 件
const { newClient, TENANT, ADMIN_UID } = require('./_db.cjs');

const MARKER = 'E2E-CHAIN-260514';
const CAMP_ID = 18;
const SKU_ID = 16;
const CHANNEL_ID = 1;

const ORDERS = [
  { member_id: 2, store_id: 2,  qty: 15, label: 'M-TEST-002 松山' },
  { member_id: 1, store_id: 36, qty: 10, label: 'M-TEST-001 萬華' },
  { member_id: 3, store_id: 37, qty: 5,  label: 'M-TEST-003 四號' },
];

async function main() {
  const c = newClient();
  await c.connect();
  console.log('==== Step 3: Create customer orders ====');

  const ci = await c.query(`SELECT id, unit_price FROM campaign_items WHERE campaign_id=$1 AND sku_id=$2`, [CAMP_ID, SKU_ID]);
  if (!ci.rows[0]) throw new Error('no campaign_item');
  const ciId = ci.rows[0].id;
  const unitPrice = Number(ci.rows[0].unit_price);
  console.log('campaign_item:', ciId, 'unit_price:', unitPrice);

  for (const o of ORDERS) {
    // idempotent: 找既有相同 (campaign, channel, member) 訂單
    const existing = await c.query(
      `SELECT id, order_no, status FROM customer_orders WHERE campaign_id=$1 AND channel_id=$2 AND member_id=$3`,
      [CAMP_ID, CHANNEL_ID, o.member_id],
    );
    if (existing.rows[0]) {
      console.log(`Reused ${o.label}: order_id=${existing.rows[0].id} (${existing.rows[0].status})`);
      continue;
    }

    const orderNo = `${MARKER}-O${o.member_id}`.slice(0, 32);
    const ord = await c.query(`
      INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, member_id,
                                   pickup_store_id, status, created_by, updated_by)
      VALUES ($1, $2, $3, $4, $5, $6, 'pending', $7, $7)
      RETURNING id, order_no
    `, [TENANT, orderNo, CAMP_ID, CHANNEL_ID, o.member_id, o.store_id, ADMIN_UID]);
    const orderId = ord.rows[0].id;
    await c.query(`
      INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
                                        status, source, created_by, updated_by)
      VALUES ($1, $2, $3, $4, $5, $6, 'pending', 'manual', $7, $7)
    `, [TENANT, orderId, ciId, SKU_ID, o.qty, unitPrice, ADMIN_UID]);
    console.log(`✓ Inserted ${o.label}: order_id=${orderId}, qty=${o.qty}`);
  }

  // 驗證 demand
  const demand = await c.query(`
    SELECT st.name AS store_name, SUM(coi.qty) AS qty
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
      JOIN stores st ON st.id = co.pickup_store_id
     WHERE co.campaign_id = $1
       AND co.status NOT IN ('cancelled','expired','transferred_out')
     GROUP BY st.name ORDER BY st.name
  `, [CAMP_ID]);
  console.log('\nDemand:', JSON.stringify(demand.rows, null, 2));
  const total = demand.rows.reduce((s, r) => s + Number(r.qty), 0);
  console.log('Total:', total);

  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

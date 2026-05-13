// Step 1+2: 建 product / SKU / prices / supplier_skus / campaign / campaign_item
// 全 idempotent — reuse existing if marker matches、避免 FK constraint 阻擋。
const { newClient, TENANT, ADMIN_UID } = require('./_db.cjs');

const MARKER = 'E2E-CHAIN-260514';

async function main() {
  const c = newClient();
  await c.connect();
  console.log('==== E2E Chain Setup (marker:', MARKER, ') ====');

  // 找 supplier
  const sup = await c.query(`SELECT id, code, name FROM suppliers WHERE tenant_id=$1 AND code='SUP-LOCAL' LIMIT 1`, [TENANT]);
  if (!sup.rows[0]) throw new Error('no SUP-LOCAL supplier');
  const supplierId = sup.rows[0].id;
  console.log('Supplier:', supplierId, sup.rows[0].name);

  const productCode = `R-${MARKER}-001`;
  const skuCode = `SKU-${MARKER}-001`;

  // Product (idempotent)
  let prodFound = await c.query(`SELECT id, product_code FROM products WHERE tenant_id=$1 AND name=$2`, [TENANT, `${MARKER} 蜂蜜茶`]);
  let productId;
  if (prodFound.rows[0]) {
    productId = prodFound.rows[0].id;
    console.log('Reused Product:', productId, prodFound.rows[0].product_code);
  } else {
    const prod = await c.query(`
      INSERT INTO products (tenant_id, product_code, name, status, storage_type, default_supplier_id,
                            images, stop_shipping, is_for_shop, sale_mode, vip_level_min, is_virtual,
                            created_by, updated_by)
      VALUES ($1, $2, $3, 'active', 'room_temp', $4,
              '[]'::jsonb, false, true, 'in_stock_only', 0, false,
              $5, $5)
      RETURNING id, product_code
    `, [TENANT, productCode, `${MARKER} 蜂蜜茶`, supplierId, ADMIN_UID]);
    productId = prod.rows[0].id;
    console.log('Inserted Product:', productId, prod.rows[0].product_code);
  }

  // SKU (idempotent)
  let skuFound = await c.query(`SELECT id, sku_code FROM skus WHERE tenant_id=$1 AND product_id=$2 AND sku_code=$3`, [TENANT, productId, skuCode]);
  let skuId;
  if (skuFound.rows[0]) {
    skuId = skuFound.rows[0].id;
    console.log('Reused SKU:', skuId, skuFound.rows[0].sku_code);
  } else {
    const sku = await c.query(`
      INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, spec, base_unit, tax_rate, status,
                        product_name, created_by, updated_by)
      VALUES ($1, $2, $3, '500ml瓶', '{}'::jsonb, '瓶', 0.05, 'active', $4, $5, $5)
      RETURNING id, sku_code
    `, [TENANT, productId, skuCode, `${MARKER} 蜂蜜茶`, ADMIN_UID]);
    skuId = sku.rows[0].id;
    console.log('Inserted SKU:', skuId, sku.rows[0].sku_code);
  }

  // Prices — 清掉舊的再 insert (沒 unique constraint、避免重複)
  await c.query(`DELETE FROM prices WHERE sku_id=$1 AND reason IS NULL`, [skuId]);
  for (const [scope, price] of [['retail', 180], ['branch', 140], ['cost', 100]]) {
    await c.query(`
      INSERT INTO prices (tenant_id, sku_id, scope, price, currency, effective_from, created_by)
      VALUES ($1, $2, $3, $4, 'TWD', NOW(), $5)
    `, [TENANT, skuId, scope, price, ADMIN_UID]);
  }
  console.log('Prices: retail=180 / branch=140 / cost=100');

  // supplier_skus — primary key (tenant_id, supplier_id, sku_id), ON CONFLICT 處理重跑
  await c.query(`
    INSERT INTO supplier_skus (tenant_id, supplier_id, sku_id, default_unit_cost, pack_qty, is_preferred,
                               created_by, updated_by)
    VALUES ($1, $2, $3, 100, 1, true, $4, $4)
    ON CONFLICT (tenant_id, supplier_id, sku_id) DO UPDATE SET
      default_unit_cost = EXCLUDED.default_unit_cost,
      is_preferred = EXCLUDED.is_preferred,
      updated_at = NOW()
  `, [TENANT, supplierId, skuId, ADMIN_UID]);
  console.log('supplier_skus: preferred=true, cost=100');

  // Campaign (idempotent)
  const campNo = `GB-${MARKER}-001`;
  let campFound = await c.query(`SELECT id, campaign_no, status, end_at FROM group_buy_campaigns WHERE tenant_id=$1 AND name=$2`,
    [TENANT, `${MARKER} 蜂蜜茶 #1`]);
  let campId;
  if (campFound.rows[0]) {
    campId = campFound.rows[0].id;
    console.log('Reused Campaign:', campId, campFound.rows[0].campaign_no, 'status:', campFound.rows[0].status);
  } else {
    const now = new Date();
    const endAt = new Date(now); endAt.setHours(endAt.getHours() + 1);
    const camp = await c.query(`
      INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, close_type,
                                       start_at, end_at, pickup_deadline,
                                       product_id, created_by, updated_by)
      VALUES ($1, $2, $3, 'open', 'regular',
              $4, $5, $6,
              $7, $8, $8)
      RETURNING id, campaign_no, end_at
    `, [TENANT, campNo, `${MARKER} 蜂蜜茶 #1`, now, endAt, new Date(now.getTime() + 5 * 86400000), productId, ADMIN_UID]);
    campId = camp.rows[0].id;
    console.log('Inserted Campaign:', campId, camp.rows[0].campaign_no, 'end_at:', camp.rows[0].end_at);
  }

  // campaign_item (idempotent via existence check — no unique constraint to use for ON CONFLICT)
  const ciFound = await c.query(`SELECT id FROM campaign_items WHERE campaign_id=$1 AND sku_id=$2`, [campId, skuId]);
  if (ciFound.rows[0]) {
    console.log('Reused campaign_item:', ciFound.rows[0].id);
  } else {
    const ci = await c.query(`
      INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price, sort_order, created_by, updated_by)
      VALUES ($1, $2, $3, 180, 0, $4, $4)
      RETURNING id
    `, [TENANT, campId, skuId, ADMIN_UID]);
    console.log('Inserted campaign_item:', ci.rows[0].id);
  }

  console.log('\n==== Setup done ====');
  console.log({ productId, skuId, supplierId, campId, campNo, marker: MARKER });

  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

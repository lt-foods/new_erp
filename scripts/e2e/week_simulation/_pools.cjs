// 載入 fixed pools (stores, skus, members, suppliers, locations, HQ)
const { TENANT } = require('./_db.cjs');

async function loadPools(c) {
  const stores = (await c.query(`
    SELECT id, code, name, location_id FROM stores
     WHERE tenant_id=$1 AND is_active=true AND location_id IS NOT NULL
     ORDER BY id`, [TENANT])).rows.map(s => ({ ...s, id: Number(s.id), location_id: Number(s.location_id) }));

  const skus = (await c.query(`
    SELECT s.id, s.sku_code, s.product_name, s.variant_name, ss.supplier_id, ss.default_unit_cost
      FROM skus s
      LEFT JOIN supplier_skus ss ON ss.sku_id=s.id AND ss.is_preferred=true
     WHERE s.tenant_id=$1 AND s.status='active'
       AND EXISTS (SELECT 1 FROM supplier_skus WHERE sku_id=s.id AND is_preferred=true)
     ORDER BY s.id`, [TENANT])).rows.map(s => ({
       ...s,
       id: Number(s.id),
       supplier_id: Number(s.supplier_id),
       default_unit_cost: Number(s.default_unit_cost ?? 50),
     }));

  // Members — 用 active 非 merged，limit 5000 才不會過大
  const members = (await c.query(`
    SELECT id FROM members
     WHERE tenant_id=$1 AND status='active' AND merged_into_member_id IS NULL
     ORDER BY id LIMIT 5000`, [TENANT])).rows.map(r => Number(r.id));

  // HQ location
  const hq = (await c.query(`SELECT id FROM locations WHERE tenant_id=$1 AND type='central_warehouse' LIMIT 1`, [TENANT])).rows[0];
  const hqId = Number(hq.id);

  // Retail prices (sku_id → price)
  const prices = new Map();
  const pr = await c.query(`
    SELECT DISTINCT ON (sku_id) sku_id, price FROM prices
     WHERE tenant_id=$1 AND scope='retail'
     ORDER BY sku_id, effective_from DESC NULLS LAST`, [TENANT]);
  for (const row of pr.rows) prices.set(Number(row.sku_id), Number(row.price));

  return { stores, skus, members, hqId, prices };
}

module.exports = { loadPools };

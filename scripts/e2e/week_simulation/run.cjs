// Week simulation orchestrator
//
// 為了控制 first-run scope、default 是 small validation scale:
//   DAYS=2, CAMPAIGNS_PER_DAY=3, STORES_PER_CAMPAIGN=[2,3], ORDERS_PER_STORE=[3,5]
//   → 約 90 orders、跑通 chain 驗證 traceability
//
// 放大到 full default (env override):
//   DAYS=7 CAMPAIGNS_PER_DAY=20 STORES_MAX=15 ORDERS_MAX=50 node run.cjs
//   → 約 42K orders

const { newClient, setJwt, TENANT, ADMIN_UID, CHANNEL_ID } = require('./_db.cjs');
const { makeRng } = require('./_rng.cjs');
const { loadPools } = require('./_pools.cjs');
const { newAudit, saveAudit, AUDIT_DIR } = require('./_audit.cjs');

const SEED = process.env.SEED || 'week-260514';
const DAYS = Number(process.env.DAYS || 7);
const CAMPAIGNS_PER_DAY = Number(process.env.CAMPAIGNS_PER_DAY || 20);
const PRODUCTS_PER_DAY = Number(process.env.PRODUCTS_PER_DAY || 20);
const SKUS_MIN = Number(process.env.SKUS_MIN || 1);
const SKUS_MAX = Number(process.env.SKUS_MAX || 3);
const STORES_MIN = Number(process.env.STORES_MIN || 5);
const STORES_MAX = Number(process.env.STORES_MAX || 10);
const ORDERS_MIN = Number(process.env.ORDERS_MIN || 10);
const ORDERS_MAX = Number(process.env.ORDERS_MAX || 25);
const QTY_MIN = Number(process.env.QTY_MIN || 1);
const QTY_MAX = Number(process.env.QTY_MAX || 5);
const MARKER = 'E2E-WEEK-260514';

let globalOrderSeq = 0; // 全局 order_no 序號、保證 unique

// Day 1 對應「今天」(本機 tz)、Day N 對應 today + (N-1)
function simDate(day, h = 9, m = 0) {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() + (day - 1));
  d.setHours(h, m, 0, 0);
  return d;
}
// 每次跑加 timestamp salt 避免 campaign_no / order_no 撞前次資料
const RUN_TAG = (() => {
  const d = new Date();
  return `R${d.getMonth() + 1}${String(d.getDate()).padStart(2, '0')}${String(d.getHours()).padStart(2, '0')}${String(d.getMinutes()).padStart(2, '0')}`;
})();

const rng = makeRng(SEED);

const log = (...a) => console.log(`[${new Date().toISOString().slice(11, 19)}]`, ...a);

async function main() {
  const startMs = Date.now();
  const c = newClient();
  await c.connect();
  await c.query(`SET application_name = 'e2e_week_simulator'`);

  const pools = await loadPools(c);
  log('Pools:', {
    stores: pools.stores.length,
    skus: pools.skus.length,
    members: pools.members.length,
    hq: pools.hqId,
  });
  log('Config:', { SEED, DAYS, CAMPAIGNS_PER_DAY, SKUS_MAX, STORES_MAX, ORDERS_MAX });

  if (pools.stores.length === 0 || pools.members.length === 0) {
    throw new Error('insufficient pools — need stores + members. backfill stores location_id first.');
  }
  if (pools.skus.length === 0 && PRODUCTS_PER_DAY <= 0) {
    throw new Error('no SKUs and PRODUCTS_PER_DAY=0 — set PRODUCTS_PER_DAY > 0 or seed SKUs');
  }

  // Cross-day state pools (FIFO-ish, random pick)
  const state = {
    openCampaigns: [],     // {id, end_day, sku_ids, day_opened, no}
    pendingPRsForSplit: [],// {pr_id}
    pendingPOsForGR: [],   // {po_id}
    pendingPOsForWave: [], // {po_id, gr_qty}
    pendingTransfers: [],  // {transfer_id, store_id}
    pendingPickups: [],    // {order_id, ready_day, store_id}
    cumulativeSkus: pools.skus.slice(), // 初始有 fixture SKUs、每天加入新建的 20 個
    totalOrders: 0,
    totalCampaigns: 0,
    totalProducts: 0,
  };

  for (let day = 1; day <= DAYS; day++) {
    const audit = newAudit(day);
    log(`========== Day ${day} ==========`);
    try {
      await runDay(c, pools, state, audit, day);
    } catch (e) {
      log(`Day ${day} ERROR:`, e.message);
      audit.errors.push({ step: 'runDay', msg: e.message });
    }
    saveAudit(audit);
    log(`Day ${day} done. State pools:`, {
      openCampaigns: state.openCampaigns.length,
      pendingPRs: state.pendingPRsForSplit.length,
      pendingPOs_GR: state.pendingPOsForGR.length,
      pendingPOs_Wave: state.pendingPOsForWave.length,
      pendingTransfers: state.pendingTransfers.length,
      pendingPickups: state.pendingPickups.length,
      totalOrders: state.totalOrders,
    });
  }

  // 收尾天 — 把所有 pending 跑完 (不再開新團、處理剩餘 pipeline)
  for (let day = DAYS + 1; day <= DAYS + 5; day++) {
    if (state.openCampaigns.length === 0 &&
        state.pendingPRsForSplit.length === 0 &&
        state.pendingPOsForGR.length === 0 &&
        state.pendingPOsForWave.length === 0 &&
        state.pendingTransfers.length === 0 &&
        state.pendingPickups.length === 0) break;
    const audit = newAudit(day);
    log(`========== Day ${day} (cleanup) ==========`);
    try {
      await runDay(c, pools, state, audit, day, /*noNew=*/true);
    } catch (e) {
      log(`Day ${day} ERROR:`, e.message);
      audit.errors.push({ step: 'runDay', msg: e.message });
    }
    saveAudit(audit);
    log(`Day ${day} done. State pools:`, {
      openCampaigns: state.openCampaigns.length,
      pendingPRs: state.pendingPRsForSplit.length,
      pendingPOs_GR: state.pendingPOsForGR.length,
      pendingPOs_Wave: state.pendingPOsForWave.length,
      pendingTransfers: state.pendingTransfers.length,
      pendingPickups: state.pendingPickups.length,
    });
  }

  await c.end();
  const dur = Math.round((Date.now() - startMs) / 1000);
  log(`✅ Simulation done in ${dur}s. Total: ${state.totalCampaigns} campaigns, ${state.totalOrders} orders. Audit at ${AUDIT_DIR}`);
}

async function runDay(c, pools, state, audit, day, noNew = false) {
  // 0. 每天建 N 個新商品 (累積到 cumulativeSkus pool)
  if (!noNew) {
    await createDailyProducts(c, pools, state, audit, day);
  }
  // 1. 開新團
  if (!noNew) {
    await openCampaigns(c, pools, state, audit, day);
  }
  // 2. 為所有 open campaigns 下單 (open 當天 + 後續每天衰減)
  await placeOrders(c, pools, state, audit, day);
  // 3. 關掉「end_day <= today」的 campaigns → auto PR
  await closeCampaigns(c, pools, state, audit, day);
  // 4. PR submit + split + send (隨機抽部分)
  await processPRs(c, pools, state, audit, day, noNew);
  // 5. GR confirm (隨機抽部分 sent POs)
  await processGRs(c, pools, state, audit, day, noNew);
  // 6. Wave + transfer (隨機抽部分 fully_received POs)
  await processWaves(c, pools, state, audit, day, noNew);
  // 7. Transfer receive (隨機抽部分 shipped transfers)
  await processReceives(c, pools, state, audit, day, noNew);
  // 8. Pickup (隨機抽部分 ready orders)
  await processPickups(c, pools, state, audit, day, noNew);
}

// ============================================================
// Step 0: 每日建 N 個新商品 (bulk insert + 加入 cumulativeSkus pool)
// ============================================================
async function createDailyProducts(c, pools, state, audit, day) {
  if (PRODUCTS_PER_DAY <= 0) return;
  // 抽一個 supplier 給今天的新商品
  let supplierId = pools.skus.length > 0 ? pools.skus[0].supplier_id : null;
  if (!supplierId) {
    const sup = await c.query(`SELECT id FROM suppliers WHERE tenant_id=$1 AND is_active=true ORDER BY id LIMIT 1`, [TENANT]);
    supplierId = sup.rows[0]?.id;
    if (!supplierId) throw new Error('no active supplier');
    supplierId = Number(supplierId);
  }
  // 商品名 / SKU 編號帶 RUN_TAG + day + idx
  const newProducts = [];
  for (let i = 0; i < PRODUCTS_PER_DAY; i++) {
    const idx = day * 1000 + i;
    newProducts.push({
      product_code: `R-WEEK-${RUN_TAG}-D${day}-${String(i + 1).padStart(2, '0')}`,
      name: `${MARKER} 商品 ${RUN_TAG} D${day}-${String(i + 1).padStart(2, '0')}`,
      sku_code: `SKU-WEEK-${RUN_TAG}-D${day}-${String(i + 1).padStart(2, '0')}`,
      sku_name: `${MARKER} 商品 D${day}-${i + 1} 標準`,
      cost: rng.int(20, 200),
    });
  }
  // Bulk INSERT products via unnest
  const prodCodes = newProducts.map(p => p.product_code);
  const prodNames = newProducts.map(p => p.name);
  const prodRes = await c.query(`
    INSERT INTO products (tenant_id, product_code, name, status, storage_type, default_supplier_id,
                          images, stop_shipping, is_for_shop, sale_mode, vip_level_min, is_virtual,
                          created_by, updated_by)
    SELECT $1, unnest($2::text[]), unnest($3::text[]),
           'active', 'room_temp', $4,
           '[]'::jsonb, false, true, 'in_stock_only', 0, false,
           $5, $5
    RETURNING id, product_code
  `, [TENANT, prodCodes, prodNames, supplierId, ADMIN_UID]);
  const productIdByCode = new Map();
  for (const r of prodRes.rows) productIdByCode.set(r.product_code, Number(r.id));

  // Bulk INSERT SKUs
  const skuTenantIds = [];
  const skuProductIds = [];
  const skuCodes = [];
  const skuNames = [];
  const skuProductNames = [];
  for (const p of newProducts) {
    const pid = productIdByCode.get(p.product_code);
    skuTenantIds.push(TENANT);
    skuProductIds.push(pid);
    skuCodes.push(p.sku_code);
    skuNames.push('標準');
    skuProductNames.push(p.name);
  }
  const skuRes = await c.query(`
    INSERT INTO skus (tenant_id, product_id, sku_code, variant_name, spec, base_unit, tax_rate, status,
                      product_name, created_by, updated_by)
    SELECT unnest($1::uuid[]), unnest($2::bigint[]), unnest($3::text[]), unnest($4::text[]),
           '{}'::jsonb, '個', 0.05, 'active',
           unnest($5::text[]), $6, $6
    RETURNING id, sku_code
  `, [skuTenantIds, skuProductIds, skuCodes, skuNames, skuProductNames, ADMIN_UID]);
  const skuIdByCode = new Map();
  for (const r of skuRes.rows) skuIdByCode.set(r.sku_code, Number(r.id));

  // Bulk INSERT prices (retail / branch / cost per SKU)
  const priceTenants = [];
  const priceSkuIds = [];
  const priceScopes = [];
  const priceValues = [];
  for (const p of newProducts) {
    const sid = skuIdByCode.get(p.sku_code);
    const retail = p.cost * 2;
    const branch = Math.round(p.cost * 1.5);
    for (const [scope, val] of [['retail', retail], ['branch', branch], ['cost', p.cost]]) {
      priceTenants.push(TENANT);
      priceSkuIds.push(sid);
      priceScopes.push(scope);
      priceValues.push(val);
    }
  }
  await c.query(`
    INSERT INTO prices (tenant_id, sku_id, scope, price, currency, effective_from, created_by)
    SELECT unnest($1::uuid[]), unnest($2::bigint[]), unnest($3::text[]),
           unnest($4::numeric[]), 'TWD', NOW(), $5
  `, [priceTenants, priceSkuIds, priceScopes, priceValues, ADMIN_UID]);

  // Bulk INSERT supplier_skus
  const ssTenants = [];
  const ssSupplierIds = [];
  const ssSkuIds = [];
  const ssCosts = [];
  for (const p of newProducts) {
    const sid = skuIdByCode.get(p.sku_code);
    ssTenants.push(TENANT);
    ssSupplierIds.push(supplierId);
    ssSkuIds.push(sid);
    ssCosts.push(p.cost);
  }
  await c.query(`
    INSERT INTO supplier_skus (tenant_id, supplier_id, sku_id, default_unit_cost, pack_qty, is_preferred,
                               created_by, updated_by)
    SELECT unnest($1::uuid[]), unnest($2::bigint[]), unnest($3::bigint[]),
           unnest($4::numeric[]), 1, true,
           $5, $5
    ON CONFLICT (tenant_id, supplier_id, sku_id) DO NOTHING
  `, [ssTenants, ssSupplierIds, ssSkuIds, ssCosts, ADMIN_UID]);

  // 加入 cumulativeSkus pool + 同步更新 pools.prices map
  for (const p of newProducts) {
    const sid = skuIdByCode.get(p.sku_code);
    const retail = p.cost * 2;
    state.cumulativeSkus.push({
      id: sid,
      sku_code: p.sku_code,
      product_name: p.name,
      variant_name: '標準',
      supplier_id: supplierId,
      default_unit_cost: p.cost,
      retail_price: retail,
    });
    pools.prices.set(sid, retail);
    state.totalProducts++;
  }
  log(`  ✓ created ${PRODUCTS_PER_DAY} new products + SKUs (cumulativeSkus now ${state.cumulativeSkus.length})`);
}

// ============================================================
// Step 1: open new campaigns
// ============================================================
async function openCampaigns(c, pools, state, audit, day) {
  for (let i = 0; i < CAMPAIGNS_PER_DAY; i++) {
    const seq = `${day}-${String(i + 1).padStart(2, '0')}`;
    const campNo = `GB-WEEK-${RUN_TAG}-${seq}`;
    const name = `${MARKER} 團 ${RUN_TAG} D${seq}`;
    const skuCount = rng.int(SKUS_MIN, SKUS_MAX);
    const chosenSkus = rng.pickN(state.cumulativeSkus, skuCount);
    // end_day = day + 1 (隔天結單)
    const endDay = day + 1;
    const startAt = simDate(day, 9, 0).toISOString();      // 開團日 09:00
    const endAt = simDate(endDay, 23, 59).toISOString();   // 結單日 23:59
    // pickup_deadline = 結單後第 6 天
    const pickupDeadline = simDate(endDay + 6, 0, 0);
    const pickupDeadlineStr = pickupDeadline.toISOString().slice(0, 10);

    const camp = await c.query(`
      INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, close_type,
                                       start_at, end_at, pickup_deadline,
                                       created_by, updated_by)
      VALUES ($1, $2, $3, 'open', 'regular',
              $4, $5, $6,
              $7, $7)
      RETURNING id, campaign_no
    `, [TENANT, campNo, name, startAt, endAt, pickupDeadlineStr, ADMIN_UID]);
    const campId = Number(camp.rows[0].id);

    // campaign_items
    for (const sku of chosenSkus) {
      const unitPrice = pools.prices.get(sku.id) || 100;
      await c.query(`
        INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price, sort_order, created_by, updated_by)
        VALUES ($1, $2, $3, $4, 0, $5, $5)
      `, [TENANT, campId, sku.id, unitPrice, ADMIN_UID]);
    }

    state.openCampaigns.push({
      id: campId,
      no: camp.rows[0].campaign_no,
      end_day: endDay,
      sku_ids: chosenSkus.map(s => s.id),
      day_opened: day,
    });
    state.totalCampaigns++;
    audit.campaigns.push({ id: campId, no: camp.rows[0].campaign_no, name, sku_ids: chosenSkus.map(s => s.id), end_day: endDay });
  }
  log(`  ✓ opened ${CAMPAIGNS_PER_DAY} campaigns`);
}

// ============================================================
// Step 2: place orders (bulk INSERT via unnest)
// ============================================================
async function placeOrders(c, pools, state, audit, day) {
  let totalNew = 0;
  // 每團每天都會下單 — 不再 chance-skip 整團
  // 訂單量依「距開團幾天」衰減: 開團當天 100%、隔天 50%、再隔天 25%
  for (const camp of state.openCampaigns) {
    const daysSinceOpen = day - camp.day_opened;
    const scale = 1 / Math.pow(2, daysSinceOpen); // 1, 0.5, 0.25, ...

    const numStores = rng.int(STORES_MIN, STORES_MAX);
    const stores = rng.pickN(pools.stores, numStores);
    const ciRows = (await c.query(`SELECT id, sku_id, unit_price FROM campaign_items WHERE campaign_id=$1`, [camp.id])).rows;
    const ciMap = new Map();
    for (const r of ciRows) ciMap.set(Number(r.sku_id), { id: Number(r.id), price: Number(r.unit_price) });

    // 蒐集 batch
    // 注意: customer_orders 有 UNIQUE (tenant_id, campaign_id, channel_id, member_id, order_kind)
    // 同團同會員不能重複下 active 單、所以每團跨 store 必須 dedupe member
    const usedMembers = new Set();
    const batch = []; // {memberId, storeId, orderNo, items: [{sku_id, qty, unit_price, ci_id}]}
    for (const store of stores) {
      const baseOrders = rng.int(ORDERS_MIN, ORDERS_MAX);
      const ordersPerStore = Math.max(1, Math.round(baseOrders * scale));
      // 抽 ordersPerStore × 2 候選、dedupe 既有 used members、再切前 N
      const candidates = rng.pickN(pools.members, ordersPerStore * 3);
      const memberSample = candidates.filter(m => !usedMembers.has(m)).slice(0, ordersPerStore);
      for (const memberId of memberSample) {
        usedMembers.add(memberId);
        globalOrderSeq++;
        const orderNo = `WK-${RUN_TAG}-${globalOrderSeq.toString(36).padStart(5, '0')}`;
        const itemSkuCount = rng.int(1, camp.sku_ids.length);
        const chosen = rng.pickN(camp.sku_ids, itemSkuCount);
        const items = chosen.map(skuId => {
          const ci = ciMap.get(skuId);
          return { sku_id: skuId, qty: rng.int(QTY_MIN, QTY_MAX), unit_price: ci.price, ci_id: ci.id };
        });
        batch.push({ memberId, storeId: store.id, orderNo, items });
      }
    }
    if (batch.length === 0) continue;

    // Bulk INSERT orders via unnest (一次 round-trip)
    // created_at = simDate(day) + 隨機 hour/minute、模擬該日陸續下單
    const orderNos = batch.map(b => b.orderNo);
    const campIds = batch.map(_ => camp.id);
    const channelIds = batch.map(_ => CHANNEL_ID);
    const memberIds = batch.map(b => b.memberId);
    const storeIds = batch.map(b => b.storeId);
    const createdAts = batch.map(_ => simDate(day, rng.int(9, 21), rng.int(0, 59)).toISOString());
    let ordRes;
    try {
      ordRes = await c.query(`
        INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, member_id,
                                     pickup_store_id, status, created_by, updated_by,
                                     created_at, updated_at)
        SELECT $1, unnest($2::text[]), unnest($3::bigint[]), unnest($4::bigint[]),
               unnest($5::bigint[]), unnest($6::bigint[]), 'pending', $7, $7,
               unnest($8::timestamptz[]), unnest($8::timestamptz[])
        RETURNING id, order_no
      `, [TENANT, orderNos, campIds, channelIds, memberIds, storeIds, ADMIN_UID, createdAts]);
    } catch (e) {
      audit.errors.push({ step: 'placeOrders bulk-order', msg: `camp ${camp.id}: ${e.message.slice(0, 200)}` });
      continue;
    }
    const idByNo = new Map();
    for (const r of ordRes.rows) idByNo.set(r.order_no, Number(r.id));

    // Bulk INSERT items
    const iTenant = TENANT;
    const iOrderIds = [];
    const iCiIds = [];
    const iSkuIds = [];
    const iQtys = [];
    const iPrices = [];
    for (const b of batch) {
      const orderId = idByNo.get(b.orderNo);
      if (!orderId) continue;
      for (const it of b.items) {
        iOrderIds.push(orderId);
        iCiIds.push(it.ci_id);
        iSkuIds.push(it.sku_id);
        iQtys.push(it.qty);
        iPrices.push(it.unit_price);
      }
    }
    if (iOrderIds.length > 0) {
      try {
        await c.query(`
          INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
                                            status, source, created_by, updated_by)
          SELECT $1, unnest($2::bigint[]), unnest($3::bigint[]), unnest($4::bigint[]),
                 unnest($5::numeric[]), unnest($6::numeric[]), 'pending', 'manual', $7, $7
        `, [iTenant, iOrderIds, iCiIds, iSkuIds, iQtys, iPrices, ADMIN_UID]);
      } catch (e) {
        audit.errors.push({ step: 'placeOrders bulk-items', msg: `camp ${camp.id}: ${e.message.slice(0, 200)}` });
      }
    }

    totalNew += batch.length;
    state.totalOrders += batch.length;
    // Audit (省記憶體只記 sample)
    if (audit.orders.length < 200) {
      for (const b of batch.slice(0, 50)) {
        audit.orders.push({
          id: idByNo.get(b.orderNo),
          no: b.orderNo,
          campaign_id: camp.id,
          member_id: b.memberId,
          store_id: b.storeId,
          items: b.items.map(it => ({ sku_id: it.sku_id, qty: it.qty })),
        });
      }
    }
  }
  log(`  ✓ placed ${totalNew} orders (bulk)`);
}

// ============================================================
// Step 3: close campaigns
// ============================================================
async function closeCampaigns(c, pools, state, audit, day) {
  // 不走 rpc_close_campaign 的 close_date path (會 aggregate 多 camp 成單 PR、導致
  // wave_items.campaign_id 不對齊 customer_orders.campaign_id、is_order_pickup_ready fail)。
  // 改: 直接 UPDATE status='closed' + 對每 camp 呼叫 rpc_create_pr_from_campaign 獨立 PR。
  const toClose = state.openCampaigns.filter(camp => camp.end_day <= day);
  for (const camp of toClose) {
    try {
      await c.query('BEGIN');
      await setJwt(c);
      // 1. 切 status (用 SQL 直接 UPDATE、跳過 close_date logic)
      await c.query(`UPDATE group_buy_campaigns SET status='closed', updated_by=$1, updated_at=NOW() WHERE id=$2 AND status='open'`, [ADMIN_UID, camp.id]);
      // 2. 為此 camp 建 campaign-type PR (獨立、不 aggregate)
      const r = await c.query(`SELECT rpc_create_pr_from_campaign($1, $2) AS pr_id`, [camp.id, ADMIN_UID]);
      const prId = Number(r.rows[0].pr_id);
      await c.query('COMMIT');
      audit.closes.push({ campaign_id: camp.id, pr_id: prId, action: 'created' });
      state.pendingPRsForSplit.push({ pr_id: prId, source_campaign_id: camp.id });
    } catch (e) {
      audit.errors.push({ step: 'closeCampaign', msg: `${camp.no}: ${e.message.slice(0, 150)}` });
      try { await c.query('ROLLBACK'); } catch {}
    }
  }
  state.openCampaigns = state.openCampaigns.filter(camp => camp.end_day > day);
  log(`  ✓ closed ${toClose.length} campaigns`);
}

// ============================================================
// Step 4: PR submit/split/send
// ============================================================
async function processPRs(c, pools, state, audit, day, drainAll) {
  const pool = state.pendingPRsForSplit;
  // 隨機抽 X 張 (drainAll 全做)
  const n = drainAll ? pool.length : Math.min(pool.length, rng.int(0, Math.max(1, pool.length)));
  const chosen = [];
  for (let i = 0; i < n; i++) {
    const idx = rng.int(0, pool.length - 1);
    chosen.push(pool.splice(idx, 1)[0]);
  }

  for (const { pr_id } of chosen) {
    try {
      // 補 PR items 必填欄位 (cost/retail/franchise/supplier)
      await c.query('BEGIN');
      await setJwt(c);
      // unit_cost 從 supplier_skus 抓; retail/franchise 從 prices 抓
      await c.query(`
        UPDATE purchase_request_items pri
           SET unit_cost = COALESCE(pri.unit_cost, ss.default_unit_cost, 50),
               retail_price = COALESCE(pri.retail_price, (SELECT price FROM prices WHERE sku_id=pri.sku_id AND scope='retail' ORDER BY effective_from DESC NULLS LAST LIMIT 1), 100),
               franchise_price = COALESCE(pri.franchise_price, (SELECT price FROM prices WHERE sku_id=pri.sku_id AND scope='branch' ORDER BY effective_from DESC NULLS LAST LIMIT 1), 80),
               suggested_supplier_id = COALESCE(pri.suggested_supplier_id, ss.supplier_id)
          FROM supplier_skus ss
         WHERE ss.sku_id = pri.sku_id AND ss.is_preferred = true AND pri.pr_id = $1
      `, [pr_id]);

      // submit
      const cur = (await c.query(`SELECT status FROM purchase_requests WHERE id=$1`, [pr_id])).rows[0];
      if (cur && cur.status === 'draft') {
        await c.query(`SELECT rpc_submit_pr($1, $2)`, [pr_id, ADMIN_UID]);
      }
      const after = (await c.query(`SELECT status, review_status FROM purchase_requests WHERE id=$1`, [pr_id])).rows[0];
      if (after.review_status !== 'approved') {
        await c.query(`SELECT rpc_approve_purchase_request($1, $2, $3)`, [pr_id, 'auto-approve', ADMIN_UID]);
      }
      // split to PO
      const split = await c.query(`SELECT rpc_split_pr_to_pos($1, $2, $3) AS po_ids`, [pr_id, pools.hqId, ADMIN_UID]);
      const poIds = (split.rows[0].po_ids || []).map(Number);
      audit.pr_splits.push({ pr_id, po_ids: poIds });
      // send each PO
      for (const poId of poIds) {
        await c.query(`SELECT rpc_send_purchase_order($1, $2, $3)`, [poId, 'phone', ADMIN_UID]);
        state.pendingPOsForGR.push({ po_id: poId });
        audit.po_sent.push({ po_id: poId });
      }
      await c.query('COMMIT');
    } catch (e) {
      try { await c.query('ROLLBACK'); } catch {}
      audit.errors.push({ step: 'processPRs', msg: `PR ${pr_id}: ${e.message.slice(0, 150)}` });
    }
  }
  log(`  ✓ processed ${chosen.length} PRs`);
}

// ============================================================
// Step 5: GR confirm
// ============================================================
async function processGRs(c, pools, state, audit, day, drainAll) {
  const pool = state.pendingPOsForGR;
  const n = drainAll ? pool.length : Math.min(pool.length, rng.int(0, Math.max(1, pool.length)));
  const chosen = [];
  for (let i = 0; i < n; i++) {
    const idx = rng.int(0, pool.length - 1);
    chosen.push(pool.splice(idx, 1)[0]);
  }
  for (const { po_id } of chosen) {
    try {
      await c.query('BEGIN');
      await setJwt(c);
      const grNo = `WK-GR-D${day}-${po_id}`;
      const poItems = (await c.query(`SELECT id, sku_id, qty_ordered, unit_cost FROM purchase_order_items WHERE po_id=$1`, [po_id])).rows;
      if (poItems.length === 0) {
        await c.query('ROLLBACK');
        continue;
      }
      const gr = await c.query(`
        INSERT INTO goods_receipts (tenant_id, gr_no, po_id, supplier_id, dest_location_id, status,
                                    receive_date, received_by, created_by, updated_by)
        VALUES ($1, $2, $3, (SELECT supplier_id FROM purchase_orders WHERE id=$3), $4, 'draft',
                CURRENT_DATE, $5, $5, $5)
        RETURNING id, gr_no`,
        [TENANT, grNo, po_id, pools.hqId, ADMIN_UID]);
      const grId = Number(gr.rows[0].id);
      const auditItems = [];
      for (const it of poItems) {
        await c.query(`
          INSERT INTO goods_receipt_items (gr_id, po_item_id, sku_id, qty_expected, qty_received, unit_cost, created_by, updated_by)
          VALUES ($1, $2, $3, $4, $4, $5, $6, $6)
        `, [grId, it.id, it.sku_id, it.qty_ordered, it.unit_cost, ADMIN_UID]);
        auditItems.push({ sku_id: Number(it.sku_id), qty: Number(it.qty_ordered) });
      }
      await c.query(`SELECT rpc_confirm_gr($1, $2)`, [grId, ADMIN_UID]);
      audit.grs.push({ gr_id: grId, gr_no: grNo, po_id, items: auditItems });
      state.pendingPOsForWave.push({ po_id });
      await c.query('COMMIT');
    } catch (e) {
      try { await c.query('ROLLBACK'); } catch {}
      audit.errors.push({ step: 'processGRs', msg: `PO ${po_id}: ${e.message.slice(0, 150)}` });
    }
  }
  log(`  ✓ processed ${chosen.length} GRs`);
}

// ============================================================
// Step 6: Wave + transfer
// ============================================================
async function processWaves(c, pools, state, audit, day, drainAll) {
  const pool = state.pendingPOsForWave;
  const n = drainAll ? pool.length : Math.min(pool.length, rng.int(0, Math.max(1, pool.length)));
  const chosen = [];
  for (let i = 0; i < n; i++) {
    const idx = rng.int(0, pool.length - 1);
    chosen.push(pool.splice(idx, 1)[0]);
  }
  for (const { po_id } of chosen) {
    try {
      // 抽 demand from v_picking_demand_by_po
      const demand = (await c.query(`
        SELECT sku_id, store_id, demand_qty, gr_qty
          FROM v_picking_demand_by_po
         WHERE po_id=$1 AND store_id IS NOT NULL AND demand_qty > 0
      `, [po_id])).rows;
      if (demand.length === 0) continue;
      const allocs = demand.map(d => ({ sku_id: Number(d.sku_id), store_id: Number(d.store_id), qty: Number(d.demand_qty) }));
      const waveDate = new Date(); waveDate.setDate(waveDate.getDate() + rng.int(0, 1));
      const wd = waveDate.toISOString().slice(0, 10);

      await c.query('BEGIN');
      await setJwt(c);
      const r = await c.query(`SELECT rpc_create_wave_from_po($1, $2, $3, $4) AS result`,
        [po_id, wd, JSON.stringify(allocs), ADMIN_UID]);
      const waveId = Number(r.rows[0].result.wave_id);
      // confirm picked → generate transfer → mark shipping
      await c.query(`SELECT rpc_confirm_picked($1, $2)`, [waveId, ADMIN_UID]);
      const gen = await c.query(`SELECT generate_transfer_from_wave($1, $2, $3) AS result`, [waveId, pools.hqId, ADMIN_UID]);
      const tfIds = (gen.rows[0].result.transfer_ids || []).map(Number);
      await c.query(`SELECT rpc_mark_orders_shipping_for_wave($1, $2)`, [waveId, ADMIN_UID]);
      audit.waves.push({ wave_id: waveId, source_po_id: po_id, transfer_ids: tfIds, allocs });
      // push transfers to pending receive pool
      for (const tfId of tfIds) {
        const meta = (await c.query(`SELECT id, transfer_no, dest_location FROM transfers WHERE id=$1`, [tfId])).rows[0];
        state.pendingTransfers.push({ transfer_id: tfId, dest_location: Number(meta.dest_location), transfer_no: meta.transfer_no });
      }
      await c.query('COMMIT');
    } catch (e) {
      try { await c.query('ROLLBACK'); } catch {}
      audit.errors.push({ step: 'processWaves', msg: `PO ${po_id}: ${e.message.slice(0, 150)}` });
    }
  }
  log(`  ✓ processed ${chosen.length} waves`);
}

// ============================================================
// Step 7: Transfer receive
// ============================================================
async function processReceives(c, pools, state, audit, day, drainAll) {
  const pool = state.pendingTransfers;
  const n = drainAll ? pool.length : Math.min(pool.length, rng.int(0, Math.max(1, pool.length)));
  const chosen = [];
  for (let i = 0; i < n; i++) {
    const idx = rng.int(0, pool.length - 1);
    chosen.push(pool.splice(idx, 1)[0]);
  }
  for (const t of chosen) {
    try {
      const items = (await c.query(`SELECT id, qty_requested FROM transfer_items WHERE transfer_id=$1`, [t.transfer_id])).rows;
      const lines = items.map(it => ({ transfer_item_id: Number(it.id), qty_received: Number(it.qty_requested) }));
      await c.query('BEGIN');
      await setJwt(c);
      await c.query(`SELECT rpc_receive_transfer($1, $2, $3, $4)`,
        [t.transfer_id, JSON.stringify(lines), ADMIN_UID, 'week-sim auto-receive']);
      await c.query('COMMIT');
      audit.receives.push({ transfer_id: t.transfer_id, transfer_no: t.transfer_no });

      // Push corresponding orders to pickup pool — 找這個 transfer 對應的 customer_orders
      // 透過 wave_items.campaign_id 反查 customer_orders.campaign_id + pickup_store
      const storeId = (await c.query(`SELECT id FROM stores WHERE location_id=$1`, [t.dest_location])).rows[0]?.id;
      if (storeId) {
        const orders = (await c.query(`
          SELECT DISTINCT co.id
            FROM customer_orders co
            JOIN customer_order_items coi ON coi.order_id=co.id
            JOIN transfer_items ti ON ti.sku_id = coi.sku_id
           WHERE ti.transfer_id = $1
             AND co.pickup_store_id = $2
             AND co.status IN ('pending','confirmed','shipping','ready')
        `, [t.transfer_id, Number(storeId)])).rows;
        for (const o of orders) {
          state.pendingPickups.push({ order_id: Number(o.id), store_id: Number(storeId), ready_day: day });
        }
      }
    } catch (e) {
      try { await c.query('ROLLBACK'); } catch {}
      audit.errors.push({ step: 'processReceives', msg: `TF ${t.transfer_id}: ${e.message.slice(0, 150)}` });
    }
  }
  log(`  ✓ received ${chosen.length} transfers`);
}

// ============================================================
// Step 8: Pickup (cash + record)
// ============================================================
async function processPickups(c, pools, state, audit, day, drainAll) {
  const pool = state.pendingPickups;
  const n = drainAll ? pool.length : Math.min(pool.length, rng.int(0, Math.max(1, pool.length)));
  const chosen = [];
  // Pickup pool 可能含 duplicate order_id (從多個 transfer 進來)、去重
  const seen = new Set();
  for (let i = pool.length - 1; i >= 0 && chosen.length < n; i--) {
    if (seen.has(pool[i].order_id)) {
      pool.splice(i, 1);
      continue;
    }
    seen.add(pool[i].order_id);
    if (rng.chance(0.7) || drainAll) {  // 70% 機率取貨、剩 30% 留到下一天
      chosen.push(pool.splice(i, 1)[0]);
    }
  }
  let success = 0;
  for (const p of chosen) {
    try {
      const items = (await c.query(`
        SELECT id, qty, unit_price FROM customer_order_items
         WHERE order_id=$1 AND status IN ('pending','reserved','ready')`, [p.order_id])).rows;
      if (items.length === 0) continue;
      const itemIds = items.map(i => Number(i.id));
      const total = items.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0);

      // pickup readiness check
      const ready = (await c.query(`SELECT is_order_pickup_ready($1) AS r`, [p.order_id])).rows[0].r;
      if (!ready) {
        // 還沒 ready 就放回 pool
        state.pendingPickups.push(p);
        continue;
      }

      await c.query('BEGIN');
      await setJwt(c);
      // 現金結帳
      await c.query(`
        UPDATE customer_orders
           SET payment_status='paid', payment_method='cash',
               remit_amount=$2, remit_at=NOW(), paid_at=NOW(), updated_by=$3
         WHERE id=$1
      `, [p.order_id, total, ADMIN_UID]);
      const r = await c.query(`SELECT rpc_record_pickup($1, $2, $3, $4) AS result`,
        [p.order_id, itemIds, ADMIN_UID, 'week-sim auto-pickup']);
      audit.pickups.push({ order_id: p.order_id, event_id: r.rows[0].result.event_id, total, item_ids: itemIds });
      success++;
      await c.query('COMMIT');
    } catch (e) {
      try { await c.query('ROLLBACK'); } catch {}
      audit.errors.push({ step: 'processPickups', msg: `Order ${p.order_id}: ${e.message.slice(0, 150)}` });
    }
  }
  log(`  ✓ picked up ${success} orders`);
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });

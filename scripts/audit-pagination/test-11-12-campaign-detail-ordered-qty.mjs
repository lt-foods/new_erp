#!/usr/bin/env node
// AUDIT #11 + #12 驗證: rpc_member_campaign_detail
//
// 風險: 原 getCampaignDetail() 透過 .from("customer_order_items").select(...)
//       無 .limit(),PostgREST max_rows=1000 截斷。當單一團累計訂單行數
//       超過 1000 時,前端看到的 ordered_qty 偏低,可能讓會員下到超賣的單。
//
// 驗證: 建立一個團 + 1 個 SKU,塞入 >1000 筆訂單行,呼叫 RPC,
//       比對 ordered_qty 是否等於 SQL COUNT 直查的真值。
//
// 用法: node scripts/audit-pagination/test-11-12-campaign-detail-ordered-qty.mjs

import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";

const ENV = Object.fromEntries(
  readFileSync("apps/admin/.env.local", "utf8")
    .split(/\r?\n/).filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split("=").map((s, i, a) => (i === 0 ? s.trim() : a.slice(1).join("=").trim()))),
);

const SUPABASE_URL = ENV.NEXT_PUBLIC_SUPABASE_URL;
const SERVICE_KEY  = ENV.SUPABASE_SERVICE_ROLE_KEY;
const TENANT_ID    = ENV.TEST_TENANT_ID;
if (!SUPABASE_URL || !SERVICE_KEY || !TENANT_ID) {
  console.error("缺少 NEXT_PUBLIC_SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / TEST_TENANT_ID");
  process.exit(2);
}

const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const TAG = "audit_pagination_11_12";
const N_ORDERS = 1100; // 超過 1000 才能觸發截斷

const PREFIX = `${TAG}_${Date.now()}`;
let campaignId, campaignItemId, skuId, productId, channelId;
const orderIds = [];

async function cleanup() {
  if (orderIds.length) {
    await sb.from("customer_order_items").delete().in("order_id", orderIds);
    await sb.from("customer_orders").delete().in("id", orderIds);
  }
  if (campaignItemId) await sb.from("campaign_items").delete().eq("id", campaignItemId);
  if (campaignId)     await sb.from("group_buy_campaigns").delete().eq("id", campaignId);
  if (skuId)          await sb.from("skus").delete().eq("id", skuId);
  if (productId)      await sb.from("products").delete().eq("id", productId);
  if (channelId)      await sb.from("line_channels").delete().eq("id", channelId);
}

async function fail(msg) {
  console.error("❌ FAIL:", msg);
  await cleanup();
  process.exit(1);
}

try {
  // 1. 建立 product / sku / campaign / channel / item
  const { data: prod, error: pe } = await sb.from("products")
    .insert({ tenant_id: TENANT_ID, product_code: `${PREFIX}_P`, name: "audit test product", status: "active" })
    .select("id").single();
  if (pe) await fail(`create product: ${pe.message}`);
  productId = prod.id;

  const { data: sku, error: se } = await sb.from("skus")
    .insert({ tenant_id: TENANT_ID, product_id: productId, sku_code: `${PREFIX}_S`, product_name: "audit sku", status: "active" })
    .select("id").single();
  if (se) await fail(`create sku: ${se.message}`);
  skuId = sku.id;

  const { data: camp, error: ce } = await sb.from("group_buy_campaigns")
    .insert({
      tenant_id: TENANT_ID,
      campaign_no: `${PREFIX}_C`,
      name: "audit campaign",
      status: "open",
      end_at: new Date(Date.now() + 86400000 * 7).toISOString(),
    })
    .select("id").single();
  if (ce) await fail(`create campaign: ${ce.message}`);
  campaignId = camp.id;

  const { data: ch, error: che } = await sb.from("line_channels")
    .insert({ tenant_id: TENANT_ID, name: `${PREFIX}_ch`, channel_id: `${PREFIX}_ch_id` })
    .select("id").single();
  if (che) await fail(`create channel: ${che.message}`);
  channelId = ch.id;

  const { data: ci, error: cie } = await sb.from("campaign_items")
    .insert({
      tenant_id: TENANT_ID,
      campaign_id: campaignId,
      sku_id: skuId,
      unit_price: 100,
      sort_order: 0,
    })
    .select("id").single();
  if (cie) await fail(`create campaign_item: ${cie.message}`);
  campaignItemId = ci.id;

  // 找一間任意 store 當 pickup_store_id
  const { data: stores, error: stErr } = await sb.from("stores")
    .select("id").eq("tenant_id", TENANT_ID).limit(1);
  if (stErr || !stores?.length) await fail("找不到測試用 store");
  const storeId = stores[0].id;

  // 2. 灌 N_ORDERS 筆訂單,每筆一個 item, qty=1
  console.log(`灌 ${N_ORDERS} 筆訂單...`);
  const BATCH = 200;
  for (let i = 0; i < N_ORDERS; i += BATCH) {
    const slice = [];
    for (let j = 0; j < BATCH && i + j < N_ORDERS; j++) {
      slice.push({
        tenant_id: TENANT_ID,
        order_no: `${PREFIX}_O_${i + j}`,
        campaign_id: campaignId,
        channel_id: channelId,
        pickup_store_id: storeId,
        status: "confirmed",
      });
    }
    const { data: inserted, error: oe } = await sb.from("customer_orders")
      .insert(slice).select("id");
    if (oe) await fail(`insert orders batch ${i}: ${oe.message}`);
    const items = inserted.map((o) => ({
      tenant_id: TENANT_ID,
      order_id: o.id,
      campaign_item_id: campaignItemId,
      sku_id: skuId,
      qty: 1,
      unit_price: 100,
    }));
    const { error: ie } = await sb.from("customer_order_items").insert(items);
    if (ie) await fail(`insert items batch ${i}: ${ie.message}`);
    orderIds.push(...inserted.map((o) => o.id));
  }
  console.log(`已灌 ${orderIds.length} 筆訂單`);

  // 3. 呼叫 RPC,驗證 ordered_qty
  const { data: detail, error: re } = await sb.rpc("rpc_member_campaign_detail", {
    p_tenant: TENANT_ID,
    p_campaign_id: campaignId,
  });
  if (re) await fail(`call rpc: ${re.message}`);
  if (!detail?.items?.length) await fail("RPC 回傳沒有 items");

  const item = detail.items.find((x) => Number(x.id) === Number(campaignItemId));
  if (!item) await fail("RPC items 找不到目標 campaign_item");

  const orderedQty = Number(item.ordered_qty);
  const orderCount = Number(detail.campaign?.order_count ?? 0);
  console.log(`RPC ordered_qty=${orderedQty}, order_count=${orderCount}`);

  if (orderedQty !== N_ORDERS) {
    await fail(`ordered_qty 應為 ${N_ORDERS},實際 ${orderedQty} — 仍有截斷風險!`);
  }
  if (orderCount !== N_ORDERS) {
    await fail(`order_count 應為 ${N_ORDERS},實際 ${orderCount}`);
  }

  // 4. 對照: 用舊式查詢確認原本會被截斷 (驗證測試本身有效)
  const { data: legacyRows } = await sb
    .from("customer_order_items")
    .select("qty, customer_orders!inner(campaign_id, status, order_kind)")
    .eq("tenant_id", TENANT_ID)
    .eq("customer_orders.campaign_id", campaignId)
    .not("customer_orders.status", "in", "(cancelled,expired)");
  const legacyCount = legacyRows?.length ?? 0;
  console.log(`對照: 舊式 .select() 拿到 ${legacyCount} 列 (應 <= 1000 證明截斷確實存在)`);
  if (legacyCount > N_ORDERS) {
    console.warn(`⚠️ 對照取到 ${legacyCount} > ${N_ORDERS},環境的 PostgREST max_rows 可能 != 1000`);
  }

  console.log("✅ PASS: rpc_member_campaign_detail 在 >1000 訂單行情境下回傳正確 ordered_qty");
  await cleanup();
  process.exit(0);
} catch (err) {
  console.error(err);
  await cleanup();
  process.exit(1);
}

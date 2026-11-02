// shopeefans-sync —— 每天把「蝦皮助手」（shopeefans.com）台灣站的月熱銷榜抓進 market_hot_products。
//
// 蝦皮助手沒有公開 API；這裡用 Alex 自己的訂閱帳號登入，打它網頁版用的同一支資料接口
// （/data-api/yasuo/api/product-analysis/list，月榜 rankingType=3、依 monthSales 排序），
// 等於是程式幫人每天開一次網頁、按「月榜」。一天只跑一次、每個類目最多 2 頁 × 100 筆，量跟人手動看差不多。
// 抓到的照 rpc_market_hot_import_service 寫進「市場熱門」（source = 'shopeefans'），
// 之後 market-ai 自動算向量與品類，對上廠商品項（見 migration 20261102000010）。
//
// 呼叫：pg_cron 'shopeefans-sync' 每天台北 05:23（x-line-note-secret），或 service_role bearer。
// 環境值（Supabase → Edge Functions → Secrets）：
//   SHOPEEFANS_USER / SHOPEEFANS_PASSWORD（必填，蝦皮助手帳密）
//   SHOPEEFANS_CATEGORIES（選填，逗號分隔的類目 id；預設：美食伴手禮、居家生活、保健、美妝保養、母嬰、寵物）
//   DEFAULT_TENANT_ID（既有）、LINE_NOTE_CRON_SECRET（既有）；內建 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY。

import { corsHeaders } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const CRON_SECRET = Deno.env.get("LINE_NOTE_CRON_SECRET") ?? "";
const SF_USER = Deno.env.get("SHOPEEFANS_USER") ?? "";
const SF_PASS = Deno.env.get("SHOPEEFANS_PASSWORD") ?? "";
const SF_CATEGORIES = (Deno.env.get("SHOPEEFANS_CATEGORIES") || "100629,100636,100001,100630,100632,100631")
  .split(",").map((s) => s.trim()).filter(Boolean);
const TENANT = Deno.env.get("DEFAULT_TENANT_ID") || "00000000-0000-0000-0000-000000000001";

const SF = "https://www.shopeefans.com/data-api";
const PAGES_PER_CATEGORY = 2;
const PAGE_SIZE = 100;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function login(): Promise<string> {
  const res = await fetch(`${SF}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: SF_USER, password: SF_PASS, mobilePrefix: "86", appId: "sf", system: "sf" }),
  });
  const d = await res.json().catch(() => null);
  if (!res.ok || !d?.access_token) throw new Error(`蝦皮助手登入失敗（${res.status}）：${String(d?.message ?? d?.error_description ?? "").slice(0, 120)}`);
  return String(d.access_token);
}

async function fetchPage(token: string, categoryId: string, page: number): Promise<any[]> {
  const q = new URLSearchParams({
    tabNo: "1", categoryId, rankingType: "3", orderBy: "monthSales", orderMethod: "desc",
    page: String(page), size: String(PAGE_SIZE), stationId: "8", platformId: "10", ifFilter: "true",
  });
  const res = await fetch(`${SF}/yasuo/api/product-analysis/list/?${q}`, { headers: { Authorization: `Bearer ${token}` } });
  const d = await res.json().catch(() => null);
  if (!res.ok || d?.status !== 100) throw new Error(`類目 ${categoryId} 第 ${page} 頁失敗（${res.status}）：${String(d?.message ?? "").slice(0, 120)}`);
  return Array.isArray(d?.data?.appDwsProductVos) ? d.data.appDwsProductVos : [];
}

function toRow(v: any, rank: number) {
  const price = v.avgPrice ?? v.price ?? v.discountPrice;
  return {
    name: String(v.productName ?? "").slice(0, 300),
    price: price == null ? "" : String(price),
    sales_30d: v.monthSales == null ? "" : String(v.monthSales),
    revenue: v.monthMoney == null ? "" : String(v.monthMoney),
    growth: v.monthSalesGrowthRate == null ? "" : String(Math.round(Number(v.monthSalesGrowthRate) * 1000) / 10),
    category: v.categoryLocalName ?? v.categoryChinesePath ?? "",
    shop: v.shopName ?? "",
    url: v.shopId && v.productId ? `https://shopee.tw/product/${v.shopId}/${v.productId}` : "",
    rank: String(rank),
    raw: {
      productImg: v.productImg ?? null, productId: v.productId ?? null, shopId: v.shopId ?? null,
      categoryId: v.categoryId ?? null, categoryPath: v.categoryChinesePath ?? null,
      dailySales: v.dailySales ?? null, weekSales: v.weekSales ?? null, totalSales: v.totalSales ?? null,
      productScore: v.productScore ?? null, syncDate: v.syncDate ?? null,
    },
  };
}

async function sync() {
  if (!SF_USER || !SF_PASS) throw new Error("缺 SHOPEEFANS_USER / SHOPEEFANS_PASSWORD（Supabase → Edge Functions → Secrets）");
  const token = await login();
  const rows: any[] = [];
  const seen = new Set<string>();
  const perCategory: Record<string, number> = {};
  let syncDate: string | null = null;
  for (const cat of SF_CATEGORIES) {
    let n = 0;
    for (let page = 1; page <= PAGES_PER_CATEGORY; page++) {
      const vos = await fetchPage(token, cat, page);
      for (const v of vos) {
        const key = `${v.shopId}/${v.productId}`;
        if (seen.has(key)) continue;
        seen.add(key);
        rows.push(toRow(v, ++n));
        if (!syncDate && v.syncDate) syncDate = String(v.syncDate);
      }
      await sleep(1500); // 慢慢來，不要一口氣打爆
      if (vos.length < PAGE_SIZE) break;
    }
    perCategory[cat] = n;
  }
  // 蝦皮助手的資料日（syncDate = 20261030）→ captured_at
  const captured = syncDate && /^\d{8}$/.test(syncDate)
    ? `${syncDate.slice(0, 4)}-${syncDate.slice(4, 6)}-${syncDate.slice(6, 8)}` : null;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/rpc_market_hot_import_service`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_tenant: TENANT, p_source: "shopeefans", p_captured_at: captured, p_rows: rows }),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`寫入失敗 ${res.status} ${text.slice(0, 200)}`);
  return { rows: rows.length, perCategory, captured, result: JSON.parse(text || "null") };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const ok = (CRON_SECRET && req.headers.get("x-line-note-secret") === CRON_SECRET) || (SERVICE_KEY && bearer === SERVICE_KEY);
  if (!ok) return json({ error: "unauthorized" }, 401);
  try {
    return json({ ok: true, ...(await sync()) });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: String((e as any)?.message ?? e).slice(0, 500) }, 500);
  }
});

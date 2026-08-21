import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";

type Session = { tenant_id: string; publisher_id: number; auth_user_id: string; lane: "tong" | "chao" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const sb = createClient(mustEnv("SUPABASE_URL"), mustEnv("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
    const body = await req.json() as Record<string, unknown>;
    const action = String(body.action ?? "");
    if (action === "list_public_campaigns") return await listPublicCampaigns(sb);
    const session = await sessionFrom(sb, req);
    if (action === "bootstrap") return await bootstrap(sb, session);
    if (action === "upload_image") return await uploadImage(sb, session, body);
    if (action === "publish") return await publish(sb, session, body);
    return json({ error: "unknown action" }, 400);
  } catch (e) {
    console.error("piaopiao-api", e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});

async function listPublicCampaigns(sb: any) {
  const tenantId = mustEnv("DEFAULT_TENANT_ID");
  const { data, error } = await sb.from("group_buy_campaigns")
    .select("id, name, cover_image_url, end_at, campaign_items(unit_price, sort_order, sku:skus(product:products(images)))")
    .eq("tenant_id", tenantId)
    .eq("status", "open").eq("is_for_shop", true).eq("sales_channel", "piaopiao")
    .neq("campaign_no", "__INTERNAL_RESTOCK__")
    .or(`end_at.is.null,end_at.gt.${new Date().toISOString()}`)
    .order("end_at", { ascending: true, nullsFirst: false });
  if (error) throw new Error(error.message);

  // 瀏覽數 / 已訂購件數：跟 liff-api list_active_campaigns 同一套 RPC
  // （不要退回撈訂單在 JS 加總 —— PostgREST 1000 列靜默截斷 + 轉單重複計算，
  // 兩個坑都收在 RPC 裡）。RPC 失敗當 0，不影響列表本體。
  const ids = (data ?? []).map((c: any) => c.id);
  const viewMap = new Map<number, number>();
  const orderedMap = new Map<number, number>();
  if (ids.length > 0) {
    const [viewsRes, aggRes] = await Promise.all([
      sb.rpc("rpc_campaign_view_counts", { p_tenant: tenantId, p_campaign_ids: ids }),
      sb.rpc("rpc_member_campaign_aggregates", { p_tenant: tenantId, p_recent_days: 7, p_campaign_ids: ids }),
    ]);
    if (viewsRes.error) console.error("[list_public_campaigns] view counts rpc failed", viewsRes.error);
    for (const r of viewsRes.data ?? []) viewMap.set(Number(r.campaign_id), Number(r.view_count ?? 0));
    if (aggRes.error) console.error("[list_public_campaigns] aggregates rpc failed", aggRes.error);
    for (const r of aggRes.data ?? []) orderedMap.set(Number(r.campaign_id), Number(r.ordered_qty ?? 0));
  }

  const base = mustEnv("SUPABASE_URL");
  return json({ campaigns: (data ?? []).map((c: any) => {
    const items = [...(c.campaign_items ?? [])].sort((a: any, b: any) => (a.sort_order ?? 0) - (b.sort_order ?? 0));
    const prices = items.map((i: any) => Number(i.unit_price)).filter(Number.isFinite);
    const image = c.cover_image_url ?? items[0]?.sku?.product?.images?.[0]?.url ?? items[0]?.sku?.product?.images?.[0] ?? null;
    return { id: c.id, name: c.name, end_at: c.end_at, cover_image_url: image ? `${base}/storage/v1/object/public/products/${String(image).split("/").map(encodeURIComponent).join("/")}` : null, min_price: prices.length ? Math.min(...prices) : 0, max_price: prices.length ? Math.max(...prices) : 0, ordered_qty: orderedMap.get(Number(c.id)) ?? 0, view_count: viewMap.get(Number(c.id)) ?? 0 };
  }) });
}

async function sessionFrom(sb: any, req: Request): Promise<Session> {
  const raw = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!raw) throw new Error("請先用漂漂館帳號登入");
  const { data: { user }, error: authError } = await sb.auth.getUser(raw);
  if (authError || !user) throw new Error("登入已失效，請重新登入");
  const { data: publisher, error } = await sb.from("piaopiao_publishers")
    .select("id, tenant_id, lane, is_active").eq("auth_user_id", user.id).maybeSingle();
  if (error || !publisher?.is_active) throw new Error("你的上架資格已停用，請聯絡總部");
  const lane = publisher.lane === "chao" ? "chao" : publisher.lane === "tong" ? "tong" : null;
  if (!publisher.tenant_id || !publisher.id || !lane) throw new Error("登入資料不完整");
  return { tenant_id: publisher.tenant_id, publisher_id: publisher.id, auth_user_id: user.id, lane };
}

async function bootstrap(sb: any, session: Session) {
  const { data: publisher, error } = await sb.from("piaopiao_publishers")
    .select("id, display_name, lane, is_active")
    .eq("id", session.publisher_id).eq("tenant_id", session.tenant_id)
    .eq("auth_user_id", session.auth_user_id).maybeSingle();
  if (error || !publisher?.is_active) throw new Error("你的上架資格已停用，請聯絡總部");
  return json({ publisher: { name: publisher.display_name, lane: publisher.lane } });
}

async function uploadImage(sb: any, session: Session, body: Record<string, unknown>) {
  const mime = String(body.mime ?? "");
  const encoded = String(body.base64 ?? "").replace(/^data:[^;]+;base64,/, "");
  if (!new Set(["image/jpeg", "image/png", "image/webp"]).has(mime)) throw new Error("只接受 JPG、PNG 或 WEBP 圖片");
  if (!encoded) throw new Error("沒有收到圖片");
  const bytes = base64Bytes(encoded);
  if (bytes.byteLength === 0 || bytes.byteLength > 5 * 1024 * 1024) throw new Error("每張圖片需小於 5MB");
  const { data: uploadDate, error: reserveError } = await sb.rpc("rpc_piaopiao_reserve_upload_slot", {
    p_tenant_id: session.tenant_id,
    p_publisher_id: session.publisher_id,
    p_operator_id: session.auth_user_id,
  });
  if (reserveError) throw new Error(`無法保留今日圖片額度：${reserveError.message}`);
  if (!uploadDate) throw new Error("今天已上傳 25 張圖片；請明天再試。即使這次建立失敗，已上傳的圖片仍會占用今天額度。");
  const dayPrefix = `piaopiao/${session.publisher_id}/${uploadDate}`;
  const ext = mime === "image/jpeg" ? "jpg" : mime === "image/png" ? "png" : "webp";
  const path = `${dayPrefix}/${crypto.randomUUID()}.${ext}`;
  const { error } = await sb.storage.from("products").upload(path, bytes, { contentType: mime, upsert: false });
  if (error) throw new Error(`圖片上傳失敗：${error.message}`);
  return json({ path });
}

async function publish(sb: any, session: Session, body: Record<string, unknown>) {
  const requestId = String(body.request_id ?? "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId)) {
    throw new Error("送出識別碼錯誤，請重新整理後再試");
  }
  const { data, error } = await sb.rpc("rpc_piaopiao_publish_batch", {
    p_tenant_id: session.tenant_id,
    p_publisher_id: session.publisher_id,
    p_request_id: requestId,
    p_operator_id: session.auth_user_id,
    p_end_at: body.end_at,
    p_pickup_deadline: body.pickup_deadline,
    p_items: body.items,
  });
  if (error) throw new Error(error.message);
  return json(data);
}
function base64Bytes(value: string) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
function mustEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

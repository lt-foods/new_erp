import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
import { verifyJwtHs256 } from "../_shared/jwt.ts";

type Session = { tenant_id: string; publisher_id: number; line_user_id: string; lane: "tong" | "chao" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const body = await req.json() as Record<string, unknown>;
    const session = await sessionFrom(req);
    const sb = createClient(mustEnv("SUPABASE_URL"), mustEnv("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
    const action = String(body.action ?? "");
    if (action === "bootstrap") return await bootstrap(sb, session);
    if (action === "upload_image") return await uploadImage(sb, session, body);
    if (action === "publish") return await publish(sb, session, body);
    if (action === "retry_share") return await retryShare(sb, session, Number(body.share_id));
    return json({ error: "unknown action" }, 400);
  } catch (e) {
    console.error("piaopiao-api", e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});

async function sessionFrom(req: Request): Promise<Session> {
  const raw = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!raw) throw new Error("請先用 LINE 登入");
  const claims = await verifyJwtHs256(raw, mustEnv("PIAOPIAO_SESSION_SECRET"));
  if (claims.purpose !== "piaopiao-publisher-session") throw new Error("登入身分不適用");
  const tenant_id = String(claims.tenant_id ?? "");
  const publisher_id = Number(claims.publisher_id ?? 0);
  const line_user_id = String(claims.line_user_id ?? "");
  const lane = claims.lane === "chao" ? "chao" : claims.lane === "tong" ? "tong" : null;
  if (!tenant_id || !publisher_id || !line_user_id || !lane) throw new Error("登入資料不完整");
  return { tenant_id, publisher_id, line_user_id, lane };
}

async function bootstrap(sb: any, session: Session) {
  const { data: publisher, error } = await sb.from("piaopiao_publishers")
    .select("id, display_name, lane, is_active")
    .eq("id", session.publisher_id).eq("tenant_id", session.tenant_id)
    .eq("line_user_id", session.line_user_id).maybeSingle();
  if (error || !publisher?.is_active) throw new Error("你的上架資格已停用，請聯絡總部");
  const { data: suppliers, error: suppliersError } = await sb.from("suppliers")
    .select("id, name").eq("tenant_id", session.tenant_id).eq("is_active", true).order("name");
  if (suppliersError) throw suppliersError;
  return json({ publisher: { name: publisher.display_name, lane: publisher.lane }, suppliers: suppliers ?? [] });
}

async function uploadImage(sb: any, session: Session, body: Record<string, unknown>) {
  const mime = String(body.mime ?? "");
  const encoded = String(body.base64 ?? "").replace(/^data:[^;]+;base64,/, "");
  if (!new Set(["image/jpeg", "image/png", "image/webp"]).has(mime)) throw new Error("只接受 JPG、PNG 或 WEBP 圖片");
  if (!encoded) throw new Error("沒有收到圖片");
  const bytes = base64Bytes(encoded);
  if (bytes.byteLength === 0 || bytes.byteLength > 5 * 1024 * 1024) throw new Error("每張圖片需小於 5MB");
  const ext = mime === "image/jpeg" ? "jpg" : mime === "image/png" ? "png" : "webp";
  const path = `piaopiao/${session.publisher_id}/${crypto.randomUUID()}.${ext}`;
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
    p_operator_id: mustEnv("PIAOPIAO_AUDIT_USER_ID"),
    p_end_at: body.end_at,
    p_pickup_deadline: body.pickup_deadline,
    p_items: body.items,
  });
  if (error) throw new Error(error.message);
  const batchId = Number(data?.batch_id);
  if (!batchId) throw new Error("建立結果不完整");
  const shares = await sharesForBatch(sb, session, batchId);
  const results = [];
  for (const share of shares) results.push(await sendShare(sb, share));
  return json({ ...data, shares: results });
}

async function retryShare(sb: any, session: Session, shareId: number) {
  if (!Number.isInteger(shareId) || shareId <= 0) throw new Error("分享資料錯誤");
  const shares = await sharesForBatch(sb, session, null, shareId);
  if (shares.length !== 1) throw new Error("找不到可重送的商品");
  const share = shares[0];
  if (share.status === "sent") return json({ share_id: share.id, status: "sent" });
  if (Date.now() - new Date(share.created_at).getTime() > 23 * 60 * 60 * 1000) {
    throw new Error("這則訊息超過 23 小時，為避免重複發送，請交由總部確認後再另行分享");
  }
  return json(await sendShare(sb, share));
}

async function sharesForBatch(sb: any, session: Session, batchId: number | null, shareId?: number) {
  // service_role 會略過 RLS，不能把巢狀 relation filter 當成權限判斷。
  // 先鎖定「這位上架員自己的批次」，再讀該批的分享紀錄，避免重送到別人的團。
  let effectiveBatchId = batchId;
  if (shareId != null) {
    const { data: share, error: shareError } = await sb.from("piaopiao_campaign_shares")
      .select("batch_id").eq("id", shareId).eq("tenant_id", session.tenant_id).maybeSingle();
    if (shareError) throw shareError;
    effectiveBatchId = Number(share?.batch_id ?? 0);
  }
  if (!effectiveBatchId) return [];
  const { data: ownBatch, error: batchError } = await sb.from("piaopiao_publish_batches")
    .select("id").eq("id", effectiveBatchId).eq("tenant_id", session.tenant_id)
    .eq("publisher_id", session.publisher_id).maybeSingle();
  if (batchError) throw batchError;
  if (!ownBatch) return [];
  let query = sb.from("piaopiao_campaign_shares").select(
    "id,created_at,line_retry_key,status,attempts,campaign_id,campaign:group_buy_campaigns!inner(id,name,description,cover_image_url)",
  ).eq("tenant_id", session.tenant_id).eq("batch_id", effectiveBatchId);
  if (shareId != null) query = query.eq("id", shareId);
  const { data, error } = await query.order("id");
  if (error) throw error;
  return (data ?? []) as Array<any>;
}

async function sendShare(sb: any, share: any) {
  const campaign = Array.isArray(share.campaign) ? share.campaign[0] : share.campaign;
  if (!campaign) throw new Error("團資料不存在");
  const front = mustEnv("PIAOPIAO_FRONT_BASE_URL").replace(/\/$/, "");
  const url = `${front}/piaopiao/c/${campaign.id}`;
  const image = publicProductUrl(campaign.cover_image_url);
  const message = {
    type: "flex",
    altText: `${String(campaign.name).slice(0, 300)}｜立即下單`,
    contents: {
      type: "bubble",
      hero: image ? { type: "image", url: image, size: "full", aspectRatio: "1:1", aspectMode: "cover", action: { type: "uri", uri: url } } : undefined,
      body: { type: "box", layout: "vertical", contents: [
        { type: "text", text: String(campaign.name).slice(0, 40), weight: "bold", size: "lg", wrap: true },
        { type: "text", text: "漂漂館・點我立即下單", size: "sm", color: "#777777", margin: "md" },
      ] },
      footer: { type: "box", layout: "vertical", spacing: "sm", contents: [
        { type: "button", style: "primary", action: { type: "uri", label: "立即下單", uri: url }, color: "#E26B89" },
      ] },
    },
  };
  try {
    const response = await fetch("https://api.line.me/v2/bot/message/push", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${mustEnv("PIAOPIAO_LINE_CHANNEL_ACCESS_TOKEN")}`,
        "X-Line-Retry-Key": String(share.line_retry_key),
      },
      body: JSON.stringify({ to: mustEnv("PIAOPIAO_SHARE_TARGET_ID"), messages: [message] }),
    });
    // 409 代表同一 retry key 先前已被 LINE 接收，視為已送，避免重複訊息。
    if (response.ok || response.status === 409) {
      await sb.from("piaopiao_campaign_shares").update({ status: "sent", attempts: Number(share.attempts ?? 0) + 1, last_error: null, sent_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", share.id);
      return { share_id: share.id, campaign_id: campaign.id, status: "sent", url };
    }
    const detail = (await response.text()).slice(0, 500);
    return await markShareFailed(sb, share, campaign.id, `LINE ${response.status}: ${detail}`);
  } catch (e) {
    return await markShareFailed(sb, share, campaign.id, e instanceof Error ? e.message : String(e));
  }
}

async function markShareFailed(sb: any, share: any, campaignId: number, detail: string) {
  await sb.from("piaopiao_campaign_shares").update({ status: "failed", attempts: Number(share.attempts ?? 0) + 1, last_error: detail.slice(0, 500), updated_at: new Date().toISOString() }).eq("id", share.id);
  return { share_id: share.id, campaign_id: campaignId, status: "failed", error: "LINE 尚未分享，可在 23 小時內重送" };
}

function publicProductUrl(path: unknown) {
  if (typeof path !== "string" || !path) return null;
  if (/^https:\/\//.test(path)) return path;
  return `${mustEnv("SUPABASE_URL")}/storage/v1/object/public/products/${path.split("/").map(encodeURIComponent).join("/")}`;
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

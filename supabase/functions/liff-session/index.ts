// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: liff-session
// 給 LIFF SDK 呼叫（LINE 內 webview）。
// 前端流程：liff.init() → liff.getIDToken() → POST 到這支
//
// 流程：
//   1. 收 id_token + store
//   2. 驗 id_token（LINE verify API）
//   3. 查綁定、未綁 → auto-register + 下載頭像
//   4. 簽 Supabase-compatible JWT 回傳
//
// 跟 line-oauth-callback 差別：
//   - 不用 state / code exchange（LIFF 直接給 id_token）
//   - 不做 302 redirect，回 JSON（前端自己 navigate）
// ─────────────────────────────────────────────────────────────────────────────

import { corsHeaders } from "../_shared/cors.ts";
import { signJwtHs256 } from "../_shared/jwt.ts";
import { verifyIdToken } from "../_shared/line.ts";
import { autoRegister } from "../_shared/auto-register.ts";

const SESSION_TTL_SEC = 60 * 60;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const body = await req.json() as { id_token?: string; store?: string };
    if (!body.id_token) return json({ error: "id_token required" }, 400);
    if (!body.store)    return json({ error: "store required" }, 400);

    const channelId   = requireEnv("LINE_LIFF_CHANNEL_ID"); // 可跟 LINE_CHANNEL_ID 相同、或獨立 LIFF channel
    const jwtSecret   = requireEnv("PROJECT_JWT_SECRET");
    const supabaseUrl = requireEnv("SUPABASE_URL");
    const serviceKey  = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
    const tenantId    = requireEnv("DEFAULT_TENANT_ID");

    // 1) verify id_token
    const payload = await verifyIdToken({
      idToken: body.id_token,
      channelId,
    });
    const lineUserId = payload.sub;
    const storeId    = String(body.store);

    // 2) lookup binding
    const bindingUrl =
      `${supabaseUrl}/rest/v1/member_line_bindings` +
      `?select=member_id&tenant_id=eq.${tenantId}` +
      `&store_id=eq.${storeId}&line_user_id=eq.${lineUserId}` +
      `&unbound_at=is.null&limit=1`;

    const resp = await fetch(bindingUrl, {
      headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
    });
    if (!resp.ok) throw new Error(`binding lookup ${resp.status}: ${await resp.text()}`);
    const rows = await resp.json() as Array<{ member_id: number }>;
    let memberId: number | null = rows.length > 0 ? rows[0].member_id : null;

    // 3) 未綁 → auto-register
    if (!memberId) {
      memberId = await autoRegister({
        supabaseUrl,
        serviceKey,
        tenantId,
        storeId,
        lineUserId,
        lineName:    payload.name    ?? null,
        linePicture: payload.picture ?? null,
      });
    }

    // 4) 簽 JWT
    const now = Math.floor(Date.now() / 1000);
    const jwt = await signJwtHs256({
      iss: "supabase",
      role: "authenticated",
      aud: "authenticated",
      exp: now + SESSION_TTL_SEC,
      tenant_id: tenantId,
      store_id: storeId,
      line_user_id: lineUserId,
      sub: String(memberId),
      member_id: memberId,
    }, jwtSecret);

    return json({
      token: jwt,
      member_id: memberId,
      store: storeId,
      line_user_id: lineUserId,
      line_name:    payload.name    ?? null,
      line_picture: payload.picture ?? null,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("liff-session error:", msg);
    return json({ error: "failed", detail: msg }, 500);
  }
});

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

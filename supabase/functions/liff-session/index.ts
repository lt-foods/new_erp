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
import { resolveStore } from "../_shared/store-resolve.ts";

const SESSION_TTL_SEC = 60 * 60 * 24 * 30; // 30 天

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const body = await req.json() as { id_token?: string; store?: string; pair_code?: string };
    if (!body.id_token) return json({ error: "id_token required" }, 400);
    if (!body.store)    return json({ error: "store required" }, 400);
    const pairCode = typeof body.pair_code === "string" ? body.pair_code.trim() : "";

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
    const storeKey   = String(body.store);

    // 1b) 解析 store key (code "S001" 或 numeric "1") → canonical { id, code }
    const resolved = await resolveStore(supabaseUrl, serviceKey, tenantId, storeKey);
    if (!resolved) return json({ error: "store_not_found", detail: storeKey }, 400);
    const storeNumericId = resolved.id;
    const storeCode = resolved.code;

    // 2) lookup binding
    const bindingUrl =
      `${supabaseUrl}/rest/v1/member_line_bindings` +
      `?select=member_id&tenant_id=eq.${tenantId}` +
      `&store_id=eq.${storeNumericId}&line_user_id=eq.${lineUserId}` +
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
        storeId: String(storeNumericId),
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
      store_id: storeNumericId,
      store_code: storeCode,
      line_user_id: lineUserId,
      sub: String(memberId),
      member_id: memberId,
    }, jwtSecret);

    const sessionPayload = {
      token: jwt,
      member_id: memberId,
      store: storeCode,
      line_user_id: lineUserId,
      line_name:    payload.name    ?? null,
      line_picture: payload.picture ?? null,
    };

    // 若帶了 pair_code（PWA 主動觸發 LIFF 登入流程），把 session 寫進 pwa_auth_codes
    // 讓 PWA 切回桌面後可以用該 code claim 拿回 session。
    if (pairCode && pairCode.length >= 8 && pairCode.length <= 64) {
      const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();
      const insertResp = await fetch(`${supabaseUrl}/rest/v1/pwa_auth_codes`, {
        method: "POST",
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          "Content-Type": "application/json",
          Prefer: "return=minimal",
        },
        body: JSON.stringify({
          code: pairCode,
          session_data: sessionPayload,
          tenant_id: tenantId,
          expires_at: expiresAt,
        }),
      });
      if (!insertResp.ok) {
        console.error("pwa_auth_codes insert failed", insertResp.status, await insertResp.text());
        // 不擋使用者，繼續回 session 給 LIFF 端
      }
    }

    return json(sessionPayload);
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

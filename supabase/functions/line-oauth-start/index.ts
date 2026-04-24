// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: line-oauth-start
// 前端用 GET /functions/v1/line-oauth-start?store=123
// → 產 state token、302 redirect 到 LINE authorize URL
// ─────────────────────────────────────────────────────────────────────────────

import { corsHeaders } from "../_shared/cors.ts";
import { signStateToken } from "../_shared/jwt.ts";

const LINE_AUTHORIZE_URL = "https://access.line.me/oauth2/v2.1/authorize";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const storeId = url.searchParams.get("store");
    if (!storeId) {
      return json({ error: "missing 'store' query param" }, 400);
    }

    const channelId  = requireEnv("LINE_CHANNEL_ID");
    const callbackUrl = requireEnv("LINE_CALLBACK_URL");
    const stateSecret = requireEnv("LINE_STATE_SECRET");

    const state = await signStateToken(storeId, stateSecret);

    const authorize = new URL(LINE_AUTHORIZE_URL);
    authorize.searchParams.set("response_type", "code");
    authorize.searchParams.set("client_id", channelId);
    authorize.searchParams.set("redirect_uri", callbackUrl);
    authorize.searchParams.set("state", state);
    authorize.searchParams.set("scope", "profile openid");
    authorize.searchParams.set("nonce", crypto.randomUUID());
    // 建議：bot_prompt=aggressive 可同時引導加好友，v1 先不開

    return Response.redirect(authorize.toString(), 302);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ error: msg }, 500);
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

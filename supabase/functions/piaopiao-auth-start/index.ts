import { corsHeaders } from "../_shared/cors.ts";
import { signJwtHs256 } from "../_shared/jwt.ts";

const AUTHORIZE_URL = "https://access.line.me/oauth2/v2.1/authorize";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const channelId = mustEnv("PIAOPIAO_LINE_CHANNEL_ID");
    const callbackUrl = mustEnv("PIAOPIAO_LINE_CALLBACK_URL");
    const now = Math.floor(Date.now() / 1000);
    const state = await signJwtHs256({
      purpose: "piaopiao-publisher-login",
      nonce: crypto.randomUUID(),
      exp: now + 600,
    }, mustEnv("PIAOPIAO_STATE_SECRET"));
    const url = new URL(AUTHORIZE_URL);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("client_id", channelId);
    url.searchParams.set("redirect_uri", callbackUrl);
    url.searchParams.set("state", state);
    url.searchParams.set("scope", "profile openid");
    url.searchParams.set("nonce", crypto.randomUUID());
    return Response.redirect(url.toString(), 302);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});

function mustEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}
function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

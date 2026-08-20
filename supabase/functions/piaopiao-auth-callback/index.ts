import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { verifyJwtHs256, signJwtHs256 } from "../_shared/jwt.ts";
import { exchangeCode, verifyIdToken } from "../_shared/line.ts";

Deno.serve(async (req) => {
  const front = mustEnv("PIAOPIAO_FRONT_BASE_URL").replace(/\/$/, "");
  try {
    const url = new URL(req.url);
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!code || !state) return redirect(front, "/piaopiao/publisher", { error: "登入資料不完整" });
    const claims = await verifyJwtHs256(state, mustEnv("PIAOPIAO_STATE_SECRET"));
    if (claims.purpose !== "piaopiao-publisher-login" || !claims.nonce) throw new Error("invalid login state");
    const channelId = mustEnv("PIAOPIAO_LINE_CHANNEL_ID");
    const tokens = await exchangeCode({
      code,
      channelId,
      channelSecret: mustEnv("PIAOPIAO_LINE_CHANNEL_SECRET"),
      redirectUri: mustEnv("PIAOPIAO_LINE_CALLBACK_URL"),
    });
    const profile = await verifyIdToken({ idToken: tokens.id_token, channelId });
    const sb = createClient(mustEnv("SUPABASE_URL"), mustEnv("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
    const tenantId = mustEnv("DEFAULT_TENANT_ID");
    const { data: publisher, error } = await sb
      .from("piaopiao_publishers")
      .select("id, display_name, lane, is_active")
      .eq("tenant_id", tenantId).eq("line_user_id", profile.sub).maybeSingle();
    if (error) throw error;
    if (!publisher?.is_active) {
      const { error: requestError } = await sb.from("piaopiao_publisher_requests").upsert({
        tenant_id: tenantId,
        line_user_id: profile.sub,
        display_name: profile.name ?? null,
        picture_url: profile.picture ?? null,
        requested_at: new Date().toISOString(),
      }, { onConflict: "tenant_id,line_user_id" });
      if (requestError) throw requestError;
      return redirect(front, "/piaopiao/publisher/waiting", {});
    }
    const now = Math.floor(Date.now() / 1000);
    const token = await signJwtHs256({
      purpose: "piaopiao-publisher-session",
      tenant_id: tenantId,
      publisher_id: publisher.id,
      line_user_id: profile.sub,
      lane: publisher.lane,
      exp: now + 60 * 60 * 8,
    }, mustEnv("PIAOPIAO_SESSION_SECRET"));
    return new Response(null, { status: 302, headers: { Location: `${front}/piaopiao/publisher#token=${encodeURIComponent(token)}` } });
  } catch (e) {
    console.error("piaopiao OAuth callback", e);
    return redirect(front, "/piaopiao/publisher", { error: "LINE 驗證失敗，請重新登入" });
  }
});

function mustEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}
function redirect(front: string, path: string, query: Record<string, string>) {
  const url = new URL(path, front);
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
  return Response.redirect(url.toString(), 302);
}

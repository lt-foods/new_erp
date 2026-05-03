import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
import { verifyJwtHs256 } from "../_shared/jwt.ts";
import webpush from "https://esm.sh/web-push@3.6.7";

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const auth = req.headers.get("authorization");
    if (!auth) return json({ error: "missing authorization" }, 401);
    
    const sb = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } }
    );

    // Get the user from the token to verify they are authenticated
    const token = auth.replace(/^Bearer\s+/i, "");
    const { data: { user }, error: authErr } = await sb.auth.getUser(token);
    
    if (authErr || !user) {
      return json({ error: "invalid token", detail: authErr?.message }, 401);
    }

    // Extract tenant_id from user metadata or claims
    const tenantId = user.app_metadata?.tenant_id;
    if (!tenantId) {
      return json({ error: "user has no tenant_id" }, 403);
    }

    const body = await req.json();
    const { member_id, title, message, url, category } = body;

    if (!member_id) return json({ error: "member_id is required" }, 400);

    // 寫一筆 in-app notification(就算沒 push subscription 也要寫,顧客還是看得到)
    const { error: notifErr } = await sb.from("notifications").insert({
      tenant_id: tenantId,
      member_id,
      category: typeof category === "string" && category ? category : "general",
      title: title || "通知",
      body: message ?? null,
      url: url ?? null,
    });
    if (notifErr) console.error("notifications insert failed:", notifErr.message);

    // Get subscriptions for this member
    const { data: subs, error: subErr } = await sb
      .from("push_subscriptions")
      .select("endpoint, p256dh, auth")
      .eq("tenant_id", tenantId)
      .eq("member_id", member_id);

    if (subErr) return json({ error: subErr.message }, 500);
    if (!subs || subs.length === 0) {
      return json({ ok: true, sent: 0, message: "Notification recorded; no active PWA subscriptions to push" });
    }

    webpush.setVapidDetails(
      "mailto:admin@new-erp.com",
      requireEnv("VAPID_PUBLIC_KEY"),
      requireEnv("VAPID_PRIVATE_KEY")
    );

    const results = await Promise.allSettled(
      subs.map((s: any) =>
        webpush.sendNotification(
          {
            endpoint: s.endpoint,
            keys: { p256dh: s.p256dh, auth: s.auth },
          },
          JSON.stringify({
            title: title || "測試通知",
            body: message || "這是一則來自管理員的測試通知。",
            url: url || "/",
          })
        )
      )
    );

    const successCount = results.filter((r) => r.status === "fulfilled").length;
    const failCount = results.filter((r) => r.status === "rejected").length;

    // Optional: Cleanup failed subscriptions (e.g. 410 Gone)
    // For a test button, we might just report back.

    return json({
      ok: true,
      sent: successCount,
      failed: failCount,
      details: results.map((r, i) => ({
        endpoint: subs[i].endpoint,
        status: r.status,
        error: r.status === "rejected" ? (r as PromiseRejectedResult).reason : undefined,
      })),
    });
  } catch (e) {
    console.error("admin-notify error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

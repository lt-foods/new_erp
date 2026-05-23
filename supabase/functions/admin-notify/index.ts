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
    const { member_id, title, message, url, category, broadcast } = body;

    const payloadTitle = title || "通知";
    const payloadBody = message ?? null;
    const notifCategory = typeof category === "string" && category ? category : "general";

    webpush.setVapidDetails(
      "mailto:admin@new-erp.com",
      requireEnv("VAPID_PUBLIC_KEY"),
      requireEnv("VAPID_PRIVATE_KEY")
    );

    // ── Broadcast mode: 對整 tenant 的 active 會員發 ─────────────────────────
    if (broadcast === true) {
      const role = user.app_metadata?.role;
      if (role !== "owner" && role !== "admin" && role !== "hq") {
        return json({ error: "broadcast requires owner/admin/hq role" }, 403);
      }

      const { data: members, error: memErr } = await sb
        .from("members")
        .select("id")
        .eq("tenant_id", tenantId)
        .eq("status", "active")
        .or("no_new_order.is.null,no_new_order.eq.false")
        .is("merged_into_member_id", null);

      if (memErr) return json({ error: memErr.message }, 500);
      const memberIds = (members ?? []).map((m: { id: number }) => m.id);
      if (memberIds.length === 0) {
        return json({ ok: true, sent: 0, recipients: 0, message: "no eligible members" });
      }

      // Bulk insert notifications
      const notifRows = memberIds.map((mid) => ({
        tenant_id: tenantId,
        member_id: mid,
        category: notifCategory,
        title: payloadTitle,
        body: payloadBody,
        url: url ?? null,
      }));
      const { error: notifErr } = await sb.from("notifications").insert(notifRows);
      if (notifErr) console.error("broadcast notifications insert failed:", notifErr.message);

      // Fetch subscriptions for these members
      const { data: subs, error: subErr } = await sb
        .from("push_subscriptions")
        .select("endpoint, p256dh, auth, member_id")
        .eq("tenant_id", tenantId)
        .in("member_id", memberIds);
      if (subErr) return json({ error: subErr.message }, 500);

      const subList = subs ?? [];
      if (subList.length === 0) {
        return json({
          ok: true,
          sent: 0,
          recipients: memberIds.length,
          message: "notifications recorded; no active push subscriptions",
        });
      }

      const pushPayload = JSON.stringify({
        title: payloadTitle,
        body: payloadBody ?? "",
        url: url || "/",
      });
      const results = await Promise.allSettled(
        subList.map((s: any) =>
          webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            pushPayload
          )
        )
      );
      const successCount = results.filter((r) => r.status === "fulfilled").length;
      const failCount = results.filter((r) => r.status === "rejected").length;
      return json({
        ok: true,
        sent: successCount,
        failed: failCount,
        recipients: memberIds.length,
        subscriptions: subList.length,
      });
    }

    // ── Single-member mode (既有行為, 不變) ─────────────────────────────────
    if (!member_id) return json({ error: "member_id is required" }, 400);

    // 寫一筆 in-app notification(就算沒 push subscription 也要寫,顧客還是看得到)
    const { error: notifErr } = await sb.from("notifications").insert({
      tenant_id: tenantId,
      member_id,
      category: notifCategory,
      title: payloadTitle,
      body: payloadBody,
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

    const results = await Promise.allSettled(
      subs.map((s: any) =>
        webpush.sendNotification(
          {
            endpoint: s.endpoint,
            keys: { p256dh: s.p256dh, auth: s.auth },
          },
          JSON.stringify({
            title: payloadTitle,
            body: payloadBody ?? "",
            url: url || "/",
          })
        )
      )
    );

    const successCount = results.filter((r) => r.status === "fulfilled").length;
    const failCount = results.filter((r) => r.status === "rejected").length;

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

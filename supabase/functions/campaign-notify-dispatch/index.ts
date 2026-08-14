// ============================================================================
// campaign-notify-dispatch — 開團「上架通知」排程發送端
//
// 觸發：pg_cron 每分鐘 → public._poke_listing_notify_dispatch() → pg_net POST 這裡
//       （有到期的排程才會被戳；平時不會有流量）
//
// 為何 verify_jwt = false 且不驗 caller：
//   - cron 端帶不了使用者 JWT。
//   - 本函式不吃任何輸入；「哪些通知該發」完全由 DB 時間決定，
//     rpc_claim_due_listing_notifications() 用 FOR UPDATE SKIP LOCKED +
//     listing_notify_sent_at 守衛做原子 claim —— 被外人狂打的效果
//     只是「提早幾秒跑本來下一分鐘就會跑的事」，發不出重複通知。
//
// 流程：claim RPC（標記已發 + 寫 in-app notifications + 回會員名單）
//       → 撈 push_subscriptions → web push（best-effort；in-app 已落地）。
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
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

type ClaimedNotification = {
  campaign_id: number;
  tenant_id: string;
  title: string;
  body: string | null;
  url: string;
  member_ids: number[];
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const sb = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } }
    );

    const { data, error } = await sb.rpc("rpc_claim_due_listing_notifications");
    if (error) return json({ error: error.message }, 500);

    const claimed = (data ?? []) as ClaimedNotification[];
    if (claimed.length === 0) return json({ ok: true, campaigns: 0, sent: 0 });

    webpush.setVapidDetails(
      "mailto:admin@new-erp.com",
      requireEnv("VAPID_PUBLIC_KEY"),
      requireEnv("VAPID_PRIVATE_KEY")
    );

    let sent = 0;
    let failed = 0;
    const perCampaign: { campaign_id: number; recipients: number; pushed: number }[] = [];

    for (const c of claimed) {
      // .in() 塞上千個 member id 會撐爆 URL —— 改成整 tenant 撈（訂閱數遠小於
      // 會員數）再在記憶體裡過濾
      const { data: subs, error: subErr } = await sb
        .from("push_subscriptions")
        .select("endpoint, p256dh, auth, member_id")
        .eq("tenant_id", c.tenant_id);
      if (subErr) {
        console.error(`campaign ${c.campaign_id}: push_subscriptions query failed:`, subErr.message);
        perCampaign.push({ campaign_id: c.campaign_id, recipients: c.member_ids.length, pushed: 0 });
        continue;
      }

      const eligible = new Set(c.member_ids);
      const targets = (subs ?? []).filter((s: { member_id: number }) => eligible.has(s.member_id));
      const payload = JSON.stringify({ title: c.title, body: c.body ?? "", url: c.url || "/" });

      const results = await Promise.allSettled(
        targets.map((s: { endpoint: string; p256dh: string; auth: string }) =>
          webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            payload
          )
        )
      );
      const ok = results.filter((r) => r.status === "fulfilled").length;
      sent += ok;
      failed += results.length - ok;
      perCampaign.push({ campaign_id: c.campaign_id, recipients: c.member_ids.length, pushed: ok });
    }

    return json({ ok: true, campaigns: claimed.length, sent, failed, detail: perCampaign });
  } catch (e) {
    console.error("campaign-notify-dispatch error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

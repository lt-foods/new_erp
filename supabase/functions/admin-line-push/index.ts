// admin-line-push: admin 對單一會員經 LINE OA（Messaging API）發訊息（文字/截圖）
//
// 呼叫者：admin 會員詳情頁（LineMessageModal）。
// Auth：函式內自驗 staff JWT（sb.auth.getUser）+ tenant 檢查，照 admin-notify 模式。
//       gateway verify_jwt=false（true 會擋 CORS preflight，見 config.toml staff-create 註解）。
//
// actions:
//   check — GET LINE profile，回「這個 line_user_id 對這支 OA 能不能推」
//           （404 = 沒加好友 **或** Login channel 跟 OA 不同 provider、ID 對不上）
//   quota — 本月推播額度（limit=null 表示方案無上限）。注意額度只算「主動
//           推播」（push/broadcast/群發），OA 後台 1:1 聊天不吃額度 —
//           後台數字跟這裡對不上時，先想這件事。
//   send  — push 文字和/或圖片。圖片 URL 限定自家 line-media bucket，
//           防止拿這支函式對會員推任意外部圖。
//
// 需要 secret：LINE_MESSAGING_CHANNEL_ACCESS_TOKEN（OA 的 Messaging API
// long-lived channel access token）。沒設會回 503 not_configured — 這是
// 部署後第一個要檢查的東西，不是程式 bug。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";

const LINE_PUSH_URL = "https://api.line.me/v2/bot/message/push";
const LINE_PROFILE_URL = "https://api.line.me/v2/bot/profile";
const LINE_QUOTA_URL = "https://api.line.me/v2/bot/message/quota";

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

    const supabaseUrl = requireEnv("SUPABASE_URL");
    const sb = createClient(
      supabaseUrl,
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } }
    );

    const token = auth.replace(/^Bearer\s+/i, "");
    const { data: { user }, error: authErr } = await sb.auth.getUser(token);
    if (authErr || !user) {
      return json({ error: "invalid token", detail: authErr?.message }, 401);
    }

    const tenantId = user.app_metadata?.tenant_id;
    if (!tenantId) return json({ error: "user has no tenant_id" }, 403);

    const body = await req.json();
    const action = body.action === "check" ? "check"
      : body.action === "quota" ? "quota"
      : "send";

    const oaToken = Deno.env.get("LINE_MESSAGING_CHANNEL_ACCESS_TOKEN");
    if (!oaToken) {
      return json({
        error: "not_configured",
        message: "尚未設定 LINE_MESSAGING_CHANNEL_ACCESS_TOKEN（LINE 官方帳號的 Messaging API channel access token）",
      }, 503);
    }
    const oaHeaders = { "Authorization": `Bearer ${oaToken}` };

    // ── quota：本月推播額度（不需要 member_id）─────────────────────────────
    if (action === "quota") {
      const [qResp, cResp] = await Promise.all([
        fetch(LINE_QUOTA_URL, { headers: oaHeaders }),
        fetch(`${LINE_QUOTA_URL}/consumption`, { headers: oaHeaders }),
      ]);
      if (!qResp.ok || !cResp.ok) {
        const detail = `quota ${qResp.status} / consumption ${cResp.status}`;
        return json({ error: "line_api_error", detail }, 502);
      }
      const q = await qResp.json();
      const c = await cResp.json();
      return json({
        ok: true,
        limit: q.type === "limited" ? q.value : null,  // null = 方案無上限
        used: c.totalUsage ?? 0,
      });
    }

    const memberId = body.member_id;
    if (!memberId) return json({ error: "member_id is required" }, 400);

    const { data: member, error: memErr } = await sb
      .from("members")
      .select("id, name, line_user_id")
      .eq("tenant_id", tenantId)
      .eq("id", memberId)
      .maybeSingle();
    if (memErr) return json({ error: memErr.message }, 500);
    if (!member) return json({ error: "member not found" }, 404);
    if (!member.line_user_id) {
      return json({ error: "member_no_line", message: "此會員未綁定 LINE" }, 400);
    }

    // ── check：能不能推得到這個人 ───────────────────────────────────────────
    if (action === "check") {
      const resp = await fetch(`${LINE_PROFILE_URL}/${member.line_user_id}`, { headers: oaHeaders });
      if (resp.ok) {
        const profile = await resp.json();
        return json({ ok: true, reachable: true, display_name: profile.displayName ?? null });
      }
      const detail = await resp.text();
      if (resp.status === 404) {
        return json({
          ok: true,
          reachable: false,
          message: "此會員尚未加入官方帳號好友（或此 LINE ID 不屬於這支官方帳號的 provider），訊息無法送達",
        });
      }
      if (resp.status === 401) {
        return json({ error: "bad_token", message: "LINE token 無效，請重新確認 LINE_MESSAGING_CHANNEL_ACCESS_TOKEN", detail }, 502);
      }
      return json({ error: "line_api_error", status: resp.status, detail }, 502);
    }

    // ── send ────────────────────────────────────────────────────────────────
    const text = typeof body.text === "string" ? body.text.trim() : "";
    const imageUrl = typeof body.image_url === "string" ? body.image_url : "";
    const previewUrl = typeof body.preview_url === "string" && body.preview_url ? body.preview_url : imageUrl;

    if (!text && !imageUrl) return json({ error: "text 或 image_url 至少要有一個" }, 400);
    if (text.length > 5000) return json({ error: "text 超過 LINE 上限 5000 字" }, 400);

    // 圖片只收自家 line-media bucket 的公開 URL
    const mediaPrefix = `${supabaseUrl}/storage/v1/object/public/line-media/`;
    if (imageUrl && !imageUrl.startsWith(mediaPrefix)) {
      return json({ error: "image_url 必須是 line-media bucket 的公開 URL" }, 400);
    }

    const messages: unknown[] = [];
    if (text) messages.push({ type: "text", text });
    if (imageUrl) {
      messages.push({ type: "image", originalContentUrl: imageUrl, previewImageUrl: previewUrl });
    }

    const resp = await fetch(LINE_PUSH_URL, {
      method: "POST",
      headers: { ...oaHeaders, "Content-Type": "application/json" },
      body: JSON.stringify({ to: member.line_user_id, messages }),
    });

    const ok = resp.ok;
    const respText = ok ? null : await resp.text();

    const { error: logErr } = await sb.from("line_push_logs").insert({
      tenant_id: tenantId,
      member_id: member.id,
      line_user_id: member.line_user_id,
      sent_by: user.id,
      text: text || null,
      image_url: imageUrl || null,
      status: ok ? "sent" : "failed",
      error: respText,
    });
    if (logErr) console.error("line_push_logs insert failed:", logErr.message);

    if (!ok) {
      // 400 幾乎都是「推不到這個人」：沒加好友 / 封鎖 / provider 不一致
      const hint = resp.status === 400
        ? "會員可能尚未加入官方帳號好友、已封鎖、或此 LINE ID 不屬於這支官方帳號"
        : undefined;
      return json({ error: "line_push_failed", status: resp.status, detail: respText, hint }, 502);
    }
    return json({ ok: true, member_name: member.name ?? null });
  } catch (e) {
    console.error("admin-line-push error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

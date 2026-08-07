// admin-line-push: admin 對單一會員經 LINE OA（Messaging API）發訊息（文字/截圖）
//
// 呼叫者：admin 會員詳情頁（LineMessageModal）。
// Auth：函式內自驗 staff JWT（sb.auth.getUser）+ tenant 檢查，照 admin-notify 模式。
//       gateway verify_jwt=false（true 會擋 CORS preflight，見 config.toml staff-create 註解）。
//
// actions:
//   check — GET LINE profile，回「這個 line_user_id 對這支 OA 能不能推」
//           （404 = 沒加好友 **或** Login channel 跟 OA 不同 provider、ID 對不上）
//           同時回 chat_url（OA 後台 1:1 聊天室連結）與 chat_mode。
//   quota — 本月推播額度（limit=null 表示方案無上限）。注意額度只算「主動
//           推播」（push/broadcast/群發），OA 後台 1:1 聊天不吃額度 —
//           後台數字跟這裡對不上時，先想這件事。
//   links — 訊息樣板要用的會員站連結（不需要 LINE token）。
//   send  — push 文字和/或圖片。圖片 URL 限定自家 line-media bucket，
//           防止拿這支函式對會員推任意外部圖。
//
// 憑證來源（見 resolveOaToken）：會員所屬分店的 store_line_oa_credentials
// → 租戶層 env LINE_MESSAGING_CHANNEL_ACCESS_TOKEN → 都沒有回 503 not_configured。
// 這個租戶是每加盟店各有自己 OA 的架構，所以主線是分店憑證，env 只是退路。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";

const LINE_PUSH_URL = "https://api.line.me/v2/bot/message/push";
const LINE_PROFILE_URL = "https://api.line.me/v2/bot/profile";
const LINE_QUOTA_URL = "https://api.line.me/v2/bot/message/quota";
const LINE_BOT_INFO_URL = "https://api.line.me/v2/bot/info";
const LINE_TOKEN_URL = "https://api.line.me/v2/oauth/accessToken";

// OA 後台（LINE Official Account Manager）的 1:1 聊天室連結。
// ⚠ 這個 URL 格式是**非官方**的 — LINE 沒有把後台網址列進 API 文件，
//   哪天改版就會失效。所以：連結壞掉不要當程式 bug 追，先手動開
//   https://chat.line.biz/ 看網址列現在長什麼樣，再回來改這一行。
// 第一段是 OA 自己的 userId（/v2/bot/info 的 userId），不是 basicId(@xxx)。
function chatConsoleUrl(botUserId: string, memberLineUserId: string): string {
  return `https://chat.line.biz/${botUserId}/chat/${memberLineUserId}`;
}

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

type OaResolved =
  | { token: string; source: "store" | "env" }
  | { error: Record<string, unknown>; status: number };

/**
 * 取「該分店」的 channel access token。
 *
 * 順序：分店自己的憑證（store_line_oa_credentials）→ 租戶層 env token → 都沒有就報錯。
 * env 那層是給「只有一個 OA」的租戶用的退路，以及分店還沒設定完的過渡期。
 *
 * 分店憑證存的是 channel_id + channel_secret（管理員在後台填的就是這兩個，
 * 比 console 裡的 long-lived token 好找），這裡用 client_credentials 換成
 * access token 並快取到期限前 —— 不快取的話每發一則訊息就多打一次 oauth。
 */
async function resolveOaToken(
  // deno-lint-ignore no-explicit-any
  sb: any,
  tenantId: string,
  storeId: number | null,
): Promise<OaResolved> {
  const envToken = Deno.env.get("LINE_MESSAGING_CHANNEL_ACCESS_TOKEN");

  if (storeId != null) {
    const { data: cred, error } = await sb
      .from("store_line_oa_credentials")
      .select("store_id, channel_id, channel_secret, access_token, access_token_expires_at")
      .eq("tenant_id", tenantId)
      .eq("store_id", storeId)
      .maybeSingle();
    if (error) return { error: { error: "internal", detail: error.message }, status: 500 };

    if (cred) {
      // 留 5 分鐘緩衝，免得剛好在發送途中過期
      const exp = cred.access_token_expires_at ? Date.parse(cred.access_token_expires_at) : 0;
      if (cred.access_token && exp > Date.now() + 5 * 60_000) {
        return { token: cred.access_token, source: "store" };
      }
      const resp = await fetch(LINE_TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "client_credentials",
          client_id: cred.channel_id,
          client_secret: cred.channel_secret,
        }),
      });
      if (!resp.ok) {
        const detail = await resp.text();
        return {
          error: {
            error: "bad_store_credentials",
            message: "分店的 LINE Channel ID / Secret 無法換到 token，請確認是否填對（要用 Messaging API channel 的，不是 Login channel）",
            detail,
          },
          status: 502,
        };
      }
      const tok = await resp.json();
      const expiresAt = new Date(Date.now() + (tok.expires_in ?? 0) * 1000).toISOString();
      const { error: upErr } = await sb
        .from("store_line_oa_credentials")
        .update({ access_token: tok.access_token, access_token_expires_at: expiresAt })
        .eq("store_id", storeId);
      // 快取寫失敗不擋發送，只是下次還要再換一次
      if (upErr) console.error("cache access_token failed:", upErr.message);
      return { token: tok.access_token, source: "store" };
    }
  }

  if (envToken) return { token: envToken, source: "env" };

  return {
    error: {
      error: "not_configured",
      message: storeId == null
        ? "此會員沒有設定取貨店，無法決定要用哪一個官方帳號發送"
        : "此會員所屬分店尚未設定 LINE Messaging API 憑證（請到「分店」→ 該店 →「LINE 推播憑證」填入 Channel ID / Secret）",
    },
    status: 503,
  };
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
      : body.action === "links" ? "links"
      : "send";

    // ── links：訊息樣板要用的會員站連結（刻意放在 LINE token 檢查之前）──────
    // 這幾條連結跟 LINE 無關，token 還沒設好時樣板也該能用。
    //
    // ⚠ 給的是會員站自己的網址，**不是** https://liff.line.me/... —
    //   LIFF 連結會把使用者丟進 LIFF endpoint，而該 endpoint 目前指向一支
    //   跨網域的 Cloudflare Worker，一跨網域 LIFF context 就沒了、登入必爆
    //   （見 CLAUDE.md「LIFF app 的 Endpoint URL 必須跟會員站同網域」）。
    //   會員站的 /orders 沒登入時會自己導去 `/` 走 useLineLogin，
    //   那條路才是唯一維護中的登入邏輯。
    if (action === "links") {
      const base = (Deno.env.get("MEMBER_FRONT_BASE_URL") ?? "").replace(/\/+$/, "");
      // localhost 是 README 給本機開發用的預設值，發到會員手機上是死連結
      const usable = /^https:\/\//.test(base);
      return json({
        ok: true,
        orders_url: usable ? `${base}/orders` : null,
        message: usable ? undefined : "MEMBER_FRONT_BASE_URL 未設定或不是 https 網址，樣板連結無法產生",
      });
    }

    const memberId = body.member_id;
    if (!memberId) return json({ error: "member_id is required" }, 400);

    const { data: member, error: memErr } = await sb
      .from("members")
      .select("id, name, line_user_id, home_store_id")
      .eq("tenant_id", tenantId)
      .eq("id", memberId)
      .maybeSingle();
    if (memErr) return json({ error: memErr.message }, 500);
    if (!member) return json({ error: "member not found" }, 404);
    if (!member.line_user_id) {
      return json({ error: "member_no_line", message: "此會員未綁定 LINE" }, 400);
    }

    // 用「會員所屬分店」的 OA 憑證。這個租戶每家加盟店各有自己的 OA，
    // 而 LINE 好友關係是綁在單一 OA 上的 —— 拿 B 店的 token 去推 A 店的
    // 好友一定失敗，所以絕不能共用一組 token。
    const oa = await resolveOaToken(sb, tenantId, member.home_store_id ?? null);
    if ("error" in oa) return json(oa.error, oa.status);
    const oaHeaders = { "Authorization": `Bearer ${oa.token}` };

    // ── quota：本月推播額度（該分店 OA 的額度）─────────────────────────────
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
        source: oa.source,
      });
    }

    // ── check：能不能推得到這個人 + OA 後台 1:1 聊天室連結 ──────────────────
    if (action === "check") {
      const [resp, infoResp] = await Promise.all([
        fetch(`${LINE_PROFILE_URL}/${member.line_user_id}`, { headers: oaHeaders }),
        fetch(LINE_BOT_INFO_URL, { headers: oaHeaders }),
      ]);

      // bot info 拿不到不擋主流程：少的只是「開聊天室」連結
      let chatUrl: string | null = null;
      let chatMode: string | null = null;
      if (infoResp.ok) {
        const info = await infoResp.json();
        chatMode = info.chatMode ?? null;   // "chat" = 後台 1:1 聊天開著；"bot" = 只走 webhook
        if (info.userId) chatUrl = chatConsoleUrl(info.userId, member.line_user_id);
      } else {
        console.error("bot info failed:", infoResp.status, await infoResp.text());
      }

      if (resp.ok) {
        const profile = await resp.json();
        return json({
          ok: true, reachable: true,
          display_name: profile.displayName ?? null,
          chat_url: chatUrl, chat_mode: chatMode,
        });
      }
      const detail = await resp.text();
      if (resp.status === 404) {
        return json({
          ok: true,
          reachable: false,
          message: "此會員尚未加入官方帳號好友（或此 LINE ID 不屬於這支官方帳號的 provider），訊息無法送達",
          chat_url: chatUrl, chat_mode: chatMode,
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

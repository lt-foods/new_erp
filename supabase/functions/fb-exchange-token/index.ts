// fb-exchange-token：把使用者貼進來的 User Access Token 換成「永不過期」的 Page Access Token
//
// 流程：
//   1. 驗證 JWT、角色（owner/admin/hq_manager）、tenant_id
//   2. 讀 fb_pages 拿目標 page_id（service_role 旁路 RLS）
//   3. 呼叫 FB Graph：
//        a. GET /oauth/access_token?grant_type=fb_exchange_token
//             → 短期 user token 換 long-lived user token（60 天）
//             若使用者已給 long-lived token，FB 仍會回傳一個新的 60 天 token，無害。
//        b. GET /{user_id}/accounts?access_token={long_user_token}
//             → 拿到使用者擁有的所有粉專 + 各自的 page token
//        c. GET /debug_token?input_token={page_token}&access_token={app_id|app_secret}
//             → 驗證 page token 確實是 never-expire（expires_at = 0）
//   4. UPDATE fb_pages.access_token，並清掉 token_invalid_at / token_last_error
//
// 為什麼 page token 會永不過期？
//   FB 文件保證：用「long-lived user token」去 /me/accounts 拿到的 page token
//   本身永不過期，即使原本的 user token 60 天後過期。
//   反之，從 short-lived user token 取的 page token 只活 1~2 小時 —— 這就是
//   既有架構為什麼 token「會一直過期」的根本原因。
//
// 需要的 Supabase secrets：
//   FB_APP_ID      —— developers.facebook.com 上 App 的 ID
//   FB_APP_SECRET  —— 同 App 的 secret（不要外洩）

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";

const FB_API_VERSION = "v19.0";
const FB_BASE = `https://graph.facebook.com/${FB_API_VERSION}`;

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

async function fbGet(
  path: string,
  params: Record<string, string>,
): Promise<Record<string, unknown>> {
  const u = new URL(`${FB_BASE}${path}`);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  const r = await fetch(u.toString());
  const text = await r.text();
  let parsed: Record<string, unknown>;
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  if (!r.ok) {
    const errObj = parsed?.error as
      | { message?: string; code?: number; type?: string }
      | undefined;
    const detail = errObj?.message || text || `HTTP ${r.status}`;
    const code = errObj?.code != null ? `[${errObj.code}] ` : "";
    throw new Error(`${code}${detail}`);
  }
  return parsed;
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
      { auth: { persistSession: false } },
    );

    const token = auth.replace(/^Bearer\s+/i, "");
    const { data: { user }, error: authErr } = await sb.auth.getUser(token);
    if (authErr || !user) {
      return json({ error: "invalid token", detail: authErr?.message }, 401);
    }

    const tenantId = user.app_metadata?.tenant_id as string | undefined;
    const role = user.app_metadata?.role as string | undefined;
    if (!tenantId) return json({ error: "user has no tenant_id" }, 403);
    if (!role || !["owner", "admin", "hq_manager"].includes(role)) {
      return json({ error: "forbidden" }, 403);
    }

    const body = await req.json();
    const fbPageDbId = Number(body?.fb_page_db_id);
    const userToken = typeof body?.user_token === "string" ? body.user_token.trim() : "";

    if (!Number.isFinite(fbPageDbId) || fbPageDbId <= 0) {
      return json({ error: "fb_page_db_id required" }, 400);
    }
    if (!userToken) {
      return json({ error: "user_token required" }, 400);
    }

    const { data: page, error: pErr } = await sb
      .from("fb_pages")
      .select("id, page_id, name")
      .eq("tenant_id", tenantId)
      .eq("id", fbPageDbId)
      .maybeSingle();
    if (pErr) return json({ error: pErr.message }, 500);
    if (!page) return json({ error: "fb_page not found in this tenant" }, 404);

    const appId = requireEnv("FB_APP_ID");
    const appSecret = requireEnv("FB_APP_SECRET");

    // 1. 短期 user token → long-lived user token
    let longUserToken: string;
    try {
      const ex = await fbGet("/oauth/access_token", {
        grant_type: "fb_exchange_token",
        client_id: appId,
        client_secret: appSecret,
        fb_exchange_token: userToken,
      });
      longUserToken = String(ex.access_token ?? "");
      if (!longUserToken) {
        return json({ error: "FB did not return a long-lived token", detail: ex }, 502);
      }
    } catch (e) {
      return json({
        error: "exchange user token failed",
        detail: e instanceof Error ? e.message : String(e),
        hint: "請確認貼入的是 User Access Token（不是 Page Token），且 App ID / Secret 設定正確",
      }, 400);
    }

    // 2. 從 long-lived user token 拿 page list（含對應的 page token）
    let accounts: Array<{ id: string; name: string; access_token: string }>;
    try {
      const r = await fbGet("/me/accounts", {
        access_token: longUserToken,
        fields: "id,name,access_token",
        limit: "200",
      });
      accounts = (r?.data as Array<{ id: string; name: string; access_token: string }>) ?? [];
    } catch (e) {
      return json({
        error: "fetch /me/accounts failed",
        detail: e instanceof Error ? e.message : String(e),
      }, 502);
    }

    const match = accounts.find((a) => String(a.id) === String(page.page_id));
    if (!match) {
      return json({
        error: "page_id not in user's owned pages",
        detail: `User does not have admin access to FB page ${page.page_id}; owned: ${accounts.map((a) => `${a.id}(${a.name})`).join(", ") || "(none)"}`,
      }, 400);
    }

    const newPageToken = match.access_token;
    if (!newPageToken) {
      return json({ error: "FB returned no page token for this page" }, 502);
    }

    // 3. debug_token 驗證 expires_at（應為 0 = never）
    let expiresAt: number | null = null;
    let isNeverExpire = false;
    try {
      const d = await fbGet("/debug_token", {
        input_token: newPageToken,
        access_token: `${appId}|${appSecret}`,
      });
      const data = d?.data as { expires_at?: number; is_valid?: boolean } | undefined;
      expiresAt = typeof data?.expires_at === "number" ? data.expires_at : null;
      isNeverExpire = expiresAt === 0;
    } catch {
      // debug_token 失敗不阻斷流程，token 仍可用
    }

    // 4. 寫入 DB + 清掉失效標記
    const { error: uErr } = await sb
      .from("fb_pages")
      .update({
        access_token: newPageToken,
        token_invalid_at: null,
        token_last_error: null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", page.id)
      .eq("tenant_id", tenantId);
    if (uErr) return json({ error: "update fb_pages failed", detail: uErr.message }, 500);

    return json({
      ok: true,
      page_id: page.page_id,
      page_name: match.name,
      never_expire: isNeverExpire,
      expires_at: expiresAt,
      warning: isNeverExpire
        ? null
        : "FB 回傳的 page token 仍有到期時間，請確認貼入的是 long-lived user token",
    });
  } catch (e) {
    console.error("fb-exchange-token error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

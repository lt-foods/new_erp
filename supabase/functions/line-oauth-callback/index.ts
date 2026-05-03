// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: line-oauth-callback
// 登記在 LINE Login Callback URL；GET /functions/v1/line-oauth-callback?code=...&state=...
//
// 流程：
//   1. 驗 state → 取出 store_id
//   2. code → exchange → id_token
//   3. verify id_token → line_user_id (sub)
//   4. 查 member_line_bindings (tenant, store, line_user_id)
//      - 已綁 → 簽 member JWT（role=authenticated + member_id）
//      - 未綁 → 簽 pending JWT（role=authenticated + line_user_id + store_id，無 member_id）
//   5. 302 redirect 回前端 /auth/complete#token=...&bound=0|1&member_id=...
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
import { signJwtHs256, verifyStateToken } from "../_shared/jwt.ts";
import { exchangeCode, verifyIdToken } from "../_shared/line.ts";
import { autoRegister } from "../_shared/auto-register.ts";
import { resolveStore } from "../_shared/store-resolve.ts";

const SESSION_TTL_SEC = 60 * 60 * 24 * 30; // 30 天

// ─── helpers ─────────────────────────────────────────────────────────────────

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

function frontBase(): string {
  return Deno.env.get("MEMBER_FRONT_BASE_URL") ?? "http://localhost:3001";
}

function redirectFront(path: string, qs: Record<string, string>): Response {
  const url = new URL(path, frontBase());
  for (const [k, v] of Object.entries(qs)) url.searchParams.set(k, v);
  return Response.redirect(url.toString(), 302);
}

function redirectFrontWithFragment(path: string, fragment: string): Response {
  const url = new URL(path, frontBase());
  return Response.redirect(`${url.toString()}#${fragment}`, 302);
}

// ─── main ────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const code   = url.searchParams.get("code");
    const state  = url.searchParams.get("state");
    const error  = url.searchParams.get("error");

    if (error) return redirectFront("/", { error });
    if (!code || !state) {
      return redirectFront("/", { error: "missing_code_or_state" });
    }

    // env
    const channelId     = requireEnv("LINE_CHANNEL_ID");
    const channelSecret = requireEnv("LINE_CHANNEL_SECRET");
    const callbackUrl   = requireEnv("LINE_CALLBACK_URL");
    const stateSecret   = requireEnv("LINE_STATE_SECRET");
    const jwtSecret     = requireEnv("PROJECT_JWT_SECRET");
    const supabaseUrl   = requireEnv("SUPABASE_URL");
    const serviceKey    = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
    const tenantId      = requireEnv("DEFAULT_TENANT_ID"); // v1 單 tenant

    // 1) state
    const { store_id: storeKey, pair_code: pairCode } = await verifyStateToken(state, stateSecret);

    // 1b) 解析 store key (code "S001" 或 numeric "1") → canonical { id, code }
    //     下游 binding lookup / autoRegister / JWT 全部用數字 ID,前端 redirect 用 code
    const resolved = await resolveStore(supabaseUrl, serviceKey, tenantId, storeKey);
    if (!resolved) {
      return redirectFront("/", { error: "oauth_failed", detail: "store_not_found" });
    }
    const storeNumericId = resolved.id;
    const storeCode = resolved.code;

    // 2) code → token
    const tokens = await exchangeCode({
      code,
      redirectUri: callbackUrl,
      channelId,
      channelSecret,
    });

    // 3) verify id_token
    const payload = await verifyIdToken({
      idToken: tokens.id_token,
      channelId,
    });
    const lineUserId = payload.sub;

    // 4) lookup binding via REST (service role)
    const bindingUrl =
      `${supabaseUrl}/rest/v1/member_line_bindings` +
      `?select=member_id&tenant_id=eq.${tenantId}` +
      `&store_id=eq.${storeNumericId}&line_user_id=eq.${lineUserId}` +
      `&unbound_at=is.null&limit=1`;

    const resp = await fetch(bindingUrl, {
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
      },
    });
    if (!resp.ok) {
      const t = await resp.text();
      throw new Error(`binding lookup failed ${resp.status}: ${t}`);
    }
    const rows = await resp.json() as Array<{ member_id: number }>;
    let memberId: number | null = rows.length > 0 ? rows[0].member_id : null;

    // 5) 未綁 → auto-register：用 LINE 個資建會員 + 綁定（省略註冊表單）
    //    placeholder phone 用 "line:<uid>"（保證唯一、不會撞真實手機）
    //    之後使用者可在設定頁補填真實 phone / 生日
    if (!memberId) {
      memberId = await autoRegister({
        supabaseUrl,
        serviceKey,
        tenantId,
        storeId: String(storeNumericId),
        lineUserId,
        lineName: payload.name ?? null,
        linePicture: payload.picture ?? null,
      });
    }

    // 6) sign session JWT（memberId 保證有值）
    const now = Math.floor(Date.now() / 1000);
    const jwt = await signJwtHs256(
      {
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
      },
      jwtSecret,
    );

    // 7) 產生 6 位數驗證碼 (PWA 跨視窗同步用)
    const code6 = Math.floor(100000 + Math.random() * 900000).toString();
    const sessionData = {
      token: jwt,
      store: storeCode,
      member_id: memberId,
      line_user_id: lineUserId,
      line_name: payload.name ?? null,
      line_picture: payload.picture ?? null,
    };

    const sb = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false },
    });
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();

    // 永遠寫一份 6 位數驗證碼（fallback，使用者手動輸入用）
    const { error: codeErr } = await sb
      .from("pwa_auth_codes")
      .insert({
        code: code6,
        session_data: sessionData,
        tenant_id: tenantId,
        expires_at: expiresAt,
      });
    if (codeErr) console.error("failed to save pwa code:", codeErr);

    // 若 PWA 主動帶 pair_code 進來,額外寫一份 keyed by pair_code,
    // PWA 切回桌面後 visibilitychange 會 silently claim,使用者不用手動輸入碼
    if (pairCode) {
      const { error: pairErr } = await sb
        .from("pwa_auth_codes")
        .insert({
          code: pairCode,
          session_data: sessionData,
          tenant_id: tenantId,
          expires_at: expiresAt,
        });
      if (pairErr) console.error("failed to save pair code:", pairErr);
    }

    // 8) redirect 回前端 /auth/success
    // - 有 pair_code → 顯示「請回到 PWA」(不秀 6 碼,避免使用者誤打)
    // - 沒有 → 顯示 6 碼 + token fragment(同舊行為)
    const params = new URLSearchParams({
      code: code6,
      bound: "1",
      store: storeCode,
    });
    if (pairCode) params.set("paired", "1");
    return redirectFrontWithFragment(
      "/auth/success",
      params.toString() + `&token=${encodeURIComponent(jwt)}`,
    );
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("oauth callback error:", msg);
    return redirectFront("/", { error: "oauth_failed", detail: msg });
  }
});

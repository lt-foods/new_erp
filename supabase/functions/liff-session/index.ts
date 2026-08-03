// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: liff-session
// 給 LIFF SDK 呼叫（LINE 內 webview）。
// 前端流程：liff.init() → liff.getIDToken() → POST 到這支
//
// 流程：
//   1. 收 id_token (+ optional store)
//   2. 驗 id_token（LINE verify API）
//   3. 決定 store：
//      - 沒帶 store → 用 line_user_id 找既有 binding（最近一筆）
//      - 帶 store → 優先用既有 binding 的 store；若無 → 用帶來的 store 註冊
//      - 無 binding 又無 store → 回 store_required（首次註冊必須選店）
//   4. 未綁 → auto-register
//   5. 簽 Supabase-compatible JWT 回傳
//
// 跟 line-oauth-callback 差別：
//   - 不用 state / code exchange（LIFF 直接給 id_token）
//   - 不做 302 redirect，回 JSON（前端自己 navigate）
// ─────────────────────────────────────────────────────────────────────────────

import { corsHeaders } from "../_shared/cors.ts";
import { signJwtHs256 } from "../_shared/jwt.ts";
import { verifyIdToken } from "../_shared/line.ts";
import { autoRegister } from "../_shared/auto-register.ts";
import { resolveStore } from "../_shared/store-resolve.ts";

// 半年。沒有續期機制（絕對過期），所以這個值就是「會員最久多久要重登一次」。
// LINE 內每次開 LIFF 都會重跑 init 自動登入，實際上碰不到；真正有感的是 PWA —
// 它是獨立 localStorage，時間一到就真的斷線，重登要繞 LIFF 配對，體驗差。
// 兩支簽 session 的函式（本檔與 line-oauth-callback）必須一致，改一邊等於埋雷。
const SESSION_TTL_SEC = 60 * 60 * 24 * 180;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const body = await req.json() as { id_token?: string; store?: string; pair_code?: string };
    if (!body.id_token) return json({ error: "id_token required" }, 400);
    const pairCode = typeof body.pair_code === "string" ? body.pair_code.trim() : "";
    const incomingStore = typeof body.store === "string" && body.store.trim().length > 0
      ? body.store.trim()
      : null;

    const channelId   = requireEnv("LINE_LIFF_CHANNEL_ID"); // 可跟 LINE_CHANNEL_ID 相同、或獨立 LIFF channel
    const jwtSecret   = requireEnv("PROJECT_JWT_SECRET");
    const supabaseUrl = requireEnv("SUPABASE_URL");
    const serviceKey  = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
    const tenantId    = requireEnv("DEFAULT_TENANT_ID");

    // 1) verify id_token
    const payload = await verifyIdToken({
      idToken: body.id_token,
      channelId,
    });
    const lineUserId = payload.sub;

    // 2) 先用 line_user_id 找既有 binding（不限 store）— 回頭客直接命中
    const existingUrl =
      `${supabaseUrl}/rest/v1/member_line_bindings` +
      `?select=member_id,store_id,bound_at&tenant_id=eq.${tenantId}` +
      `&line_user_id=eq.${lineUserId}&unbound_at=is.null` +
      `&order=bound_at.desc&limit=1`;
    const existingResp = await fetch(existingUrl, {
      headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
    });
    if (!existingResp.ok) {
      throw new Error(`binding lookup ${existingResp.status}: ${await existingResp.text()}`);
    }
    const existingRows = await existingResp.json() as Array<{ member_id: number; store_id: number }>;

    let memberId: number | null = null;
    let storeNumericId: number;
    let storeCode: string;

    if (existingRows.length > 0) {
      // 回頭客：用既有 binding 的 store，忽略 URL ?store= 帶來的 store
      memberId = existingRows[0].member_id;
      storeNumericId = existingRows[0].store_id;
      const resolved = await resolveStore(supabaseUrl, serviceKey, tenantId, String(storeNumericId));
      if (!resolved) return json({ error: "store_not_found", detail: String(storeNumericId) }, 500);
      storeCode = resolved.code;
    } else {
      // 沒 binding → 必須有 store 才能首次註冊
      if (!incomingStore) {
        return json({ error: "store_required", detail: "first registration requires store" }, 400);
      }
      const resolved = await resolveStore(supabaseUrl, serviceKey, tenantId, incomingStore);
      if (!resolved) return json({ error: "store_not_found", detail: incomingStore }, 400);
      storeNumericId = resolved.id;
      storeCode = resolved.code;

      memberId = await autoRegister({
        supabaseUrl,
        serviceKey,
        tenantId,
        storeId: String(storeNumericId),
        lineUserId,
        lineName:    payload.name    ?? null,
        linePicture: payload.picture ?? null,
      });
    }

    // bump members.last_visit_at（fire-and-forget，不阻塞登入；trigger 透過 GUC 跳過 updated_at）
    if (memberId != null) {
      void touchMemberVisit(supabaseUrl, serviceKey, memberId);
    }

    // 4) 簽 JWT
    const now = Math.floor(Date.now() / 1000);
    const jwt = await signJwtHs256({
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
    }, jwtSecret);

    const sessionPayload = {
      token: jwt,
      member_id: memberId,
      store: storeCode,
      line_user_id: lineUserId,
      line_name:    payload.name    ?? null,
      line_picture: payload.picture ?? null,
    };

    // 若帶了 pair_code（PWA 主動觸發 LIFF 登入流程），把 session 寫進 pwa_auth_codes
    // 讓 PWA 切回桌面後可以用該 code claim 拿回 session。
    if (pairCode && pairCode.length >= 8 && pairCode.length <= 64) {
      const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();
      const insertResp = await fetch(`${supabaseUrl}/rest/v1/pwa_auth_codes`, {
        method: "POST",
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          "Content-Type": "application/json",
          Prefer: "return=minimal",
        },
        body: JSON.stringify({
          code: pairCode,
          session_data: sessionPayload,
          tenant_id: tenantId,
          expires_at: expiresAt,
        }),
      });
      if (!insertResp.ok) {
        console.error("pwa_auth_codes insert failed", insertResp.status, await insertResp.text());
        // 不擋使用者，繼續回 session 給 LIFF 端
      }
    }

    return json(sessionPayload);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("liff-session error:", msg);
    return json({ error: "failed", detail: msg }, 500);
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

async function touchMemberVisit(supabaseUrl: string, serviceKey: string, memberId: number) {
  try {
    const resp = await fetch(`${supabaseUrl}/rest/v1/rpc/rpc_member_touch_visit`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_member_id: memberId }),
    });
    if (!resp.ok) {
      console.warn("touch_visit failed", resp.status, await resp.text());
    }
  } catch (e) {
    console.warn("touch_visit error", e);
  }
}

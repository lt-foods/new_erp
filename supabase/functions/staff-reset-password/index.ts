// staff-reset-password — 由 owner/admin 幫員工重設登入密碼
//
// 改別人的密碼必須用 service_role（Supabase Auth Admin API），無法做成 client RPC，
// 故沿用 staff-create 的骨架：service_role client + getUser(caller token) 驗身份。
//
// 規則（判斷集中在 _shared/staffPasswordReset.ts，有單元測試）：
//   - caller 必須 owner/admin 且有 tenant_id
//   - 目標用 auth.admin.getUserById 取，app_metadata.tenant_id 必須 = caller tenant
//   - 目標是 owner 時 caller 必須是 owner（admin 不可動 owner）
//   - password ≥ 6 碼（對齊 auth.minimum_password_length）
//   - 回應只回 { ok: true }；回應、log、錯誤訊息都不帶密碼
//
// 只需內建 secret SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY，未新增其他 secret。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
import { checkCaller, checkInput, checkTarget } from "../_shared/staffPasswordReset.ts";

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
    const authHeader = req.headers.get("authorization");
    if (!authHeader) return json({ error: "missing authorization" }, 401);

    const sb = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } },
    );

    const token = authHeader.replace(/^Bearer\s+/i, "");
    const { data: { user: caller }, error: authErr } = await sb.auth.getUser(token);
    if (authErr || !caller) {
      return json({ error: "invalid token", detail: authErr?.message }, 401);
    }

    // 先擋掉店長／店員，不必讀 body、不必查目標
    const c = checkCaller(caller);
    if (!c.ok) return json({ error: c.error }, c.status);

    const input = checkInput(await req.json().catch(() => null));
    if (!input.ok) return json({ error: input.error }, input.status);

    const { data: got, error: getErr } = await sb.auth.admin.getUserById(input.userId);
    // getUserById 找不到時回 error；一律當作「找不到」交給 checkTarget（與跨公司同訊息）
    const target = getErr ? null : (got?.user ?? null);
    const t = checkTarget(caller, target);
    if (!t.ok) return json({ error: t.error }, t.status);

    const { error: updErr } = await sb.auth.admin.updateUserById(input.userId, {
      password: input.password,
    });
    if (updErr) {
      // Auth 回的訊息不含密碼本身（例：弱密碼規則），可直接回給前端
      return json({ error: updErr.message ?? "重設失敗" }, 400);
    }

    return json({ ok: true });
  } catch (e) {
    // 不要 log body / 密碼；只記錯誤型別與訊息
    console.error("staff-reset-password error:", e instanceof Error ? e.message : "unknown");
    return json({ error: "internal" }, 500);
  }
});

// staff-create — 由 owner/admin 建立新員工 auth 帳號
//
// 建立 staff 必須用 service_role（Supabase Auth Admin API），無法做成 client RPC，
// 故沿用 admin-notify 的骨架：service_role client + getUser(caller token) 驗身份。
//
// 規則對齊 rpc_update_staff_role / rpc_update_staff_stores：
//   - caller 必須 owner/admin 且有 tenant_id
//   - admin 不可建立 owner（只有 owner 可以）
//   - 新帳號 tenant_id 強制 = caller tenant（忽略 body 夾帶的 tenant）
//   - stores 名稱必須屬於該 tenant 或 '總倉' magic value
//   - 'disabled' 不可作為建立角色（停用走既有「停用」流程）
//   - password 選填：有給就用（≥6 碼，對齊 auth.minimum_password_length），
//     留空則系統產生一次性臨時密碼。自訂密碼不回傳（對方已知）。
//
// 只需內建 secret SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY，未新增其他 secret。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";

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

// 對齊 public._is_valid_staff_role，但刻意排除 'disabled'
const VALID_ROLES = [
  "owner", "admin", "hq_manager", "hq_accountant",
  "purchaser", "assistant", "store_manager", "store_staff",
];

const HQ_WAREHOUSE = "總倉";

function genTempPassword(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  const b64 = btoa(s).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  // 前綴確保含大小寫與符號，滿足常見密碼規則；亂度由 16 bytes 提供
  return `Lt-${b64}`;
}

function isEmail(s: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
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

    const callerRole = (caller.app_metadata?.role as string | undefined) ?? "";
    const tenantId = caller.app_metadata?.tenant_id as string | undefined;
    if (!tenantId) return json({ error: "caller has no tenant_id" }, 403);
    if (callerRole !== "owner" && callerRole !== "admin") {
      return json({ error: "permission denied: requires owner/admin role" }, 403);
    }

    const body = (await req.json().catch(() => null)) as
      | { email?: unknown; display_name?: unknown; role?: unknown; stores?: unknown; password?: unknown }
      | null;
    if (!body) return json({ error: "invalid json body" }, 400);

    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    const displayName = typeof body.display_name === "string" ? body.display_name.trim() : "";
    const role = typeof body.role === "string" ? body.role : "";
    const stores = Array.isArray(body.stores)
      ? body.stores
          .filter((x): x is string => typeof x === "string")
          .map((x) => x.trim())
          .filter(Boolean)
      : [];
    // 不 trim 密碼（前後空白可能是刻意的）；空字串視為「未提供」→ 自動產生
    const customPw = typeof body.password === "string" ? body.password : "";

    if (!email || !isEmail(email)) return json({ error: "invalid email" }, 400);
    if (!displayName) return json({ error: "display_name required" }, 400);
    if (!VALID_ROLES.includes(role)) return json({ error: `invalid role: ${role}` }, 422);
    if (role === "owner" && callerRole !== "owner") {
      return json({ error: "admin cannot create owner" }, 403);
    }
    if (customPw.length > 0 && customPw.length < 6) {
      return json({ error: "密碼至少 6 碼" }, 422);
    }

    // store 名稱驗證：每個非「總倉」名稱必須存在於 caller tenant 的 stores
    const nonMagic = stores.filter((n) => n !== HQ_WAREHOUSE);
    if (nonMagic.length > 0) {
      const { data: storeRows, error: storeErr } = await sb
        .from("stores")
        .select("name")
        .eq("tenant_id", tenantId)
        .in("name", nonMagic);
      if (storeErr) return json({ error: storeErr.message }, 500);
      const known = new Set((storeRows ?? []).map((r: { name: string }) => r.name));
      const invalid = nonMagic.filter((n) => !known.has(n));
      if (invalid.length > 0) {
        return json({ error: `store not in tenant: ${invalid.join(", ")}` }, 422);
      }
    }

    const pwSource = customPw.length > 0 ? "admin" : "generated";
    const password = customPw.length > 0 ? customPw : genTempPassword();
    const { data: created, error: createErr } = await sb.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { display_name: displayName },
      app_metadata: { tenant_id: tenantId, role, stores },
    });

    if (createErr) {
      const msg = createErr.message ?? String(createErr);
      const code = (createErr as { code?: string }).code ?? "";
      if (code === "email_exists" || /already.*regist|already.*exist|duplicate/i.test(msg)) {
        return json({ error: "此 Email 已有帳號", detail: msg }, 409);
      }
      return json({ error: msg }, 400);
    }

    return json({
      ok: true,
      user_id: created.user?.id,
      email: created.user?.email,
      password_source: pwSource,
      // 自動產生才回傳密碼；admin 自訂的不回傳（對方已知、不必反射 secret）
      ...(pwSource === "generated" ? { temp_password: password } : {}),
    });
  } catch (e) {
    // 不要 log body / 密碼
    console.error("staff-create error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

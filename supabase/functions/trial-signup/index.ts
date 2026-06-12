// trial-signup — 試用租戶自助註冊（公開端點，SaaS 化 Phase 1）
//
// 流程（docs/PLAN-試用租戶註冊.md §3）：
//   1. 輸入驗證 + rate limit（trial_signup_attempts：同 email 7 天 1 次、同 IP 24h 3 次）
//   2. 建 tenants row（status='trial'，試用 TRIAL_DAYS 天、預設 14）
//   3. anon signUp（讓 Supabase Auth 寄驗證信；驗完才能登入）
//   4. admin.updateUserById 設 app_metadata { tenant_id, role:'owner', stores:[] }
//      — custom_access_token_hook 在「登入簽 token 時」才讀 app_metadata，
//        所以「先 signUp、後補 metadata」沒有 race：用戶要先收信驗證才登得進來。
//   5. rpc_seed_trial_tenant：總倉 + 示範門市 + 預設會員等級
//   任一步失敗 → 反向清理（刪 user、刪 tenant row），不留半套。
//
// 骨架沿用 staff-create（service_role client + json helper），但本端點公開、
// 不驗 caller JWT（config.toml verify_jwt=false）。
// 只用內建 secret SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY；
// 選用 env：TRIAL_DAYS（預設 14）。

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

function isEmail(s: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
}

const EMAIL_COOLDOWN_DAYS = 7; // 同 email 幾天內只能註冊 1 次
const IP_LIMIT_24H = 3; //        同 IP 24 小時內最多幾次

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  // 反向清理用：哪一步成功了就記下來
  let createdTenantId: string | null = null;
  let createdUserId: string | null = null;

  const sb = createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { persistSession: false } },
  );

  try {
    const body = (await req.json().catch(() => null)) as
      | { company_name?: unknown; owner_name?: unknown; email?: unknown; password?: unknown }
      | null;
    if (!body) return json({ error: "invalid json body" }, 400);

    const companyName = typeof body.company_name === "string" ? body.company_name.trim() : "";
    const ownerName = typeof body.owner_name === "string" ? body.owner_name.trim() : "";
    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    // 不 trim 密碼（對齊 staff-create）
    const password = typeof body.password === "string" ? body.password : "";

    if (!companyName) return json({ error: "請填寫商家名稱" }, 400);
    if (companyName.length > 50) return json({ error: "商家名稱過長（≤50 字）" }, 422);
    if (!ownerName) return json({ error: "請填寫姓名" }, 400);
    if (!email || !isEmail(email)) return json({ error: "Email 格式不正確" }, 400);
    // 公開註冊比 staff-create（6 碼）嚴：8 碼起跳
    if (password.length < 8) return json({ error: "密碼至少 8 碼" }, 422);

    // ── rate limit ──────────────────────────────────────────
    const ip =
      req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || null;

    const emailSince = new Date(Date.now() - EMAIL_COOLDOWN_DAYS * 86400_000).toISOString();
    const { count: emailCount, error: emailRlErr } = await sb
      .from("trial_signup_attempts")
      .select("id", { count: "exact", head: true })
      .eq("email", email)
      .gte("created_at", emailSince);
    if (emailRlErr) return json({ error: emailRlErr.message }, 500);
    if ((emailCount ?? 0) >= 1) {
      return json({ error: `此 Email 在 ${EMAIL_COOLDOWN_DAYS} 天內已申請過試用` }, 429);
    }

    if (ip) {
      const ipSince = new Date(Date.now() - 86400_000).toISOString();
      const { count: ipCount, error: ipRlErr } = await sb
        .from("trial_signup_attempts")
        .select("id", { count: "exact", head: true })
        .eq("ip", ip)
        .gte("created_at", ipSince);
      if (ipRlErr) return json({ error: ipRlErr.message }, 500);
      if ((ipCount ?? 0) >= IP_LIMIT_24H) {
        return json({ error: "申請過於頻繁，請 24 小時後再試" }, 429);
      }
    }

    // 通過驗證與 rate limit 才記一筆（避免亂打格式錯誤就吃掉額度）
    const { error: attemptErr } = await sb
      .from("trial_signup_attempts")
      .insert({ email, ip });
    if (attemptErr) return json({ error: attemptErr.message }, 500);

    // ── 1. 建 tenant ────────────────────────────────────────
    const trialDays = Number(Deno.env.get("TRIAL_DAYS") ?? "14") || 14;
    const now = new Date();
    const expires = new Date(now.getTime() + trialDays * 86400_000);
    const { data: tenant, error: tenantErr } = await sb
      .from("tenants")
      .insert({
        name: companyName,
        status: "trial",
        trial_started_at: now.toISOString(),
        trial_expires_at: expires.toISOString(),
        contact_email: email,
      })
      .select("id")
      .single();
    if (tenantErr) return json({ error: tenantErr.message }, 500);
    createdTenantId = tenant.id as string;

    // ── 2. signUp（anon client → Supabase Auth 寄驗證信）────
    const anon = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
      auth: { persistSession: false },
    });
    const origin = req.headers.get("origin");
    const { data: signUpData, error: signUpErr } = await anon.auth.signUp({
      email,
      password,
      options: {
        data: { display_name: ownerName },
        // GoTrue 會對照 redirect allowlist，不在名單就 fallback Site URL
        ...(origin ? { emailRedirectTo: `${origin}/login` } : {}),
      },
    });
    if (signUpErr) {
      throw new Error(`signUp failed: ${signUpErr.message}`);
    }
    // email 已存在時 signUp 不報錯，回一個 identities 為空的假 user（防 enumeration）
    const newUser = signUpData.user;
    if (!newUser || (Array.isArray(newUser.identities) && newUser.identities.length === 0)) {
      // 不是我們建的 user，不能清掉；只回收 tenant row
      await sb.from("tenants").delete().eq("id", createdTenantId);
      createdTenantId = null;
      return json({ error: "此 Email 已有帳號，請直接登入" }, 409);
    }
    createdUserId = newUser.id;

    // ── 3. 設 app_metadata（tenant + owner 角色）────────────
    const { error: metaErr } = await sb.auth.admin.updateUserById(createdUserId, {
      app_metadata: { tenant_id: createdTenantId, role: "owner", stores: [] },
    });
    if (metaErr) throw new Error(`set app_metadata failed: ${metaErr.message}`);

    // ── 4. seed 基礎資料 ────────────────────────────────────
    const { error: seedErr } = await sb.rpc("rpc_seed_trial_tenant", {
      p_tenant_id: createdTenantId,
    });
    if (seedErr) throw new Error(`seed failed: ${seedErr.message}`);

    return json({
      ok: true,
      tenant_id: createdTenantId,
      trial_expires_at: expires.toISOString(),
      need_email_confirm: true,
    });
  } catch (e) {
    // 反向清理：不留半套帳號
    try {
      if (createdUserId) await sb.auth.admin.deleteUser(createdUserId);
      if (createdTenantId) await sb.from("tenants").delete().eq("id", createdTenantId);
    } catch (cleanupErr) {
      console.error("trial-signup cleanup failed:", cleanupErr);
    }
    console.error("trial-signup error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

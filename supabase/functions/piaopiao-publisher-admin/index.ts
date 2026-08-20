import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
import { normalizePiaopiaoLoginId, piaopiaoLoginEmail } from "../_shared/piaopiaoPublisherAccount.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const sb = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
    const caller = await requireAdmin(sb, req);
    const body = await req.json() as Record<string, unknown>;
    if (body.action === "create") return await createPublisher(sb, caller, body);
    if (body.action === "reset_password") return await resetPassword(sb, caller, body);
    if (body.action === "set_active") return await setActive(sb, caller, body);
    return json({ error: "unknown action" }, 400);
  } catch (e) {
    console.error("piaopiao-publisher-admin", e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});

async function requireAdmin(sb: any, req: Request) {
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) throw new Error("請先登入總部後台");
  const { data: { user }, error } = await sb.auth.getUser(token);
  const role = user?.app_metadata?.role;
  const tenantId = user?.app_metadata?.tenant_id;
  if (error || !user || !tenantId || (role !== "owner" && role !== "admin")) throw new Error("只有總部管理員可管理上架帳號");
  return { userId: user.id, tenantId: String(tenantId) };
}

async function createPublisher(sb: any, caller: { userId: string; tenantId: string }, body: Record<string, unknown>) {
  const loginId = normalizePiaopiaoLoginId(body.login_id);
  const displayName = typeof body.display_name === "string" ? body.display_name.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const lane = body.lane === "tong" || body.lane === "chao" ? body.lane : null;
  if (!loginId || !displayName || !lane) throw new Error("請填帳號、顯示名稱與分線");
  if (password.length < 10) throw new Error("密碼至少 10 碼");
  const { data: created, error: createError } = await sb.auth.admin.createUser({
    email: piaopiaoLoginEmail(loginId), password, email_confirm: true,
    user_metadata: { display_name: displayName },
    // 刻意不給 tenant_id：這不是 ERP 帳號，不能讀既有 ERP 資料。
    app_metadata: { role: "piaopiao_publisher" },
  });
  if (createError || !created.user) throw new Error(createError?.message ?? "建立帳號失敗");
  const { data: publisher, error: insertError } = await sb.from("piaopiao_publishers").insert({
    tenant_id: caller.tenantId, auth_user_id: created.user.id, login_id: loginId,
    display_name: displayName, lane, created_by: caller.userId, updated_by: caller.userId,
  }).select("id, login_id, display_name, lane, is_active").single();
  if (insertError) {
    await sb.auth.admin.deleteUser(created.user.id);
    throw new Error(insertError.message);
  }
  return json({ publisher });
}

async function resetPassword(sb: any, caller: { tenantId: string }, body: Record<string, unknown>) {
  const publisherId = Number(body.publisher_id);
  const password = typeof body.password === "string" ? body.password : "";
  if (!Number.isInteger(publisherId) || publisherId <= 0 || password.length < 10) throw new Error("請輸入至少 10 碼的新密碼");
  const { data: publisher, error } = await sb.from("piaopiao_publishers")
    .select("auth_user_id").eq("id", publisherId).eq("tenant_id", caller.tenantId).maybeSingle();
  if (error || !publisher) throw new Error("找不到上架帳號");
  const { error: updateError } = await sb.auth.admin.updateUserById(publisher.auth_user_id, { password });
  if (updateError) throw new Error(updateError.message);
  return json({ ok: true });
}

async function setActive(sb: any, caller: { userId: string; tenantId: string }, body: Record<string, unknown>) {
  const publisherId = Number(body.publisher_id);
  const isActive = body.is_active === true;
  if (!Number.isInteger(publisherId) || publisherId <= 0 || typeof body.is_active !== "boolean") throw new Error("上架帳號資料錯誤");
  const { data: publisher, error } = await sb.from("piaopiao_publishers")
    .select("auth_user_id, is_active").eq("id", publisherId).eq("tenant_id", caller.tenantId).maybeSingle();
  if (error || !publisher) throw new Error("找不到上架帳號");
  const { error: rowError } = await sb.from("piaopiao_publishers").update({ is_active: isActive, updated_by: caller.userId, updated_at: new Date().toISOString() }).eq("id", publisherId);
  if (rowError) throw new Error(rowError.message);
  const { error: authError } = await sb.auth.admin.updateUserById(publisher.auth_user_id, { ban_duration: isActive ? "none" : "876000h" });
  if (authError) {
    await sb.from("piaopiao_publishers").update({ is_active: publisher.is_active, updated_by: caller.userId, updated_at: new Date().toISOString() }).eq("id", publisherId);
    throw new Error(authError.message);
  }
  return json({ ok: true });
}

function requireEnv(name: string) { const value = Deno.env.get(name); if (!value) throw new Error(`missing env ${name}`); return value; }
function json(body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }

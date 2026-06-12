// tenant-purge — 一鍵刪除整個試用租戶（SaaS 化 Phase 3）
//
// 兩種合法 caller（docs/PLAN-試用租戶註冊.md §5.2）：
//   1. 試用者本人：Authorization Bearer = 該租戶 owner 的 JWT，只能刪自己的租戶
//      （tenant_id 一律取自 caller app_metadata，忽略 body 夾帶）
//   2. 平台管理者：x-platform-admin-secret header = env PLATFORM_ADMIN_SECRET，
//      tenant_id 由 body 指定（清垃圾註冊用）
//
// 防呆：body.confirm_name 必須與 tenants.name 完全一致（仿 GitHub 刪 repo）。
// 防線：rpc_purge_tenant 內建 is_protected / status 雙保險，這裡擋了也擋。
//
// 執行順序：
//   1. 驗 caller + 守門
//   2. rpc_purge_tenant（DB 整包單一 transaction；回傳該租戶 auth user ids）
//   3. Auth Admin API 逐一刪 auth.users
//   4. Storage 按 {tenant_id}/ prefix 清 products / member-avatars bucket
//   3、4 失敗不 rollback DB（已 purge 完成），記 log 由平台後續清 — 殘留的是
//   無主帳號與圖片檔，不是業務資料。
//
// secrets：內建 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY；
// 選用 PLATFORM_ADMIN_SECRET（沒設就只開放本人自刪）。

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

const PURGE_BUCKETS = ["products", "member-avatars"];

async function purgeStoragePrefix(
  sb: ReturnType<typeof createClient>,
  bucket: string,
  prefix: string,
): Promise<number> {
  let removed = 0;
  // list 一批刪一批，直到清空（單層；目前路徑慣例是 {tenant_id}/{uuid}.{ext} 單層）
  for (;;) {
    const { data: files, error } = await sb.storage.from(bucket).list(prefix, { limit: 100 });
    if (error || !files || files.length === 0) break;
    const paths = files.map((f) => `${prefix}/${f.name}`);
    const { error: rmErr } = await sb.storage.from(bucket).remove(paths);
    if (rmErr) break; // best-effort：殘留檔案記在回傳值給平台追
    removed += paths.length;
    if (files.length < 100) break;
  }
  return removed;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const sb = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } },
    );

    const body = (await req.json().catch(() => null)) as
      | { tenant_id?: unknown; confirm_name?: unknown }
      | null;
    if (!body) return json({ error: "invalid json body" }, 400);
    const confirmName = typeof body.confirm_name === "string" ? body.confirm_name : "";

    // ── 驗 caller，決定目標 tenant ────────────────────────────
    let targetTenantId: string;
    let requestedBy: string;

    const platformSecret = Deno.env.get("PLATFORM_ADMIN_SECRET");
    const givenSecret = req.headers.get("x-platform-admin-secret");

    if (platformSecret && givenSecret) {
      if (givenSecret !== platformSecret) {
        return json({ error: "invalid platform secret" }, 403);
      }
      const bodyTenantId = typeof body.tenant_id === "string" ? body.tenant_id : "";
      if (!bodyTenantId) return json({ error: "tenant_id required" }, 400);
      targetTenantId = bodyTenantId;
      requestedBy = "platform";
    } else {
      const authHeader = req.headers.get("authorization");
      if (!authHeader) return json({ error: "missing authorization" }, 401);
      const token = authHeader.replace(/^Bearer\s+/i, "");
      const { data: { user: caller }, error: authErr } = await sb.auth.getUser(token);
      if (authErr || !caller) {
        return json({ error: "invalid token", detail: authErr?.message }, 401);
      }
      const callerRole = (caller.app_metadata?.role as string | undefined) ?? "";
      const callerTenant = caller.app_metadata?.tenant_id as string | undefined;
      if (!callerTenant) return json({ error: "caller has no tenant_id" }, 403);
      if (callerRole !== "owner") {
        return json({ error: "permission denied: 只有負責人可以刪除租戶資料" }, 403);
      }
      // 本人只能刪自己；body.tenant_id 一律忽略
      targetTenantId = callerTenant;
      requestedBy = `self:${caller.id}`;
    }

    // ── 守門（rpc 內還有一層，這裡先給可讀錯誤）──────────────
    const { data: tenant, error: tErr } = await sb
      .from("tenants")
      .select("id, name, status, is_protected")
      .eq("id", targetTenantId)
      .single();
    if (tErr || !tenant) return json({ error: "tenant not found" }, 404);
    if (tenant.is_protected) return json({ error: "此租戶受保護，不可刪除" }, 403);
    if (!["trial", "suspended"].includes(tenant.status as string)) {
      return json({ error: `只能刪除試用租戶（目前狀態：${tenant.status}）` }, 422);
    }
    if (confirmName !== tenant.name) {
      return json({ error: "確認名稱不符，請輸入完整商家名稱" }, 422);
    }

    // ── 1. DB purge（單一 transaction）──────────────────────
    const { data: purgeResult, error: purgeErr } = await sb.rpc("rpc_purge_tenant", {
      p_tenant_id: targetTenantId,
      p_requested_by: requestedBy,
    });
    if (purgeErr) return json({ error: purgeErr.message }, 500);
    const result = purgeResult as { tables: Record<string, number>; auth_user_ids: string[] };

    // ── 2. auth.users（best-effort）──────────────────────────
    const failedUsers: string[] = [];
    for (const uid of result.auth_user_ids ?? []) {
      const { error: delErr } = await sb.auth.admin.deleteUser(uid);
      if (delErr) failedUsers.push(uid);
    }

    // ── 3. storage（best-effort）─────────────────────────────
    const storageRemoved: Record<string, number> = {};
    for (const bucket of PURGE_BUCKETS) {
      storageRemoved[bucket] = await purgeStoragePrefix(sb, bucket, targetTenantId);
    }

    return json({
      ok: true,
      tenant_id: targetTenantId,
      tables: result.tables,
      auth_users_deleted: (result.auth_user_ids?.length ?? 0) - failedUsers.length,
      auth_users_failed: failedUsers,
      storage_removed: storageRemoved,
    });
  } catch (e) {
    console.error("tenant-purge error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

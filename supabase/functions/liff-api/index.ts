// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: liff-api
// 取代客戶端直接 call PostgREST rpc_liff_*
// 原因：Supabase 已切 ECC P-256 簽章，我們自簽的 HS256 JWT 會被拒；
//       改成 Edge Function 驗我們自己的 JWT、用 service_role 繞過 PostgREST。
//
// 路由（靠 body.action 分流）：
//   POST /functions/v1/liff-api  { action: "lookup_by_phone", phone }
//   POST /functions/v1/liff-api  { action: "register_and_bind", phone, name, birthday }
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
import { verifyJwtHs256 } from "../_shared/jwt.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  try {
    // ── auth ──
    const auth = req.headers.get("authorization");
    if (!auth) return json({ error: "missing authorization" }, 401);
    const token = auth.replace(/^Bearer\s+/i, "");
    const jwtSecret = requireEnv("PROJECT_JWT_SECRET");
    let claims;
    try {
      claims = await verifyJwtHs256(token, jwtSecret);
    } catch (e) {
      return json({ error: "invalid token", detail: String(e) }, 401);
    }

    const tenantId   = String(claims.tenant_id  ?? "");
    const storeId    = Number(claims.store_id   ?? 0);
    const lineUserId = String(claims.line_user_id ?? "");
    if (!tenantId || !storeId || !lineUserId) {
      return json({ error: "missing claims in token" }, 401);
    }

    // ── body ──
    const body = await req.json() as Record<string, unknown>;
    const action = String(body.action ?? "");

    // ── service role client ──
    const sb = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    const memberId = claims.member_id ? Number(claims.member_id) : null;

    // ── dispatch ──
    switch (action) {
      case "lookup_by_phone":
        return await lookupByPhone(sb, tenantId, String(body.phone ?? ""));
      case "register_and_bind":
        return await registerAndBind(sb, {
          tenantId,
          storeId,
          lineUserId,
          phone:    String(body.phone ?? ""),
          name:     String(body.name  ?? ""),
          birthday: String(body.birthday ?? ""),
        });
      case "get_me":
        if (!memberId) return json({ error: "no member_id in token" }, 401);
        return await getMe(sb, tenantId, memberId);
      case "update_me":
        if (!memberId) return json({ error: "no member_id in token" }, 401);
        return await updateMe(sb, tenantId, memberId, {
          phone:    body.phone    as string | undefined,
          name:     body.name     as string | undefined,
          birthday: body.birthday as string | undefined,
          email:    body.email    as string | undefined,
        });
      case "get_overview":
        if (!memberId) return json({ error: "no member_id in token" }, 401);
        return await getOverview(sb, tenantId, storeId, memberId);
      case "list_my_orders":
        if (!memberId) return json({ error: "no member_id in token" }, 401);
        return await listMyOrders(sb, tenantId, storeId, memberId, String(body.tab ?? ""));
      case "list_my_settlements":
        if (!memberId) return json({ error: "no member_id in token" }, 401);
        return await listMySettlements(sb, tenantId, storeId, memberId, String(body.tab ?? ""));
      default:
        return json({ error: `unknown action: ${action}` }, 400);
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("liff-api error:", msg);
    return json({ error: "internal", detail: msg }, 500);
  }
});

// ─── actions ─────────────────────────────────────────────────────────────────

async function lookupByPhone(
  sb: ReturnType<typeof createClient>,
  tenantId: string,
  phone: string,
) {
  if (!phone.trim()) return json({ error: "phone required" }, 400);

  // SHA256 hash
  const hash = await sha256Hex(phone.trim());

  const { data, error } = await sb
    .from("members")
    .select("id, member_no, name, home_store_id")
    .eq("tenant_id", tenantId)
    .eq("phone_hash", hash)
    .not("status", "in", "(deleted,merged)")
    .limit(1);

  if (error) return json({ error: error.message }, 500);
  if (!data || data.length === 0) return json({ match: null });

  const row = data[0] as {
    id: number;
    member_no: string;
    name: string | null;
    home_store_id: number | null;
  };

  // 取 home_store_name
  let homeStoreName: string | null = null;
  if (row.home_store_id) {
    const { data: s } = await sb
      .from("stores")
      .select("name")
      .eq("id", row.home_store_id)
      .single();
    homeStoreName = (s as { name?: string } | null)?.name ?? null;
  }

  return json({
    match: {
      member_id:       row.id,
      member_no:       row.member_no,
      name_masked:     maskName(row.name),
      home_store_name: homeStoreName,
    },
  });
}

async function registerAndBind(
  sb: ReturnType<typeof createClient>,
  p: {
    tenantId: string;
    storeId: number;
    lineUserId: string;
    phone: string;
    name: string;
    birthday: string;
  },
) {
  if (!p.phone.trim())    return json({ error: "phone required" }, 400);

  // 驗 store
  const { data: store } = await sb
    .from("stores")
    .select("id")
    .eq("id", p.storeId)
    .eq("tenant_id", p.tenantId)
    .single();
  if (!store) return json({ error: "store not in tenant" }, 400);

  const phoneHash = await sha256Hex(p.phone.trim());

  // 查既有會員
  const { data: existing } = await sb
    .from("members")
    .select("id")
    .eq("tenant_id", p.tenantId)
    .eq("phone_hash", phoneHash)
    .not("status", "in", "(deleted,merged)")
    .limit(1);

  let memberId: number;
  let isNewMember = false;

  if (existing && existing.length > 0) {
    memberId = (existing[0] as { id: number }).id;
  } else {
    // 新建（需要 name + birthday）
    if (!p.name.trim())    return json({ error: "name required" }, 400);
    if (!p.birthday.trim()) return json({ error: "birthday required" }, 400);

    const now = new Date();
    const pad = (n: number, w = 2) => String(n).padStart(w, "0");
    const memberNo = `M${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}${pad(Math.floor(Math.random() * 1000), 3)}`;

    const birthMd = p.birthday.slice(5, 10); // "YYYY-MM-DD" → "MM-DD"

    const { data: inserted, error: insertErr } = await sb
      .from("members")
      .insert({
        tenant_id:     p.tenantId,
        member_no:     memberNo,
        phone_hash:    phoneHash,
        phone:         p.phone.trim(),
        name:          p.name.trim(),
        birthday:      p.birthday,
        birth_md:      birthMd,
        home_store_id: p.storeId,
        status:        "active",
      })
      .select("id")
      .single();

    if (insertErr || !inserted) {
      return json({ error: "insert member failed", detail: insertErr?.message }, 500);
    }
    memberId = (inserted as { id: number }).id;
    isNewMember = true;
  }

  // INSERT binding（衝突 = 已綁）
  let wasBound = false;
  const { error: bindErr } = await sb
    .from("member_line_bindings")
    .insert({
      tenant_id:    p.tenantId,
      store_id:     p.storeId,
      member_id:    memberId,
      line_user_id: p.lineUserId,
    });

  if (bindErr) {
    // duplicate key = 已綁
    if (bindErr.code === "23505") {
      wasBound = true;
    } else {
      return json({ error: "insert binding failed", detail: bindErr.message }, 500);
    }
  }

  return json({
    member_id:      memberId,
    is_new_member:  isNewMember,
    was_bound:      wasBound,
  });
}

async function getMe(
  sb: ReturnType<typeof createClient>,
  tenantId: string,
  memberId: number,
) {
  const { data, error } = await sb
    .from("members")
    .select("id, member_no, name, phone, email, birthday, gender, home_store_id, avatar_url, status")
    .eq("tenant_id", tenantId)
    .eq("id", memberId)
    .single();

  if (error) return json({ error: error.message }, 500);

  const row = data as {
    id: number;
    member_no: string;
    name: string | null;
    phone: string | null;
    email: string | null;
    birthday: string | null;
    gender: string | null;
    home_store_id: number | null;
    avatar_url: string | null;
    status: string;
  };

  return json({
    member_id:     row.id,
    member_no:     row.member_no,
    name:          row.name,
    phone:         row.phone?.startsWith("line:") ? null : row.phone,  // 隱藏 placeholder
    email:         row.email,
    birthday:      row.birthday,
    gender:        row.gender,
    home_store_id: row.home_store_id,
    avatar_url:    row.avatar_url,
    status:        row.status,
  });
}

async function updateMe(
  sb: ReturnType<typeof createClient>,
  tenantId: string,
  memberId: number,
  p: {
    phone?:    string;
    name?:     string;
    birthday?: string;
    email?:    string;
  },
) {
  // 組更新內容、空值不動
  const patch: Record<string, unknown> = {};

  if (p.name !== undefined) {
    const n = p.name.trim();
    if (!n) return json({ error: "name cannot be empty" }, 400);
    patch.name = n;
  }

  if (p.phone !== undefined) {
    const ph = p.phone.trim();
    if (ph) {
      // 檢查格式（台灣手機：09 開頭 10 位）
      if (!/^09\d{8}$/.test(ph)) {
        return json({ error: "phone format invalid，台灣手機請用 09xxxxxxxx" }, 400);
      }
      const newHash = await sha256Hex(ph);
      // 檢查 phone_hash unique（同 tenant 除了自己以外）
      const { data: conflict } = await sb
        .from("members")
        .select("id")
        .eq("tenant_id", tenantId)
        .eq("phone_hash", newHash)
        .neq("id", memberId)
        .limit(1);
      if (conflict && conflict.length > 0) {
        return json({ error: "此手機號已被其他會員使用" }, 409);
      }
      patch.phone = ph;
      patch.phone_hash = newHash;
    }
    // 空白 → 不改（避免誤清）
  }

  if (p.birthday !== undefined) {
    const b = p.birthday.trim();
    if (b) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(b)) {
        return json({ error: "birthday format must be YYYY-MM-DD" }, 400);
      }
      patch.birthday = b;
      patch.birth_md = b.slice(5, 10);
    }
  }

  if (p.email !== undefined) {
    const em = p.email.trim();
    if (em) {
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(em)) {
        return json({ error: "email format invalid" }, 400);
      }
      patch.email = em;
      patch.email_hash = await sha256Hex(em.toLowerCase());
    } else {
      patch.email = null;
      patch.email_hash = null;
    }
  }

  if (Object.keys(patch).length === 0) {
    return json({ error: "nothing to update" }, 400);
  }

  patch.updated_at = new Date().toISOString();

  const { error } = await sb
    .from("members")
    .update(patch)
    .eq("tenant_id", tenantId)
    .eq("id", memberId);

  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
}

// ─── overview / orders / settlements ────────────────────────────────────────

async function getOverview(
  sb: ReturnType<typeof createClient>,
  tenantId: string,
  storeId: number,
  memberId: number,
) {
  // store info
  const { data: storeRow, error: sErr } = await sb
    .from("stores")
    .select("id, code, name, banner_url, description, payment_methods_text, shipping_methods_text")
    .eq("tenant_id", tenantId)
    .eq("id", storeId)
    .single();
  if (sErr || !storeRow) {
    return json({ error: "store not found", detail: sErr?.message }, 404);
  }

  // 未結金額（payment_status='unpaid' AND status NOT IN cancelled/expired）
  const { data: unpaidRows, error: uErr } = await sb
    .from("v_customer_order_summary")
    .select("payable_amount")
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .eq("store_id", storeId)
    .eq("payment_status", "unpaid")
    .not("status", "in", "(cancelled,expired)");
  if (uErr) return json({ error: "receivable query failed", detail: uErr.message }, 500);

  const receivable = (unpaidRows ?? []).reduce(
    (s, r) => s + Number((r as { payable_amount: number }).payable_amount ?? 0),
    0,
  );

  // 進行中訂單數（status NOT IN completed/cancelled/expired）
  const { count: activeCount, error: aErr } = await sb
    .from("v_customer_order_summary")
    .select("*", { count: "exact", head: true })
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .eq("store_id", storeId)
    .not("status", "in", "(completed,cancelled,expired)");
  if (aErr) return json({ error: "active count failed", detail: aErr.message }, 500);

  return json({
    store: storeRow,
    receivable_amount:   receivable,
    active_orders_count: activeCount ?? 0,
  });
}

async function listMyOrders(
  sb: ReturnType<typeof createClient>,
  tenantId: string,
  storeId: number,
  memberId: number,
  tab: string,
) {
  if (tab !== "active" && tab !== "history") {
    return json({ error: "tab must be 'active' or 'history'" }, 400);
  }

  // 6 個月內（PRD-LIFF前端 Q8）
  const cutoff = new Date();
  cutoff.setMonth(cutoff.getMonth() - 6);

  let q = sb
    .from("v_customer_order_summary")
    .select("*")
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .eq("store_id", storeId)
    .gte("created_at", cutoff.toISOString())
    .order("created_at", { ascending: false })
    .limit(100);

  if (tab === "active") {
    q = q.not("status", "in", "(completed,cancelled,expired)");
  } else {
    q = q.eq("status", "completed");
  }

  const { data, error } = await q;
  if (error) return json({ error: error.message }, 500);

  return json({ orders: data ?? [] });
}

async function listMySettlements(
  sb: ReturnType<typeof createClient>,
  tenantId: string,
  storeId: number,
  memberId: number,
  tab: string,
) {
  if (tab !== "unpaid" && tab !== "shipped") {
    return json({ error: "tab must be 'unpaid' or 'shipped'" }, 400);
  }

  const cutoff = new Date();
  cutoff.setMonth(cutoff.getMonth() - 6);

  let q = sb
    .from("v_customer_order_summary")
    .select("*")
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .eq("store_id", storeId)
    .gte("created_at", cutoff.toISOString())
    .order("created_at", { ascending: false })
    .limit(100);

  if (tab === "unpaid") {
    q = q.eq("payment_status", "unpaid").not("status", "in", "(cancelled,expired)");
  } else {
    q = q.in("status", ["shipping", "completed"]);
  }

  const { data, error } = await q;
  if (error) return json({ error: error.message }, 500);

  return json({ settlements: data ?? [] });
}

// ─── helpers ─────────────────────────────────────────────────────────────────

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

async function sha256Hex(s: string): Promise<string> {
  const bytes = new TextEncoder().encode(s);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function maskName(name: string | null): string | null {
  if (!name) return null;
  if (name.length <= 1) return name;
  return name[0] + "*".repeat(name.length - 1);
}

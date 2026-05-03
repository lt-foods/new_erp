import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
import { verifyJwtHs256 } from "../_shared/jwt.ts";
import webpush from "https://esm.sh/web-push@3.6.7";

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

/**
 * 把 storage 內的 path 轉成完整 public URL。
 * 已經是完整 URL(http/https)就原樣回傳。null/空值回 null。
 */
function toPublicUrl(
  supabaseUrl: string,
  bucket: string,
  pathOrUrl: string | null | undefined,
): string | null {
  if (!pathOrUrl) return null;
  if (/^https?:\/\//i.test(pathOrUrl)) return pathOrUrl;
  return `${supabaseUrl}/storage/v1/object/public/${bucket}/${pathOrUrl}`;
}

// ─── actions ─────────────────────────────────────────────────────────────────

async function listStores(sb: any, tenantId: string) {
  const { data, error } = await sb
    .from("stores")
    .select("id, code, name")
    .eq("tenant_id", tenantId)
    .eq("is_active", true)
    .order("code", { ascending: true });
  if (error) return json({ error: error.message }, 500);
  return json({ stores: data ?? [] });
}

async function claimPwaAuthCode(
  sb: any,
  code: string,
) {
  // 接受 6 碼人工驗證碼或 8–64 碼 pairing token（PWA → LIFF 自動配對用）
  if (!code || (code.length !== 6 && (code.length < 8 || code.length > 64))) {
    return json({ error: "invalid code format" }, 400);
  }
  const { data: row, error: fetchErr } = await sb
    .from("pwa_auth_codes")
    .select("*")
    .eq("code", code)
    .gt("expires_at", new Date().toISOString())
    .single();

  if (fetchErr || !row) {
    return json({ error: "code invalid or expired" }, 404);
  }
  await sb.from("pwa_auth_codes").delete().eq("id", row.id);
  return json(row.session_data);
}

async function lookupByPhone(sb: any, tenantId: string, phone: string) {
  if (!phone.trim()) return json({ error: "phone required" }, 400);
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
  const row = data[0];
  let homeStoreName: string | null = null;
  if (row.home_store_id) {
    const { data: s } = await sb.from("stores").select("name").eq("id", row.home_store_id).single();
    homeStoreName = s?.name ?? null;
  }
  return json({
    match: {
      member_id: row.id,
      member_no: row.member_no,
      name_masked: maskName(row.name),
      home_store_name: homeStoreName,
    },
  });
}

async function registerAndBind(sb: any, p: any) {
  if (!p.phone.trim()) return json({ error: "phone required" }, 400);
  const { data: store } = await sb.from("stores").select("id").eq("id", p.storeId).eq("tenant_id", p.tenantId).single();
  if (!store) return json({ error: "store not in tenant" }, 400);
  const phoneHash = await sha256Hex(p.phone.trim());
  const { data: existing } = await sb.from("members").select("id").eq("tenant_id", p.tenantId).eq("phone_hash", phoneHash).not("status", "in", "(deleted,merged)").limit(1);
  let memberId: number;
  let isNewMember = false;
  if (existing && existing.length > 0) {
    memberId = existing[0].id;
  } else {
    if (!p.name.trim()) return json({ error: "name required" }, 400);
    if (!p.birthday.trim()) return json({ error: "birthday required" }, 400);
    const now = new Date();
    const pad = (n: number, w = 2) => String(n).padStart(w, "0");
    const memberNo = `M${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}${pad(Math.floor(Math.random() * 1000), 3)}`;
    const { data: inserted, error: insertErr } = await sb.from("members").insert({
        tenant_id: p.tenantId,
        member_no: memberNo,
        phone_hash: phoneHash,
        phone: p.phone.trim(),
        name: p.name.trim(),
        birthday: p.birthday,
        birth_md: p.birthday.slice(5, 10),
        home_store_id: p.storeId,
        status: "active",
      }).select("id").single();
    if (insertErr || !inserted) return json({ error: "insert member failed", detail: insertErr?.message }, 500);
    memberId = inserted.id;
    isNewMember = true;
  }
  let wasBound = false;
  const { error: bindErr } = await sb.from("member_line_bindings").insert({
      tenant_id: p.tenantId,
      store_id: p.storeId,
      member_id: memberId,
      line_user_id: p.lineUserId,
    });
  if (bindErr && bindErr.code === "23505") wasBound = true;
  else if (bindErr) return json({ error: "insert binding failed", detail: bindErr.message }, 500);
  return json({ member_id: memberId, is_new_member: isNewMember, was_bound: wasBound });
}

async function getMe(sb: any, tenantId: string, memberId: number) {
  const { data, error } = await sb.from("members").select("id, member_no, name, phone, email, birthday, gender, home_store_id, avatar_url, status").eq("tenant_id", tenantId).eq("id", memberId).single();
  if (error) return json({ error: error.message }, 500);
  return json({
    ...data,
    member_id: data.id,
    phone: data.phone?.startsWith("line:") ? null : data.phone,
  });
}

async function updateMe(sb: any, tenantId: string, memberId: number, p: any) {
  const patch: any = {};
  if (p.name !== undefined) {
    const n = p.name.trim();
    if (!n) return json({ error: "name cannot be empty" }, 400);
    patch.name = n;
  }
  if (p.phone !== undefined) {
    const ph = p.phone.trim();
    if (ph) {
      if (!/^09\d{8}$/.test(ph)) return json({ error: "phone format invalid" }, 400);
      const newHash = await sha256Hex(ph);
      const { data: conflict } = await sb.from("members").select("id").eq("tenant_id", tenantId).eq("phone_hash", newHash).neq("id", memberId).limit(1);
      if (conflict && conflict.length > 0) return json({ error: "此手機號已被其他會員使用" }, 409);
      patch.phone = ph;
      patch.phone_hash = newHash;
    }
  }
  if (p.birthday !== undefined) {
    const b = p.birthday.trim();
    if (b) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(b)) return json({ error: "birthday format invalid" }, 400);
      patch.birthday = b;
      patch.birth_md = b.slice(5, 10);
    }
  }
  if (p.email !== undefined) {
    const em = p.email.trim();
    if (em) {
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(em)) return json({ error: "email format invalid" }, 400);
      patch.email = em;
      patch.email_hash = await sha256Hex(em.toLowerCase());
    } else {
      patch.email = null;
      patch.email_hash = null;
    }
  }
  if (Object.keys(patch).length === 0) return json({ error: "nothing to update" }, 400);
  patch.updated_at = new Date().toISOString();
  const { error } = await sb.from("members").update(patch).eq("tenant_id", tenantId).eq("id", memberId);
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
}

async function getOverview(sb: any, tenantId: string, storeId: number, memberId: number) {
  const { data: storeRow, error: sErr } = await sb.from("stores").select("id, code, name, banner_url, description, payment_methods_text, shipping_methods_text").eq("tenant_id", tenantId).eq("id", storeId).single();
  if (sErr || !storeRow) return json({ error: "store not found" }, 404);
  storeRow.banner_url = toPublicUrl(requireEnv("SUPABASE_URL"), "products", storeRow.banner_url);
  const { data: unpaidRows } = await sb.from("v_customer_order_summary").select("payable_amount").eq("tenant_id", tenantId).eq("member_id", memberId).eq("store_id", storeId).eq("payment_status", "unpaid").not("status", "in", "(cancelled,expired)");
  const receivable = (unpaidRows ?? []).reduce((s: number, r: any) => s + Number(r.payable_amount ?? 0), 0);
  const { count: activeCount } = await sb.from("v_customer_order_summary").select("*", { count: "exact", head: true }).eq("tenant_id", tenantId).eq("member_id", memberId).eq("store_id", storeId).not("status", "in", "(completed,cancelled,expired)");
  return json({ store: storeRow, receivable_amount: receivable, active_orders_count: activeCount ?? 0 });
}

async function listMyOrders(sb: any, tenantId: string, storeId: number, memberId: number, tab: string) {
  const cutoff = new Date(); cutoff.setMonth(cutoff.getMonth() - 6);
  let q = sb.from("v_customer_order_summary").select("*").eq("tenant_id", tenantId).eq("member_id", memberId).eq("store_id", storeId).gte("created_at", cutoff.toISOString()).order("created_at", { ascending: false }).limit(100);
  if (tab === "active") q = q.not("status", "in", "(completed,cancelled,expired)");
  else q = q.eq("status", "completed");
  const { data, error } = await q;
  if (error) return json({ error: error.message }, 500);

  // 把 items.image_url + campaign_cover_url 轉成 storage public URL
  const supabaseUrl = requireEnv("SUPABASE_URL");
  const orders = (data ?? []).map((o: any) => ({
    ...o,
    campaign_cover_url: toPublicUrl(supabaseUrl, "products", o.campaign_cover_url),
    items: (o.items ?? []).map((it: any) => ({
      ...it,
      image_url: toPublicUrl(supabaseUrl, "products", it.image_url),
    })),
  }));
  return json({ orders });
}

async function listMySettlements(sb: any, tenantId: string, storeId: number, memberId: number, tab: string) {
  const cutoff = new Date(); cutoff.setMonth(cutoff.getMonth() - 6);
  let q = sb.from("v_customer_order_summary").select("*").eq("tenant_id", tenantId).eq("member_id", memberId).eq("store_id", storeId).gte("created_at", cutoff.toISOString()).order("created_at", { ascending: false }).limit(100);
  if (tab === "unpaid") q = q.eq("payment_status", "unpaid").not("status", "in", "(cancelled,expired)");
  else q = q.in("status", ["shipping", "completed"]);
  const { data, error } = await q;
  if (error) return json({ error: error.message }, 500);
  return json({ settlements: data ?? [] });
}

async function listActiveCampaigns(sb: any, tenantId: string, closeType?: string | null) {
  // end_at IS NULL 表示「無到期日」(管理員未設),也算進行中,要保留
  let q = sb
    .from("group_buy_campaigns")
    .select("id, campaign_no, name, description, cover_image_url, end_at, pickup_deadline, campaign_items(unit_price, sort_order, sku:skus(product:products(images)))")
    .eq("tenant_id", tenantId)
    .eq("status", "open")
    .or(`end_at.is.null,end_at.gt.${new Date().toISOString()}`);
  if (closeType) q = q.eq("close_type", closeType);
  const { data, error } = await q
    .order("end_at", { ascending: true, nullsFirst: false })
    .limit(50);
  if (error) return json({ error: error.message }, 500);

  const supabaseUrl = requireEnv("SUPABASE_URL");
  const campaigns = (data ?? []).map((c: any) => {
    const items = c.campaign_items ?? [];
    const prices: number[] = items
      .map((i: any) => Number(i.unit_price))
      .filter((n: number) => Number.isFinite(n));

    // 封面回退鏈:campaign.cover_image_url > 第一個 SKU 的第一張產品圖
    const sortedItems = [...items].sort(
      (a: any, b: any) => (a.sort_order ?? 0) - (b.sort_order ?? 0),
    );
    const fallbackImgs = sortedItems[0]?.sku?.product?.images;
    const fallbackPath = Array.isArray(fallbackImgs) && fallbackImgs.length > 0
      ? (typeof fallbackImgs[0] === "string" ? fallbackImgs[0] : fallbackImgs[0]?.url ?? null)
      : null;
    const cover = toPublicUrl(supabaseUrl, "products", c.cover_image_url)
      ?? toPublicUrl(supabaseUrl, "products", fallbackPath);

    return {
      id: c.id,
      campaign_no: c.campaign_no,
      name: c.name,
      description: c.description,
      cover_image_url: cover,
      end_at: c.end_at,
      pickup_deadline: c.pickup_deadline,
      item_count: prices.length,
      min_price: prices.length > 0 ? Math.min(...prices) : 0,
      max_price: prices.length > 0 ? Math.max(...prices) : 0,
    };
  });
  return json({ campaigns });
}

async function getCampaignDetail(sb: any, tenantId: string, campaignId: number) {
  const { data: c, error: cErr } = await sb
    .from("group_buy_campaigns")
    .select("id, campaign_no, name, description, cover_image_url, status, end_at, pickup_deadline")
    .eq("tenant_id", tenantId)
    .eq("id", campaignId)
    .single();
  if (cErr || !c) return json({ error: "campaign not found" }, 404);

  const { data: items, error: iErr } = await sb
    .from("campaign_items")
    .select("id, unit_price, cap_qty, sort_order, sku:skus(id, sku_code, product_name, variant_name, product:products(name, images))")
    .eq("tenant_id", tenantId)
    .eq("campaign_id", campaignId)
    .order("sort_order", { ascending: true });
  if (iErr) return json({ error: iErr.message }, 500);

  const supabaseUrl = requireEnv("SUPABASE_URL");
  c.cover_image_url = toPublicUrl(supabaseUrl, "products", c.cover_image_url);

  // hero carousel:campaign cover + 所有 SKU 全部圖,去重
  const heroPaths: string[] = [];
  if (c.cover_image_url) heroPaths.push(c.cover_image_url);
  for (const it of items ?? []) {
    const imgs = it.sku?.product?.images;
    if (!Array.isArray(imgs)) continue;
    for (const img of imgs) {
      const path = typeof img === "string" ? img : img?.url ?? null;
      if (!path) continue;
      const fullUrl = toPublicUrl(supabaseUrl, "products", path);
      if (fullUrl && !heroPaths.includes(fullUrl)) heroPaths.push(fullUrl);
    }
  }

  const flat = (items ?? []).map((it: any) => {
    const imgs = it.sku?.product?.images;
    const rawImg = Array.isArray(imgs) && imgs.length > 0
      ? (typeof imgs[0] === "string" ? imgs[0] : imgs[0]?.url ?? null)
      : null;
    const firstImg = toPublicUrl(supabaseUrl, "products", rawImg);
    return {
      campaign_item_id: it.id,
      sku_id: it.sku?.id,
      sku_code: it.sku?.sku_code,
      product_name: it.sku?.product_name ?? it.sku?.product?.name ?? null,
      variant_name: it.sku?.variant_name ?? null,
      image_url: firstImg,
      unit_price: Number(it.unit_price),
      cap_qty: it.cap_qty != null ? Number(it.cap_qty) : null,
    };
  });
  return json({ campaign: c, items: flat, hero_images: heroPaths });
}

async function placeMemberOrder(
  sb: any,
  tenantId: string,
  memberId: number,
  p: any,
) {
  const campaignId = Number(p.campaign_id);
  const items = Array.isArray(p.items) ? p.items : [];
  const notes = typeof p.notes === "string" ? p.notes.trim() : null;

  if (!campaignId) return json({ error: "campaign_id required" }, 400);
  if (items.length === 0) return json({ error: "items required" }, 400);

  // 取得 member + home_store
  const { data: member, error: mErr } = await sb
    .from("members")
    .select("id, name, home_store_id")
    .eq("tenant_id", tenantId)
    .eq("id", memberId)
    .single();
  if (mErr || !member) return json({ error: "member not found" }, 404);

  const pickupStoreId = Number(p.pickup_store_id ?? member.home_store_id ?? 0);
  if (!pickupStoreId) return json({ error: "pickup_store_id required" }, 400);

  // 確認活動 open + 還沒過期
  const { data: campaign, error: cErr } = await sb
    .from("group_buy_campaigns")
    .select("id, status, campaign_no, end_at")
    .eq("tenant_id", tenantId)
    .eq("id", campaignId)
    .single();
  if (cErr || !campaign) return json({ error: "campaign not found" }, 404);
  if (campaign.status !== "open") return json({ error: "campaign not open" }, 400);
  if (campaign.end_at && new Date(campaign.end_at).getTime() <= Date.now()) {
    return json({ error: "campaign already ended" }, 400);
  }

  // 找 pickup store 對應的 channel(取第一個 active 的)
  const { data: channel } = await sb
    .from("line_channels")
    .select("id")
    .eq("tenant_id", tenantId)
    .eq("home_store_id", pickupStoreId)
    .eq("is_active", true)
    .order("id", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (!channel) return json({ error: "no active channel for pickup store" }, 400);

  // 找既有訂單 or 新建(unique: tenant+campaign+channel+member)
  const { data: existing } = await sb
    .from("customer_orders")
    .select("id, order_no")
    .eq("tenant_id", tenantId)
    .eq("campaign_id", campaignId)
    .eq("channel_id", channel.id)
    .eq("member_id", memberId)
    .maybeSingle();

  let orderId: number;
  let orderNo: string;

  if (existing) {
    orderId = existing.id;
    orderNo = existing.order_no;
    await sb.from("customer_orders").update({
      pickup_store_id: pickupStoreId,
      notes: notes ?? null,
      updated_at: new Date().toISOString(),
    }).eq("id", orderId);
  } else {
    const { count } = await sb
      .from("customer_orders")
      .select("*", { count: "exact", head: true })
      .eq("tenant_id", tenantId)
      .eq("campaign_id", campaignId);
    orderNo = `${campaign.campaign_no}-${String((count ?? 0) + 1).padStart(4, "0")}`;
    const { data: inserted, error: insErr } = await sb
      .from("customer_orders")
      .insert({
        tenant_id: tenantId,
        order_no: orderNo,
        campaign_id: campaignId,
        channel_id: channel.id,
        member_id: memberId,
        nickname_snapshot: member.name,
        pickup_store_id: pickupStoreId,
        status: "pending",
        notes: notes ?? null,
      })
      .select("id")
      .single();
    if (insErr || !inserted) {
      return json({ error: "failed to create order", detail: insErr?.message }, 500);
    }
    orderId = inserted.id;
  }

  // items: 同 campaign_item_id 累加,否則新增
  for (const it of items) {
    const ciId = Number(it.campaign_item_id);
    const qty = Number(it.qty);
    if (!ciId || !qty || qty <= 0) continue;

    const { data: ci } = await sb
      .from("campaign_items")
      .select("unit_price, sku_id")
      .eq("id", ciId)
      .eq("tenant_id", tenantId)
      .eq("campaign_id", campaignId)
      .maybeSingle();
    if (!ci) continue;

    const { data: existingItem } = await sb
      .from("customer_order_items")
      .select("id, qty")
      .eq("order_id", orderId)
      .eq("campaign_item_id", ciId)
      .maybeSingle();

    if (existingItem) {
      await sb.from("customer_order_items").update({
        qty: Number(existingItem.qty) + qty,
        updated_at: new Date().toISOString(),
      }).eq("id", existingItem.id);
    } else {
      await sb.from("customer_order_items").insert({
        tenant_id: tenantId,
        order_id: orderId,
        campaign_item_id: ciId,
        sku_id: ci.sku_id,
        qty: qty,
        unit_price: ci.unit_price,
        status: "pending",
        source: "liff",
      });
    }
  }

  return json({ ok: true, order_id: orderId, order_no: orderNo });
}

async function generatePwaAuthCode(
  sb: any,
  tenantId: string,
  memberId: number,
  claims: any,
  jwt: string,
  p: any,
) {
  const code6 = Math.floor(100000 + Math.random() * 900000).toString();
  // session_data.store 是給前端顯示用,要回 code (e.g. "S001") 而非數字 ID
  // claims.store_code 由 line-oauth-callback / liff-session 寫入
  const sessionData = {
    token: jwt,
    store: String(claims.store_code ?? claims.store_id ?? ""),
    member_id: memberId,
    line_user_id: String(claims.line_user_id ?? ""),
    line_name: typeof p.line_name === "string" ? p.line_name : null,
    line_picture: typeof p.line_picture === "string" ? p.line_picture : null,
  };
  const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();

  const { error } = await sb.from("pwa_auth_codes").insert({
    code: code6,
    session_data: sessionData,
    tenant_id: tenantId,
    expires_at: expiresAt,
  });
  if (error) return json({ error: error.message }, 500);

  return json({ code: code6, expires_in_sec: 300 });
}

async function listMyNotifications(sb: any, tenantId: string, memberId: number) {
  const { data, error } = await sb
    .from("notifications")
    .select("id, category, title, body, url, read_at, created_at")
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) return json({ error: error.message }, 500);
  return json({ notifications: data ?? [] });
}

async function getMyUnreadNotificationCount(sb: any, tenantId: string, memberId: number) {
  const { count, error } = await sb
    .from("notifications")
    .select("*", { count: "exact", head: true })
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .is("read_at", null);
  if (error) return json({ error: error.message }, 500);
  return json({ count: count ?? 0 });
}

async function markNotificationRead(sb: any, tenantId: string, memberId: number, p: any) {
  const now = new Date().toISOString();
  let q = sb
    .from("notifications")
    .update({ read_at: now })
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .is("read_at", null);
  if (!p.mark_all) {
    const id = Number(p.id);
    if (!id) return json({ error: "id required when mark_all is not set" }, 400);
    q = q.eq("id", id);
  }
  const { error } = await q;
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
}

async function upsertPushSubscription(sb: any, tenantId: string, memberId: number, p: any) {
  if (!p.endpoint) return json({ error: "endpoint required" }, 400);
  
  const rpcParams = {
    p_endpoint: p.endpoint,
    p_p256dh: p.p256dh,
    p_auth: p.auth,
    p_user_agent: p.user_agent || p.userAgent, 
    p_member_id: memberId,
    p_tenant_id: tenantId,
  };

  const { data: insertedId, error } = await sb.rpc("rpc_upsert_push_subscription", rpcParams);
  
  if (error) {
    console.error("rpc_upsert_push_subscription error:", error);
    return json({ error: error.message, details: error }, 500);
  }
  
  return json({ ok: true, id: insertedId, debug: rpcParams });
}

// ─── main ────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const body = await req.json() as Record<string, unknown>;
    const action = String(body.action ?? "");
    const sb = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });

    // ── 不需要 Token 的 actions ──
    if (action === "claim_pwa_auth_code") return await claimPwaAuthCode(sb, String(body.code ?? ""));
    if (action === "list_stores") return await listStores(sb, requireEnv("DEFAULT_TENANT_ID"));

    const auth = req.headers.get("authorization");
    if (!auth) return json({ error: "missing authorization" }, 401);
    const token = auth.replace(/^Bearer\s+/i, "");
    const jwtSecret = requireEnv("PROJECT_JWT_SECRET");
    let claims;
    try { claims = await verifyJwtHs256(token, jwtSecret); } catch (e) { return json({ error: "invalid token", detail: String(e) }, 401); }

    const tenantId = String(claims.tenant_id ?? "");
    const storeId = Number(claims.store_id ?? 0);
    const lineUserId = String(claims.line_user_id ?? "");
    const memberId = claims.member_id ? Number(claims.member_id) : null;
    if (!tenantId || !storeId || !lineUserId) return json({ error: "missing claims in token" }, 401);

    switch (action) {
      case "lookup_by_phone": return await lookupByPhone(sb, tenantId, String(body.phone ?? ""));
      case "register_and_bind": return await registerAndBind(sb, { tenantId, storeId, lineUserId, phone: String(body.phone ?? ""), name: String(body.name ?? ""), birthday: String(body.birthday ?? "") });
      case "get_me": if (!memberId) return json({ error: "no member_id" }, 401); return await getMe(sb, tenantId, memberId);
      case "update_me": if (!memberId) return json({ error: "no member_id" }, 401); return await updateMe(sb, tenantId, memberId, body);
      case "get_overview": if (!memberId) return json({ error: "no member_id" }, 401); return await getOverview(sb, tenantId, storeId, memberId);
      case "list_my_orders": if (!memberId) return json({ error: "no member_id" }, 401); return await listMyOrders(sb, tenantId, storeId, memberId, String(body.tab ?? ""));
      case "list_my_settlements": if (!memberId) return json({ error: "no member_id" }, 401); return await listMySettlements(sb, tenantId, storeId, memberId, String(body.tab ?? ""));
      case "upsert_push_subscription": if (!memberId) return json({ error: "no member_id" }, 401); return await upsertPushSubscription(sb, tenantId, memberId, body);
      case "list_my_notifications": if (!memberId) return json({ error: "no member_id" }, 401); return await listMyNotifications(sb, tenantId, memberId);
      case "get_my_unread_notification_count": if (!memberId) return json({ error: "no member_id" }, 401); return await getMyUnreadNotificationCount(sb, tenantId, memberId);
      case "mark_notification_read": if (!memberId) return json({ error: "no member_id" }, 401); return await markNotificationRead(sb, tenantId, memberId, body);
      case "generate_pwa_auth_code": if (!memberId) return json({ error: "no member_id" }, 401); return await generatePwaAuthCode(sb, tenantId, memberId, claims, token, body);
      case "list_active_campaigns": return await listActiveCampaigns(sb, tenantId, typeof body.close_type === "string" ? body.close_type : null);
      case "get_campaign_detail": return await getCampaignDetail(sb, tenantId, Number(body.campaign_id ?? 0));
      case "place_member_order": if (!memberId) return json({ error: "no member_id" }, 401); return await placeMemberOrder(sb, tenantId, memberId, body);
      default: return json({ error: `unknown action: ${action}` }, 400);
    }
  } catch (e) {
    console.error("liff-api error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

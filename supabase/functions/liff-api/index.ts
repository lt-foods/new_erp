import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";
import { verifyJwtHs256, type JwtClaims } from "../_shared/jwt.ts";
import { renewSessionTokenIfNeeded } from "../_shared/session.ts";
import { isMissingOwnerStoreColumn, isMissingSalesChannelColumn } from "../_shared/salesChannelGuard.ts";
import { BIND_CODE_TTL_MIN, buildBindMessage, generateBindCode } from "../_shared/lineBinding.ts";
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

/**
 * 現貨貼文的圖片：貼文自帶的 spot_images 優先，沒有才 fallback 回商品主檔。
 *
 * 兩邊都是 products bucket 的相對路徑陣列，但主檔那份歷史上允許
 * `{ url }` 物件，所以這裡兩種形狀都收。手打的商品沒有 SKU、只有 spot_images。
 */
function resolveSpotImages(
  supabaseUrl: string,
  spotImages: unknown,
  productImages: unknown,
): string[] {
  const src = Array.isArray(spotImages) && spotImages.length > 0 ? spotImages : productImages;
  if (!Array.isArray(src)) return [];
  const out: string[] = [];
  for (const img of src) {
    const path = typeof img === "string" ? img : (img as any)?.url ?? null;
    const url = toPublicUrl(supabaseUrl, "products", path);
    if (url && !out.includes(url)) out.push(url);
  }
  return out;
}

// ─── actions ─────────────────────────────────────────────────────────────────

/**
 * 建立 account link 用的一次性 nonce。
 *
 * 流程：顧客在店家 OA 傳訊息 → webhook 回一則帶 linkToken 的連結 →
 * 顧客點進會員站 /link 並登入（到這裡我們才知道他是哪位會員）→
 * 呼叫這支拿 nonce → 導去 LINE 的 accountLink 頁 → LINE 回 accountLink
 * webhook，帶著同一個 nonce → 綁定完成。
 *
 * nonce 是「這是哪位會員」的憑據，所以必須由**已驗證的會員 token** 產生，
 * 不能讓前端自己指定 member_id。
 */
async function createAccountLinkNonce(
  // deno-lint-ignore no-explicit-any
  sb: any, tenantId: string, memberId: number, storeCode: string,
) {
  const { data: store, error: sErr } = await sb
    .from("stores").select("id").eq("tenant_id", tenantId).eq("code", storeCode).maybeSingle();
  if (sErr) return json({ error: sErr.message }, 500);
  if (!store) return json({ error: "store_not_found" }, 404);

  // LINE 要求 nonce 至少 128 bits、用安全亂數產生
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  const nonce = btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, (c) =>
    ({ "+": "-", "/": "_", "=": "" }[c] ?? c));

  const { error } = await sb.from("line_account_link_nonces").insert({
    nonce, tenant_id: tenantId, store_id: store.id, member_id: memberId,
  });
  if (error) return json({ error: error.message }, 500);
  return json({ nonce });
}

// ─── 限量商品下單前的「店家 LINE 綁定」 ──────────────────────────────────────
//
// 「綁定」= store_line_followers 有這位會員（member_id 已填、followed=true）。
// 那張表的 line_user_id 是**該店 OA provider** 的 ID，店家用它推「到貨通知」、
// 棄單時也聯絡得到人 —— 這正是限量商品要求先綁定的原因。
//
// 寫入端有兩條路，都在 line-webhook：
//   1. 綁定碼（本次新增）：start_line_binding 發碼 → 前端開 OA 對話預填
//      「綁定碼：XXXXXX」→ 會員按送出 → webhook 核銷 + 綁定。一則訊息完成。
//   2. account link（既有）：會員隨便傳訊息 → webhook 回「查看我的訂單」連結。
// 這裡只負責發碼與回報狀態，不寫 store_line_followers。

/** 取貨店的綁定目標：OA basic id + 是否具備完成綁定的條件（憑證齊全才有 webhook） */
async function resolveLineBindTarget(sb: any, tenantId: string, storeId: number) {
  const { data: store } = await sb
    .from("stores")
    .select("id, name, line_oa_basic_id")
    .eq("tenant_id", tenantId)
    .eq("id", storeId)
    .maybeSingle();
  const oaId = String(store?.line_oa_basic_id ?? "").trim() || null;
  let hasCreds = false;
  if (oaId) {
    // 憑證（channel secret）沒設就收不到 webhook，綁定永遠完不成 → 視為不可綁
    const { data: cred } = await sb
      .from("store_line_oa_credentials")
      .select("store_id")
      .eq("store_id", storeId)
      .maybeSingle();
    hasCreds = !!cred;
  }
  return {
    storeName: (store?.name as string | undefined) ?? null,
    oaId,
    bindable: !!oaId && hasCreds,
  };
}

async function memberBoundToStore(sb: any, storeId: number, memberId: number): Promise<boolean> {
  const { data } = await sb
    .from("store_line_followers")
    .select("id")
    .eq("store_id", storeId)
    .eq("member_id", memberId)
    .eq("followed", true)
    .limit(1)
    .maybeSingle();
  return !!data;
}

/** 前端輪詢用：這位會員對這家店綁好了沒 */
async function getLineBindState(sb: any, tenantId: string, memberId: number, storeId: number) {
  if (!storeId) return json({ error: "store_id required" }, 400);
  const target = await resolveLineBindTarget(sb, tenantId, storeId);
  const bound = target.bindable ? await memberBoundToStore(sb, storeId, memberId) : false;
  return json({
    store_id: storeId,
    store_name: target.storeName,
    oa_id: target.oaId,
    bindable: target.bindable,
    bound,
  });
}

/**
 * 發（或重用）綁定碼。回傳前端開 OA 對話要用的一切：oa_id + 預填訊息。
 * 同會員同店還有活著的碼就直接重用 —— 會員反覆按下單不會把表灌爆，
 * 也不會讓「已經開著的 LINE 對話框」裡那組碼突然失效。
 */
async function startLineBinding(sb: any, tenantId: string, memberId: number, storeId: number) {
  if (!storeId) return json({ error: "store_id required" }, 400);
  const target = await resolveLineBindTarget(sb, tenantId, storeId);
  if (!target.bindable) return json({ error: "此店家尚未啟用 LINE 綁定" }, 400);
  if (await memberBoundToStore(sb, storeId, memberId)) {
    return json({ bound: true });
  }

  // 重用還有 5 分鐘以上效期的碼；快過期就發新的，免得會員送出時剛好失效
  const { data: existing } = await sb
    .from("line_binding_codes")
    .select("code, expires_at")
    .eq("member_id", memberId)
    .eq("store_id", storeId)
    .is("used_at", null)
    .gt("expires_at", new Date(Date.now() + 5 * 60_000).toISOString())
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();

  let code = existing?.code as string | undefined;
  if (!code) {
    const expiresAt = new Date(Date.now() + BIND_CODE_TTL_MIN * 60_000).toISOString();
    // 活著的碼全域唯一（partial unique index）；撞號就重生，最多試 3 次
    for (let i = 0; i < 3 && !code; i++) {
      const candidate = generateBindCode();
      const { error } = await sb.from("line_binding_codes").insert({
        tenant_id: tenantId,
        member_id: memberId,
        store_id: storeId,
        code: candidate,
        expires_at: expiresAt,
      });
      if (!error) code = candidate;
      else if (!String(error.message ?? "").includes("duplicate")) {
        return json({ error: error.message }, 500);
      }
    }
    if (!code) return json({ error: "無法產生綁定碼，請稍後再試" }, 500);
  }

  return json({
    bound: false,
    code,
    oa_id: target.oaId,
    store_name: target.storeName,
    message_text: buildBindMessage(code),
  });
}

async function listStores(sb: any, tenantId: string) {
  // line_liff_id：每家店在自己 Provider 底下的 LIFF ID。會員必須用「所屬分店」
  // 那支 LIFF 登入，拿到的 line_user_id 才跟該店官方帳號同 provider、推得動。
  // 不是密鑰（本來就明碼在會員端 bundle），可以隨門市清單一起公開。
  //
  // is_visible_to_customers（@20260902020000）：門市可以「照常營運但客人看不到」。
  // 這支走 service_role（見 main 的 createClient），RLS 完全繞過 —— 這一行就是
  // 唯一的防線，沒有別的地方會再擋一次。不要拿掉。
  // ⚠ 只管「選單列不列」：門市也能從網址參數 / localStorage 指定
  // （useLineLogin.ts:189-196、:224-229），已經選過該店的客人不受影響（刻意的）。
  const { data, error } = await sb
    .from("stores")
    .select("id, code, name, line_liff_id")
    .eq("tenant_id", tenantId)
    .eq("is_active", true)
    .eq("is_visible_to_customers", true)
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
  // maybeSingle：會員可能已被後台刪除（rpc_member_purge），但對方手機的 JWT 還沒過期。
  // 這時要回明確的 member_not_found 讓前端清 session 重新登入，
  // 不能讓 .single() 的「Cannot coerce ...」原始錯誤流到畫面上（2026-08 實際發生）。
  const { data, error } = await sb.from("members").select("id, member_no, name, phone, email, birthday, gender, home_store_id, avatar_url, status").eq("tenant_id", tenantId).eq("id", memberId).maybeSingle();
  if (error) return json({ error: error.message }, 500);
  if (!data) return json({ error: "member_not_found" }, 401);
  let home_store_name: string | null = null;
  if (data.home_store_id) {
    const { data: s } = await sb.from("stores").select("name").eq("tenant_id", tenantId).eq("id", data.home_store_id).maybeSingle();
    home_store_name = s?.name ?? null;
  }
  return json({
    ...data,
    home_store_name,
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
  // home_store_id 只允許 admin 從會員明細頁改 (rpc_set_member_home_store)；LIFF 不可改。
  if (Object.keys(patch).length === 0) return json({ error: "nothing to update" }, 400);
  patch.updated_at = new Date().toISOString();
  const { error } = await sb.from("members").update(patch).eq("tenant_id", tenantId).eq("id", memberId);
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
}

async function getWallet(sb: any, tenantId: string, memberId: number) {
  const { data, error } = await sb
    .from("wallet_balances")
    .select("balance, version, last_movement_at, updated_at")
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .maybeSingle();
  if (error) return json({ error: error.message }, 500);
  // 沒 row 表示從未動過 → 餘額 0
  return json({
    balance: Number(data?.balance ?? 0),
    version: Number(data?.version ?? 0),
    last_movement_at: data?.last_movement_at ?? null,
    updated_at: data?.updated_at ?? null,
  });
}

async function listWalletLedger(sb: any, tenantId: string, memberId: number, body: any) {
  const limit = Math.min(Math.max(Number(body.limit ?? 30), 1), 100);
  const beforeId = body.before_id ? Number(body.before_id) : null;
  let q = sb
    .from("wallet_ledger")
    .select("id, change, balance_after, type, source_type, source_id, payment_method, reverses, reason, created_at")
    .eq("tenant_id", tenantId)
    .eq("member_id", memberId)
    .order("id", { ascending: false })
    .limit(limit);
  if (beforeId) q = q.lt("id", beforeId);
  const { data, error } = await q;
  if (error) return json({ error: error.message }, 500);
  return json({ ledger: data ?? [], has_more: (data?.length ?? 0) === limit });
}

async function getOverview(sb: any, tenantId: string, storeId: number, memberId: number) {
  const { data: storeRow, error: sErr } = await sb.from("stores").select("id, code, name, banner_url, description, payment_methods_text, shipping_methods_text").eq("tenant_id", tenantId).eq("id", storeId).single();
  if (sErr || !storeRow) return json({ error: "store not found" }, 404);
  storeRow.banner_url = toPublicUrl(requireEnv("SUPABASE_URL"), "products", storeRow.banner_url);
  // 未結金額 / 進行中筆數依 member_id 會員級加總，不依 store_id 過濾：
  // member_id 是 tenant 級、訂單 pickup 店可不同於登入店，需與 listMyOrders（跨店）一致，
  // 否則訂單列表看得到、overview 金額卻 0。
  // 「未結單金額」＝ 已訂未領貨 = SUM(outstanding_amount)（@20260810000000）。
  // 不可以用 payment_status='unpaid' 當條件 —— 那個欄位全站從來沒被寫成 'paid'
  // （取貨收現金，rpc_record_pickup 不碰它），等於沒過濾，會把早就取走的訂單
  // 一路累加上去（回報案例：顯示 $3,072、實際未領只有 $1,110）。
  // 不設時間下限，跟 listMyOrders 同一套母體（2026-08-27 拿掉 6 個月 cutoff）——
  // 團友會拿「進行中訂單」逐張加總來對這個數字，兩邊的範圍不一致就又會被回報對不上。
  const { data: unpaidRows } = await sb.from("v_customer_order_summary").select("outstanding_amount").eq("tenant_id", tenantId).eq("member_id", memberId).gt("outstanding_amount", 0);
  const receivable = (unpaidRows ?? []).reduce((s: number, r: any) => s + Number(r.outstanding_amount ?? 0), 0);
  // transferred_out（轉手給別人）的品項仍留在原單且維持 pending，貨已經在新單上 → 不算進行中。
  const { count: activeCount } = await sb.from("v_customer_order_summary").select("*", { count: "exact", head: true }).eq("tenant_id", tenantId).eq("member_id", memberId).not("status", "in", "(completed,cancelled,expired,transferred_out)");
  return json({ store: storeRow, receivable_amount: receivable, active_orders_count: activeCount ?? 0 });
}

/**
 * 取貨事件（order_pickup_events，append-only）→ 依訂單分組。
 *
 * 會員端「已完成」分頁靠它把品項還原成「客人那一次到店結單拿走的組合」：
 * 一次櫃台結單 = 每張訂單各一筆事件（/pickup 的「一次全取」是逐張呼叫
 * rpc_record_pickup），所以事件本身就是那一次拿走的品項清單。
 *
 * 撤銷取貨（rpc_undo_pickup，20260704000010）不刪原事件 —— 該表禁改禁刪 ——
 * 而是補一筆 pickup_undone、notes 固定 `撤銷取貨事件 #<id>`。被撤銷的那一次
 * 不能再算數，判法與後台 apps/admin/src/lib/pickupReceipt.ts 的
 * undonePickupEventIds 同一套（改一邊記得改另一邊）。
 *
 * notes 不外露：那是店員的內部備註（「一次全取（儲值金 $500）」之類）。
 */
async function fetchPickupEventsByOrder(
  sb: any,
  orderIds: number[],
): Promise<Map<number, { id: number; event_type: string; picked_at: string; item_ids: number[] }[]>> {
  const out = new Map<number, { id: number; event_type: string; picked_at: string; item_ids: number[] }[]>();
  if (orderIds.length === 0) return out;
  // 逐頁撈到見底：PostgREST 有 max-rows 上限（超過會**靜默截斷**，不是報錯），
  // 重度團友的事件數會一路長，被截斷的訂單會掉出「那一次結單」分組、
  // 該次的取貨金額也跟著少算。keyset（id >）分頁，一頁 1000。
  const rows: any[] = [];
  let lastId = 0;
  for (let page = 0; page < 50; page++) {
    const { data, error } = await sb
      .from("order_pickup_events")
      .select("id, order_id, event_type, item_ids, notes, created_at")
      .in("order_id", orderIds)
      .in("event_type", ["picked_up", "partial_pickup", "pickup_undone"])
      .gt("id", lastId)
      .order("id", { ascending: true })
      .limit(1000);
    // 取貨紀錄拿不到只是少了分組，訂單本身照列 —— 不要讓整頁掛掉
    if (error) { console.error("fetchPickupEventsByOrder:", error.message); return out; }
    const batch = (data ?? []) as any[];
    rows.push(...batch);
    if (batch.length < 1000) break;
    lastId = Number(batch[batch.length - 1].id);
  }
  const undone = new Set<number>();
  for (const r of rows) {
    if (r.event_type !== "pickup_undone") continue;
    const m = /撤銷取貨事件 #(\d+)/.exec(String(r.notes ?? ""));
    if (m) undone.add(Number(m[1]));
  }
  for (const r of rows) {
    if (r.event_type === "pickup_undone" || undone.has(Number(r.id))) continue;
    const list = out.get(Number(r.order_id)) ?? [];
    list.push({
      id: Number(r.id),
      event_type: String(r.event_type),
      picked_at: String(r.created_at),
      item_ids: Array.isArray(r.item_ids) ? r.item_ids.map(Number).filter(Number.isFinite) : [],
    });
    out.set(Number(r.order_id), list);
  }
  return out;
}

/**
 * 符合條件的單要**全部**撈回來，不能只撈最新 100 筆、也不設時間下限。
 * 重度團友半年 200+ 張「已完成」很常見（2026-08-27 盤點：22 位會員超過 100、
 * 最多 273），.limit(100) 砍尾巴的結果就是「訂單明明已完成，APP 上卻找不到」
 * （古華 老爹的 6/5 檸檬鴨單前面有 173 張更新的 completed）。進行中被砍更糟：
 * 「應付總金額」跟著少算 —— 2026-08-27 松山 M20260805101217525 就是這樣：
 * APP 顯示待取貨 10 筆 $1,255，現場實取 18 筆 $2,593，被砍掉的 8 張全是 7 月舊單。
 * 原本還有 6 個月 cutoff，同日 Alex 拍板拿掉：**清單跟金額的母體必須一模一樣**，
 * 任何一邊多一層時間過濾，客人逐張加總就對不上。
 * 逐頁 100 筆撈到見底；5000 筆只是 runaway 保險（目前最重會員 422 張）。
 * 排序掛 id 當 tiebreaker，created_at 同秒的單跨頁才不會被跳過或重複。
 */
async function fetchAllOrderSummaries(
  sb: any,
  tenantId: string,
  memberId: number,
  applyFilter: (q: any) => any,
): Promise<{ data?: any[]; error?: { message: string } }> {
  const PAGE = 100, MAX_ROWS = 5000;
  const all: any[] = [];
  for (let from = 0; from < MAX_ROWS; from += PAGE) {
    const q = applyFilter(
      sb.from("v_customer_order_summary").select("*")
        .eq("tenant_id", tenantId).eq("member_id", memberId)
        .order("created_at", { ascending: false }).order("id", { ascending: false })
        .range(from, from + PAGE - 1),
    );
    const { data, error } = await q;
    if (error) return { error };
    all.push(...(data ?? []));
    if ((data ?? []).length < PAGE) break;
  }
  return { data: all };
}

/**
 * 「待到貨」「待取貨」的應付總金額 —— **後端算完直接回，前端不准再從列表加總**
 * （2026-08-27 Alex 指示）。前端自己加總的問題：口徑跟著前端的分桶 / 過濾走，
 * 任何一邊改了（隱藏分頁、截斷、拆分身）數字就跟著歪，客訴對帳只能猜。
 *
 * 分桶與分攤規則**逐字對齊**會員端（改這裡記得改那邊，反之亦然）：
 *   - itemPhase：apps/member/src/components/OrderCard.tsx —— 單頭 cancelled/expired/
 *     transferred_out 整張跳過；行 picked_up → 已完成、cancelled/expired → 不成立；
 *     其餘 arrived===true → 待取貨、否則待到貨（缺值當沒到，寧可少報）。
 *   - 金額分攤：apps/member/src/app/orders/page.tsx —— 單頭 outstanding_amount 依
 *     「該分身未取貨值 / 整張單未取貨值」等比分攤，兩個分頁相加 = 整張單未結金額，
 *     不會把同一張單算兩次。
 *   - has_picked：分身分攤額 < 整張單 payable_amount → 副標「已取貨的不計」。
 * 後台複製品 apps/admin/src/components/MemberOrdersAppView.tsx 的 outstandingTotals
 * 也是同一套，四份要一起動。
 */
function computePayableTotals(rows: any[]) {
  const totals = {
    waiting: { count: 0, amount: 0, has_picked: false },
    pickup: { count: 0, amount: 0, has_picked: false },
  };
  for (const o of rows) {
    // completed 也要跳過（與 itemPhase 的 completed 分支對齊）：單頭完成後仍掛
    // active 的行是「量被未取退貨覆蓋」的殘留，不屬於待到貨／待取貨。
    // active tab 本來就不含 completed，這裡是防守（口徑四份同步，見檔頭）。
    if (["cancelled", "expired", "transferred_out", "completed"].includes(String(o.status ?? ""))) continue;
    const items = Array.isArray(o.items) ? o.items : [];
    const active = items.filter((it: any) => !["cancelled", "expired", "picked_up"].includes(String(it.status ?? "")));
    const wholeUnpicked = active.reduce((s: number, it: any) => s + Number(it.subtotal ?? 0), 0);
    const outstanding = Number(o.outstanding_amount ?? o.payable_amount ?? 0);
    const payable = Number(o.payable_amount ?? 0);
    for (const phase of ["waiting", "pickup"] as const) {
      const part = active.filter((it: any) => (it.arrived === true) === (phase === "pickup"));
      if (part.length === 0) continue;
      const partSubtotal = part.reduce((s: number, it: any) => s + Number(it.subtotal ?? 0), 0);
      const partAmount = wholeUnpicked > 0 ? (outstanding * partSubtotal) / wholeUnpicked : 0;
      totals[phase].count += 1;
      totals[phase].amount += partAmount;
      if (partAmount < payable) totals[phase].has_picked = true;
    }
  }
  // 有折扣／儲值金的單分攤後會出現小數，畫面不能出現 $1,255.4 —— 最後才捨入，
  // 逐張捨入會讓兩頁相加對不回整張單的未結金額。
  totals.waiting.amount = Math.round(totals.waiting.amount);
  totals.pickup.amount = Math.round(totals.pickup.amount);
  return totals;
}

async function listMyOrders(sb: any, tenantId: string, _storeId: number, memberId: number, tab: string) {
  // 不依 store_id 過濾：同一 line_user 可能綁多店 OA，但 member_id 是 tenant 級；
  // 「我的訂單」呈現該 member 在所有店的訂單，OrderCard 會顯示 store_name 區別。
  // active: 一般取消的訂單不顯示，但「斷貨取消」(stockout_at 有值) 要讓顧客看得到
  const { data, error } = await fetchAllOrderSummaries(sb, tenantId, memberId, (q) =>
    tab === "active" ? q.not("status", "in", "(completed,expired)") : q.eq("status", "completed"));
  if (error) return json({ error: error.message }, 500);

  const rows = tab === "active"
    ? (data ?? []).filter((o: any) => o.status !== "cancelled" || o.stockout_at)
    : (data ?? []);

  // 每張單掛上自己的取貨事件 —— 會員端「已完成」分頁要能把品項還原成
  // 「客人那一次到店結單的組合」（同一次結單常橫跨好幾張單）。
  // 多一次查詢就好，不要每張單各查一次。
  const pickupsByOrder = await fetchPickupEventsByOrder(sb, rows.map((o: any) => Number(o.id)));

  // 把 items.image_url + campaign_cover_url 轉成 storage public URL
  const supabaseUrl = requireEnv("SUPABASE_URL");
  const orders = rows.map((o: any) => ({
    ...o,
    campaign_cover_url: toPublicUrl(supabaseUrl, "products", o.campaign_cover_url),
    items: (o.items ?? []).map((it: any) => ({
      ...it,
      image_url: toPublicUrl(supabaseUrl, "products", it.image_url),
    })),
    pickups: pickupsByOrder.get(Number(o.id)) ?? [],
  }));
  // 應付總金額只跟 active 分頁的單有關（completed 的行全是已取 / 取消，
  // 不會落在待到貨 / 待取貨），history 就不用多付一次計算
  if (tab === "active") return json({ orders, totals: computePayableTotals(rows) });
  return json({ orders });
}

async function listMySettlements(sb: any, tenantId: string, _storeId: number, memberId: number, tab: string) {
  // 同 listMyOrders：跨店訂單都納入（OrderCard 顯示 store_name），
  // 且撈到見底、不能砍最新 100 筆（理由見 fetchAllOrderSummaries）。
  // 「待付款」＝ 還有沒領走的貨（同 getOverview 的口徑，@20260810000000）。
  // 同樣不能用 payment_status='unpaid'：那會把所有已取貨的舊單一起列出來。
  const { data, error } = await fetchAllOrderSummaries(sb, tenantId, memberId, (q) =>
    tab === "unpaid" ? q.gt("outstanding_amount", 0) : q.in("status", ["shipping", "completed"]));
  if (error) return json({ error: error.message }, 500);
  return json({ settlements: data ?? [] });
}

/**
 * 現貨專區 — 互助交流板「我有庫存可提供」(post_type='offer') 曝光到會員端。
 *
 * 只回還在架上的：status='active'、未到期、qty_remaining > 0。
 * （request「我要求助」是店對店的求援，不是可買的貨，不外露給會員。）
 *
 * 金額規則（跨店金額隱藏）：
 *   只有「釋出店 = 會員所屬店」才回 unit_price；跨店一律回 null，
 *   而且是在 server 端就不放進 payload — 前端根本拿不到金額，
 *   不是只有 UI 藏起來（避免看 network response 就繞過）。
 *
 * 會員所屬店以 members.home_store_id 為準；未綁定會員退回 JWT 的 store_id
 * （就是他掃碼進站的那間店）。
 *
 * 板上的 note 是店對店的內部備註，不外露。
 * LINE@ 只回「會員所屬店」那一間的（my_store_line_oa_id），
 * 其他店的聯絡方式不外流 — 會員一律只跟自己的店往來。
 */
/**
 * 會員所屬店：以 members.home_store_id 為準，未綁定會員退回 JWT 的 store_id。
 * 現貨專區的金額可見性整個建立在這個值上，list / detail 共用同一份判斷。
 */
async function resolveMemberStoreId(
  sb: any,
  tenantId: string,
  jwtStoreId: number,
  memberId: number | null,
): Promise<number> {
  if (!memberId) return jwtStoreId;
  const { data: m } = await sb
    .from("members")
    .select("home_store_id")
    .eq("tenant_id", tenantId)
    .eq("id", memberId)
    .maybeSingle();
  return m?.home_store_id ? Number(m.home_store_id) : jwtStoreId;
}

async function listSpotProducts(
  sb: any,
  tenantId: string,
  jwtStoreId: number,
  memberId: number | null,
) {
  const myStoreId = await resolveMemberStoreId(sb, tenantId, jwtStoreId, memberId);

  const { data: rows, error } = await sb
    .from("mutual_aid_board")
    .select(
      "id, offering_store_id, sku_id, qty_remaining, expires_at, created_at, source_customer_order_id, spot_price, spot_title, spot_unit, spot_images, sku:skus(sku_code, product_name, variant_name, base_unit, product:products(name, images))",
    )
    .eq("tenant_id", tenantId)
    .eq("post_type", "offer")
    .eq("status", "active")
    .gt("qty_remaining", 0)
    .gt("expires_at", new Date().toISOString())
    // 店家把「其他分店的會員也看得到」關掉的，只有釋出店自己的會員查得到。
    // 一定要在這裡濾 —— 前端藏卡片沒用，raw response 還是會外流。
    .or(`spot_visible_to_other_stores.eq.true,offering_store_id.eq.${myStoreId}`)
    .order("created_at", { ascending: false });
  if (error) return json({ error: error.message }, 500);

  const storeIds = Array.from(
    new Set([
      myStoreId,
      ...(rows ?? []).map((r: any) => Number(r.offering_store_id)),
    ].filter((id) => Number.isFinite(id) && id > 0)),
  );
  const storeNameMap = new Map<number, string>();
  let myStoreLineOaId: string | null = null;
  if (storeIds.length > 0) {
    const { data: ss } = await sb
      .from("stores")
      .select("id, name, line_oa_basic_id")
      .eq("tenant_id", tenantId)
      .in("id", storeIds);
    for (const s of ss ?? []) {
      storeNameMap.set(Number(s.id), s.name);
      // 只留自己店的 LINE@，別店的不進 payload
      if (Number(s.id) === myStoreId) {
        myStoreLineOaId = (s.line_oa_basic_id ?? "").trim() || null;
      }
    }
  }

  // 單價只查「自己店」那幾筆的來源訂單 — 跨店的價格連查都不查，
  // 保證不可能因為之後改動而不小心漏進 response。
  const myOrderIds = Array.from(
    new Set(
      (rows ?? [])
        .filter((r: any) => Number(r.offering_store_id) === myStoreId)
        .map((r: any) => r.source_customer_order_id)
        .filter((x: any): x is number => x != null),
    ),
  );
  const priceMap = new Map<string, number>();
  if (myOrderIds.length > 0) {
    const { data: its } = await sb
      .from("customer_order_items")
      .select("order_id, sku_id, unit_price")
      .eq("tenant_id", tenantId)
      .in("order_id", myOrderIds);
    for (const it of its ?? []) {
      const price = Number(it.unit_price);
      if (!Number.isFinite(price)) continue;
      priceMap.set(`${it.order_id}:${it.sku_id}`, price);
    }
  }

  // 瀏覽次數（顧客端卡片顯示「👁 N」）。RPC 未部署時整段當 0，不影響列表。
  const viewMap = new Map<number, number>();
  const boardIds = (rows ?? []).map((r: any) => Number(r.id));
  if (boardIds.length > 0) {
    const { data: viewRows } = await sb.rpc("rpc_spot_view_counts", {
      p_tenant: tenantId,
      p_board_ids: boardIds,
    });
    for (const v of viewRows ?? []) {
      viewMap.set(Number(v.board_id), Number(v.view_count ?? 0));
    }
  }

  const supabaseUrl = requireEnv("SUPABASE_URL");
  const items = (rows ?? []).map((r: any) => {
    const isMyStore = Number(r.offering_store_id) === myStoreId;
    const images = resolveSpotImages(supabaseUrl, r.spot_images, r.sku?.product?.images);
    // 原價 = 來源訂單單價；釋出價 = 店家上架時自訂的 spot_price（沒填就用原價）。
    // 釋出價低於原價才回 original_price（會員端據此畫刪除線）；跨店兩者皆 null。
    const original = isMyStore && r.source_customer_order_id != null
      ? priceMap.get(`${r.source_customer_order_id}:${r.sku_id}`) ?? null
      : null;
    const spot = r.spot_price != null && Number.isFinite(Number(r.spot_price))
      ? Number(r.spot_price)
      : null;
    const price = isMyStore ? (spot ?? original) : null;
    const originalPrice = isMyStore && spot != null && original != null && original > spot
      ? original
      : null;
    return {
      id: Number(r.id),
      // 手動上架的現貨可能完全沒有 SKU（店家直接手打的商品）
      sku_id: r.sku_id != null ? Number(r.sku_id) : null,
      sku_code: r.sku?.sku_code ?? null,
      product_name: r.sku?.product_name ?? r.sku?.product?.name ?? null,
      variant_name: r.sku?.variant_name ?? null,
      // 上架時改寫的標題優先；沒改就由前端組 product_name／variant_name
      spot_title: r.spot_title ?? null,
      unit: r.spot_unit ?? r.sku?.base_unit ?? null,
      image_url: images[0] ?? null,
      store_id: Number(r.offering_store_id),
      store_name: storeNameMap.get(Number(r.offering_store_id)) ?? null,
      qty_remaining: Number(r.qty_remaining ?? 0),
      expires_at: r.expires_at,
      is_my_store: isMyStore,
      unit_price: price,
      original_price: originalPrice,
      view_count: viewMap.get(Number(r.id)) ?? 0,
    };
  });

  // 自己店的排前面（那些才看得到金額、才真的買得到），其餘維持最新在前
  items.sort((a: any, b: any) => Number(b.is_my_store) - Number(a.is_my_store));

  return json({
    items,
    my_store_id: myStoreId,
    my_store_name: storeNameMap.get(myStoreId) ?? null,
    my_store_line_oa_id: myStoreLineOaId,
  });
}

/**
 * 現貨專區單一商品詳情。
 *
 * 上架條件和列表完全一致（offer / active / 未到期 / 還有量 / 跨店可見性）——
 * 條件不符就回 404，不能因為「知道 id」就繞過列表看得到的範圍（例如已被認領光、
 * 已取消、已過期的貼文，別租戶的 id，或別店設成「只給本店會員看」的現貨）。
 *
 * 金額規則同列表：跨店連查都不查，`unit_price` 恆為 null。
 * 板上的 note 一樣不外露；LINE@ 只回會員自己店那一間的。
 */
async function getSpotProduct(
  sb: any,
  tenantId: string,
  jwtStoreId: number,
  memberId: number | null,
  boardId: number,
) {
  if (!boardId) return json({ error: "id required" }, 400);
  const myStoreId = await resolveMemberStoreId(sb, tenantId, jwtStoreId, memberId);

  const { data: r, error } = await sb
    .from("mutual_aid_board")
    .select(
      "id, offering_store_id, sku_id, qty_remaining, expires_at, created_at, source_customer_order_id, spot_price, spot_description, spot_title, spot_unit, spot_images, sku:skus(sku_code, product_name, variant_name, base_unit, product:products(name, description, images))",
    )
    .eq("tenant_id", tenantId)
    .eq("id", boardId)
    .eq("post_type", "offer")
    .eq("status", "active")
    .gt("qty_remaining", 0)
    .gt("expires_at", new Date().toISOString())
    // 同列表：只給本店看的，別店會員連知道 id 也開不出來（落到下面的 404）
    .or(`spot_visible_to_other_stores.eq.true,offering_store_id.eq.${myStoreId}`)
    .maybeSingle();
  if (error) return json({ error: error.message }, 500);
  if (!r) return json({ error: "spot product not found" }, 404);

  const isMyStore = Number(r.offering_store_id) === myStoreId;

  const { data: ss } = await sb
    .from("stores")
    .select("id, name, line_oa_basic_id")
    .eq("tenant_id", tenantId)
    .in("id", Array.from(new Set([myStoreId, Number(r.offering_store_id)])));
  let storeName: string | null = null;
  let myStoreName: string | null = null;
  let myStoreLineOaId: string | null = null;
  for (const s of ss ?? []) {
    if (Number(s.id) === Number(r.offering_store_id)) storeName = s.name;
    if (Number(s.id) === myStoreId) {
      myStoreName = s.name;
      // 只回自己店的 LINE@，別店的聯絡方式不外流
      myStoreLineOaId = (s.line_oa_basic_id ?? "").trim() || null;
    }
  }

  // 原價 = 來源訂單單價；釋出價 = spot_price 優先。低於原價才回 original_price
  // （刪除線用）。跨店連查都不查，兩者皆 null —— 同列表的金額隱藏規則。
  let originalPrice: number | null = null;
  let unitPrice: number | null = null;
  if (isMyStore) {
    let original: number | null = null;
    if (r.source_customer_order_id != null) {
      const { data: it } = await sb
        .from("customer_order_items")
        .select("unit_price")
        .eq("tenant_id", tenantId)
        .eq("order_id", r.source_customer_order_id)
        .eq("sku_id", r.sku_id)
        .limit(1)
        .maybeSingle();
      const p = Number(it?.unit_price);
      original = Number.isFinite(p) ? p : null;
    }
    const spot = r.spot_price != null && Number.isFinite(Number(r.spot_price))
      ? Number(r.spot_price)
      : null;
    unitPrice = spot ?? original;
    originalPrice = spot != null && original != null && original > spot ? original : null;
  }

  const supabaseUrl = requireEnv("SUPABASE_URL");
  const images = resolveSpotImages(supabaseUrl, r.spot_images, r.sku?.product?.images);

  // 瀏覽次數（本次瀏覽由前端另外打 track_spot_view 記，並拿回最新計數）
  const { data: viewRows } = await sb.rpc("rpc_spot_view_counts", {
    p_tenant: tenantId,
    p_board_ids: [Number(r.id)],
  });

  return json({
    item: {
      id: Number(r.id),
      // 手動上架的現貨可能完全沒有 SKU（店家直接手打的商品）
      sku_id: r.sku_id != null ? Number(r.sku_id) : null,
      sku_code: r.sku?.sku_code ?? null,
      product_name: r.sku?.product_name ?? r.sku?.product?.name ?? null,
      variant_name: r.sku?.variant_name ?? null,
      // 上架時改寫的標題優先；沒改就由前端組 product_name／variant_name
      spot_title: r.spot_title ?? null,
      // 上架時改寫的說明優先；沒改就 fallback 回商品主檔
      description: r.spot_description ?? r.sku?.product?.description ?? null,
      unit: r.spot_unit ?? r.sku?.base_unit ?? null,
      image_url: images[0] ?? null,
      images,
      store_id: Number(r.offering_store_id),
      store_name: storeName,
      qty_remaining: Number(r.qty_remaining ?? 0),
      expires_at: r.expires_at,
      is_my_store: isMyStore,
      unit_price: unitPrice,
      original_price: originalPrice,
      view_count: Number(viewRows?.[0]?.view_count ?? 0),
      viewer_count: Number(viewRows?.[0]?.viewer_count ?? 0),
    },
    my_store_id: myStoreId,
    my_store_name: myStoreName,
    my_store_line_oa_id: myStoreLineOaId,
  });
}

async function listActiveCampaigns(
  sb: any,
  tenantId: string,
  closeType?: string | null,
  memberId?: number | null,
  jwtStoreId?: number,
) {
  // 店家自開團（owner_store_id 非 NULL）只給該店的會員看。
  // 一定要在**這裡**濾 —— 前端藏卡片沒用，raw response 還是會外流
  // （理由同 listSpotProducts 的 spot_visible_to_other_stores）。
  const myStoreId = await resolveMemberStoreId(sb, tenantId, Number(jwtStoreId ?? 0), memberId ?? null);

  // end_at IS NULL 表示「無到期日」(管理員未設),也算進行中,要保留
  const campaignQuery = (withMainChannel: boolean, withStoreScope: boolean) => {
    let q = sb
      .from("group_buy_campaigns")
      .select(
        withStoreScope
          ? "id, campaign_no, name, description, cover_image_url, close_type, total_cap_qty, end_at, pickup_deadline, owner_store_id, campaign_items(unit_price, cap_qty, sort_order, sku:skus(product:products(images)))"
          : "id, campaign_no, name, description, cover_image_url, close_type, total_cap_qty, end_at, pickup_deadline, campaign_items(unit_price, cap_qty, sort_order, sku:skus(product:products(images)))",
      )
      .eq("tenant_id", tenantId)
      .eq("status", "open")
      .eq("is_for_shop", true)
      .neq("campaign_no", "__INTERNAL_RESTOCK__")
      .or(`end_at.is.null,end_at.gt.${new Date().toISOString()}`);
    // 一般商城永遠只讀 main；漂漂館走獨立 piaopiao-api。
    if (withMainChannel) q = q.eq("sales_channel", "main");
    // 店家自開團只給主辦店的會員；查不出會員所屬店（未綁定又沒有 JWT store）
    // 就只回總倉團，寧可少給也不要外流別店的團。
    if (withStoreScope) {
      q = myStoreId > 0
        ? q.or(`owner_store_id.is.null,owner_store_id.eq.${myStoreId}`)
        : q.is("owner_store_id", null);
    }
    if (closeType && closeType !== "sale_limit") q = q.eq("close_type", closeType);
    return q.order("end_at", { ascending: true, nullsFirst: false });
  };
  // 不加 limit：曾經 .limit(50) 在 open 團數超過 50 時把最晚結單的整批截掉
  // （end_at ASC NULLS LAST + 截 50），顧客端整個團就消失。PostgREST 仍有
  // db-max-rows=1000 兜底，55 個團也才一頁。
  let { data, error } = await campaignQuery(true, true);
  // 只有 migration 尚未套用時才可退舊查法；此時不可能已有漂漂團 / 店家自開團。
  if (isMissingOwnerStoreColumn(error)) ({ data, error } = await campaignQuery(true, false));
  if (isMissingSalesChannelColumn(error)) ({ data, error } = await campaignQuery(false, false));

  const sourceCampaigns = closeType === "sale_limit"
    ? (data ?? []).filter((c: any) =>
      c.close_type === "fast"
      || c.close_type === "limited"
      || (Number(c.total_cap_qty ?? 0) > 0 && c.close_type !== "food_train")
      || (c.close_type !== "food_train" && (c.campaign_items ?? []).some((i: any) => Number(i.cap_qty ?? 0) > 0))
    )
    : (data ?? []);

  const allIds = sourceCampaigns.map((c: any) => c.id);

  // 瀏覽次數（顧客端顯示「N 次瀏覽」）。RPC 未部署時整段當 0，不影響列表。
  const viewMap = new Map<number, number>();
  if (allIds.length > 0) {
    const { data: viewRows } = await sb.rpc("rpc_campaign_view_counts", {
      p_tenant: tenantId,
      p_campaign_ids: allIds,
    });
    for (const r of viewRows ?? []) {
      viewMap.set(Number(r.campaign_id), Number(r.view_count ?? 0));
    }
  }

  // 已下單總量（前端算「剩 N 份」/「搶購一空」/「已售出 N 份」）
  // + 訂單數 / 近 7 天訂單數（最熱銷、近期售出排序）。
  //
  // 三個數字一律走 rpc_member_campaign_aggregates，不要退回「撈訂單再在 JS
  // 加總」——那條路踩過兩個坑：
  //   1. PostgREST 有 1000 列上限且是**靜默截斷**。上架中的團底下有 1600+
  //      筆訂單，已售出會少算；換成一團一列的 RETURNS TABLE RPC 也一樣，
  //      團數 1500+ 照樣被截，而且截掉的是 id 最大的新團（= 正在賣的那些）。
  //      這支 RETURNS jsonb（單列單值）不受影響，再用 p_campaign_ids 限定
  //      只算這一頁的團。
  //   2. 轉單是「複製 + 標記」不是「搬移」，訂單層級要排除 transferred_out、
  //      品項層級要排除 cancelled（部分轉出的來源品項留在原單），否則已售出
  //      虛增、吃掉 cap_qty 名額，把還有貨的團顯示成售完。過濾規則收在
  //      RPC 內，與 admin 的 lib/orderStatus.ts 同一套。
  const orderedMap = new Map<number, number>();
  const countMap = new Map<number, number>();
  const recentMap = new Map<number, number>();
  if (allIds.length > 0) {
    const { data: aggRows, error: aggErr } = await sb.rpc("rpc_member_campaign_aggregates", {
      p_tenant: tenantId,
      p_recent_days: 7,
      p_campaign_ids: allIds,
    });
    // 靜默失敗會變成「全部 0 人下單、已售出 0」，看起來像沒人買 —— 留 log
    if (aggErr) console.error("[list_active_campaigns] aggregates rpc failed", aggErr);
    for (const r of (aggRows ?? []) as any[]) {
      const cid = Number(r.campaign_id);
      orderedMap.set(cid, Number(r.ordered_qty ?? 0));
      countMap.set(cid, Number(r.order_count ?? 0));
      recentMap.set(cid, Number(r.recent_order_count ?? 0));
    }
  }

  if (error) return json({ error: error.message }, 500);

  const supabaseUrl = requireEnv("SUPABASE_URL");
  const campaigns = sourceCampaigns.map((c: any) => {
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
      close_type: c.close_type,
      // 店家自開團：非 NULL = 這團是該店自己開的（前端置頂區塊 + 標籤用）
      owner_store_id: c.owner_store_id ?? null,
      total_cap_qty: c.total_cap_qty,
      has_item_cap: items.some((i: any) => Number(i.cap_qty ?? 0) > 0),
      ordered_qty: orderedMap.get(Number(c.id)) ?? 0,
      order_count: countMap.get(Number(c.id)) ?? 0,
      recent_order_count: recentMap.get(Number(c.id)) ?? 0,
      view_count: viewMap.get(Number(c.id)) ?? 0,
      end_at: c.end_at,
      pickup_deadline: c.pickup_deadline,
      item_count: prices.length,
      min_price: prices.length > 0 ? Math.min(...prices) : 0,
      max_price: prices.length > 0 ? Math.max(...prices) : 0,
    };
  });

  // 取貨提醒: 該會員「已備貨可取」(status='ready') 的訂單數
  let pendingPickupCount = 0;
  if (memberId) {
    const { count } = await sb
      .from("customer_orders")
      .select("id", { count: "exact", head: true })
      .eq("tenant_id", tenantId)
      .eq("member_id", memberId)
      .eq("status", "ready");
    pendingPickupCount = count ?? 0;
  }

  return json({ campaigns, pending_pickup_count: pendingPickupCount });
}

/**
 * 開團詳細。`available=false` 代表「只能看、不能下單」。
 *
 * 為什麼要有唯讀模式：訂單卡的品項點得進商品頁（2026-08-15），而會員的訂單
 * 絕大多數是**已結單**的團 —— 線上 6 個月內 69,540 張單裡，通過原本那道
 * 「open + is_for_shop + 還沒到 end_at」閘門的只有 2,114 張（3%）。
 * 沿用原本無條件 404 的話，等於每 30 張訂單卡有 29 張點下去是死路。
 *
 * 放寬的範圍卡在「這位會員自己買過這一團」：沒買過的人（含猜 id 的）
 * 一律維持 404，未上架 / 內部團不會因此外流。
 *
 * 不必擔心唯讀模式被繞過下單：`rpc_place_member_order_guarded`
 * 自己也擋 status / is_for_shop / end_at（20260813000000），
 * 寫入端的閘門跟這裡的讀取端閘門是同一套條件。
 */
async function getCampaignDetail(sb: any, tenantId: string, campaignId: number, memberId: number | null, salesChannel?: string | null, jwtStoreId?: number) {
  const cols = "id, campaign_no, name, description, cover_image_url, status, close_type, end_at, pickup_deadline, total_cap_qty, is_for_shop";
  const runCampaignQuery = (withStoreScope: boolean) =>
    sb
      .from("group_buy_campaigns")
      .select(withStoreScope ? `${cols}, owner_store_id` : cols)
      .eq("tenant_id", tenantId)
      .eq("id", campaignId)
      .eq("sales_channel", salesChannel === "piaopiao" ? "piaopiao" : "main")
      .single();
  let { data: c, error: cErr } = await runCampaignQuery(true);
  if (isMissingOwnerStoreColumn(cErr)) ({ data: c, error: cErr } = await runCampaignQuery(false));
  if (cErr || !c) return json({ error: "campaign not found" }, 404);

  // 店家自開團只有主辦店的會員能看 —— 連結被轉貼給別店的客人時當作不存在。
  // 列表已經濾過，這裡是直接開網址（/shop/c/<id>）那條路的防線。
  if (c.owner_store_id) {
    const myStoreId = await resolveMemberStoreId(sb, tenantId, Number(jwtStoreId ?? 0), memberId);
    if (Number(c.owner_store_id) !== myStoreId) {
      return json({ error: "campaign not found" }, 404);
    }
  }

  const available = c.status === "open"
    && !!c.is_for_shop
    && !(c.end_at && new Date(c.end_at).getTime() <= Date.now());
  if (!available) {
    if (!memberId) return json({ error: "campaign not available" }, 404);
    // 自己的訂單（含取消 / 逾期的）才放行 —— 客人要回頭看「我買的是什麼」，
    // 而訂單被取消時最需要看的就是那一頁。
    const { count, error: oErr } = await sb
      .from("customer_orders")
      .select("id", { count: "exact", head: true })
      .eq("tenant_id", tenantId)
      .eq("member_id", memberId)
      .eq("campaign_id", campaignId);
    if (oErr || !count) return json({ error: "campaign not available" }, 404);
  }
  c.available = available;

  const { data: items, error: iErr } = await sb
    .from("campaign_items")
    .select("id, unit_price, cap_qty, sort_order, sku:skus(id, sku_code, product_name, variant_name, product:products(name, images))")
    .eq("tenant_id", tenantId)
    .eq("campaign_id", campaignId)
    .order("sort_order", { ascending: true });
  if (iErr) return json({ error: iErr.message }, 500);

  // 算出活動總訂單數
  const { count: orderCount } = await sb
    .from("customer_orders")
    .select("*", { count: "exact", head: true })
    .eq("tenant_id", tenantId)
    .eq("campaign_id", campaignId)
    .not("status", "in", "(cancelled,expired)")
    .or("order_kind.is.null,order_kind.eq.normal");
  c.order_count = orderCount ?? 0;

  // 瀏覽次數（這次的瀏覽由前端另外打 track_campaign_view 記，並拿回最新計數）
  const { data: viewRows } = await sb.rpc("rpc_campaign_view_counts", {
    p_tenant: tenantId,
    p_campaign_ids: [campaignId],
  });
  c.view_count = Number(viewRows?.[0]?.view_count ?? 0);
  c.viewer_count = Number(viewRows?.[0]?.viewer_count ?? 0);

  // 算出各品項已下單總量（過濾規則同 listActiveCampaigns 的 orderedMap：
  // 訂單層級排除 cancelled/expired/transferred_out、品項層級排除 cancelled/expired，
  // 否則轉出的量會被算兩次、吃掉 cap_qty 名額）
  //
  // order_kind 的「normal 或 null」不能用 .or() 寫 —— PostgREST 的 or= 是
  // 頂層 logic tree，塞 embedded 欄位（customer_orders.order_kind.…）會被
  // 直接拒收：PGRST100 "failed to parse logic tree"。supabase-js 把錯誤放在
  // 這裡沒接的 error 欄位，data 變 null ⇒ 整張表已售出通通顯示 0（這段
  // 從寫下來就是壞的，不是這次改壞的）。改成 DB 只做得到的過濾、
  // order_kind 拉回來在 JS 判，行為與 listActiveCampaigns 那段一致。
  const itemOrderedMap = new Map<number, number>();
  const { data: itemOrderRows, error: itemOrderErr } = await sb
    .from("customer_order_items")
    .select("campaign_item_id, qty, customer_orders!inner(status, order_kind)")
    .eq("tenant_id", tenantId)
    .eq("customer_orders.campaign_id", campaignId)
    .not("status", "in", "(cancelled,expired)")
    .not("customer_orders.status", "in", "(cancelled,expired,transferred_out)");
  if (itemOrderErr) {
    // 靜默失敗會變成「全部已售出 0」，看起來像沒人買 —— 留 log 才查得到
    console.error("[get_campaign_detail] item ordered_qty query failed", itemOrderErr);
  }

  for (const row of itemOrderRows ?? []) {
    const kind = row.customer_orders?.order_kind;
    if (kind != null && kind !== "normal") continue;
    const ciId = Number(row.campaign_item_id);
    const q = Number(row.qty ?? 0);
    itemOrderedMap.set(ciId, (itemOrderedMap.get(ciId) ?? 0) + q);
  }

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
      ordered_qty: itemOrderedMap.get(Number(it.id)) ?? 0,
    };
  });
  return json({ campaign: c, items: flat, hero_images: heroPaths });
}

/**
 * 分享連結的預覽卡資料（OG tags 用），**免 token**。
 *
 * 為什麼要另外一支而不是重用 get_campaign_detail：貼到 LINE / FB 之後去抓
 * OG tag 的是對方的爬蟲，它沒有、也不可能有會員 JWT。所以這支必須掛在
 * dispatcher 的免 token 區，回傳的欄位也只挑「連結本來就打算給所有人看的」
 * ——團名、封面圖、起跳價、結單時間，沒有任何會員 / 訂單資訊。
 *
 * 過期或已結單的團**照樣回**：連結已經在群組裡了，讓它顯示團名與圖，
 * 比退回一張店家 logo 的通用卡有用（頁面本身還是會擋下單）。
 * 只擋掉「本來就不該出現在賣場」的：非 is_for_shop、內部補貨 sentinel。
 */
async function getCampaignPreview(sb: any, tenantId: string, campaignId: number, salesChannel?: string | null) {
  if (!campaignId) return json({ error: "campaign_id required" }, 400);

  let previewQuery = sb
    .from("group_buy_campaigns")
    .select(
      "id, campaign_no, name, description, cover_image_url, status, is_for_shop, end_at, campaign_items(unit_price, sort_order, sku:skus(product:products(images)))",
    )
    .eq("tenant_id", tenantId)
    .eq("id", campaignId);
  previewQuery = previewQuery.eq("sales_channel", salesChannel === "piaopiao" ? "piaopiao" : "main");
  const { data: c, error } = await previewQuery.maybeSingle();
  if (error) return json({ error: error.message }, 500);
  if (!c || !c.is_for_shop || c.campaign_no === "__INTERNAL_RESTOCK__") {
    return json({ error: "campaign not found" }, 404);
  }

  const supabaseUrl = requireEnv("SUPABASE_URL");
  const items = [...(c.campaign_items ?? [])].sort(
    (a: any, b: any) => Number(a.sort_order ?? 0) - Number(b.sort_order ?? 0),
  );

  // 圖：團封面優先，沒設就退回第一個品項的商品主圖 —— 很多團是直接沿用
  // 商品照沒另外上傳封面，少了這一步那些團的預覽卡就沒圖。
  let image = toPublicUrl(supabaseUrl, "products", c.cover_image_url);
  if (!image) {
    for (const it of items) {
      const imgs = (it as any).sku?.product?.images;
      if (!Array.isArray(imgs) || imgs.length === 0) continue;
      const raw = typeof imgs[0] === "string" ? imgs[0] : imgs[0]?.url ?? null;
      const url = toPublicUrl(supabaseUrl, "products", raw);
      if (url) { image = url; break; }
    }
  }

  const prices = items
    .map((it: any) => Number(it.unit_price))
    .filter((n: number) => Number.isFinite(n) && n > 0);

  return json({
    campaign: {
      id: c.id,
      campaign_no: c.campaign_no,
      name: c.name,
      description: c.description,
      image_url: image,
      price_from: prices.length > 0 ? Math.min(...prices) : null,
      status: c.status,
      end_at: c.end_at,
    },
  });
}

/**
 * 記一次商品瀏覽，回傳更新後的計數。
 *
 * 去重（同會員同商品 30 分鐘內只算一次）在 SQL 裡做 —— 前端的 useEffect
 * 會因為返回 / 重整重跑，只靠前端擋不住，數字會失真。
 */
async function trackCampaignView(
  sb: any,
  tenantId: string,
  memberId: number,
  campaignId: number,
  salesChannel: string | null,
) {
  if (!campaignId) return json({ error: "campaign_id required" }, 400);
  const requiredSalesChannel = salesChannel === "piaopiao" ? "piaopiao" : "main";
  const { data: campaign, error: campaignError } = await sb.from("group_buy_campaigns")
    .select("id")
    .eq("id", campaignId)
    .eq("tenant_id", tenantId)
    .eq("sales_channel", requiredSalesChannel)
    .maybeSingle();
  if (campaignError) return json({ error: campaignError.message }, 500);
  if (!campaign) return json({ error: "campaign not found" }, 404);
  const { data, error } = await sb.rpc("rpc_track_campaign_view", {
    p_tenant: tenantId,
    p_campaign_id: campaignId,
    p_member_id: memberId,
  });
  if (error) return json({ error: error.message }, 500);
  const row = Array.isArray(data) ? data[0] : data;
  return json({
    view_count: Number(row?.view_count ?? 0),
    viewer_count: Number(row?.viewer_count ?? 0),
  });
}

/** 記一次現貨商品瀏覽（規則同 trackCampaignView，只是換一張表） */
async function trackSpotView(
  sb: any,
  tenantId: string,
  memberId: number,
  boardId: number,
) {
  if (!boardId) return json({ error: "id required" }, 400);
  const { data, error } = await sb.rpc("rpc_track_spot_view", {
    p_tenant: tenantId,
    p_board_id: boardId,
    p_member_id: memberId,
  });
  if (error) return json({ error: error.message }, 500);
  const row = Array.isArray(data) ? data[0] : data;
  return json({
    view_count: Number(row?.view_count ?? 0),
    viewer_count: Number(row?.viewer_count ?? 0),
  });
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
  // 下單通路（前端 detectClientChannel() 帶上來）：'pwa' = 會員 App、'liff' = LINE 商城。
  // 只收白名單，舊版前端 / 亂帶值一律退回 'liff' —— 那是這個欄位在
  // 2026-08-08 之前的唯一值，口徑才不會斷掉（見 migration 20260808000020）。
  const itemSource = p.client === "pwa" ? "pwa" : "liff";

  if (!campaignId) return json({ error: "campaign_id required" }, 400);
  if (items.length === 0) return json({ error: "items required" }, 400);
  const requiredSalesChannel = p.sales_channel === "piaopiao" ? "piaopiao" : "main";
  const campaignCols = "id, close_type, total_cap_qty, campaign_items(cap_qty)";
  const runCampaign = (withStoreScope: boolean) =>
    sb
      .from("group_buy_campaigns")
      .select(withStoreScope ? `${campaignCols}, owner_store_id` : campaignCols)
      .eq("tenant_id", tenantId)
      .eq("id", campaignId)
      .eq("sales_channel", requiredSalesChannel)
      .maybeSingle();
  let { data: campaign, error: campaignErr } = await runCampaign(true);
  if (isMissingOwnerStoreColumn(campaignErr)) ({ data: campaign, error: campaignErr } = await runCampaign(false));
  if (campaignErr || !campaign) return json({ error: "campaign not available" }, 404);

  // 取得 member + home_store
  const { data: member, error: mErr } = await sb
    .from("members")
    .select("id, name, home_store_id")
    .eq("tenant_id", tenantId)
    .eq("id", memberId)
    .single();
  if (mErr || !member) {
    return json({
      error: "member not found",
      detail: `memberId=${memberId} tenantId=${tenantId} dbErr=${mErr?.message ?? "no rows"}`,
    }, 404);
  }

  const pickupStoreId = Number(p.pickup_store_id ?? member.home_store_id ?? 0);
  if (!pickupStoreId) return json({ error: "pickup_store_id required" }, 400);

  // 店家自開團：只有主辦店的客人能下單，而且一定在主辦店取貨。
  // 這團的貨是該店自己買的、只由該店負責出（rpc_receive_store_campaign 收貨時
  // 也只推 pickup_store = 主辦店 的訂單），別店的單根本沒有人會去配貨。
  if (campaign.owner_store_id && Number(campaign.owner_store_id) !== pickupStoreId) {
    return json({ error: "這個團只開放給該分店的會員，請確認你的取貨門市", code: "store_campaign_other_store" }, 403);
  }

  // ── 限量團閘門：先綁定取貨店的 LINE 官方帳號才能下單 ──────────────────────
  // 「限量」判準與商城「限量搶購」分頁同一套（listActiveCampaigns 的 sale_limit）：
  // fast / limited、或非 food_train 而設了總量 / 單品上限。要求綁定的原因：
  // 限量品搶到就是承諾，棄單店家要聯絡得到人（同一條綁定也餵「到貨通知」推播）。
  // 店家沒設 OA / 憑證不擋 —— 擋了也沒有任何路可以完成綁定。
  // 閘門查詢失敗一律放行：這是商業規則不是安全邊界，不能因基礎設施出錯全面擋單。
  const closeType = String(campaign.close_type ?? "");
  const isLimitedSale = closeType === "fast" || closeType === "limited" || (
    closeType !== "food_train" && (
      Number(campaign.total_cap_qty ?? 0) > 0
      || (campaign.campaign_items ?? []).some((i: any) => Number(i.cap_qty ?? 0) > 0)
    )
  );
  if (isLimitedSale) {
    try {
      const target = await resolveLineBindTarget(sb, tenantId, pickupStoreId);
      if (target.bindable && !(await memberBoundToStore(sb, pickupStoreId, memberId))) {
        // error 字串是舊版前端唯一看得到的東西（alert 原文照噴），要能照著做：
        // 加好友 → 傳一則訊息 → webhook 會回 account link 連結完成綁定。
        // 新版前端認 code 欄位，改走綁定碼彈窗（一鍵完成），不會看到這段字。
        return json({
          error: `此為限量商品，請先加入${target.storeName ?? "店家"}的 LINE 官方帳號（${target.oaId}）並傳一則訊息完成綁定，再回來下單`,
          code: "line_binding_required",
          detail: { store_id: pickupStoreId, store_name: target.storeName, oa_id: target.oaId },
        }, 403);
      }
    } catch (e) {
      console.error("[place_member_order] line bind gate check failed, allowing order:", e);
    }
  }

  const requested = new Map<number, number>();
  for (const it of items) {
    const ciId = Number(it.campaign_item_id);
    const qty = Number(it.qty);
    if (!ciId || !Number.isFinite(qty) || qty <= 0) continue;
    requested.set(ciId, (requested.get(ciId) ?? 0) + qty);
  }
  if (requested.size === 0) return json({ error: "items required" }, 400);

  // 找下單用 line_channel：
  //   1) 優先：pickup store 自己的 active channel
  //   2) 退回：tenant 任一 active channel（系統常見 setup 是「全店共用一個 LINE bot 下單入口」，
  //      只有少數店建了自己專屬 channel；中和店等只有「補貨申請」channel 的店會走這條 fallback）
  let channel: { id: number } | null = null;
  const { data: storeChannel } = await sb
    .from("line_channels")
    .select("id")
    .eq("tenant_id", tenantId)
    .eq("home_store_id", pickupStoreId)
    .eq("is_active", true)
    .order("id", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (storeChannel) channel = storeChannel;
  if (!channel) {
    const { data: anyChannel } = await sb
      .from("line_channels")
      .select("id")
      .eq("tenant_id", tenantId)
      .eq("is_active", true)
      .order("id", { ascending: true })
      .limit(1)
      .maybeSingle();
    if (anyChannel) channel = anyChannel;
  }
  if (!channel) return json({ error: "no active channel for tenant" }, 400);

  const rpcItems = Array.from(requested.entries()).map(([campaign_item_id, qty]) => ({
    campaign_item_id,
    qty,
  }));
  const { data: placedRows, error: placeErr } = await sb.rpc("rpc_place_member_order_guarded", {
    p_tenant: tenantId,
    p_campaign_id: campaignId,
    p_channel_id: channel.id,
    p_member_id: memberId,
    p_pickup_store_id: pickupStoreId,
    p_items: rpcItems,
    p_notes: notes,
    p_source: itemSource,
  });
  if (placeErr) {
    const msg = placeErr.message ?? "";
    if (msg.includes("item sold out")) return json({ error: "item sold out" }, 409);
    if (msg.includes("sold out")) return json({ error: "sold out" }, 409);
    if (msg.includes("campaign not found")) return json({ error: "campaign not found" }, 404);
    if (msg.includes("member not found")) return json({ error: "member not found" }, 404);
    return json({ error: msg || "failed to create order" }, 400);
  }
  const placed = Array.isArray(placedRows) ? placedRows[0] : placedRows;
  return json({ ok: true, order_id: placed?.order_id, order_no: placed?.order_no });
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

/**
 * 收前端的錯誤 log。**不需要 token** — 最需要記錄的正是「還沒登入就壞掉」。
 *
 * 因為是開放端點，所有欄位一律截長度、且每分鐘全域上限 300 筆；
 * 超過就靜默丟掉（回 ok，不讓前端因為 log 失敗再噴一次錯）。
 * 有帶合法 token 時才補 member_id / store_id / line_user_id。
 */
// 開放端點共用的截長工具：欄位一律限制長度，free-form JSON 超長就截斷保留頭段
function cut(v: unknown, n: number): string | null {
  if (v === null || v === undefined) return null;
  const s = typeof v === "string" ? v : String(v);
  return s.length > n ? s.slice(0, n) : s;
}
function cutJson(v: unknown, n: number): unknown {
  if (v === null || v === undefined) return null;
  const s = JSON.stringify(v);
  if (s === undefined) return null;
  return s.length > n ? { truncated: true, raw: s.slice(0, n) } : v;
}

/** 洩洪閥：client_error_logs 每分鐘全域上限，超過回 true（呼叫端靜默丟掉） */
async function clientLogRateLimited(sb: any): Promise<boolean> {
  const since = new Date(Date.now() - 60_000).toISOString();
  const { count } = await sb
    .from("client_error_logs")
    .select("id", { count: "exact", head: true })
    .gte("created_at", since);
  return typeof count === "number" && count >= 300;
}

async function logClientError(
  sb: any,
  tenantId: string,
  body: Record<string, unknown>,
  claims: Record<string, unknown> | null,
) {
  const message = cut(body.message, 500);
  if (!message) return json({ ok: false, error: "message required" }, 400);

  // 洩洪閥：前端進到 render loop 時不要把 DB 灌爆
  if (await clientLogRateLimited(sb)) {
    return json({ ok: true, dropped: "rate_limited" });
  }

  const level = ["error", "warn", "info"].includes(String(body.level))
    ? String(body.level)
    : "error";

  const { error } = await sb.from("client_error_logs").insert({
    tenant_id:    tenantId,
    member_id:    claims?.member_id ? Number(claims.member_id) : null,
    line_user_id: claims?.line_user_id ? cut(claims.line_user_id, 64) : cut(body.line_user_id, 64),
    store_code:   cut(body.store_code, 32),
    level,
    source:       cut(body.source, 64) ?? "unknown",
    message,
    detail:       cutJson(body.detail, 4000),
    page_url:     cut(body.page_url, 500),
    user_agent:   cut(body.user_agent, 300),
    env:          cutJson(body.env, 1000),
  });
  if (error) {
    console.error("log_client_error insert failed:", error);
    return json({ ok: false, error: error.message }, 500);
  }
  return json({ ok: true });
}

/**
 * 使用者主動回報：把前端本機 ring buffer 整包收進來，存成**一筆** `user_report`。
 * 一筆 = 一次回報，detail.logs 內含完整清單 — 分析時一個 row 就是一個現場。
 *
 * 跟 log_client_error 一樣免 token（登入壞掉時最需要回報），
 * 也一樣吃全域洩洪閥；上限 50 筆、每筆欄位都截長。
 */
async function reportClientLogs(
  sb: any,
  tenantId: string,
  body: Record<string, unknown>,
  claims: Record<string, unknown> | null,
) {
  const rawLogs = Array.isArray(body.logs) ? body.logs.slice(-50) : [];

  if (await clientLogRateLimited(sb)) {
    return json({ ok: true, dropped: "rate_limited" });
  }

  const logs = rawLogs.map((l) => {
    const e = (l ?? {}) as Record<string, unknown>;
    return {
      at:      cut(e.at, 40),
      level:   ["error", "warn", "info"].includes(String(e.level)) ? String(e.level) : "error",
      source:  cut(e.source, 64),
      message: cut(e.message, 500),
      detail:  cutJson(e.detail, 1500),
    };
  });
  const note = cut(body.note, 500);

  const { error } = await sb.from("client_error_logs").insert({
    tenant_id:    tenantId,
    member_id:    claims?.member_id ? Number(claims.member_id) : null,
    line_user_id: claims?.line_user_id ? cut(claims.line_user_id, 64) : cut(body.line_user_id, 64),
    store_code:   cut(body.store_code, 32),
    level:        "info",
    source:       "user_report",
    message:      `使用者主動回報（${logs.length} 筆）${note ? `：${note}` : ""}`.slice(0, 500),
    detail:       { note, count: logs.length, logs },
    page_url:     cut(body.page_url, 500),
    user_agent:   cut(body.user_agent, 300),
    env:          cutJson(body.env, 1000),
  });
  if (error) {
    console.error("report_client_logs insert failed:", error);
    return json({ ok: false, error: error.message }, 500);
  }
  return json({ ok: true, received: logs.length });
}

/**
 * 滑動續期：token 剩餘壽命不足就換發一顆，用 `renewed_token` 欄位夾帶回前端。
 *
 * 為什麼寄生在既有回應上而不是獨立端點：續期要「使用者有在用」才發生，
 * 而每個 action 本身就是「有在用」的證據，多開一支端點只是多一次往返。
 *
 * 三個保護：
 *   - 只加在成功的 JSON 物件回應上（失敗回應前端走 throw 路徑，不會讀 body）
 *   - 用 clone() 讀 body，續期失敗時原回應還能原封不動送出去
 *   - 整段包 try —— 延長 session 是加值功能，絕不能讓它把本來成功的請求弄失敗
 */
async function withRenewedToken(
  resp: Response,
  claims: JwtClaims,
  secret: string,
): Promise<Response> {
  try {
    if (!resp.ok) return resp;
    if (!resp.headers.get("content-type")?.includes("application/json")) return resp;

    const next = await renewSessionTokenIfNeeded(claims, secret);
    if (!next) return resp;

    const body = await resp.clone().json();
    if (body === null || typeof body !== "object" || Array.isArray(body)) return resp;
    return json({ ...body, renewed_token: next });
  } catch (e) {
    console.error("token renew failed:", e);
    return resp;
  }
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
    // 分享連結的 OG 預覽：呼叫的是 LINE / FB 的爬蟲（沒有會員 token），必須免驗
    if (action === "get_campaign_preview") {
      return await getCampaignPreview(sb, requireEnv("DEFAULT_TENANT_ID"), Number(body.campaign_id ?? 0), typeof body.sales_channel === "string" ? body.sales_channel : null);
    }
    if (action === "guest_heartbeat") {
      // 商城訪客心跳（未登入逛 /shop 的人也要算進在線統計）：免 token。
      // anon id 由前端 localStorage 產生；UUID 格式檢查與灌水守衛（新列
      // 速率上限）都在 rpc_guest_heartbeat 裡，這裡照單轉交即可。
      const { error: ghErr } = await sb.rpc("rpc_guest_heartbeat", {
        p_tenant: requireEnv("DEFAULT_TENANT_ID"),
        p_anon_id: String(body.anon_id ?? ""),
        p_store_id: Number(body.store_id ?? 0) > 0 ? Number(body.store_id) : null,
      });
      if (ghErr) console.error("guest_heartbeat failed:", ghErr);
      return json({ ok: true });
    }
    if (action === "log_client_error" || action === "report_client_logs") {
      // 有帶 token 就順便解出來補會員資訊；解不開不算錯（登入前的錯誤本來就沒 token）
      let logClaims: Record<string, unknown> | null = null;
      const logAuth = req.headers.get("authorization");
      if (logAuth) {
        try {
          logClaims = await verifyJwtHs256(
            logAuth.replace(/^Bearer\s+/i, ""),
            requireEnv("PROJECT_JWT_SECRET"),
          ) as Record<string, unknown>;
        } catch { /* 匿名記錄 */ }
      }
      const logTenant = logClaims?.tenant_id
        ? String(logClaims.tenant_id)
        : requireEnv("DEFAULT_TENANT_ID");
      return action === "log_client_error"
        ? await logClientError(sb, logTenant, body, logClaims)
        : await reportClientLogs(sb, logTenant, body, logClaims);
    }

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

    const resp = await (async (): Promise<Response> => {
      switch (action) {
        case "lookup_by_phone": return await lookupByPhone(sb, tenantId, String(body.phone ?? ""));
        case "register_and_bind": return await registerAndBind(sb, { tenantId, storeId, lineUserId, phone: String(body.phone ?? ""), name: String(body.name ?? ""), birthday: String(body.birthday ?? "") });
        case "create_account_link_nonce": if (!memberId) return json({ error: "no member_id" }, 401); return await createAccountLinkNonce(sb, tenantId, memberId, String(body.store ?? ""));
        case "get_me": if (!memberId) return json({ error: "no member_id" }, 401); return await getMe(sb, tenantId, memberId);
        case "update_me": if (!memberId) return json({ error: "no member_id" }, 401); return await updateMe(sb, tenantId, memberId, body);
        case "get_overview": if (!memberId) return json({ error: "no member_id" }, 401); return await getOverview(sb, tenantId, storeId, memberId);
        case "get_wallet": if (!memberId) return json({ error: "no member_id" }, 401); return await getWallet(sb, tenantId, memberId);
        case "list_wallet_ledger": if (!memberId) return json({ error: "no member_id" }, 401); return await listWalletLedger(sb, tenantId, memberId, body);
        case "list_my_orders": if (!memberId) return json({ error: "no member_id" }, 401); return await listMyOrders(sb, tenantId, storeId, memberId, String(body.tab ?? ""));
        case "list_my_settlements": if (!memberId) return json({ error: "no member_id" }, 401); return await listMySettlements(sb, tenantId, storeId, memberId, String(body.tab ?? ""));
        case "upsert_push_subscription": if (!memberId) return json({ error: "no member_id" }, 401); return await upsertPushSubscription(sb, tenantId, memberId, body);
        case "list_my_notifications": if (!memberId) return json({ error: "no member_id" }, 401); return await listMyNotifications(sb, tenantId, memberId);
        case "get_my_unread_notification_count": if (!memberId) return json({ error: "no member_id" }, 401); return await getMyUnreadNotificationCount(sb, tenantId, memberId);
        case "mark_notification_read": if (!memberId) return json({ error: "no member_id" }, 401); return await markNotificationRead(sb, tenantId, memberId, body);
        case "generate_pwa_auth_code": if (!memberId) return json({ error: "no member_id" }, 401); return await generatePwaAuthCode(sb, tenantId, memberId, claims, token, body);
        case "list_active_campaigns": return await listActiveCampaigns(sb, tenantId, typeof body.close_type === "string" ? body.close_type : null, memberId, storeId);
        case "get_campaign_detail": return await getCampaignDetail(sb, tenantId, Number(body.campaign_id ?? 0), memberId, typeof body.sales_channel === "string" ? body.sales_channel : null, storeId);
        case "track_campaign_view": if (!memberId) return json({ error: "no member_id" }, 401); return await trackCampaignView(sb, tenantId, memberId, Number(body.campaign_id ?? 0), typeof body.sales_channel === "string" ? body.sales_channel : null);
        case "list_spot_products": return await listSpotProducts(sb, tenantId, storeId, memberId);
        case "get_spot_product": return await getSpotProduct(sb, tenantId, storeId, memberId, Number(body.id ?? 0));
        case "track_spot_view": if (!memberId) return json({ error: "no member_id" }, 401); return await trackSpotView(sb, tenantId, memberId, Number(body.id ?? 0));
        case "heartbeat": {
          // 在線心跳（admin 儀表板「同時在線 / DAU」）。身分一律取自驗過的 JWT。
          if (!memberId) return json({ error: "no member_id" }, 401);
          const { error: hbErr } = await sb.rpc("rpc_member_heartbeat", { p_tenant: tenantId, p_member_id: memberId, p_store_id: storeId || null });
          if (hbErr) { console.error("heartbeat failed:", hbErr); return json({ ok: false }, 500); }
          return json({ ok: true });
        }
        case "place_member_order": if (!memberId) return json({ error: "no member_id" }, 401); return await placeMemberOrder(sb, tenantId, memberId, body);
        case "get_line_bind_state": if (!memberId) return json({ error: "no member_id" }, 401); return await getLineBindState(sb, tenantId, memberId, Number(body.store_id ?? 0) || storeId);
        case "start_line_binding": if (!memberId) return json({ error: "no member_id" }, 401); return await startLineBinding(sb, tenantId, memberId, Number(body.store_id ?? 0) || storeId);
        default: return json({ error: `unknown action: ${action}` }, 400);
      }
    })();
    return await withRenewedToken(resp, claims, jwtSecret);
  } catch (e) {
    console.error("liff-api error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

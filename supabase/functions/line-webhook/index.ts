// line-webhook: 收各分店 LINE 官方帳號的 Messaging API webhook 事件
//
// 這支存在的理由：LINE 的 user ID 綁 Provider。14 家店的 OA 各在自己的
// Provider，members.line_user_id（來自單一支 Login channel）對任何一家店的 OA
// 都查不到（2026-08-07 實測：松山店 12 位活躍會員全數 404）。要推播就必須拿到
// 「該店 provider 的 ID」，而唯一的來源就是該店 OA 自己的 webhook。
//
// 設定方式：每家店的 Webhook URL 各自帶自己的 store code，例：
//   https://<project>.supabase.co/functions/v1/line-webhook?store=S002
// 用 query 而不是靠 body 的 destination 判斷，是因為**驗簽需要先知道用哪把
// channel secret**；URL 帶著就不必先信任未驗證的 body。
// （沒帶 store 時才退而求其次用 destination 比對 bot_user_id。）
//
// ⚠ verify_jwt 必須是 false：LINE 不會帶我們的 JWT。安全性靠 X-Line-Signature
//   驗簽（HMAC-SHA256 + channel secret），驗不過一律 403。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";

const LINE_PROFILE_URL = "https://api.line.me/v2/bot/profile";
const LINE_REPLY_URL = "https://api.line.me/v2/bot/message/reply";
const LINE_LINK_TOKEN_URL = (uid: string) => `https://api.line.me/v2/bot/user/${uid}/linkToken`;

/** 同一個人多久內只邀一次綁定 —— 不擋的話每傳一句話就收到一則機器訊息 */
const INVITE_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * 對「還不知道是誰」的顧客回一則帶 account link 的訊息。
 *
 * 刻意包裝成「查看我的訂單」而不是「請完成綁定」：顧客本來就是來問訂單的，
 * 點下去就看到訂單，綁定是順帶發生的副作用，他不需要理解綁定是什麼。
 *
 * 用 replyToken 回覆 —— **不吃推播額度**，所以這個機制本身零成本。
 * 失敗一律吞掉：邀請沒送出去不該影響 webhook 回 200（LINE 會重送整批事件）。
 */
async function inviteAccountLink(
  accessToken: string,
  replyToken: string,
  lineUserId: string,
  storeCode: string,
  memberBase: string,
): Promise<boolean> {
  try {
    const ltResp = await fetch(LINE_LINK_TOKEN_URL(lineUserId), {
      method: "POST",
      headers: { "Authorization": `Bearer ${accessToken}` },
    });
    if (!ltResp.ok) {
      console.error("linkToken failed:", ltResp.status, await ltResp.text());
      return false;
    }
    const { linkToken } = await ltResp.json();
    // linkToken 只有 10 分鐘效期，所以是「當下回覆」才有意義，不能事後補寄
    const url = `${memberBase}/link?lt=${encodeURIComponent(linkToken)}&store=${encodeURIComponent(storeCode)}`;

    const rResp = await fetch(LINE_REPLY_URL, {
      method: "POST",
      headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        replyToken,
        messages: [{
          type: "text",
          text: `您好！這裡可以查看您的訂單與取貨進度 👇\n${url}`,
        }],
      }),
    });
    if (!rResp.ok) {
      console.error("reply failed:", rResp.status, await rResp.text());
      return false;
    }
    return true;
  } catch (e) {
    console.error("inviteAccountLink error:", String(e));
    return false;
  }
}

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

/** X-Line-Signature = Base64(HMAC-SHA256(channel_secret, raw_body)) */
async function verifySignature(
  rawBody: string,
  signature: string,
  channelSecret: string,
): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(channelSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
  // 長度不同直接不等；長度相同才逐字元比，避免早退洩漏資訊
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  // LINE 只會 POST。回 200 要快 —— 逾時 LINE 會判定 webhook 失敗並停用。
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  try {
    const url = new URL(req.url);
    const storeCode = url.searchParams.get("store");
    const rawBody = await req.text();
    const signature = req.headers.get("x-line-signature") ?? "";

    const sb = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } },
    );

    // 找出這通 webhook 屬於哪一家店（要拿它的 channel secret 驗簽）
    let credQuery = sb
      .from("store_line_oa_credentials")
      .select("store_id, tenant_id, channel_secret, access_token, stores!inner(code)");
    if (storeCode) {
      credQuery = credQuery.eq("stores.code", storeCode);
    } else {
      // 沒帶 store：用 body 的 destination（= OA 自己的 userId）比對。
      // 這裡讀的是**還沒驗簽**的 body，只當查表 key 用，不做任何信任決策。
      const dest = (() => { try { return JSON.parse(rawBody)?.destination ?? null; } catch { return null; } })();
      if (!dest) return new Response("store not specified", { status: 400 });
      credQuery = credQuery.eq("bot_user_id", dest);
    }
    const { data: cred, error: credErr } = await credQuery.maybeSingle();
    if (credErr) {
      console.error("cred lookup failed:", credErr.message);
      return new Response("internal", { status: 500 });
    }
    if (!cred) {
      console.error("no credentials for store:", storeCode);
      return new Response("unknown store", { status: 404 });
    }
    // PostgREST 的 to-one 關聯有時回物件、有時回陣列，兩種都要接得住
    const credStoreCode: string | null =
      (Array.isArray(cred.stores) ? cred.stores[0]?.code : cred.stores?.code) ?? storeCode;

    if (!await verifySignature(rawBody, signature, cred.channel_secret)) {
      console.error("bad signature for store:", storeCode);
      return new Response("bad signature", { status: 403 });
    }

    const body = JSON.parse(rawBody);
    const events: Record<string, unknown>[] = body.events ?? [];

    // LINE 後台按「Verify」時送的是空 events —— 必須回 200 才算驗證成功
    if (events.length === 0) return new Response("ok", { status: 200 });

    for (const ev of events) {
      const type = ev.type as string;
      const source = ev.source as Record<string, unknown> | undefined;
      const lineUserId = source?.userId as string | undefined;
      if (!lineUserId) continue;   // 群組 / 聊天室事件沒有 userId，略過

      const at = ev.timestamp ? new Date(Number(ev.timestamp)).toISOString() : new Date().toISOString();

      if (type === "unfollow") {
        await sb.from("store_line_followers")
          .update({ followed: false, last_event_at: at })
          .eq("store_id", cred.store_id)
          .eq("line_user_id", lineUserId);
        continue;
      }

      if (type === "accountLink") {
        const link = ev.link as { result?: string; nonce?: string } | undefined;
        if (link?.result !== "ok" || !link.nonce) {
          console.error("accountLink failed or missing nonce");
          continue;
        }
        // nonce 是我們在發 linkToken 前自己種下的，帶著「這是哪位會員」
        const { data: n } = await sb
          .from("line_account_link_nonces")
          .select("nonce, member_id, store_id, tenant_id, used_at")
          .eq("nonce", link.nonce)
          .maybeSingle();
        if (!n || n.used_at || n.store_id !== cred.store_id) {
          console.error("nonce invalid / already used / store mismatch");
          continue;
        }
        await sb.from("store_line_followers").upsert({
          tenant_id: n.tenant_id,
          store_id: n.store_id,
          line_user_id: lineUserId,
          member_id: n.member_id,
          followed: true,
          linked_at: at,
          last_event_at: at,
        }, { onConflict: "store_id,line_user_id" });
        await sb.from("line_account_link_nonces")
          .update({ used_at: new Date().toISOString() })
          .eq("nonce", link.nonce);
        continue;
      }

      // follow / message / 其他有 userId 的事件 → 至少把這個人記進名冊。
      // member_id 先留 NULL：webhook 只知道「有這個 LINE 使用者」，
      // 不知道他是哪位會員，要等 account link 完成才填得上。
      // ⚠ 不能只在 type === "follow" 才抓 profile。
      // 實際上線後多數人是先「傳訊息」才被收進名冊（既有好友不會再觸發 follow），
      // 只認 follow 的話名冊會一整排沒有名字，店員在配對選單只看得到
      // "U5a54b59…" 這種字串，等於選不出來（2026-08-08 實際踩到）。
      // 所以：只要這個人在名冊裡還沒有名字，任何事件都補抓一次。
      let displayName: string | null = null;
      let pictureUrl: string | null = null;

      const { data: existing2 } = await sb
        .from("store_line_followers")
        .select("display_name, member_id, link_invited_at")
        .eq("store_id", cred.store_id)
        .eq("line_user_id", lineUserId)
        .maybeSingle();
      const existing = existing2;

      if (!existing?.display_name && cred.access_token) {
        try {
          const p = await fetch(`${LINE_PROFILE_URL}/${lineUserId}`, {
            headers: { "Authorization": `Bearer ${cred.access_token}` },
          });
          if (p.ok) {
            const prof = await p.json();
            displayName = prof.displayName ?? null;
            pictureUrl = prof.pictureUrl ?? null;
          }
        } catch (e) {
          console.error("profile fetch failed:", String(e));
        }
      }

      const row: Record<string, unknown> = {
        tenant_id: cred.tenant_id,
        store_id: cred.store_id,
        line_user_id: lineUserId,
        followed: true,
        last_event_at: at,
      };
      if (displayName) row.display_name = displayName;
      if (pictureUrl) row.picture_url = pictureUrl;

      const { error: upErr } = await sb
        .from("store_line_followers")
        .upsert(row, { onConflict: "store_id,line_user_id", ignoreDuplicates: false });
      if (upErr) console.error("binding upsert failed:", upErr.message);

      // 還不知道他是哪位會員 → 回一則帶 account link 的「查看我的訂單」。
      // 只在有 replyToken 時做（reply 免額度，且 linkToken 只有 10 分鐘效期，
      // 事後補寄沒有意義）。已配對的人不打擾。
      const replyToken = ev.replyToken as string | undefined;
      const memberBase = (Deno.env.get("MEMBER_FRONT_BASE_URL") ?? "").replace(/\/+$/, "");
      const invitedAt = existing2?.link_invited_at ? Date.parse(existing2.link_invited_at) : 0;
      const cooled = Date.now() - invitedAt > INVITE_COOLDOWN_MS;

      if (replyToken && cred.access_token && memberBase && credStoreCode && !existing2?.member_id && cooled) {
        const sent = await inviteAccountLink(
          cred.access_token, replyToken, lineUserId, credStoreCode ?? "", memberBase,
        );
        if (sent) {
          await sb.from("store_line_followers")
            .update({ link_invited_at: new Date().toISOString() })
            .eq("store_id", cred.store_id)
            .eq("line_user_id", lineUserId);
        }
      }
    }

    return new Response("ok", { status: 200 });
  } catch (e) {
    // 回 500 會讓 LINE 重送；但解析失敗重送也不會變好，記下來回 200 比較安全。
    console.error("line-webhook error:", e);
    return new Response("ok", { status: 200 });
  }
});

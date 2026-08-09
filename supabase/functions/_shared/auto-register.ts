// ─────────────────────────────────────────────────────────────────────────────
// auto-register: 用 LINE 個資自動建會員 + 綁定 + 下載頭像
// 被 line-oauth-callback（web OAuth）與 liff-session（LIFF SDK）共用
// ─────────────────────────────────────────────────────────────────────────────

export async function autoRegister(p: {
  supabaseUrl: string;
  serviceKey: string;
  tenantId: string;
  storeId: string;
  lineUserId: string;
  lineName: string | null;
  linePicture?: string | null;
}): Promise<number> {
  const authHeaders = {
    apikey: p.serviceKey,
    Authorization: `Bearer ${p.serviceKey}`,
  };

  // 先用 line_user_id 查既有會員（取代舊的 phone_hash placeholder 查法）
  const existingUrl =
    `${p.supabaseUrl}/rest/v1/members?select=id,line_display_name&tenant_id=eq.${p.tenantId}` +
    `&line_user_id=eq.${encodeURIComponent(p.lineUserId)}&limit=1`;
  const existingResp = await fetch(existingUrl, { headers: authHeaders });
  const existing = await existingResp.json() as Array<{ id: number; line_display_name: string | null }>;
  let memberId: number;

  if (existing.length > 0) {
    memberId = existing[0].id;
    // 已有會員也要把 LINE 顯示名稱刷新一次（客人改了 LINE 名字，App 要跟著變）
    await syncLineDisplayName({
      supabaseUrl: p.supabaseUrl,
      authHeaders,
      memberId,
      lineName: p.lineName,
      current: existing[0].line_display_name,
    });
  } else {
    const now = new Date();
    const pad = (n: number, w = 2) => String(n).padStart(w, "0");
    const memberNo = `M${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}${pad(Math.floor(Math.random() * 1000), 3)}`;

    // phone / phone_hash 都留 NULL；真實手機待使用者日後補填
    const insertResp = await fetch(`${p.supabaseUrl}/rest/v1/members`, {
      method: "POST",
      headers: {
        ...authHeaders,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify({
        tenant_id: p.tenantId,
        member_no: memberNo,
        // name = 後台自己編的名字，只是拿 LINE 名稱當建檔初值，之後只有後台能改
        name: p.lineName ?? "(未提供)",
        // line_display_name = 會員端 App 顯示的名字，每次登入都會被 LINE 覆寫
        line_display_name: p.lineName,
        home_store_id: Number(p.storeId),
        line_user_id: p.lineUserId,
        status: "active",
      }),
    });
    if (!insertResp.ok) {
      throw new Error(`insert member failed ${insertResp.status}: ${await insertResp.text()}`);
    }
    const inserted = await insertResp.json() as Array<{ id: number }>;
    memberId = inserted[0].id;
  }

  // 下載 LINE 頭像、存 Storage（失敗不擋註冊）
  if (p.linePicture) {
    try {
      await uploadAvatar({
        supabaseUrl: p.supabaseUrl,
        serviceKey: p.serviceKey,
        memberId,
        lineUserId: p.lineUserId,
        pictureUrl: p.linePicture,
        authHeaders,
      });
    } catch (e) {
      console.warn("avatar upload failed (non-fatal):", e);
    }
  }

  // INSERT binding（衝突 = 已綁）
  const bindResp = await fetch(`${p.supabaseUrl}/rest/v1/member_line_bindings`, {
    method: "POST",
    headers: {
      ...authHeaders,
      "Content-Type": "application/json",
      Prefer: "resolution=ignore-duplicates,return=minimal",
    },
    body: JSON.stringify({
      tenant_id: p.tenantId,
      store_id: Number(p.storeId),
      member_id: memberId,
      line_user_id: p.lineUserId,
    }),
  });
  if (!bindResp.ok && bindResp.status !== 409) {
    throw new Error(`insert binding failed ${bindResp.status}: ${await bindResp.text()}`);
  }

  return memberId;
}

// ─────────────────────────────────────────────────────────────────────────────
// members.line_display_name = 會員端 App 顯示的名字，唯一真相來源是 LINE。
// 每次 LINE 登入都刷新，客人在 LINE 改名 → 下次開 App 就跟著變。
// **不要**在這裡順手改 members.name —— 那是後台自己編、給店員搜尋用的名字，
// 被 LINE 蓋掉的話後台就再也搜不到自己標記過的人（這正是分家的原因）。
// 失敗不擋登入：顯示名稱過期只是小事，登不進去才是大事。
//
// 「值一樣就不要寫」是刻意的：members 有 touch_updated_at trigger，無條件
// PATCH 會讓每個人每次登入都 bump updated_at，後台會員列表的「更新」欄
// 就變成登入時間、排序語意毀掉（同一個坑見 20260611000010 的 last_visit_at）。
// ─────────────────────────────────────────────────────────────────────────────
async function syncLineDisplayName(p: {
  supabaseUrl: string;
  authHeaders: Record<string, string>;
  memberId: number;
  lineName: string | null;
  /** 已知的現值；undefined = 未知，會先 GET 一次 */
  current?: string | null;
}) {
  if (!p.lineName) return;
  try {
    let current = p.current;
    if (current === undefined) {
      const resp = await fetch(
        `${p.supabaseUrl}/rest/v1/members?select=line_display_name&id=eq.${p.memberId}&limit=1`,
        { headers: p.authHeaders },
      );
      if (!resp.ok) throw new Error(`read ${resp.status}: ${await resp.text()}`);
      const rows = await resp.json() as Array<{ line_display_name: string | null }>;
      if (rows.length === 0) return;
      current = rows[0].line_display_name;
    }
    if (current === p.lineName) return;

    const patchResp = await fetch(
      `${p.supabaseUrl}/rest/v1/members?id=eq.${p.memberId}`,
      {
        method: "PATCH",
        headers: {
          ...p.authHeaders,
          "Content-Type": "application/json",
          Prefer: "return=minimal",
        },
        body: JSON.stringify({ line_display_name: p.lineName }),
      },
    );
    if (!patchResp.ok) {
      throw new Error(`patch ${patchResp.status}: ${await patchResp.text()}`);
    }
  } catch (e) {
    console.warn("sync line_display_name failed (non-fatal):", e);
  }
}

// 給「已有 binding、不會走 autoRegister」的回頭客路徑用（liff-session /
// line-oauth-callback）。內部沿用同一支實作，避免兩邊各寫一份而漂移。
export async function refreshLineDisplayName(p: {
  supabaseUrl: string;
  serviceKey: string;
  memberId: number;
  lineName: string | null;
}) {
  await syncLineDisplayName({
    supabaseUrl: p.supabaseUrl,
    authHeaders: { apikey: p.serviceKey, Authorization: `Bearer ${p.serviceKey}` },
    memberId: p.memberId,
    lineName: p.lineName,
  });
}

async function uploadAvatar(p: {
  supabaseUrl: string;
  serviceKey: string;
  memberId: number;
  lineUserId: string;
  pictureUrl: string;
  authHeaders: Record<string, string>;
}) {
  const imgResp = await fetch(p.pictureUrl);
  if (!imgResp.ok) throw new Error(`download avatar ${imgResp.status}`);
  const contentType = imgResp.headers.get("content-type") ?? "image/jpeg";
  const ext = contentType.includes("png") ? "png" :
              contentType.includes("webp") ? "webp" : "jpg";
  const blob = await imgResp.arrayBuffer();

  const path = `line-${p.lineUserId}.${ext}`;
  const uploadResp = await fetch(
    `${p.supabaseUrl}/storage/v1/object/member-avatars/${path}`,
    {
      method: "POST",
      headers: {
        ...p.authHeaders,
        "Content-Type": contentType,
        "x-upsert": "true",
      },
      body: blob,
    },
  );
  if (!uploadResp.ok) {
    throw new Error(`upload avatar ${uploadResp.status}: ${await uploadResp.text()}`);
  }

  const publicUrl = `${p.supabaseUrl}/storage/v1/object/public/member-avatars/${path}`;

  const updateResp = await fetch(
    `${p.supabaseUrl}/rest/v1/members?id=eq.${p.memberId}`,
    {
      method: "PATCH",
      headers: {
        ...p.authHeaders,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ avatar_url: publicUrl }),
    },
  );
  if (!updateResp.ok) {
    throw new Error(`update avatar_url ${updateResp.status}: ${await updateResp.text()}`);
  }
}


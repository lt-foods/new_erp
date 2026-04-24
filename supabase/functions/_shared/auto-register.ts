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
    `${p.supabaseUrl}/rest/v1/members?select=id&tenant_id=eq.${p.tenantId}` +
    `&line_user_id=eq.${encodeURIComponent(p.lineUserId)}&limit=1`;
  const existingResp = await fetch(existingUrl, { headers: authHeaders });
  const existing = await existingResp.json() as Array<{ id: number }>;
  let memberId: number;

  if (existing.length > 0) {
    memberId = existing[0].id;
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
        name: p.lineName ?? "(未提供)",
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


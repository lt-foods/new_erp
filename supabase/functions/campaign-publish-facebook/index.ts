// 同步上架 FB 粉絲團：把 group_buy_campaign 的內容發到指定的 FB Pages
//
// 流程：
//   1. 驗證 JWT、角色（owner/admin/hq_manager）、tenant_id
//   2. 讀 fb_pages 拿 access_token（service_role 旁路 RLS）
//   3. 依圖片數量分流呼叫 FB Graph：
//        0 張 → POST /{page-id}/feed { message }
//        1 張 → POST /{page-id}/photos { url, message }（會自動建 feed post）
//        n 張 → 先逐張 POST /{page-id}/photos?published=false 拿 media_fbid，
//               再 POST /{page-id}/feed { message, attached_media[] }
//   4. 不論成功/失敗都寫一筆 campaign_fb_posts
//
// 注意 `link` 參數在 v3.3 之後對非審核 App 不可靠，所以 URL 直接拼進 message body。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import { corsHeaders } from "../_shared/cors.ts";

const FB_API_VERSION = "v19.0";
const FB_BASE = `https://graph.facebook.com/${FB_API_VERSION}`;

type FbPage = {
  id: number;
  page_id: string;
  name: string;
  access_token: string;
  is_active: boolean;
};

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

async function fbCall(
  path: string,
  params: Record<string, string>,
): Promise<Record<string, unknown>> {
  const form = new URLSearchParams(params);
  const r = await fetch(`${FB_BASE}${path}`, { method: "POST", body: form });
  const text = await r.text();
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { raw: text };
  }
  if (!r.ok) {
    const errObj = parsed?.error as { message?: string } | undefined;
    throw new Error(errObj?.message || text || `HTTP ${r.status}`);
  }
  return parsed;
}

async function fbFetchPermalink(
  fbPostId: string,
  accessToken: string,
): Promise<string | null> {
  try {
    const u = new URL(`${FB_BASE}/${fbPostId}`);
    u.searchParams.set("fields", "permalink_url");
    u.searchParams.set("access_token", accessToken);
    const r = await fetch(u.toString());
    if (!r.ok) return null;
    const d = await r.json();
    return typeof d.permalink_url === "string" ? d.permalink_url : null;
  } catch {
    return null;
  }
}

async function publishToPage(
  page: FbPage,
  message: string,
  imageUrls: string[],
): Promise<{ fb_post_id: string; permalink: string | null }> {
  let fbPostId: string;

  if (imageUrls.length === 0) {
    const res = await fbCall(`/${page.page_id}/feed`, {
      message,
      access_token: page.access_token,
    });
    fbPostId = String(res.id);
  } else if (imageUrls.length === 1) {
    const res = await fbCall(`/${page.page_id}/photos`, {
      url: imageUrls[0],
      message,
      access_token: page.access_token,
    });
    // /photos 回傳 { id, post_id }，post_id 才是 feed 上的貼文
    fbPostId = String(res.post_id ?? res.id);
  } else {
    const mediaIds: string[] = [];
    for (const url of imageUrls) {
      const res = await fbCall(`/${page.page_id}/photos`, {
        url,
        published: "false",
        access_token: page.access_token,
      });
      mediaIds.push(String(res.id));
    }
    const params: Record<string, string> = {
      message,
      access_token: page.access_token,
    };
    mediaIds.forEach((mid, i) => {
      params[`attached_media[${i}]`] = JSON.stringify({ media_fbid: mid });
    });
    const res = await fbCall(`/${page.page_id}/feed`, params);
    fbPostId = String(res.id);
  }

  const permalink = await fbFetchPermalink(fbPostId, page.access_token);
  return { fb_post_id: fbPostId, permalink };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const auth = req.headers.get("authorization");
    if (!auth) return json({ error: "missing authorization" }, 401);

    const sb = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } },
    );

    const token = auth.replace(/^Bearer\s+/i, "");
    const { data: { user }, error: authErr } = await sb.auth.getUser(token);
    if (authErr || !user) {
      return json({ error: "invalid token", detail: authErr?.message }, 401);
    }

    const tenantId = user.app_metadata?.tenant_id as string | undefined;
    const role = user.app_metadata?.role as string | undefined;
    if (!tenantId) return json({ error: "user has no tenant_id" }, 403);
    if (!role || !["owner", "admin", "hq_manager"].includes(role)) {
      return json({ error: "forbidden" }, 403);
    }

    const body = await req.json();
    const campaignId = Number(body?.campaign_id);
    const fbPageIds = Array.isArray(body?.fb_page_ids)
      ? body.fb_page_ids.map((x: unknown) => Number(x)).filter((n: number) => Number.isFinite(n))
      : [];
    const messageInput = typeof body?.message === "string" ? body.message : "";
    const imageUrls: string[] = Array.isArray(body?.image_urls)
      ? body.image_urls.filter((u: unknown) => typeof u === "string" && u.length > 0) as string[]
      : [];

    if (!Number.isFinite(campaignId) || campaignId <= 0) {
      return json({ error: "campaign_id required" }, 400);
    }
    if (fbPageIds.length === 0) {
      return json({ error: "fb_page_ids required" }, 400);
    }
    const message = messageInput.trim();
    if (!message) return json({ error: "message required" }, 400);

    const { data: campaign, error: cErr } = await sb
      .from("group_buy_campaigns")
      .select("id, tenant_id, name")
      .eq("id", campaignId)
      .eq("tenant_id", tenantId)
      .maybeSingle();
    if (cErr) return json({ error: cErr.message }, 500);
    if (!campaign) return json({ error: "campaign not found" }, 404);

    const { data: pages, error: pErr } = await sb
      .from("fb_pages")
      .select("id, page_id, name, access_token, is_active")
      .eq("tenant_id", tenantId)
      .in("id", fbPageIds);
    if (pErr) return json({ error: pErr.message }, 500);
    if (!pages || pages.length === 0) {
      return json({ error: "no valid fb pages" }, 400);
    }

    const results: Array<{
      fb_page_id: number;
      page_name: string;
      status: "success" | "failed";
      fb_post_id?: string;
      permalink?: string | null;
      error?: string;
    }> = [];

    for (const p of pages as FbPage[]) {
      if (!p.is_active) {
        await sb.from("campaign_fb_posts").insert({
          tenant_id: tenantId,
          campaign_id: campaignId,
          fb_page_id: p.id,
          status: "failed",
          message,
          image_urls: imageUrls,
          error_message: "page is inactive",
          posted_by: user.id,
        });
        results.push({
          fb_page_id: p.id,
          page_name: p.name,
          status: "failed",
          error: "page is inactive",
        });
        continue;
      }

      try {
        const { fb_post_id, permalink } = await publishToPage(p, message, imageUrls);
        await sb.from("campaign_fb_posts").insert({
          tenant_id: tenantId,
          campaign_id: campaignId,
          fb_page_id: p.id,
          fb_post_id,
          permalink,
          status: "success",
          message,
          image_urls: imageUrls,
          posted_by: user.id,
          posted_at: new Date().toISOString(),
        });
        results.push({
          fb_page_id: p.id,
          page_name: p.name,
          status: "success",
          fb_post_id,
          permalink,
        });
      } catch (e) {
        const errMsg = e instanceof Error ? e.message : String(e);
        await sb.from("campaign_fb_posts").insert({
          tenant_id: tenantId,
          campaign_id: campaignId,
          fb_page_id: p.id,
          status: "failed",
          message,
          image_urls: imageUrls,
          error_message: errMsg,
          posted_by: user.id,
        });
        results.push({
          fb_page_id: p.id,
          page_name: p.name,
          status: "failed",
          error: errMsg,
        });
      }
    }

    return json({ ok: true, results });
  } catch (e) {
    console.error("campaign-publish-facebook error:", e);
    return json({ error: "internal", detail: String(e) }, 500);
  }
});

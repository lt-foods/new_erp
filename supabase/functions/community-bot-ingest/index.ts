// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: community-bot-ingest
//
// 接收 LINE 群組 #選品 機器人 (透過 Apps Script Web App 轉發) 的候選商品。
// 寫入 community_product_candidates 表。
//
// 流程：
//   1. 驗 X-Bot-Secret header (從 COMMUNITY_BOT_SECRET env 比對)
//   2. parse JSON payload
//   3. raw_text 必填、空回 400
//   4. 用 service_role 透過 PostgREST INSERT
//   5. duplicate (PostgREST 409 + idx_ccp_source_external 命中) 回 200 + duplicate:true
//   6. 其他錯誤回 500 + 訊息 (Apps Script 看到才知道要不要 retry)
//
// 設計慣例 (對齊 _shared/cors.ts、liff-session/index.ts)：
//   - Deno.serve + OPTIONS handler
//   - requireEnv / json() helper
//   - 直接 fetch PostgREST (不用 supabase-js client)
// ─────────────────────────────────────────────────────────────────────────────

import { corsHeaders } from "../_shared/cors.ts";

interface IngestPayload {
  // 必填
  text: string;                        // LINE 文案 → raw_text

  // dedup key (建議: LINE message id；機器人沒填則 NULL，不防重)
  message_id?: string;                 // → source_external_id

  // 來源 (機器人有抓到才填，否則 NULL)
  user_id?: string;                    // → source_user_id
  user_name?: string;                  // → source_user_name
  channel?: string;                    // → source_channel (LINE 群組名/id)
  post_url?: string;                   // → source_post_url

  // 機器人猜的商品名 (對應 Apps Script payload.productName)
  product_name?: string;               // → product_name_hint

  // 其他不認的欄位也接受、不報錯 (forward compatibility)
  // 完整 payload 會原樣存進 raw JSONB 欄位
  [key: string]: unknown;
}

Deno.serve(async (req) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  try {
    // ── 1. 驗密鑰 ──────────────────────────────────────────────
    const expectedSecret = requireEnv("COMMUNITY_BOT_SECRET");
    const providedSecret = req.headers.get("x-bot-secret");
    if (!providedSecret || providedSecret !== expectedSecret) {
      console.warn(
        "community-bot-ingest: unauthorized",
        "ip=", req.headers.get("x-forwarded-for") ?? "unknown",
      );
      return json({ error: "unauthorized" }, 401);
    }

    // ── 2. parse payload ──────────────────────────────────────
    let payload: IngestPayload;
    try {
      payload = await req.json() as IngestPayload;
    } catch {
      return json({ error: "invalid json body" }, 400);
    }

    // ── 3. raw_text 必填 ───────────────────────────────────────
    if (
      !payload.text ||
      typeof payload.text !== "string" ||
      payload.text.trim() === ""
    ) {
      return json(
        { error: "text (raw_text) is required and must be non-empty string" },
        400,
      );
    }

    // ── 4. INSERT 到 community_product_candidates ──────────────
    const supabaseUrl = requireEnv("SUPABASE_URL");
    const serviceKey  = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
    const tenantId    = requireEnv("DEFAULT_TENANT_ID");

    // 同時支援 snake_case 和 camelCase
    // (Apps Script 既存 contract 用 camelCase: data.productName / data.userId)
    // 機器人若以 forward-as-is 傳遞、會收到 camelCase；若 Apps Script 轉換、會是 snake_case
    const pick = (snake: string, camel: string) =>
      (payload[snake] as string | undefined) ??
      (payload[camel] as string | undefined) ?? null;

    const row = {
      tenant_id:          tenantId,
      raw_text:           payload.text,
      raw:                payload,                                  // 完整 payload 留底
      source_external_id: pick("message_id",   "messageId"),
      source_user_id:     pick("user_id",      "userId"),
      source_user_name:   pick("user_name",    "userName"),
      source_channel:     pick("channel",      "channel"),          // 沒 camelCase 變體
      source_post_url:    pick("post_url",     "postUrl"),
      product_name_hint:  pick("product_name", "productName"),
    };

    const insertUrl = `${supabaseUrl}/rest/v1/community_product_candidates`;
    const resp = await fetch(insertUrl, {
      method: "POST",
      headers: {
        apikey:        serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
        Prefer:        "return=representation",
      },
      body: JSON.stringify(row),
    });

    // ── 5. duplicate handling ─────────────────────────────────
    // PostgreSQL 23505 (unique_violation) → PostgREST 回 409
    // 用 JSON code 主判定 + index name 副判定 (比純 string include 穩)
    if (resp.status === 409) {
      const errBody = await resp.text();
      let errJson: { code?: string; details?: string; message?: string } = {};
      try {
        errJson = JSON.parse(errBody);
      } catch {
        // PostgREST 通常回 JSON、parse 失敗 fallback 到 string include
      }

      const isUniqueViolation = errJson.code === "23505";
      const isOurDedupIndex =
        (errJson.details ?? "").includes("idx_ccp_source_external") ||
        (errJson.message ?? "").includes("idx_ccp_source_external") ||
        errBody.includes("idx_ccp_source_external");  // fallback

      if (isUniqueViolation && isOurDedupIndex) {
        console.log(
          "community-bot-ingest: duplicate, source_external_id=",
          row.source_external_id,
        );
        return json({
          ok: true,
          duplicate: true,
          source_external_id: row.source_external_id,
        });
      }

      // 不是我們的 dedup 衝突 → 真的錯誤 (FK / 其他 unique constraint)
      throw new Error(`postgrest 409: ${errBody}`);
    }

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`postgrest ${resp.status}: ${errText}`);
    }

    const inserted = await resp.json() as Array<{ id: number }>;
    return json({
      ok: true,
      duplicate: false,
      id: inserted[0]?.id,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("community-bot-ingest error:", msg);
    return json({ error: "failed", detail: msg }, 500);
  }
});

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

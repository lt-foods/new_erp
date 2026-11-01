// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: product-tag
//
// 新品自動貼標（LLM 那一半）。pg_cron 每 30 分鐘跑 _product_tag_tick()
// （20261101000020）：先用規則補，規則補不到的才打這支。
//
// 流程：
//   1. 驗 x-product-tag-secret（= PRODUCT_TAG_CRON_SECRET）
//   2. 讀 product_tags（code / name / group）當候選清單
//   3. rpc_product_tag_llm_claim 撿一批（預設 40）沒標籤的商品
//   4. 一次丟給 OpenAI（JSON schema 輸出），模型只能回清單裡的 code
//   5. 逐筆 rpc_product_tag_llm_write 寫回（code 不存在 DB 端會濾掉；失敗則清 tag_llm_at 讓下輪重撿）
//   6. 時間夠就再撿一批；截止時間在 handler 裡算（模組層級只求值一次，見 CLAUDE.md #970）
//
// 不驗 JWT（verify_jwt=false）：只收 cron 的 secret。沒 secret 一律 401。
//
// secrets：PRODUCT_TAG_CRON_SECRET、OPENAI_API_KEY，選填 OPENAI_TAG_MODEL（預設 gpt-4o-mini）；
//          內建 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY。
// ─────────────────────────────────────────────────────────────────────────────

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

type Tag = { code: string; name: string; tag_group: string };
type Product = { id: number; name: string; short_name: string | null; description: string | null };

const BATCH = 40;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const secret = Deno.env.get("PRODUCT_TAG_CRON_SECRET");
  if (!secret || req.headers.get("x-product-tag-secret") !== secret) {
    return json({ error: "unauthorized" }, 401);
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) return json({ error: "OPENAI_API_KEY not set", tagged: 0 }, 500);
  const model = Deno.env.get("OPENAI_TAG_MODEL") || "gpt-4o-mini";

  // 截止時間在 handler 裡算：Edge Function 牆鐘上限 150s，留餘裕給最後一批寫回
  const deadline = Date.now() + 100_000;
  const sb = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false },
  });

  const { data: tagRows, error: tagErr } = await sb
    .from("product_tags")
    .select("code,name,tag_group")
    .eq("is_active", true);
  if (tagErr) return json({ error: tagErr.message }, 500);
  const tags = (tagRows ?? []) as Tag[];
  if (tags.length === 0) return json({ ok: true, tagged: 0, note: "no tags" });
  const validCodes = new Set(tags.map((t) => t.code));

  let claimed = 0, tagged = 0, empty = 0, failed = 0;
  while (Date.now() < deadline) {
    const { data: rows, error } = await sb.rpc("rpc_product_tag_llm_claim", { p_limit: BATCH });
    if (error) return json({ error: error.message, claimed, tagged, empty, failed }, 500);
    const products = (rows ?? []) as Product[];
    if (products.length === 0) break;
    claimed += products.length;

    let result: Map<number, string[]>;
    try {
      result = await classify(apiKey, model, tags, products);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error("product-tag: openai failed", msg);
      // 整批退回（清 tag_llm_at），下一輪重撿
      for (const p of products) {
        await sb.rpc("rpc_product_tag_llm_write", { p_product_id: p.id, p_tag_codes: [], p_error: msg });
      }
      failed += products.length;
      return json({ error: msg, claimed, tagged, empty, failed }, 502);
    }

    for (const p of products) {
      const codes = (result.get(p.id) ?? []).filter((c) => validCodes.has(c));
      const { error: wErr } = await sb.rpc("rpc_product_tag_llm_write", {
        p_product_id: p.id, p_tag_codes: codes, p_error: null,
      });
      if (wErr) { failed++; console.error("product-tag: write failed", p.id, wErr.message); continue; }
      if (codes.length > 0) tagged++; else empty++;
    }
  }

  return json({ ok: true, claimed, tagged, empty, failed });
});

/** 一批商品 → OpenAI → { product_id: [tag codes] }。模型只能從清單裡選。 */
async function classify(apiKey: string, model: string, tags: Tag[], products: Product[]): Promise<Map<number, string[]>> {
  const byGroup = new Map<string, string[]>();
  for (const t of tags) {
    const list = byGroup.get(t.tag_group) ?? [];
    list.push(`${t.code}=${t.name}`);
    byGroup.set(t.tag_group, list);
  }
  const tagText = [...byGroup.entries()].map(([g, list]) => `【${g}】${list.join("、")}`).join("\n");

  const system =
    "你是台灣團購店的商品分類員。對每個商品，從標籤清單中挑出適用的標籤 code，規則：\n" +
    "1. 只能用清單裡的 code，不要發明新的。\n" +
    "2. 每個商品至少 1 個「生鮮」「食品」或「非食品」群的標籤；食品類再細分時可以同時給大類和子類（例如 prepared + prep_dumpling）。\n" +
    "3. 溫層（frozen / chilled / ambient）只給食品與生鮮，依品名判斷（寫明冷凍→frozen、冷藏/鮮奶/豆腐→chilled，其餘常溫→ambient）；非食品不給溫層。\n" +
    "4. 屬性（jp / kr / gift）看得出來才給。\n" +
    "5. 真的看不出是什麼就回空陣列。\n" +
    "標籤清單：\n" + tagText;

  const user = products.map((p) =>
    `id=${p.id} 品名：${p.name}` +
    (p.short_name && p.short_name !== p.name ? `｜短名：${p.short_name}` : "") +
    (p.description ? `｜描述：${p.description.replace(/\s+/g, " ").slice(0, 200)}` : "")
  ).join("\n");

  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      temperature: 0,
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "product_tags",
          strict: true,
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              items: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    id: { type: "integer" },
                    tags: { type: "array", items: { type: "string" } },
                  },
                  required: ["id", "tags"],
                },
              },
            },
            required: ["items"],
          },
        },
      },
    }),
  });
  if (!resp.ok) throw new Error(`openai ${resp.status}: ${(await resp.text()).slice(0, 300)}`);
  const body = await resp.json() as { choices?: { message?: { content?: string } }[] };
  const content = body.choices?.[0]?.message?.content ?? "{}";
  const parsed = JSON.parse(content) as { items?: { id: number; tags: string[] }[] };
  const out = new Map<number, string[]>();
  for (const it of parsed.items ?? []) out.set(Number(it.id), Array.isArray(it.tags) ? it.tags : []);
  return out;
}

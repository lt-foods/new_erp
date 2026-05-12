#!/usr/bin/env node
// Chunked stage + commit smoke test (uses p_row_offset + p_limit)
//   node scripts/test-member-import-chunked.mjs [N]

import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import Papa from "papaparse";

const ENV = Object.fromEntries(
  readFileSync("apps/admin/.env.local", "utf8")
    .split(/\r?\n/).filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split("=").map((s, i, a) => (i === 0 ? s.trim() : a.slice(1).join("=").trim()))),
);
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
const { error: e1 } = await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });
if (e1) throw e1;

const N = Number(process.argv[2] ?? 1500);
const CHUNK = 500;
const csv = readFileSync("C:/Users/Alex/Downloads/顧客管理-樂樂團購訂單管理系統.csv", "utf8");
const data = Papa.parse(csv, { skipEmptyLines: true }).data;
const header = data[0];
const idx = {
  external_id: header.findIndex((c) => c?.trim() === "顧客代號"),
  name_raw:    header.findIndex((c) => c?.trim() === "名字"),
  label:       header.findIndex((c) => c?.trim() === "標籤"),
  joined_at:   header.findIndex((c) => c?.trim() === "加入日期"),
  last_visit_at: header.findIndex((c) => c?.trim() === "最後登入"),
};
const rows = [];
for (let i = 1; i < data.length && rows.length < N; i++) {
  const r = data[i];
  const eid = (r[idx.external_id] ?? "").trim();
  if (!eid) continue;
  rows.push({
    external_id: eid,
    name_raw: r[idx.name_raw] ?? "",
    label: r[idx.label] ?? "",
    joined_at: r[idx.joined_at] ?? "",
    last_visit_at: r[idx.last_visit_at] ?? "",
  });
}
console.log(`✓ parsed ${rows.length} rows`);

const bid = `chunked_${Date.now()}`;
const agg = { total: 0, ok: 0, duplicate_in_batch: 0, duplicate_existing: 0, errors: 0 };
const tStage = Date.now();
for (let i = 0; i < rows.length; i += CHUNK) {
  const chunk = rows.slice(i, i + CHUNK);
  const { data: out, error } = await sb.rpc("rpc_stage_member_import", {
    p_batch_id: bid, p_source: "lele", p_rows: chunk, p_row_offset: i,
  });
  if (error) { console.error("stage err", error); process.exit(1); }
  agg.total += out.chunk_total; agg.ok += out.chunk_ok;
  agg.duplicate_in_batch += out.chunk_duplicate_in_batch;
  agg.duplicate_existing += out.chunk_duplicate_existing;
  agg.errors += out.chunk_errors;
  console.log(`  chunk ${i + 1}~${i + chunk.length}: ${JSON.stringify(out)}`);
}
console.log(`✓ stage done in ${Date.now() - tStage}ms, agg=${JSON.stringify(agg)}`);

const tCommit = Date.now();
let committed = 0, skipped = 0;
while (true) {
  const { data: out, error } = await sb.rpc("rpc_commit_member_import", { p_batch_id: bid, p_limit: 500 });
  if (error) { console.error("commit err", error); process.exit(1); }
  committed += out.committed; skipped += out.skipped;
  console.log(`  commit chunk: +${out.committed} (skipped ${out.skipped})`);
  if (out.committed === 0) break;
}
console.log(`✓ commit done in ${Date.now() - tCommit}ms, committed=${committed} skipped=${skipped}`);

await sb.rpc("rpc_cancel_member_import", { p_batch_id: bid });
console.log("✓ cancel done");

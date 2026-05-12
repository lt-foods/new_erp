#!/usr/bin/env node
// One-shot integration test for rpc_stage / commit / cancel _member_import
// Uses ADMIN_EMAIL / ADMIN_PASSWORD from apps/admin/.env.local
//
// Run:  node scripts/test-member-import.mjs

import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import Papa from "papaparse";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ENV = Object.fromEntries(
  readFileSync(resolve(__dirname, "../apps/admin/.env.local"), "utf8")
    .split(/\r?\n/)
    .filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split("=").map((s, i, a) => (i === 0 ? s.trim() : a.slice(1).join("=").trim()))),
);

const URL  = ENV.NEXT_PUBLIC_SUPABASE_URL;
const ANON = ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const EMAIL = ENV.ADMIN_EMAIL;
const PASSWORD = ENV.ADMIN_PASSWORD;
if (!URL || !ANON || !EMAIL || !PASSWORD) {
  console.error("Missing env"); process.exit(1);
}

const sb = createClient(URL, ANON, { auth: { persistSession: false } });

const { error: signErr } = await sb.auth.signInWithPassword({ email: EMAIL, password: PASSWORD });
if (signErr) { console.error("login fail", signErr); process.exit(1); }
console.log("✓ logged in as", EMAIL);

// 取實際樂樂 CSV 前 N 筆
const N = Number(process.argv[2] ?? 20);
const csvPath = "C:/Users/Alex/Downloads/顧客管理-樂樂團購訂單管理系統.csv";
const csvText = readFileSync(csvPath, "utf8");
const parsed = Papa.parse(csvText, { skipEmptyLines: true });
const allRows = parsed.data;
const header = allRows[0];
const idx = {
  external_id:   header.findIndex((c) => c?.trim() === "顧客代號"),
  name_raw:      header.findIndex((c) => c?.trim() === "名字"),
  label:         header.findIndex((c) => c?.trim() === "標籤"),
  joined_at:     header.findIndex((c) => c?.trim() === "加入日期"),
  last_visit_at: header.findIndex((c) => c?.trim() === "最後登入"),
};
console.log("header idx:", idx);

const rows = [];
for (let i = 1; i < allRows.length && rows.length < N; i++) {
  const r = allRows[i];
  const externalId = (r[idx.external_id] ?? "").trim();
  if (!externalId) continue;
  rows.push({
    external_id: externalId,
    name_raw: r[idx.name_raw] ?? "",
    label: r[idx.label] ?? "",
    joined_at: r[idx.joined_at] ?? "",
    last_visit_at: r[idx.last_visit_at] ?? "",
  });
}
console.log(`✓ parsed ${rows.length} rows from CSV`);
console.log("sample rows:", JSON.stringify(rows.slice(0, 3), null, 2));

// 加幾個 edge case row
const batchId = `test_${Date.now()}`;
const testRows = [
  ...rows,
  // duplicate within batch (same external_id as row 0)
  { ...rows[0], name_raw: rows[0].name_raw + " (dup)" },
  // missing external_id
  { external_id: "", name_raw: "#x : 【缺代號】", label: "永和", joined_at: "", last_visit_at: "" },
  // name regex fail
  { external_id: "99999991", name_raw: "亂寫格式", label: "—", joined_at: "", last_visit_at: "" },
  // label ambiguous (平鎮 → 多 store)
  { external_id: "99999992", name_raw: "#99999992 : 【模糊店】", label: "平鎮", joined_at: "2026-05-01", last_visit_at: "—" },
];

console.log(`\n=== stage batch ${batchId} with ${testRows.length} rows ===`);
const { data: stageData, error: stageErr } = await sb.rpc("rpc_stage_member_import", {
  p_batch_id: batchId,
  p_source: "lele",
  p_rows: testRows,
});
if (stageErr) { console.error("stage error:", stageErr); process.exit(1); }
console.log("stage result:", stageData);

// 從 staging 抓回所有 row
const { data: staged, error: readErr } = await sb
  .from("member_imports")
  .select("row_index, parsed_external_id, parsed_name, parsed_name_suffix, parsed_takeout_store_name_hint, parsed_home_store_id, parsed_joined_at, validation_status, validation_errors, resolved_member_id")
  .eq("batch_id", batchId)
  .order("row_index");
if (readErr) { console.error("read error:", readErr); process.exit(1); }
console.log(`\n=== staged rows (${staged.length}) ===`);
for (const r of staged) {
  console.log(
    `#${String(r.row_index).padStart(3)} ${r.validation_status.padEnd(20)} ext=${r.parsed_external_id ?? "—"}  name=${r.parsed_name ?? "—"}  hint=${r.parsed_takeout_store_name_hint ?? "—"}  store=${r.parsed_home_store_id ?? "—"}  suffix=${r.parsed_name_suffix ?? "—"}  errs=${JSON.stringify(r.validation_errors)}`
  );
}

// commit
console.log(`\n=== commit ===`);
const { data: commitData, error: commitErr } = await sb.rpc("rpc_commit_member_import", { p_batch_id: batchId });
if (commitErr) { console.error("commit error:", commitErr); process.exit(1); }
console.log("commit result:", commitData);

// 驗證 members 新增
const { data: newMembers, error: mErr } = await sb
  .from("members")
  .select("id, member_no, external_source, external_id, name, takeout_store_name_hint, home_store_id, status, joined_at")
  .in("external_id", testRows.map((r) => r.external_id).filter(Boolean))
  .eq("external_source", "lele");
if (mErr) { console.error("members read error:", mErr); process.exit(1); }
console.log(`\n=== members with these external_id (${newMembers.length}) ===`);
for (const m of newMembers) {
  console.log(`  ${m.member_no} ext=${m.external_id} name=${m.name} hint=${m.takeout_store_name_hint ?? "—"} store=${m.home_store_id ?? "—"}`);
}

// cancel (清掉 staging 殘餘 non-committed row)
const { data: cancelData } = await sb.rpc("rpc_cancel_member_import", { p_batch_id: batchId });
console.log("\ncancel result:", cancelData);

console.log("\n✓ test complete");

#!/usr/bin/env node
// Wallet 初始化驗證：手動塞幾筆 row 帶 wallet_balance 跑 stage→commit→查 wallet_ledger/balances

import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";

const ENV = Object.fromEntries(
  readFileSync("apps/admin/.env.local", "utf8")
    .split(/\r?\n/).filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split("=").map((s, i, a) => (i === 0 ? s.trim() : a.slice(1).join("=").trim()))),
);
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });
console.log("✓ logged in");

const bid = `wallet_${Date.now()}`;
const rows = [
  { external_id: "TEST-W-001", name_raw: "#TEST-W-001 : 【錢包小張】", label: "永和", joined_at: "2026-05-12", last_visit_at: "", wallet_balance: "500" },
  { external_id: "TEST-W-002", name_raw: "#TEST-W-002 : 【沒儲值】",   label: "—",    joined_at: "2026-05-12", last_visit_at: "", wallet_balance: "0" },
  { external_id: "TEST-W-003", name_raw: "#TEST-W-003 : 【千元儲值】", label: "平鎮", joined_at: "2026-05-12", last_visit_at: "", wallet_balance: "1,000" },
  { external_id: "TEST-W-004", name_raw: "#TEST-W-004 : 【負數壞值】", label: "",     joined_at: "2026-05-12", last_visit_at: "", wallet_balance: "-50" },
  { external_id: "TEST-W-005", name_raw: "#TEST-W-005 : 【亂值】",     label: "",     joined_at: "2026-05-12", last_visit_at: "", wallet_balance: "abc" },
];

const { data: stageOut, error: e1 } = await sb.rpc("rpc_stage_member_import", {
  p_batch_id: bid, p_source: "lele", p_rows: rows, p_row_offset: 0,
});
if (e1) { console.error("stage err", e1); process.exit(1); }
console.log("stage:", stageOut);

const { data: staged } = await sb.from("member_imports")
  .select("row_index, parsed_external_id, parsed_name, parsed_wallet_balance, validation_status, validation_errors")
  .eq("batch_id", bid).order("row_index");
for (const r of staged) {
  console.log(`  #${r.row_index} ${r.validation_status.padEnd(20)} ext=${r.parsed_external_id} wallet=${r.parsed_wallet_balance ?? "—"} errs=${JSON.stringify(r.validation_errors)}`);
}

const { data: commitOut, error: e2 } = await sb.rpc("rpc_commit_member_import", { p_batch_id: bid, p_limit: 500 });
if (e2) { console.error("commit err", e2); process.exit(1); }
console.log("\ncommit:", commitOut);

// 查 wallet_ledger + wallet_balances
const { data: created } = await sb.from("members")
  .select("id, member_no, external_id, name")
  .eq("external_source", "lele")
  .in("external_id", rows.map(r => r.external_id));
console.log(`\nnew members (${created.length}):`);
for (const m of created) console.log(`  ${m.member_no} ext=${m.external_id} ${m.name}`);

const ids = created.map(m => m.id);
const { data: ledger } = await sb.from("wallet_ledger")
  .select("member_id, change, balance_after, type, source_type, reason")
  .in("member_id", ids);
console.log(`\nwallet_ledger entries (${ledger.length}):`);
for (const l of ledger) console.log(`  member#${l.member_id} change=${l.change} bal=${l.balance_after} type=${l.type} src=${l.source_type} reason=${l.reason}`);

const { data: bals } = await sb.from("wallet_balances")
  .select("member_id, balance, version")
  .in("member_id", ids);
console.log(`\nwallet_balances (${bals.length}):`);
for (const b of bals) console.log(`  member#${b.member_id} balance=${b.balance} v=${b.version}`);

await sb.rpc("rpc_cancel_member_import", { p_batch_id: bid });
console.log("\n✓ done");

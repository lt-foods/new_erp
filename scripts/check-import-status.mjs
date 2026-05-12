#!/usr/bin/env node
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";

const ENV = Object.fromEntries(
  readFileSync("apps/admin/.env.local", "utf8")
    .split(/\r?\n/).filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split("=").map((s, i, a) => (i === 0 ? s.trim() : a.slice(1).join("=").trim()))),
);
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });

const bid = process.argv[2] ?? "15be7b3d-b65c-4e56-ba7a-9f0b2e052ab4";

// 該 batch 各 status 計數
const statuses = ["pending","ok","duplicate_existing","duplicate_in_batch","error","committed","cancelled","error_at_commit"];
console.log(`batch ${bid}:`);
for (const s of statuses) {
  const { count } = await sb.from("member_imports").select("id", { count: "exact", head: true }).eq("batch_id", bid).eq("validation_status", s);
  if (count) console.log(`  ${s.padEnd(22)} ${count}`);
}

// 該 batch resolved_member_id 對應到的 members 數
const { count: memberCount } = await sb.from("members").select("id", { count: "exact", head: true }).eq("external_source", "lele");
console.log(`\nmembers WHERE external_source='lele': ${memberCount}`);

// wallet ledger 樂樂匯入計數
const { count: walletCount } = await sb.from("wallet_ledger").select("id", { count: "exact", head: true }).eq("source_type", "import_lele");
console.log(`wallet_ledger source_type='import_lele': ${walletCount}`);

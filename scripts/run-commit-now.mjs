import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
const ENV = Object.fromEntries(
  readFileSync("apps/admin/.env.local", "utf8")
    .split(/\r?\n/).filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split("=").map((s, i, a) => (i === 0 ? s.trim() : a.slice(1).join("=").trim()))),
);
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });
const bid = process.argv[2];
const t0 = Date.now();
let total = 0;
while (true) {
  const t1 = Date.now();
  const { data, error } = await sb.rpc("rpc_commit_member_import", { p_batch_id: bid, p_limit: 500 });
  if (error) { console.error(`chunk error after ${Date.now() - t1}ms:`, error); break; }
  total += data.committed;
  console.log(`+${data.committed} skip=${data.skipped} wallet=${data.wallet_initialized} (${Date.now() - t1}ms) total=${total}`);
  if (data.committed === 0) break;
}
console.log(`\n✓ done in ${Date.now() - t0}ms, total committed=${total}`);

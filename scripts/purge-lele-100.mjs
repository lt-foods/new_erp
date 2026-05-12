import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
const ENV = Object.fromEntries(readFileSync("apps/admin/.env.local","utf8").split(/\r?\n/).filter(l=>l&&!l.startsWith("#")).map(l=>l.split("=").map((s,i,a)=>i===0?s.trim():a.slice(1).join("=").trim())));
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });
const t0 = Date.now();
let total = 0;
let safety = 0;
while (true) {
  const t1 = Date.now();
  const { data, error } = await sb.rpc("rpc_admin_purge_lele_imports", { p_limit: 50 });
  if (error) { console.error(`error +${Date.now()-t1}ms:`, error.message); break; }
  total += data.members_deleted;
  if (safety % 10 === 0 || data.members_deleted === 0) {
    console.log(`  -${data.members_deleted} total=${total} +${Date.now()-t1}ms`);
  }
  if (data.members_deleted === 0) {
    console.log(`  imports=${data.imports_deleted} stores=${data.stores_deleted}`);
    break;
  }
  if (++safety > 500) { console.log("safety break"); break; }
}
console.log(`✓ ${Date.now()-t0}ms total purged=${total}`);

import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
const ENV = Object.fromEntries(readFileSync("apps/admin/.env.local","utf8").split(/\r?\n/).filter(l=>l&&!l.startsWith("#")).map(l=>l.split("=").map((s,i,a)=>i===0?s.trim():a.slice(1).join("=").trim())));
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });

// 1. list_staff
const { data: list, error: e1 } = await sb.rpc("rpc_list_staff");
if (e1) { console.error("list err", e1); process.exit(1); }
console.log(`✓ list_staff: ${list.length} users`);
for (const u of list) console.log(`  ${u.role.padEnd(15)} ${u.email}  stores=${JSON.stringify(u.stores)}  signed=${u.last_sign_in_at?.slice(0,10) ?? "—"}`);

// 2. 試 update_role 自己（應該被擋）
const me = list.find(u => u.email === ENV.ADMIN_EMAIL);
if (me) {
  const { error } = await sb.rpc("rpc_update_staff_role", { p_user_id: me.user_id, p_role: 'store_staff' });
  console.log(`\n self-demote: ${error ? '✓ rejected (' + error.message + ')' : '✗ should reject'}`);
}

// 3. invalid role
const { error: e3 } = await sb.rpc("rpc_update_staff_role", { p_user_id: me.user_id, p_role: 'superhero' });
console.log(`invalid role: ${e3 ? '✓ rejected (' + e3.message + ')' : '✗ should reject'}`);

// 4. update stores 自己（合法）
const { error: e4 } = await sb.rpc("rpc_update_staff_stores", { p_user_id: me.user_id, p_store_ids: [1] });
console.log(`update stores self: ${e4 ? '✗ ' + e4.message : '✓ ok'}`);

// 5. update stores 含不存在 id
const { error: e5 } = await sb.rpc("rpc_update_staff_stores", { p_user_id: me.user_id, p_store_ids: [1, 99999] });
console.log(`update stores w/ invalid id: ${e5 ? '✓ rejected (' + e5.message + ')' : '✗ should reject'}`);

// 6. 復原 stores（依先前列表）
if (me) {
  const orig = Array.isArray(me.stores) && me.stores.length ? me.stores : [];
  await sb.rpc("rpc_update_staff_stores", { p_user_id: me.user_id, p_store_ids: orig.filter(x => typeof x === 'number') });
  console.log(`restored stores`);
}

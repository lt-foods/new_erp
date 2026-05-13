import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
const ENV = Object.fromEntries(readFileSync("apps/admin/.env.local","utf8").split(/\r?\n/).filter(l=>l&&!l.startsWith("#")).map(l=>l.split("=").map((s,i,a)=>i===0?s.trim():a.slice(1).join("=").trim())));
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });
const { data: list } = await sb.rpc("rpc_list_staff");
const me = list.find(u => u.email === ENV.ADMIN_EMAIL);
console.log(`me: ${me.email} role="${me.role}"`);

// self-demote
const { error: e1 } = await sb.rpc("rpc_update_staff_role", { p_user_id: me.user_id, p_role: 'store_staff' });
console.log(`self-demote: ${e1 ? '✓ ' + e1.message : '✗ should reject'}`);

// stores invalid name
const { error: e2 } = await sb.rpc("rpc_update_staff_stores", { p_user_id: me.user_id, p_store_names: ['平鎮店', '不存在的店'] });
console.log(`invalid store name: ${e2 ? '✓ ' + e2.message : '✗ should reject'}`);

// stores valid name
const { error: e3 } = await sb.rpc("rpc_update_staff_stores", { p_user_id: me.user_id, p_store_names: ['平鎮店'] });
console.log(`valid store name: ${e3 ? '✗ ' + e3.message : '✓ ok'}`);

// stores magic 總倉
const { error: e4 } = await sb.rpc("rpc_update_staff_stores", { p_user_id: me.user_id, p_store_names: ['總倉'] });
console.log(`magic 總倉: ${e4 ? '✗ ' + e4.message : '✓ ok'}`);

// 復原為空（cktalex 原本沒設）
await sb.rpc("rpc_update_staff_stores", { p_user_id: me.user_id, p_store_names: [] });
console.log('restored to []');

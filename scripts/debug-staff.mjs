import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
const ENV = Object.fromEntries(readFileSync("apps/admin/.env.local","utf8").split(/\r?\n/).filter(l=>l&&!l.startsWith("#")).map(l=>l.split("=").map((s,i,a)=>i===0?s.trim():a.slice(1).join("=").trim())));
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
const { data: sess } = await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });
console.log("session user app_metadata:", sess.session.user.app_metadata);
console.log("session JWT (decoded):");
const parts = sess.session.access_token.split('.');
const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
console.log("  app_metadata:", payload.app_metadata);
console.log("  role (root):", payload.role);

const { data, error } = await sb.rpc("rpc_list_staff");
console.log("list_staff: error=", error, " count=", data?.length);

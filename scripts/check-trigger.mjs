import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
const ENV = Object.fromEntries(readFileSync("apps/admin/.env.local","utf8").split(/\r?\n/).filter(l=>l&&!l.startsWith("#")).map(l=>l.split("=").map((s,i,a)=>i===0?s.trim():a.slice(1).join("=").trim())));
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });
// 用 query 來看 triggers — 需要 rpc 或 view
const { data, error } = await sb.from("pg_trigger").select("*").limit(1);
console.log("test:", { data, error });

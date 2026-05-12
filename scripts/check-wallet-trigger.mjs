import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
const ENV = Object.fromEntries(readFileSync("apps/admin/.env.local","utf8").split(/\r?\n/).filter(l=>l&&!l.startsWith("#")).map(l=>l.split("=").map((s,i,a)=>i===0?s.trim():a.slice(1).join("=").trim())));
const sb = createClient(ENV.NEXT_PUBLIC_SUPABASE_URL, ENV.NEXT_PUBLIC_SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: ENV.ADMIN_EMAIL, password: ENV.ADMIN_PASSWORD });
// 列出 wallet_ledger 上的 trigger names — 需要 RPC
const { data: maybe } = await sb.from("wallet_ledger").select("id").limit(1);
console.log(maybe);

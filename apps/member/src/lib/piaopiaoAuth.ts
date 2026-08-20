import { createClient, type SupabaseClient } from "@supabase/supabase-js";

let client: SupabaseClient | null = null;

export function piaopiaoLoginEmail(loginId: string): string {
  return `${loginId.trim().toLowerCase()}@piaopiao.local`;
}

export function getPiaopiaoAuth(): SupabaseClient {
  if (client) return client;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) throw new Error("系統尚未設定連線");
  client = createClient(url, anonKey, {
    auth: { storageKey: "piaopiao_publisher_auth", persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
  });
  return client;
}

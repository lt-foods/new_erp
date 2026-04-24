import { createClient, type SupabaseClient } from "@supabase/supabase-js";

/**
 * 回傳以 custom JWT 認證的 Supabase client。
 * token 從 URL fragment 取得後寫入 sessionStorage，再由 getSession() 讀出。
 */
export function getSupabase(jwt: string | null): SupabaseClient {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY",
    );
  }
  return createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: jwt
      ? { headers: { Authorization: `Bearer ${jwt}` } }
      : undefined,
  });
}

export function lineOauthStartUrl(storeId: string): string {
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base) throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");
  return `${base}/functions/v1/line-oauth-start?store=${encodeURIComponent(storeId)}`;
}

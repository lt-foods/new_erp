import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { clearSession, updateSessionToken } from "@/lib/session";
import { logClientError } from "@/lib/clientLog";

/**
 * 以 custom JWT 認證的 Supabase client（目前未使用，保留給未來讀取 RLS 保護的資料用）
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

export function lineOauthStartUrl(storeId: string, pairCode?: string): string {
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base) throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");
  const url = new URL(`${base}/functions/v1/line-oauth-start`);
  url.searchParams.set("store", storeId);
  if (pairCode) url.searchParams.set("pair", pairCode);
  return url.toString();
}

/**
 * 呼叫 liff-api Edge Function（所有會員端 DB 操作走這支，不直接打 PostgREST）。
 * 原因：我們簽的 HS256 JWT 過不了 Supabase PostgREST（已切 ECC P-256）。
 */
export async function callLiffApi<T = unknown>(
  jwt: string,
  body: Record<string, unknown>,
): Promise<T> {
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base) throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");

  const resp = await fetch(`${base}/functions/v1/liff-api`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify(body),
  });

  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    const msg = (data as { error?: string; detail?: string }).error
      ?? `liff-api ${resp.status}`;

    // 會員已被後台刪除（rpc_member_purge）但手機上的 JWT 還沒過期：
    // 這顆殭屍 session 會讓所有頁面互踢（/ 看到 member_id 跳內頁、內頁查無人噴錯）。
    // 集中在這裡拆彈：清 session、回登入頁重新註冊。
    if (resp.status === 401 && msg === "member_not_found") {
      logClientError(
        "member_not_found_session_cleared",
        "會員已不存在，清除本機 session 回登入頁",
        { action: body.action },
        "warn",
      );
      clearSession();
      if (typeof window !== "undefined") window.location.replace("/");
      // 讓呼叫端的 catch 拿到可讀訊息（頁面即將跳走，訊息幾乎不會被看到）
      throw new Error("此帳號已被移除，請重新註冊");
    }

    const err = new Error(msg);
    (err as Error & { detail?: unknown }).detail = (data as { detail?: unknown }).detail;
    // 機器可判別的錯誤代碼（例：line_binding_required），讓呼叫端不用 parse 中文訊息
    (err as Error & { code?: unknown }).code = (data as { code?: unknown }).code;
    throw err;
  }

  // 滑動續期：後端在 token 快到期時夾帶新的回來，換上去即可。
  // 每個 API 呼叫本身就是「使用者還在用」的證據，所以只要持續使用就不會被登出。
  const renewed = (data as { renewed_token?: unknown }).renewed_token;
  if (typeof renewed === "string" && renewed) updateSessionToken(renewed);

  return data as T;
}

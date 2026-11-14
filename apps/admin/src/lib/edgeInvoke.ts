// 呼叫「函式內自己驗呼叫者」的 Edge Function（staff-create / staff-reset-password …）。
//
// 這類函式用 auth.getUser(token) 驗身份 —— 會連「這次登入還在不在」一起問 Auth；
// 一般資料讀寫（PostgREST）只驗簽章。所以登入在伺服器端被清掉之後
// （別台裝置按了登出、密碼被重設），畫面最長還能照常用一小時，
// 只有這類函式回 401 "invalid token"，而且原本是整句英文直接丟給使用者。
// 2026-11-14：同一個帳號在另一支手機按了登出，一分鐘後這支 iPhone 按重設密碼就卡在這裡。
//
// 接法：先換一次憑證再試；換不到＝登入真的沒了。supabase-js 在 refresh 被拒時
// 會自己清掉本機 session → (protected)/layout 導回登入頁，這裡只負責給一句看得懂的話。
//
// 不 import getSupabase（client 由呼叫端傳入）：這支才能被 node --test 直接載入。

export const SESSION_EXPIRED_MSG = "登入已失效，請重新登入後再操作一次";

type InvokeResponse<T> = { data: T | null; error: unknown };

export type EdgeInvokeClient = {
  functions: {
    invoke: <T>(name: string, options: { body: Record<string, unknown> }) => Promise<InvokeResponse<T>>;
  };
  auth: { refreshSession: () => Promise<{ error: unknown }> };
};

/** 從 supabase-js 的 FunctionsHttpError 取出 HTTP 狀態與函式自己回的 error 字串 */
export async function readEdgeError(
  error: unknown,
  fallback: string,
): Promise<{ status: number | null; message: string }> {
  const e = (error ?? {}) as { message?: unknown; context?: unknown };
  const ctx = e.context as { status?: unknown; json?: unknown } | undefined;
  const status = typeof ctx?.status === "number" ? ctx.status : null;
  let message = typeof e.message === "string" && e.message ? e.message : fallback;
  try {
    if (ctx && typeof ctx.json === "function") {
      const j = (await (ctx.json as () => Promise<unknown>)()) as { error?: unknown } | null;
      if (typeof j?.error === "string" && j.error) message = j.error;
    }
  } catch {
    /* body 不是 JSON：保留原訊息 */
  }
  return { status, message };
}

/** 函式不承認呼叫者的憑證（≠ 權限不足的 403、≠ 輸入有誤的 4xx） */
export function isCallerRejected(status: number | null, message: string): boolean {
  return status === 401 && (message === "invalid token" || message === "missing authorization");
}

export async function invokeEdge<T>(
  sb: EdgeInvokeClient,
  name: string,
  body: Record<string, unknown>,
  fallback: string,
): Promise<{ data: T | null; error: string | null }> {
  for (let attempt = 0; ; attempt++) {
    const { data, error } = await sb.functions.invoke<T>(name, { body });
    if (!error) return { data, error: null };

    const { status, message } = await readEdgeError(error, fallback);
    if (!isCallerRejected(status, message)) return { data: null, error: message };

    // 只重試一次：換得到新憑證就再打，換不到（或換了還是被拒）就請使用者重新登入
    if (attempt === 0) {
      const { error: refreshErr } = await sb.auth.refreshSession();
      if (!refreshErr) continue;
    }
    return { data: null, error: SESSION_EXPIRED_MSG };
  }
}

// staff-reset-password 的權限判斷（純函式，不碰網路，方便單元測試）
//
// 規則對齊 staff-create：
//   - caller 必須 owner/admin 且有 tenant_id
//   - 目標必須同 tenant（只看 app_metadata.tenant_id）
//   - 目標是 owner 時 caller 必須是 owner（admin 不可動 owner）
//   - 密碼 ≥ 6 碼（對齊 auth.minimum_password_length）
// 錯誤訊息一律不帶密碼。

export const MIN_PASSWORD_LENGTH = 6;

type Meta = { role?: unknown; tenant_id?: unknown } | null | undefined;
export type AuthUserLike = { id: string; app_metadata?: Meta };

export type Denied = { ok: false; status: number; error: string };
export type Allowed = { ok: true };

function roleOf(u: AuthUserLike): string {
  const r = u.app_metadata?.role;
  return typeof r === "string" ? r : "";
}

function tenantOf(u: AuthUserLike): string {
  const t = u.app_metadata?.tenant_id;
  return typeof t === "string" ? t : "";
}

// 第一關：只看呼叫者本身（不必先查目標就能擋掉店長／店員）
export function checkCaller(caller: AuthUserLike): Allowed | Denied {
  if (!tenantOf(caller)) return { ok: false, status: 403, error: "caller has no tenant_id" };
  const role = roleOf(caller);
  if (role !== "owner" && role !== "admin") {
    return { ok: false, status: 403, error: "permission denied: requires owner/admin role" };
  }
  return { ok: true };
}

// 輸入格式：user_id 必填、password ≥ 6 碼（不 trim，前後空白可能是刻意的）
export function checkInput(
  body: unknown,
): ({ ok: true; userId: string; password: string }) | Denied {
  if (!body || typeof body !== "object") return { ok: false, status: 400, error: "invalid json body" };
  const b = body as { user_id?: unknown; password?: unknown };
  const userId = typeof b.user_id === "string" ? b.user_id.trim() : "";
  const password = typeof b.password === "string" ? b.password : "";
  if (!userId) return { ok: false, status: 400, error: "user_id required" };
  if (password.length < MIN_PASSWORD_LENGTH) {
    return { ok: false, status: 422, error: `密碼至少 ${MIN_PASSWORD_LENGTH} 碼` };
  }
  return { ok: true, userId, password };
}

// 第二關：呼叫者 vs 目標
export function checkTarget(caller: AuthUserLike, target: AuthUserLike | null): Allowed | Denied {
  const c = checkCaller(caller);
  if (!c.ok) return c;
  // 找不到與跨公司回同一個訊息，避免拿來探測別家帳號是否存在
  if (!target || tenantOf(target) !== tenantOf(caller)) {
    return { ok: false, status: 404, error: "找不到這位員工" };
  }
  if (roleOf(target) === "owner" && roleOf(caller) !== "owner") {
    return { ok: false, status: 403, error: "admin 不可重設 owner 的密碼" };
  }
  return { ok: true };
}

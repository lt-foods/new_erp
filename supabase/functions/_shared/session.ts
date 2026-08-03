// 會員 session token 的存續策略 —— 三支函式共用，值必須一致：
//   liff-session          簽發（LIFF 自動登入）
//   line-oauth-callback   簽發（網頁 OAuth）
//   liff-api              續期（每次呼叫時檢查，快到期就換發）
// 以前 TTL 常數各自寫死在兩支裡，改一邊就會變成「用哪條路登入決定能撐多久」。

import { signJwtHs256, type JwtClaims } from "./jwt.ts";

/** 一顆 session token 從簽發起算的壽命 */
export const SESSION_TTL_SEC = 60 * 60 * 24 * 180; // 半年

/**
 * 剩餘壽命低於這個值就換發新的（滑動續期）。
 *
 * 設在 TTL 的一半：使用者只要在半個週期內開過一次 app 就會被續期，
 * 等於「持續在用的人永遠不會被登出，真的長期沒用才需要重登」。
 * 設太接近 TTL 會變成每次呼叫都換發（浪費簽章 + 前端一直寫 localStorage）。
 */
export const RENEW_WHEN_REMAINING_SEC = SESSION_TTL_SEC / 2;

/** 簽一顆 session token。exp 由這裡統一決定，呼叫端不要自己算。 */
export async function signSessionToken(
  claims: Omit<JwtClaims, "exp" | "iat">,
  secret: string,
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return await signJwtHs256({ ...claims, exp: now + SESSION_TTL_SEC }, secret);
}

/**
 * 快到期就換發一顆新的，否則回 null（呼叫端不必做任何事）。
 *
 * 沿用原本的 claims（tenant_id / store_id / member_id …），只換 iat / exp —
 * 續期不是重新認證，不該改變身分或權限。
 */
export async function renewSessionTokenIfNeeded(
  claims: JwtClaims,
  secret: string,
): Promise<string | null> {
  const exp = Number(claims.exp);
  if (!Number.isFinite(exp)) return null;

  const now = Math.floor(Date.now() / 1000);
  const remaining = exp - now;
  // 已過期的不該走到這裡（verify 會先擋），保險起見也不續期 —
  // 否則等於讓過期 token 自我復活。
  if (remaining <= 0 || remaining > RENEW_WHEN_REMAINING_SEC) return null;

  const next: JwtClaims = { ...claims };
  delete next.exp;
  delete next.iat;
  return await signSessionToken(next, secret);
}

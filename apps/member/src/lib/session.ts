// Session helpers — 從 URL fragment 抓 token，存 sessionStorage

const TOKEN_KEY = "member_jwt";
const STORE_KEY = "member_store_id";
const MEMBER_KEY = "member_id";

export type Session = {
  token: string;
  storeId: string;
  memberId: number | null;
  bound: boolean;
};

/** 從 URL fragment 解出 session，存入 sessionStorage，並清理 URL。 */
export function consumeFragmentToSession(): Session | null {
  if (typeof window === "undefined") return null;
  const hash = window.location.hash.replace(/^#/, "");
  if (!hash) return null;
  const p = new URLSearchParams(hash);
  const token = p.get("token");
  const store = p.get("store");
  if (!token || !store) return null;

  const memberId = p.get("member_id") ? Number(p.get("member_id")) : null;
  const bound = p.get("bound") === "1";

  sessionStorage.setItem(TOKEN_KEY, token);
  sessionStorage.setItem(STORE_KEY, store);
  if (memberId) sessionStorage.setItem(MEMBER_KEY, String(memberId));

  // 清 fragment，避免 refresh / 分享外洩
  window.history.replaceState(null, "", window.location.pathname + window.location.search);

  return { token, storeId: store, memberId, bound };
}

export function getSession(): Session | null {
  if (typeof window === "undefined") return null;
  const token = sessionStorage.getItem(TOKEN_KEY);
  const storeId = sessionStorage.getItem(STORE_KEY);
  if (!token || !storeId) return null;
  const mid = sessionStorage.getItem(MEMBER_KEY);
  return {
    token,
    storeId,
    memberId: mid ? Number(mid) : null,
    bound: !!mid,
  };
}

export function clearSession() {
  if (typeof window === "undefined") return;
  sessionStorage.removeItem(TOKEN_KEY);
  sessionStorage.removeItem(STORE_KEY);
  sessionStorage.removeItem(MEMBER_KEY);
}

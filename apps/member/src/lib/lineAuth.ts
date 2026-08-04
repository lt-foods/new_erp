// LINE 登入的共用原語 —— 環境判斷、LIFF 旗標、PWA 配對碼、建立 session。
//
// 這些原本全部散在首頁（app/page.tsx）裡。搬出來的理由很實際：登入這條路上
// 每一個「不能這樣做」都是在會員手機上踩過才寫下來的（見 CLAUDE.md 的 LINE/LIFF
// 段落），而現在不只首頁要登入 —— /join 這種推廣落地頁也要。複製一份等於把
// 那些教訓也複製一份，下次修 bug 只會修到其中一份。
//
// 這個檔只放「跟畫面無關」的部分；狀態機（要不要轉圈、要不要顯示指引）在
// useLineLogin.ts。

import { lineOauthStartUrl, callLiffApi } from "@/lib/supabase";
import { saveSession } from "@/lib/session";
import { logClientError } from "@/lib/clientLog";

export { lineOauthStartUrl };

/**
 * 切回 PWA 時「輪詢」領取配對 token，而不是只試一次。
 *
 * 使用者關掉 LINE 回到 PWA 的那一瞬間，LIFF 端可能還在寫 pwa_auth_codes。
 * 只試一次很容易剛好落在寫入完成之前 —— 一旦錯過，在使用者再次切出去切回來
 * 之前都不會重試，體感就是「自動登入沒用」，只好去打驗證碼。
 */
const CLAIM_RETRY_ATTEMPTS = 8;
const CLAIM_RETRY_DELAY_MS = 1500;

export const PAIR_TOKEN_KEY = "pwa_pair_token";
/** 只允許往 LIFF 彈一次的旗標（sessionStorage），避免 LIFF ↔ 網頁互推無限迴圈 */
export const LIFF_RETRY_KEY = "liff_login_retry";
/** 「已登入但不在 LIFF client」的自動補完每次瀏覽只做一次，避免 / ↔ /shop 互推 */
export const AUTO_COMPLETE_KEY = "liff_auto_complete_done";

/**
 * 轉圈超過這個時間就直接切到登入頁。
 *
 * 自動登入牽涉 LIFF SDK 載入、init、liff-session、LINE 的 verify API…
 * 任何一段掛住，使用者看到的都是同一個轉不完的圈，而且什麼都不能按 ——
 * 只能關掉重進（實測這樣反而就登入成功了）。與其讓他自己摸索，
 * 不如逾時就把可以操作的登入頁交回去。
 *
 * 10 秒是留給慢網路的餘裕：正常流程 2–5 秒會走完；真的成功了會導頁，
 * 元件卸載、這個 timer 也就跟著清掉，不會誤觸。
 */
export const LOGIN_STUCK_MS = 10_000;

/** liff.init() 掛住時的止血點（要比 LOGIN_STUCK_MS 短，才有機會走完後續退路） */
export const LIFF_INIT_TIMEOUT_MS = 5_000;

export const LINE_BROWSER_HINT =
  "這個畫面是在 LINE 的內建瀏覽器開啟的，LINE 不允許在這裡完成登入。" +
  "請點右上角「⋮」選「用其他瀏覽器開啟」，或複製下面的連結貼到 Safari / Chrome 再登入。";

/** sessionStorage 在無痕 / 被擋時會 throw，一律包起來 */
export function sessionFlag(key: string): boolean {
  try { return sessionStorage.getItem(key) !== null; } catch { return false; }
}
export function setSessionFlag(key: string) {
  try { sessionStorage.setItem(key, "1"); } catch { /* noop */ }
}
export function clearSessionFlag(key: string) {
  try { sessionStorage.removeItem(key); } catch { /* noop */ }
}

/** liff.* 在 init 失敗 / SDK 狀態不完整時會 throw，讀值一律包起來 */
export function safe<T>(fn: () => T): T | null {
  try { return fn(); } catch { return null; }
}

/** 是否在 LINE 的內建瀏覽器裡（含 LIFF browser）。UA 帶 " Line/"。 */
export function isInLineApp(): boolean {
  if (typeof navigator === "undefined") return false;
  return / Line\//i.test(navigator.userAgent);
}

export function isStandalone(): boolean {
  if (typeof window === "undefined") return false;
  return (
    (window.navigator as { standalone?: boolean }).standalone === true ||
    window.matchMedia("(display-mode: standalone)").matches
  );
}

/** 組 LIFF 入口 URL（LINE 會用 LIFF 重開這個 app，init 時自動登入） */
export function liffAppUrl(
  liffId: string,
  storeId?: string | null,
  pairCode?: string | null,
): string {
  const q = new URLSearchParams();
  if (storeId) q.set("store", storeId);
  if (pairCode) q.set("pair", pairCode);
  const qs = q.toString();
  return `https://liff.line.me/${encodeURIComponent(liffId)}${qs ? `?${qs}` : ""}`;
}

export function genPairToken(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return Array.from({ length: 32 }, () =>
    Math.floor(Math.random() * 16).toString(16),
  ).join("");
}

/**
 * LIFF 會把原始 query 包進 liff.state，而且常帶著路徑，格式可能是：
 *   "?store=1"、"/?store=1"、"/shop?store=1"、或純 "store=1"。
 * 一律抓「第一個 ? 之後」的部分當 query 解析（沒有 ? 就整串當 query）。
 */
export function liffStateParams(raw: string): URLSearchParams {
  const q = raw.indexOf("?");
  return new URLSearchParams(q >= 0 ? raw.slice(q + 1) : raw);
}

/** 從網址（含 LIFF 包起來的 liff.state）讀某個參數 */
export function readParam(name: string): string | null {
  if (typeof window === "undefined") return null;
  const sp = new URLSearchParams(window.location.search);
  const direct = sp.get(name);
  if (direct) return direct;
  const raw = sp.get("liff.state");
  if (raw) return liffStateParams(raw).get(name);
  return null;
}

export function readStore(): string | null {
  return readParam("store");
}

/** 本次瀏覽暫存的配對碼（URL 被沖掉後還讀得到） */
const PAIR_PENDING_KEY = "pending_pair_code";

/**
 * 取配對碼：URL 優先，其次是本 context 稍早存下的那份。
 *
 * 為什麼一定要備份：liff.login() 導去 LINE 再回來時，URL 上的 liff.state
 * （裡面才有 pair）會被 LIFF 換成 `?code=...&liffClientId=...`，pair 就此消失。
 * 於是登入是成功了，卻不會寫 pwa_auth_codes，PWA 那端永遠領不到 ——
 * 2026-08-03 實測「手動回到 PWA 還是停在等待畫面」的卡點就在這裡。
 *
 * 用 sessionStorage 而非 localStorage：配對碼只在這一趟登入有意義，
 * 留到下次瀏覽只會拿舊碼去領一個早就過期的 session。
 */
export function resolvePairCode(): string | null {
  if (typeof window === "undefined") return null;
  const fromUrl = readParam("pair");
  if (fromUrl) {
    try { sessionStorage.setItem(PAIR_PENDING_KEY, fromUrl); } catch { /* noop */ }
    return fromUrl;
  }
  try { return sessionStorage.getItem(PAIR_PENDING_KEY); } catch { return null; }
}

export function clearPendingPairCode() {
  try { sessionStorage.removeItem(PAIR_PENDING_KEY); } catch { /* noop */ }
}

/**
 * 嘗試用 localStorage 內的 pair token 拿回 session。
 * 成功 → 直接導向 /shop。
 * 還沒準備好 → silent fail（等下次 visibilitychange 再試）。
 */
async function tryClaimPairToken(): Promise<boolean> {
  if (typeof window === "undefined") return false;
  const token = localStorage.getItem(PAIR_TOKEN_KEY);
  if (!token) return false;

  try {
    const data = await callLiffApi<{
      token: string;
      store: string;
      member_id: number;
      line_user_id: string;
      line_name: string | null;
      line_picture: string | null;
    }>("", { action: "claim_pwa_auth_code", code: token });

    // 直接寫入，不繞 URL fragment（理由同 runLiffSession：長 fragment 在
    // Android WebView 上不保證留得住，掉了就等於白登入一場）
    saveSession({
      token:       data.token,
      storeId:     data.store,
      memberId:    data.member_id,
      lineUserId:  data.line_user_id,
      lineName:    data.line_name,
      linePicture: data.line_picture,
    });
    localStorage.removeItem(PAIR_TOKEN_KEY);
    window.location.href = "/shop";
    return true;
  } catch {
    // 沒到期或還沒寫入 → 等下次
    return false;
  }
}

/** 同時間只跑一輪輪詢（多次 visibilitychange 不該疊出好幾輪） */
let claimPolling = false;

export async function claimPairTokenWithRetry(): Promise<void> {
  if (typeof window === "undefined" || claimPolling) return;
  if (!localStorage.getItem(PAIR_TOKEN_KEY)) return;

  claimPolling = true;
  try {
    for (let i = 0; i < CLAIM_RETRY_ATTEMPTS; i++) {
      // 成功會直接 navigate 到 /shop，不會回到這裡
      if (await tryClaimPairToken()) return;
      // 被別的分頁 / 這輪之外的呼叫領走了，或使用者切走了 → 收工
      if (!localStorage.getItem(PAIR_TOKEN_KEY)) return;
      if (document.visibilityState !== "visible") return;
      await new Promise((r) => setTimeout(r, CLAIM_RETRY_DELAY_MS));
    }
  } finally {
    claimPolling = false;
  }
}

/**
 * 拿 LIFF 的 id_token 去後端換 session。
 *
 * 後端（liff-session）查不到 binding 又有帶 store 時會直接 auto-register ——
 * 也就是說「用 LINE 登入」與「用 LINE 註冊」是同一條路，前端不必分。
 * 沒帶 store 又是新客會回 store_required，呼叫端要接住並讓使用者選門市。
 */
export async function runLiffSession(
  idToken: string,
  storeId: string | null,
  pairCode: string | null,
) {
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base) throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");

  const body: Record<string, string> = {
    id_token: idToken,
  };
  if (storeId) body.store = storeId;
  if (pairCode) body.pair_code = pairCode;

  const resp = await fetch(`${base}/functions/v1/liff-session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    throw new Error(
      (data as { error?: string; detail?: string }).detail
        ?? (data as { error?: string }).error
        ?? `liff-session ${resp.status}`,
    );
  }

  // 記錄配對鑰匙有沒有真的寄存到遠端 —— PWA 那端輪詢領不到時，
  // 靠這筆才分得出是「根本沒寫進去」還是「寫了但沒領到」
  logClientError(
    "liff_session_ok",
    `liff-session 完成（pair_written=${String((data as { pair_written?: unknown }).pair_written)}）`,
    {
      has_pair: Boolean(pairCode),
      pair_written: (data as { pair_written?: unknown }).pair_written ?? null,
      pair_error: (data as { pair_error?: unknown }).pair_error ?? null,
      store: storeId,
    },
    "info",
  );

  // 若是 PWA pairing 流程,session 已經寫進 pwa_auth_codes,
  // 這裡 LIFF 端不需要也不應該跳到 /me（user 應該回 PWA）。
  if (pairCode) {
    // 已經交棒給 PWA 了，備份就該清掉 —— 留著只會讓這個 context 之後
    // 又拿同一組碼去寫一次，覆蓋掉 PWA 可能已經領走的那筆
    clearPendingPairCode();
    return;
  }

  // 直接寫進 localStorage，不繞 URL fragment。
  // 繞 fragment 是 OAuth 那條的限制（後端 302 只能這樣帶 token），LIFF 這條
  // 資料已經在手上，多繞一趟只是多一個失敗點：token 是 300+ 字元的 JWT，
  // 在 Android WebView 上長 fragment 不保證留得住 —— 掉了 /shop 就讀不到
  // session，被踢回登入頁，而登入頁又會自動補完再導一次，卡成轉圈圈迴圈。
  saveSession({
    token:       String(data.token),
    storeId:     String(data.store),
    memberId:    data.member_id != null ? Number(data.member_id) : null,
    lineUserId:  data.line_user_id != null ? String(data.line_user_id) : null,
    lineName:    data.line_name    != null ? String(data.line_name)    : null,
    linePicture: data.line_picture != null ? String(data.line_picture) : null,
  });

  // LIFF 自然登入(沒帶 pair) = 在 LINE webview 內。放行完整商店體驗:
  // 直接進 /shop,跟 standalone PWA 一致(不再只停在 /me)。
  window.location.href = "/shop";
}

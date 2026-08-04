"use client";

import { useEffect, useRef, useState } from "react";
import { lineOauthStartUrl, callLiffApi } from "@/lib/supabase";
import { loadLiff } from "@/lib/liff";
import { clearSession, getSession, listenForSession, saveSession } from "@/lib/session";
import {
  isPageUnloading,
  logCaught,
  logClientError,
  reportLogsToBackend,
} from "@/lib/clientLog";
import Spinner, { LoadingScreen } from "@/components/Spinner";

type Status = "loading" | "idle" | "liff_auth" | "pair_done" | "pwa_waiting" | "error";

/**
 * 切回 PWA 時「輪詢」領取配對 token，而不是只試一次。
 *
 * 使用者關掉 LINE 回到 PWA 的那一瞬間，LIFF 端可能還在寫 pwa_auth_codes。
 * 只試一次很容易剛好落在寫入完成之前 —— 一旦錯過，在使用者再次切出去切回來
 * 之前都不會重試，體感就是「自動登入沒用」，只好去打驗證碼。
 */
const CLAIM_RETRY_ATTEMPTS = 8;
const CLAIM_RETRY_DELAY_MS = 1500;

const PAIR_TOKEN_KEY = "pwa_pair_token";
/** 只允許往 LIFF 彈一次的旗標（sessionStorage），避免 LIFF ↔ 網頁互推無限迴圈 */
const LIFF_RETRY_KEY = "liff_login_retry";
/** 「已登入但不在 LIFF client」的自動補完每次瀏覽只做一次，避免 / ↔ /shop 互推 */
const AUTO_COMPLETE_KEY = "liff_auto_complete_done";

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
const LOGIN_STUCK_MS = 10_000;

/** liff.init() 掛住時的止血點（要比 LOGIN_STUCK_MS 短，才有機會走完後續退路） */
const LIFF_INIT_TIMEOUT_MS = 5_000;

/** sessionStorage 在無痕 / 被擋時會 throw，一律包起來 */
function sessionFlag(key: string): boolean {
  try { return sessionStorage.getItem(key) !== null; } catch { return false; }
}
function setSessionFlag(key: string) {
  try { sessionStorage.setItem(key, "1"); } catch { /* noop */ }
}
function clearSessionFlag(key: string) {
  try { sessionStorage.removeItem(key); } catch { /* noop */ }
}

/** liff.* 在 init 失敗 / SDK 狀態不完整時會 throw，讀值一律包起來 */
function safe<T>(fn: () => T): T | null {
  try { return fn(); } catch { return null; }
}

/** 是否在 LINE 的內建瀏覽器裡（含 LIFF browser）。UA 帶 " Line/"。 */
function isInLineApp(): boolean {
  if (typeof navigator === "undefined") return false;
  return / Line\//i.test(navigator.userAgent);
}

/** 組 LIFF 入口 URL（LINE 會用 LIFF 重開這個 app，init 時自動登入） */
function liffAppUrl(
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

const LINE_BROWSER_HINT =
  "這個畫面是在 LINE 的內建瀏覽器開啟的，LINE 不允許在這裡完成登入。" +
  "請點右上角「⋮」選「用其他瀏覽器開啟」，或複製下面的連結貼到 Safari / Chrome 再登入。";

function isStandalone(): boolean {
  if (typeof window === "undefined") return false;
  return (
    (window.navigator as { standalone?: boolean }).standalone === true ||
    window.matchMedia("(display-mode: standalone)").matches
  );
}

function genPairToken(): string {
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
function liffStateParams(raw: string): URLSearchParams {
  const q = raw.indexOf("?");
  return new URLSearchParams(q >= 0 ? raw.slice(q + 1) : raw);
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
function resolvePairCode(): string | null {
  if (typeof window === "undefined") return null;
  const fromUrl = readPairFromUrl();
  if (fromUrl) {
    try { sessionStorage.setItem(PAIR_PENDING_KEY, fromUrl); } catch { /* noop */ }
    return fromUrl;
  }
  try { return sessionStorage.getItem(PAIR_PENDING_KEY); } catch { return null; }
}

function clearPendingPairCode() {
  try { sessionStorage.removeItem(PAIR_PENDING_KEY); } catch { /* noop */ }
}

function readPairFromUrl(): string | null {
  if (typeof window === "undefined") return null;
  const sp = new URLSearchParams(window.location.search);
  const direct = sp.get("pair");
  if (direct) return direct;
  // LIFF 把 query 包進 liff.state
  const ls = sp.get("liff.state");
  if (ls) return liffStateParams(ls).get("pair");
  return null;
}

/**
 * 嘗試用 localStorage 內的 pair token 拿回 session。
 * 成功 → 把 session 寫進 fragment 然後跳 /me。
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

async function claimPairTokenWithRetry(): Promise<void> {
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

type StoreOption = { id: number; code: string; name: string };

export default function LandingPage() {
  const [storeId, setStoreId] = useState<string | null>(null);
  const [inputStoreId, setInputStoreId] = useState("");
  const [stores, setStores] = useState<StoreOption[]>([]);
  const [status, setStatus] = useState<Status>("loading");
  const [error, setError] = useState<string | null>(null);
  const [standalone, setStandalone] = useState(false);
  /** 在 LINE 內建瀏覽器又沒有 LIFF context = 無路可走，改給外部瀏覽器指引 */
  const [lineStuck, setLineStuck] = useState(false);
  const [linkCopied, setLinkCopied] = useState(false);
  /** 驗證碼是退路，預設收起來，不跟「用 LINE 登入」並列 */
  const [showSyncCode, setShowSyncCode] = useState(false);
  /** PWA 等待畫面用：LINE 沒自動開起來時讓使用者手動再開一次 */
  const [pwaLoginUrl, setPwaLoginUrl] = useState<string | null>(null);
  const [reportState, setReportState] = useState<"idle" | "sending" | "sent" | "failed">("idle");
  /** LIFF 已登入但缺門市時留下的 id_token，選完門市直接拿它補完登入 */
  const liffIdTokenRef = useRef<string | null>(null);
  /** init 成功的 liff 實例（給「卡在 LINE 裡」時的手動重試用） */
  const liffRef = useRef<Awaited<ReturnType<typeof loadLiff>> | null>(null);

  // 6 位數驗證碼 fallback
  const [syncCode, setSyncCode] = useState("");
  const [syncing, setSyncing] = useState(false);

  useEffect(() => {
    const sa = isStandalone();
    setStandalone(sa);

    // 已綁(有 memberId)才跳走;只有 token 沒 member_id 不跳,避免跟 /shop 互推產生
    // redirect loop。standalone PWA 與 LINE LIFF 內建瀏覽器 → /shop(完整商店);
    // 一般外部瀏覽器 → /me
    const isLine =
      typeof navigator !== "undefined" && / Line\//i.test(navigator.userAgent);
    const landing = sa || isLine ? "/shop" : "/me";

    const existing = getSession();
    if (existing && existing.memberId) {
      // 真的登入成功了才把兩個一次性旗標清掉，下次登入才有完整的重試額度
      clearSessionFlag(LIFF_RETRY_KEY);
      clearSessionFlag(AUTO_COMPLETE_KEY);
      window.location.href = landing;
      return;
    }

    // 監聽跨視窗登入(同 origin BroadcastChannel,桌機瀏覽器有用)
    const unlisten = listenForSession((s) => {
      if (s.memberId) window.location.href = landing;
    });

    // 抓門市清單給下拉選用(免 token,公開資訊)
    callLiffApi<{ stores: StoreOption[] }>("", { action: "list_stores" })
      .then((r) => setStores(r.stores ?? []))
      .catch((e) => {
        // 跳頁把這個 fetch 取消掉不算故障（Safari 回 "Load failed"），記了只是雜訊
        if (isPageUnloading()) return;
        // 抓不到就退回手動輸入；但要留痕以免靜默失敗（例：.env.local 缺 NEXT_PUBLIC_SUPABASE_URL → callLiffApi throw）
        logCaught("list_stores_failed", e, { fallback: "manual_store_input" });
      });

    // 3. 從 LIFF 配對流程切回 PWA 時，自動 claim
    void claimPairTokenWithRetry();
    const onVis = () => {
      if (document.visibilityState === "visible") void claimPairTokenWithRetry();
    };
    document.addEventListener("visibilitychange", onVis);

    // 保底：轉圈太久就把可操作的登入頁交回去，不要讓使用者只能關掉重進
    const stuckTimer = window.setTimeout(() => {
      setStatus((cur) => {
        if (cur !== "loading" && cur !== "liff_auth") return cur;
        logClientError(
          "login_stuck_timeout",
          `登入流程逾時（${LOGIN_STUCK_MS / 1000}s），改顯示登入頁`,
          { stuck_at: cur },
          "warn",
        );
        return "idle";
      });
    }, LOGIN_STUCK_MS);

    (async () => {
      const errInUrl = new URLSearchParams(window.location.search).get("error");
      if (errInUrl) {
        // OAuth callback 失敗會把原因塞回 ?error=，這是登入壞掉最直接的證據
        logClientError("oauth_callback_error", errInUrl);
        setError(errInUrl);
      }

      const liffId = process.env.NEXT_PUBLIC_LIFF_ID;

      // 一進頁面就把配對碼備份起來 —— 必須趕在 liff.login() 把 URL 上的
      // liff.state 換成 ?code=... 之前，否則這趟 PWA 配對就再也接不回去了
      resolvePairCode();

      // 讀門市
      let s = readStore();
      if (!s && typeof window !== "undefined") {
        s = localStorage.getItem("last_store_id");
      }
      if (s) {
        setStoreId(s);
        localStorage.setItem("last_store_id", s);
      }

      // LIFF 初始化
      if (liffId) {
        try {
          const liff = await loadLiff();
          // liff.init() 會掛住不 resolve —— 實測 2026-08-04：從 liff.login()
          // 帶著 ?code= 回來時，SDK 在內部換 token 那步卡死，init 永遠不回，
          // 整個頁面就停在 loading（liffRef 也因此一直是 null）。
          // 沒有 timeout 的 await 等於把整條登入流程押在 SDK 身上。
          await Promise.race([
            liff.init({ liffId }),
            new Promise((_, reject) =>
              setTimeout(() => reject(new Error("liff.init timeout")), LIFF_INIT_TIMEOUT_MS),
            ),
          ]);
          liffRef.current = liff;

          const sFromLiff = readStore();
          if (sFromLiff) {
            s = sFromLiff;
            setStoreId(s);
            localStorage.setItem("last_store_id", s);
          }

          if (liff.isInClient()) {
            setStatus("liff_auth");
            if (!liff.isLoggedIn()) {
              // ⚠️ 這裡**不能**呼叫 liff.login()。
              // LIFF browser 內的登入是 liff.init() 自動跑的；官方明講
              // 「LIFF browser 內的 LINE Login 授權請求行為不保證」，
              // 實際呼叫會被導到 access.line.me 然後回一頁 400 Bad Request，
              // 使用者就卡死在那頁（2026-08 會員回報）。
              // 正解：重新開一次 LIFF app，讓 init 的 auto login 再跑一次；
              // 只重試一次，第二次還不行就給明確指引，不要無限彈。
              if (!sessionFlag(LIFF_RETRY_KEY)) {
                logClientError(
                  "liff_auto_login_failed",
                  "LIFF isInClient 但 isLoggedIn=false，重開 LIFF 重試一次",
                  { store: s, has_pair: Boolean(resolvePairCode()) },
                  "warn",
                );
                setSessionFlag(LIFF_RETRY_KEY);
                window.location.href = liffAppUrl(liffId, s, resolvePairCode());
                return;
              }
              logClientError(
                "liff_auto_login_failed_final",
                "重開 LIFF 後仍未登入，改顯示指引",
                { store: s },
              );
              setError(
                "LINE 自動登入沒有完成。請關掉這個視窗，從 LINE 官方帳號的選單重新開啟一次；若還是不行，請改用手機瀏覽器開啟本站登入。",
              );
              setStatus("idle");
              return;
            }
            clearSessionFlag(LIFF_RETRY_KEY);
            // LIFF 走自動登入,先把 webview 內任何殘留的舊 session 清掉,
            // 避免 fragment 寫入後跟舊 key 撞
            clearSession();
            const idToken = liff.getIDToken();
            if (!idToken) {
              logClientError("liff_id_token_null", "LIFF getIDToken 回 null", { store: s });
              throw new Error("LIFF getIDToken returned null");
            }

            const pairCode = resolvePairCode();
            try {
              // 沒帶 store 也試 — 後端會用 line_user_id 找既有 binding
              await runLiffSession(idToken, s, pairCode);
            } catch (e) {
              const msg = e instanceof Error ? e.message : String(e);
              if (msg.includes("store_required")) {
                // 首次註冊、又沒帶 store → 顯示 store picker。
                // 留著 idToken：使用者選完門市按登入時要用它把 LIFF 登入補完，
                // 絕對不能退回 OAuth —— 在 LINE 裡走 OAuth 就是那頁 400。
                liffIdTokenRef.current = idToken;
                setStatus("idle");
                return;
              }
              logCaught("liff_session_failed", e, { store: s, has_pair: Boolean(pairCode) });
              throw e;
            }

            if (pairCode) {
              setStatus("pair_done");
              // 嘗試關掉 LINE webview（iOS 通常只是關掉 webview,使用者要自己回桌面）
              try { liff.closeWindow(); } catch { /* noop */ }
              return;
            }
            return;
          }

          // 走到這裡 = 不在 LIFF client（LINE 內建瀏覽器或一般瀏覽器）。
          //
          // 但 liff.login() 跑完回來時就是這個狀態：isInClient 仍是 false，
          // isLoggedIn 卻已經是 true。原本沒有這段，於是登入其實已經完成，
          // 使用者卻被丟回登入頁、得再按一次「用 LINE 登入」才會真的進去
          // —— 這就是「LIFF 登入要按兩次」。這裡直接把它補完。
          if (safe(() => liff.isLoggedIn())) {
            const idToken = safe(() => liff.getIDToken());
            if (idToken) {
              // 缺門市時留給 start()：使用者選完店按一次就能補完，不必重登
              liffIdTokenRef.current = idToken;
              // 自動補完每次瀏覽只做一次。萬一 session 寫了卻沒被 /shop 認出來
              // （或還有別的破口），會被踢回這裡再補完一次 → 又導 /shop →
              // 無限轉圈，而 log 因為去重只留得下第一筆，等於什麼線索都沒有。
              if (s && !sessionFlag(AUTO_COMPLETE_KEY)) {
                setSessionFlag(AUTO_COMPLETE_KEY);
                setStatus("liff_auth");
                try {
                  await runLiffSession(idToken, s, resolvePairCode());
                  return;
                } catch (e) {
                  const msg = e instanceof Error ? e.message : String(e);
                  // store_required 不是錯誤，只是還要選門市
                  if (!msg.includes("store_required")) {
                    logCaught("liff_auto_complete_failed", e, { store: s });
                  }
                  // 落回下面的 idle，讓使用者手動重試
                }
              }
            }
          }

          if (!s) {
            setStatus("idle");
            return;
          }
        } catch (e) {
          // 走到這裡 = LIFF 這條路整條掛掉，使用者會退回選門市 + OAuth。
          // 不是致命，但要留痕：多數 LIFF 問題都只在會員手機上重現得出來。
          logCaught("liff_init_failed", e, { store: s, liff_id: liffId });
        }
      }

      setStatus("idle");
    })();

    return () => {
      document.removeEventListener("visibilitychange", onVis);
      window.clearTimeout(stuckTimer);
      unlisten();
    };
  }, []);

  /**
   * standalone PWA：一律生 pair token,本地存好,
   *   - 有 LIFF_ID  → 開 LIFF URL(LINE app 內自動登入)
   *   - 沒 LIFF_ID  → 開 OAuth URL 帶 pair(callback 寫 pwa_auth_codes)
   *   兩條都用 anchor target=_blank 讓 PWA 留在 standalone 背景,
   *   visibilitychange 切回時自動 claim。
   * 一般瀏覽器(非 standalone)：原本 OAuth 流程。
   */
  const start = () => {
    if (!storeId) return;

    const liffId = process.env.NEXT_PUBLIC_LIFF_ID;

    if (standalone) {
      // 點下登入 = 明確要重新登,清掉所有舊 session 避免「看到舊 token 就跳 /me」
      clearSession();
      const token = genPairToken();
      localStorage.setItem(PAIR_TOKEN_KEY, token);

      // PWA 一律走 OAuth，不走 LIFF。
      //
      // LIFF 那條在 PWA 上沒有任何好處：PWA 開外部連結用的是 iOS 的
      // in-app browser，不是 LINE app —— 沒有自動登入，到頭來一樣要跑一次
      // LINE 授權。卻多繞一次 liff.line.me 跳轉（2026-08-03 實測會停在白畫面），
      // 而且致命的是 pair 掛在 URL 的 liff.state 上，liff.login() 一走就被沖掉，
      // 後端永遠收不到，pwa_auth_codes 也就永遠不會寫入
      // （實測 liff_session_ok 的 pair_written 一直是 null）。
      //
      // OAuth 這條的 pair 是編進 state JWT，由 line-oauth-callback 解出後
      // 直接寫進 pwa_auth_codes —— 全程在後端，前端 URL 怎麼變都沖不掉。
      const targetUrl = lineOauthStartUrl(storeId, token);

      // ⚠️ 這裡**不要**用 a.target="_blank"。
      // iOS 的 standalone PWA 對程式化開新視窗不可靠：可能靜默失敗（畫面
      // 停在等待、LINE 根本沒開），也可能開到 Safari —— 那更糟，登入完成後
      // session 進的是 Safari，PWA 這端永遠領不到。
      // 2026-08-03 實測就是卡在這：等待畫面出現，但 pwa_auth_codes 與
      // client_error_logs 全無紀錄，代表 LINE 那端根本沒被開起來。
      //
      // 直接導航兩種結果都走得通：
      //   1. iOS 攔截 universal link → 開 LINE，PWA 留在背景、頁面沒變，
      //      切回來時 visibilitychange 觸發領取
      //   2. 沒被攔截 → 在 PWA 內走到本站（liff.state 帶著 store 與 pair），
      //      整段登入就在 PWA 內完成，session 直接落地，連配對都不需要
      setPwaLoginUrl(targetUrl);
      logClientError(
        "pwa_login_started",
        "PWA 觸發 LINE 登入",
        { store: storeId, via: "oauth" },
        "info",
      );
      // 讓使用者知道「回來這裡就會自動完成」，否則切回來看到原本的登入頁
      // 會以為失敗，就去打驗證碼了
      setStatus("pwa_waiting");

      // 先試開新視窗：iOS 只有這樣才會建立返回鏈，LINE 左上角才會出現
      // 「◀ 包子媽生鮮小舖」讓使用者一鍵回來。直接用 location.href 導航雖然
      // 一定開得起來，卻沒有那條返回鏈 —— 使用者就回不到 PWA 了。
      //
      // 但 standalone PWA 的 window.open 有時會靜默失敗，所以不靠回傳值判斷
      // （iOS 可能回一個沒真的開起來的 window），改看「頁面有沒有進背景」：
      // 真的開起來了，這個頁面就會被切到背景。
      window.open(targetUrl, "_blank");
      window.setTimeout(() => {
        if (document.visibilityState !== "visible") return;
        logClientError(
          "pwa_login_open_fallback",
          "window.open 沒開起來，改直接導航",
          { store: storeId },
          "warn",
        );
        window.location.href = targetUrl;
      }, 2000);
      return;
    }

    // 已經在 LIFF 裡、只是缺門市（後端回 store_required）：
    // 選完門市用手上的 id_token 把登入補完就好，不要再繞任何 LINE 的授權頁。
    const pendingIdToken = liffIdTokenRef.current;
    if (pendingIdToken) {
      setStatus("liff_auth");
      runLiffSession(pendingIdToken, storeId, resolvePairCode()).catch((e) => {
        logCaught("liff_session_retry_failed", e, { store: storeId });
        setError(e instanceof Error ? e.message : String(e));
        setStatus("idle");
      });
      return;
    }

    const liff = liffRef.current;

    // 已經登入 LIFF（含 web 登入完成回來）：直接拿 id_token 建 session。
    // 首次 init 若因後端暫時性錯誤失敗（例：缺 env），使用者按登入就是在重試這條。
    if (liff && safe(() => liff.isLoggedIn())) {
      const idToken = safe(() => liff.getIDToken());
      if (idToken) {
        setStatus("liff_auth");
        runLiffSession(idToken, storeId, resolvePairCode()).catch((e) => {
          logCaught("liff_session_retry_failed", e, { store: storeId });
          setError(e instanceof Error ? e.message : String(e));
          setStatus("idle");
        });
        return;
      }
    }

    // 在 LINE 內建瀏覽器、還沒登入 → 走自家 OAuth，不要用 liff.login()。
    //
    // 2026-08-04 實測：liff.login() 導去 LINE 授權後帶著 ?code= 回來，
    // liff.init() 會在內部換 token 那步掛死、永遠不 resolve，頁面就停在
    // loading（liffRef 也一直是 null），使用者只能關掉重進。
    //
    // OAuth 這條完全不碰 LIFF SDK，也就沒有那個掛點：
    //   - redirect_uri 是 line-oauth-callback（channel 已註冊，不會 400 ——
    //     先前那個 400 是 LIFF 的 redirect_uri 指到本站造成的，與這條無關）
    //   - callback 302 回本站，session 在同一個 context 直接落地
    // PWA 早先改走這條之後就沒再出過事，LINE 內建瀏覽器同理。
    //
    // 只試一次，回來還是沒登入才給外部瀏覽器指引，不要在 LINE 裡鬼打牆。
    if (isInLineApp()) {
      if (!sessionFlag(LIFF_RETRY_KEY)) {
        setSessionFlag(LIFF_RETRY_KEY);
        logClientError(
          "line_browser_oauth_login",
          "LINE 內建瀏覽器：走 OAuth 登入",
          { store: storeId },
          "warn",
        );
        clearSession();
        window.location.href = lineOauthStartUrl(storeId, resolvePairCode() ?? undefined);
        return;
      }
      logClientError(
        "line_browser_login_blocked",
        "LINE 內建瀏覽器登入不成，改顯示外部瀏覽器指引",
        { store: storeId, has_liff_id: Boolean(liffId), has_liff: Boolean(liff) },
      );
      setLineStuck(true);
      return;
    }

    clearSession();
    // 帶上 URL 裡的 pair：PWA 把使用者導到瀏覽器登入時（例如 iOS 沒把
    // liff.line.me 交給 LINE app，而是開在 Safari），pair 會跟著 liff.state 過來。
    // 不轉交給 OAuth 的話，登入成功後不會寫 pwa_auth_codes，PWA 那端永遠領不到，
    // 使用者就只剩手動輸入驗證碼一條路 —— 這正是要消滅的情境。
    window.location.href = lineOauthStartUrl(storeId, resolvePairCode() ?? undefined);
  };

  /**
   * 指引畫面上的「再試一次」：start() 已經自動試過一輪 LIFF 登入，
   * 這顆是給使用者手動再試的（例如上一次是網路瞬斷、或他剛切換了 LINE 帳號）。
   */
  const retryLiffLogin = () => {
    const liff = liffRef.current;
    if (!liff) return;
    logClientError(
      "liff_login_manual_retry",
      "使用者在 LINE 內手動重試 LIFF 登入",
      { store: storeId },
      "warn",
    );
    try {
      liff.login();
    } catch (e) {
      logCaught("liff_login_manual_retry_failed", e, { store: storeId });
    }
  };

  /** 把本機錯誤紀錄整包送到後端（client_error_logs 的 user_report），給客服後續分析 */
  const reportProblem = async () => {
    if (reportState === "sending") return;
    setReportState("sending");
    const ok = await reportLogsToBackend(error ?? undefined);
    setReportState(ok ? "sent" : "failed");
  };

  /** 卡在 LINE 內建瀏覽器時唯一的出路：把網址帶去外部瀏覽器 */
  const copyLoginLink = async () => {
    const url = storeId
      ? `${window.location.origin}/?store=${encodeURIComponent(storeId)}`
      : window.location.origin;
    try {
      await navigator.clipboard.writeText(url);
      setLinkCopied(true);
      setTimeout(() => setLinkCopied(false), 3000);
    } catch (e) {
      // LINE webview 常擋剪貼簿 —— 退回顯示網址讓使用者自己長按複製
      logCaught("copy_login_link_failed", e, { store: storeId });
      setError(`請手動開啟：${url}`);
    }
  };

  const handleManualStoreSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const s = inputStoreId.trim().toUpperCase();
    if (!s) return;
    setStoreId(s);
    localStorage.setItem("last_store_id", s);
  };

  const handleSyncSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (syncCode.length !== 6 || syncing) return;

    setSyncing(true);
    setError(null);
    try {
      const data = await callLiffApi<{
        token: string;
        store: string;
        member_id: number;
        line_user_id: string;
        line_name: string | null;
        line_picture: string | null;
      }>("", { action: "claim_pwa_auth_code", code: syncCode });

      saveSession({
        token:       data.token,
        storeId:     data.store,
        memberId:    data.member_id,
        lineUserId:  data.line_user_id,
        lineName:    data.line_name,
        linePicture: data.line_picture,
      });
      window.location.href = "/shop";
    } catch (e) {
      logCaught("pwa_sync_code_failed", e);
      setError(e instanceof Error ? e.message : "驗證碼無效或已過期");
    } finally {
      setSyncing(false);
    }
  };

  return (
    <main className="mx-auto flex min-h-[100dvh] w-full max-w-md flex-col items-center px-6 pb-10 pt-12">
      {/* 品牌主視覺：店家實際 banner（含 logo + 店名 + 服務項目） */}
      <div className="w-full overflow-hidden rounded-[20px] shadow-[0_18px_40px_-14px_rgba(158,47,80,0.42)]">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src="/brand/banner.jpg"
          alt="包子媽生鮮小舖 — 新鮮直送・社區團購"
          className="block w-full"
        />
      </div>

      <div className="mt-9 w-full">
        {status === "loading" && <LoadingScreen className="py-14" />}

        {status === "liff_auth" && <LoadingScreen className="py-14" />}

        {status === "pwa_waiting" && (
          <div className="card space-y-4 p-6 text-center">
            <Spinner size={28} />
            <p className="text-[17px] font-bold text-[var(--foreground)]">
              請完成 LINE 登入
            </p>
            <p className="text-[14px] leading-relaxed text-[var(--secondary-label)]">
              完成後請回到本 App，我們會自動帶您進入，不需要輸入任何驗證碼。
            </p>
            {/* 回來的路不只一條，而使用者不見得找得到 —— 明講兩種。
                改走 OAuth 後多數情況是在瀏覽器視窗完成，關掉即可回到這裡 */}
            <div className="w-full rounded-xl bg-[var(--fill-quaternary,rgba(120,120,128,0.08))] p-3 text-left text-[13px] leading-relaxed text-[var(--secondary-label)]">
              回來的方式：
              <br />
              1. 點登入畫面左上角的「✕」或「◀」關閉
              <br />
              2. 或從手機桌面重新點開本 App
            </div>
            {/* LINE 沒被開起來時的自救 —— 沒有這顆就只能乾等，
                而使用者無從判斷是「還沒好」還是「根本沒開」 */}
            {pwaLoginUrl && (
              <a
                href={pwaLoginUrl}
                className="block w-full rounded-xl bg-[#06C755] px-4 py-3 text-[15px] font-semibold text-white transition active:scale-[0.98]"
              >
                登入畫面沒開啟？點這裡再試一次
              </a>
            )}
            <button
              onClick={() => setStatus("idle")}
              className="text-[14px] font-medium text-[var(--secondary-label)] underline underline-offset-4"
            >
              返回
            </button>
          </div>
        )}

        {status === "pair_done" && (
          <div className="card p-6 text-center">
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-[#06C755]/12 text-[28px] text-[#06C755]">
              ✓
            </div>
            <p className="mt-3 text-[17px] font-bold text-[var(--foreground)]">登入完成</p>
            {/* 「PWA 圖示」是黑話，會員看不懂；而且回去的路有兩條，都要講 */}
            <p className="mt-2 text-left text-[14px] leading-relaxed text-[var(--secondary-label)]">
              請回到「包子媽生鮮小舖」App：
              <br />
              1. 點左上角的「◀ 包子媽生鮮小舖」
              <br />
              2. 或關閉 LINE，從手機桌面重新點開本 App
            </p>
          </div>
        )}

        {status === "idle" && (
          <div className="w-full space-y-5">
            {error && (
              <div className="w-full space-y-2 rounded-2xl bg-[var(--ios-red)]/10 p-3 text-left text-[14px] text-[#c4271d]">
                <p>發生錯誤：{error}</p>
                <button
                  onClick={reportProblem}
                  disabled={reportState === "sending"}
                  className="w-full rounded-lg border border-[#c4271d]/30 px-3 py-2 text-[13px] font-semibold text-[#c4271d] transition active:scale-[0.98] disabled:opacity-60"
                >
                  {reportState === "sending" && "傳送中…"}
                  {reportState === "sent" && "✓ 已傳送，客服會盡快處理"}
                  {reportState === "failed" && "傳送失敗，請截圖給客服"}
                  {reportState === "idle" && "回報此問題給客服"}
                </button>
              </div>
            )}

            {!storeId ? (
              <div className="card space-y-4 p-5">
                <p className="text-[15px] font-medium text-[var(--foreground)]">
                  歡迎！請選擇您的門市以開始
                </p>
                <form onSubmit={handleManualStoreSubmit} className="flex flex-col gap-3">
                  {stores.length > 0 ? (
                    <select
                      value={inputStoreId}
                      onChange={(e) => setInputStoreId(e.target.value)}
                      className="w-full appearance-none rounded-xl border border-[var(--separator)] bg-[var(--background)] px-4 py-3 text-[16px] text-[var(--foreground)] focus:border-[var(--brand)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-soft)]"
                      required
                      autoFocus
                    >
                      <option value="" disabled>請選擇門市…</option>
                      {stores.map((s) => (
                        <option key={s.id} value={s.code}>
                          {s.name}（{s.code}）
                        </option>
                      ))}
                    </select>
                  ) : (
                    <input
                      type="text"
                      placeholder="例如: S001"
                      value={inputStoreId}
                      onChange={(e) => setInputStoreId(e.target.value)}
                      className="w-full rounded-xl border border-[var(--separator)] bg-[var(--background)] px-4 py-3 text-[16px] focus:border-[var(--brand)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-soft)]"
                      autoFocus
                    />
                  )}
                  <button
                    type="submit"
                    disabled={!inputStoreId}
                    className="w-full rounded-xl brand-gradient px-4 py-3 text-[16px] font-semibold text-white shadow-[0_10px_24px_-10px_rgba(158,47,80,0.6)] transition active:scale-[0.98] disabled:opacity-40"
                  >
                    進入門市
                  </button>
                </form>
              </div>
            ) : (
              <div className="space-y-6">
                <div className="card space-y-4 p-5 text-center">
                  <p className="text-[15px] text-[var(--secondary-label)]">
                    您目前位於{" "}
                    <span className="font-bold text-[var(--brand-strong)]">
                      {stores.find((s) => s.code === storeId)?.name ?? storeId}
                    </span>{" "}
                    門市
                  </p>
                  {lineStuck ? (
                    <div className="space-y-3 text-left">
                      <p className="text-[14px] leading-relaxed text-[var(--foreground)]">
                        {LINE_BROWSER_HINT}
                      </p>
                      <button
                        onClick={copyLoginLink}
                        className="w-full rounded-xl brand-gradient px-4 py-3 text-[15px] font-semibold text-white transition active:scale-[0.98]"
                      >
                        {linkCopied ? "已複製，請貼到瀏覽器開啟" : "複製本頁連結"}
                      </button>
                      {liffRef.current && (
                        <button
                          onClick={retryLiffLogin}
                          className="w-full rounded-xl border border-[var(--separator)] px-4 py-2.5 text-[14px] font-medium text-[var(--secondary-label)] transition active:scale-[0.98]"
                        >
                          仍要在 LINE 內再試一次
                        </button>
                      )}
                      <button
                        onClick={reportProblem}
                        disabled={reportState === "sending"}
                        className="w-full rounded-xl border border-[var(--separator)] px-4 py-2.5 text-[14px] font-medium text-[var(--secondary-label)] transition active:scale-[0.98] disabled:opacity-60"
                      >
                        {reportState === "sending" && "傳送中…"}
                        {reportState === "sent" && "✓ 已回報，客服會盡快處理"}
                        {reportState === "failed" && "回報失敗，請截圖給客服"}
                        {reportState === "idle" && "回報此問題給客服"}
                      </button>
                    </div>
                  ) : (
                    <button
                      onClick={start}
                      className="flex w-full items-center justify-center gap-2 rounded-xl bg-[#06C755] px-4 py-3.5 text-[16px] font-semibold text-white shadow-[0_10px_24px_-10px_rgba(6,199,85,0.7)] transition active:scale-[0.98]"
                    >
                      <svg viewBox="0 0 24 24" fill="currentColor" className="h-5 w-5">
                        <path d="M12 3C6.5 3 2 6.6 2 11c0 3.9 3.5 7.2 8.3 7.9.3.06.7.2.8.45.08.23.05.58.03.81l-.13.8c-.04.24-.19.93.81.51 1-.42 5.4-3.2 7.36-5.47C20.5 14.5 22 12.9 22 11c0-4.4-4.5-8-10-8Z" />
                      </svg>
                      {standalone ? "用 LINE 登入" : "用 LINE 註冊 / 登入"}
                    </button>
                  )}
                  {standalone && (
                    <p className="text-[12px] text-[var(--tertiary-label)]">
                      將開啟 LINE 登入頁，完成後自動回到此 App。
                    </p>
                  )}
                </div>

                {/* 驗證碼是「自動配對失敗」時的救命繩，不是並列的登入選項。
                    平鋪出來會讓會員以為登入本來就要打一組碼 —— 而那段流程
                    （自己先去瀏覽器登入、記下 6 碼、切回來輸入）對一般人根本走不完。
                    預設收起來，只有真的卡住的人才會展開。 */}
                {standalone && !showSyncCode && (
                  <button
                    onClick={() => setShowSyncCode(true)}
                    className="mx-auto block text-[13px] text-[var(--tertiary-label)] underline underline-offset-4"
                  >
                    登入遇到問題？用驗證碼手動同步
                  </button>
                )}

                {standalone && showSyncCode && (
                  <>
                    <div className="card space-y-3 p-5">
                      <p className="text-[14px] text-[var(--secondary-label)]">
                        僅在自動登入失敗時需要：請先用手機瀏覽器開啟本站登入，
                        再把該畫面顯示的 6 位數驗證碼輸入這裡。
                      </p>
                      <form onSubmit={handleSyncSubmit} className="flex gap-2">
                        <input
                          type="text"
                          inputMode="numeric"
                          pattern="[0-9]*"
                          maxLength={6}
                          placeholder="6 位數驗證碼"
                          value={syncCode}
                          onChange={(e) => setSyncCode(e.target.value)}
                          className="flex-1 rounded-xl border border-[var(--separator)] bg-[var(--background)] px-3 py-2.5 text-center font-mono text-xl tracking-widest focus:border-[var(--brand)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-soft)]"
                        />
                        <button
                          type="submit"
                          disabled={syncCode.length !== 6 || syncing}
                          className="flex items-center justify-center gap-2 rounded-xl brand-gradient px-5 py-2.5 text-[15px] font-semibold text-white transition active:scale-[0.97] disabled:opacity-40"
                        >
                          {syncing ? <Spinner size={16} onColor /> : "驗證"}
                        </button>
                      </form>
                    </div>
                  </>
                )}

                <button
                  onClick={() => { setStoreId(null); setInputStoreId(""); }}
                  className="mx-auto block text-[14px] font-medium text-[var(--secondary-label)] underline underline-offset-4"
                >
                  更換其他門市
                </button>
              </div>
            )}
          </div>
        )}
      </div>

      <div className="mt-auto pt-10 text-center text-[12px] text-[var(--tertiary-label)]">
        <p className="font-medium">包子媽生鮮小舖</p>
        <p className="mt-0.5 tracking-wide">Baozi Ma Group Buying</p>
      </div>
    </main>
  );
}

function readStore(): string | null {
  const sp = new URLSearchParams(window.location.search);
  const s = sp.get("store");
  if (s) return s;
  const raw = sp.get("liff.state");
  if (raw) return liffStateParams(raw).get("store");
  return null;
}

async function runLiffSession(
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

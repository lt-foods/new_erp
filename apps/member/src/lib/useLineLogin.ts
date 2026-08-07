"use client";

// 「用 LINE 登入 / 註冊」的整段狀態機。
//
// 首頁（/）與推廣落地頁（/join）長得完全不一樣，但要走的登入路徑是同一條，
// 而那條路上的每一個分支都是踩過雷才長成現在這樣（LIFF browser 不能自己
// liff.login()、PWA 不能走 LIFF、LINE 內建瀏覽器要改走 OAuth…）。
// 兩頁各寫一份 = 下次修 bug 只會修到其中一份，所以集中在這裡。
//
// 這支只管「怎麼登入」；長什麼樣子由呼叫端自己畫。

import { useCallback, useEffect, useRef, useState } from "react";
import { loadLiff } from "@/lib/liff";
import { cacheStoreLiffIds, resolveLiffId, resolveLiffIdSync } from "@/lib/storeLiff";
import { callLiffApi, lineOauthStartUrl } from "@/lib/supabase";
import { clearSession, getSession, listenForSession } from "@/lib/session";
import {
  isPageUnloading,
  logCaught,
  logClientError,
} from "@/lib/clientLog";
import {
  AUTH_CODE_INTENT_KEY,
  AUTO_COMPLETE_KEY,
  LIFF_INIT_TIMEOUT_MS,
  LIFF_RETRY_KEY,
  LOGIN_STUCK_MS,
  PAIR_TOKEN_KEY,
  claimPairTokenWithRetry,
  clearSessionFlag,
  genPairToken,
  isInLineApp,
  isStandalone,
  liffAppUrl,
  readParam,
  readStore,
  resolvePairCode,
  runLiffSession,
  safe,
  sessionFlag,
  setSessionFlag,
} from "@/lib/lineAuth";

export type LoginStatus =
  | "loading"
  | "idle"
  | "liff_auth"
  | "pair_done"
  | "pwa_waiting";

export type StoreOption = {
  id: number;
  code: string;
  name: string;
  /** 該店 Provider 底下的 LIFF ID；沒設就退回 NEXT_PUBLIC_LIFF_ID */
  line_liff_id?: string | null;
};

export type UseLineLoginOptions = {
  /**
   * 只有一間店時自動選起來，不要讓使用者先過一關「選門市」。
   *
   * 首頁預設 false（維持原本行為）；推廣落地頁開 true —— 從社群點進來的人
   * 對「門市」沒有概念，第一眼就被問只會流失。
   */
  autoSelectSingleStore?: boolean;
};

export type UseLineLogin = {
  status: LoginStatus;
  setStatus: (s: LoginStatus) => void;
  error: string | null;
  setError: (e: string | null) => void;
  /** 目前選定的門市代號（stores.code） */
  storeId: string | null;
  /** 使用者主動選門市時用這個（會記進 localStorage 當下次的預設） */
  chooseStore: (code: string | null) => void;
  stores: StoreOption[];
  /** 跑在已安裝的 PWA（standalone）裡 */
  standalone: boolean;
  /** 在 LINE 內建瀏覽器且已無路可走 → 呼叫端顯示「用外部瀏覽器開啟」指引 */
  lineStuck: boolean;
  /** PWA 等待畫面用：LINE 沒自動開起來時讓使用者手動再開一次 */
  pwaLoginUrl: string | null;
  /** LIFF SDK 有 init 成功 → 可以顯示「在 LINE 內再試一次」 */
  canRetryLiff: boolean;
  /** 按下「用 LINE 登入 / 註冊」 */
  start: () => void;
  retryLiffLogin: () => void;
};

export function useLineLogin(options: UseLineLoginOptions = {}): UseLineLogin {
  const { autoSelectSingleStore = false } = options;

  /** 使用者 / URL / localStorage 明確指定的門市 */
  const [pickedStore, setPickedStore] = useState<string | null>(null);
  const [stores, setStores] = useState<StoreOption[]>([]);

  /**
   * 實際生效的門市 = 明確指定的那個，沒有的話才退到「只有一間店就用它」。
   *
   * 用 render 時算而不是拿 effect 去 setState：多一次 render 事小，
   * 「清單載回來的瞬間門市短暫是 null」會讓 CTA 閃一下 disabled 才對。
   */
  const storeId =
    pickedStore ??
    (autoSelectSingleStore && stores.length === 1 ? stores[0].code : null);
  const [status, setStatus] = useState<LoginStatus>("loading");
  const [error, setError] = useState<string | null>(null);
  const [standalone, setStandalone] = useState(false);
  /** 在 LINE 內建瀏覽器又沒有 LIFF context = 無路可走，改給外部瀏覽器指引 */
  const [lineStuck, setLineStuck] = useState(false);
  const [pwaLoginUrl, setPwaLoginUrl] = useState<string | null>(null);
  const [canRetryLiff, setCanRetryLiff] = useState(false);
  /** LIFF 已登入但缺門市時留下的 id_token，選完門市直接拿它補完登入 */
  const liffIdTokenRef = useRef<string | null>(null);
  /** init 成功的 liff 實例（給「卡在 LINE 裡」時的手動重試用） */
  const liffRef = useRef<Awaited<ReturnType<typeof loadLiff>> | null>(null);

  useEffect(() => {
    // eslint 的 set-state-in-effect 會嫌這行，但不能改成 useState 的 lazy initializer：
    // isStandalone() 在 server 一定回 false，client 首次 render 若回 true 就是
    // hydration mismatch。環境判斷只能等掛載後才做。
    const sa = isStandalone();
    setStandalone(sa);

    // 已綁(有 memberId)才跳走;只有 token 沒 member_id 不跳,避免跟 /shop 互推產生
    // redirect loop。standalone PWA 與 LINE LIFF 內建瀏覽器 → /shop(完整商店);
    // 一般外部瀏覽器 → /me
    const isLine = isInLineApp();
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
      .then((r) => {
        setStores(r.stores ?? []);
        // 存起來給下次冷啟動用：LINE 內 liff.init() 跑在清單抓回來之前
        cacheStoreLiffIds(r.stores ?? []);
      })
      .catch((e) => {
        // 跳頁把這個 fetch 取消掉不算故障（Safari 回 "Load failed"），記了只是雜訊
        if (isPageUnloading()) return;
        // 抓不到就退回手動輸入；但要留痕以免靜默失敗（例：.env.local 缺 NEXT_PUBLIC_SUPABASE_URL → callLiffApi throw）
        logCaught("list_stores_failed", e, { fallback: "manual_store_input" });
      });

    // 從 LIFF 配對流程切回 PWA 時，自動 claim
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

      // 一進頁面就把配對碼備份起來 —— 必須趕在 liff.login() 把 URL 上的
      // liff.state 換成 ?code=... 之前，否則這趟 PWA 配對就再也接不回去了
      resolvePairCode();

      // 從 PWA 的「取驗證碼」指引連結進來的才帶 want_code=1。
      // 記在 sessionStorage，等 OAuth 轉一圈回到 /auth/success 時，那頁才知道
      // 這個人是來取碼的，不要把他直接送進商店。
      if (readParam("want_code") === "1") setSessionFlag(AUTH_CODE_INTENT_KEY);

      // 讀門市
      let s = readStore();
      if (!s && typeof window !== "undefined") {
        s = localStorage.getItem("last_store_id");
      }
      if (s) {
        setPickedStore(s);
        localStorage.setItem("last_store_id", s);
      }

      // 用「這家店」的 LIFF 登入，不是租戶預設的那支。
      //
      // LINE 的 user ID 綁 Provider：14 家店的官方帳號各在自己的 Provider，
      // 用錯的 LIFF 登入，拿到的 line_user_id 對該店 OA 是查不到的（推播必失敗）。
      // 這行必須排在讀門市之後、liff.init() 之前 —— 順序不能動。
      // 該店沒設就退回 NEXT_PUBLIC_LIFF_ID，等於維持這個欄位出現前的行為。
      const liffId = await resolveLiffId(s);

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
          setCanRetryLiff(true);

          const sFromLiff = readStore();
          if (sFromLiff) {
            s = sFromLiff;
            setPickedStore(s);
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

  /** 使用者主動選門市 —— 記起來當下次的預設 */
  const chooseStore = useCallback((code: string | null) => {
    setPickedStore(code);
    if (typeof window === "undefined") return;
    if (code) localStorage.setItem("last_store_id", code);
    else localStorage.removeItem("last_store_id");
  }, []);

  /**
   * standalone PWA：一律生 pair token,本地存好,開 OAuth URL 帶 pair
   *   (callback 寫 pwa_auth_codes)，visibilitychange 切回時自動 claim。
   * 一般瀏覽器(非 standalone)：LIFF 手上有 id_token 就直接補完，否則走 OAuth。
   */
  const start = useCallback(() => {
    if (!storeId) return;

    // 同上：用該店的 LIFF。走到這裡門市清單早就載完、快取是熱的，
    // 所以讀快取版本就夠（這是 callback，不能 await）。
    const liffId = resolveLiffIdSync(storeId);

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
  }, [standalone, storeId]);

  /**
   * 指引畫面上的「再試一次」：start() 已經自動試過一輪 LIFF 登入，
   * 這顆是給使用者手動再試的（例如上一次是網路瞬斷、或他剛切換了 LINE 帳號）。
   */
  const retryLiffLogin = useCallback(() => {
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
  }, [storeId]);

  return {
    status,
    setStatus,
    error,
    setError,
    storeId,
    chooseStore,
    stores,
    standalone,
    lineStuck,
    pwaLoginUrl,
    canRetryLiff,
    start,
    retryLiffLogin,
  };
}

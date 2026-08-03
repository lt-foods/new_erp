"use client";

import { useEffect, useState } from "react";
import { lineOauthStartUrl, callLiffApi } from "@/lib/supabase";
import { loadLiff } from "@/lib/liff";
import { clearSession, getSession, listenForSession } from "@/lib/session";
import Spinner, { LoadingScreen } from "@/components/Spinner";

type Status = "loading" | "idle" | "liff_auth" | "pair_done" | "error";

const PAIR_TOKEN_KEY = "pwa_pair_token";
/** 只允許往 LIFF 彈一次的旗標（sessionStorage），避免 LIFF ↔ 網頁互推無限迴圈 */
const LIFF_RETRY_KEY = "liff_login_retry";

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
  "LINE 內建瀏覽器無法完成 LINE 登入。請點右上角「⋮」選「用其他瀏覽器開啟」後再登入，或從 LINE 官方帳號的選單重新進入。";

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

    const frag = new URLSearchParams({
      token: data.token,
      store: data.store,
      bound: "1",
      member_id: String(data.member_id),
      line_user_id: data.line_user_id,
      line_name: data.line_name ?? "",
      line_picture: data.line_picture ?? "",
    });
    localStorage.removeItem(PAIR_TOKEN_KEY);
    window.location.href = `/shop#${frag.toString()}`;
    return true;
  } catch {
    // 沒到期或還沒寫入 → 等下次
    return false;
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
      clearSessionFlag(LIFF_RETRY_KEY);
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
        // 抓不到就退回手動輸入；但要 warn 以免靜默失敗（例：.env.local 缺 NEXT_PUBLIC_SUPABASE_URL → callLiffApi throw）
        console.warn("[liff] list_stores failed, falling back to text input:", e);
      });

    // 3. 從 LIFF 配對流程切回 PWA 時，自動 claim
    void tryClaimPairToken();
    const onVis = () => {
      if (document.visibilityState === "visible") void tryClaimPairToken();
    };
    document.addEventListener("visibilitychange", onVis);

    (async () => {
      const errInUrl = new URLSearchParams(window.location.search).get("error");
      if (errInUrl) setError(errInUrl);

      const liffId = process.env.NEXT_PUBLIC_LIFF_ID;

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
          await liff.init({ liffId });

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
                setSessionFlag(LIFF_RETRY_KEY);
                window.location.href = liffAppUrl(liffId, s, readPairFromUrl());
                return;
              }
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
            if (!idToken) throw new Error("LIFF getIDToken returned null");

            const pairCode = readPairFromUrl();
            try {
              // 沒帶 store 也試 — 後端會用 line_user_id 找既有 binding
              await runLiffSession(idToken, s, pairCode);
            } catch (e) {
              const msg = e instanceof Error ? e.message : String(e);
              if (msg.includes("store_required")) {
                // 首次註冊、又沒帶 store → 顯示 store picker
                setStatus("idle");
                return;
              }
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

          if (!s) {
            setStatus("idle");
            return;
          }
        } catch (e) {
          console.warn("liff init failed, falling back:", e);
        }
      }

      setStatus("idle");
    })();

    return () => {
      document.removeEventListener("visibilitychange", onVis);
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

      const targetUrl = liffId
        ? liffAppUrl(liffId, storeId, token)
        : lineOauthStartUrl(storeId, token);

      const a = document.createElement("a");
      a.href = targetUrl;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      document.body.appendChild(a);
      a.click();
      a.remove();
      return;
    }

    // 在 LINE 內建瀏覽器開本站（例：從聊天室 / 貼文點連結進來，不是 LIFF context）：
    // 一樣不能把人丟去 access.line.me 跑 OAuth，會回 400 Bad Request。
    // 改用 LIFF URL 讓 LINE 以 LIFF 重開這個 app（LIFF 內是自動登入）。
    if (isInLineApp()) {
      if (liffId && !sessionFlag(LIFF_RETRY_KEY)) {
        setSessionFlag(LIFF_RETRY_KEY);
        clearSession();
        window.location.href = liffAppUrl(liffId, storeId);
        return;
      }
      setError(LINE_BROWSER_HINT);
      return;
    }

    clearSession();
    window.location.href = lineOauthStartUrl(storeId);
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

      const frag = new URLSearchParams({
        token: data.token,
        store: data.store,
        bound: "1",
        member_id: String(data.member_id),
        line_user_id: data.line_user_id,
        line_name: data.line_name ?? "",
        line_picture: data.line_picture ?? "",
      });
      window.location.href = `/shop#${frag.toString()}`;
    } catch (e) {
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

        {status === "pair_done" && (
          <div className="card p-6 text-center">
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-[#06C755]/12 text-[28px] text-[#06C755]">
              ✓
            </div>
            <p className="mt-3 text-[17px] font-bold text-[var(--foreground)]">登入完成</p>
            <p className="mt-1 text-[14px] text-[var(--secondary-label)]">
              請關閉 LINE 視窗，回到桌面點擊 PWA 圖示。
            </p>
          </div>
        )}

        {status === "idle" && (
          <div className="w-full space-y-5">
            {error && (
              <div className="w-full rounded-2xl bg-[var(--ios-red)]/10 p-3 text-left text-[14px] text-[#c4271d]">
                發生錯誤：{error}
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
                  <button
                    onClick={start}
                    className="flex w-full items-center justify-center gap-2 rounded-xl bg-[#06C755] px-4 py-3.5 text-[16px] font-semibold text-white shadow-[0_10px_24px_-10px_rgba(6,199,85,0.7)] transition active:scale-[0.98]"
                  >
                    <svg viewBox="0 0 24 24" fill="currentColor" className="h-5 w-5">
                      <path d="M12 3C6.5 3 2 6.6 2 11c0 3.9 3.5 7.2 8.3 7.9.3.06.7.2.8.45.08.23.05.58.03.81l-.13.8c-.04.24-.19.93.81.51 1-.42 5.4-3.2 7.36-5.47C20.5 14.5 22 12.9 22 11c0-4.4-4.5-8-10-8Z" />
                    </svg>
                    {standalone ? "用 LINE 登入" : "用 LINE 註冊 / 登入"}
                  </button>
                  {standalone && (
                    <p className="text-[12px] text-[var(--tertiary-label)]">
                      將在 LINE app 中完成登入，再回到此 PWA App。
                    </p>
                  )}
                </div>

                {standalone && (
                  <>
                    <div className="relative">
                      <div className="absolute inset-0 flex items-center">
                        <span className="w-full border-t border-[var(--separator)]" />
                      </div>
                      <div className="relative flex justify-center">
                        <span className="bg-[var(--background)] px-3 text-[12px] font-medium text-[var(--tertiary-label)]">
                          或者
                        </span>
                      </div>
                    </div>

                    <div className="card space-y-3 p-5">
                      <p className="text-[14px] text-[var(--secondary-label)]">
                        如果您已在瀏覽器登入，請輸入驗證碼：
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

  // 若是 PWA pairing 流程,session 已經寫進 pwa_auth_codes,
  // 這裡 LIFF 端不需要也不應該跳到 /me（user 應該回 PWA）。
  if (pairCode) return;

  const frag = new URLSearchParams({
    token:        String(data.token),
    store:        String(data.store),
    bound:        "1",
    member_id:    String(data.member_id),
    line_user_id: String(data.line_user_id ?? ""),
  });
  if (data.line_name)    frag.set("line_name",    String(data.line_name));
  if (data.line_picture) frag.set("line_picture", String(data.line_picture));
  // LIFF 自然登入(沒帶 pair) = 在 LINE webview 內。放行完整商店體驗:
  // 直接進 /shop,跟 standalone PWA 一致(不再只停在 /me)。
  window.location.href = `/shop#${frag.toString()}`;
}

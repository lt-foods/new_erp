"use client";

import { useEffect, useState } from "react";
import { lineOauthStartUrl, callLiffApi } from "@/lib/supabase";
import { loadLiff } from "@/lib/liff";
import { clearSession, getSession, listenForSession } from "@/lib/session";

type Status = "loading" | "idle" | "liff_auth" | "pair_done" | "error";

const PAIR_TOKEN_KEY = "pwa_pair_token";

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

function readPairFromUrl(): string | null {
  if (typeof window === "undefined") return null;
  const sp = new URLSearchParams(window.location.search);
  const direct = sp.get("pair");
  if (direct) return direct;
  // LIFF 把 query 包進 liff.state
  const ls = sp.get("liff.state");
  if (ls) {
    const inner = new URLSearchParams(ls.startsWith("?") ? ls.slice(1) : ls);
    return inner.get("pair");
  }
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
    // redirect loop。PWA standalone → /shop;LINE / 一般瀏覽器 → /me
    const landing = sa ? "/shop" : "/me";

    const existing = getSession();
    if (existing && existing.memberId) {
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
      .catch(() => { /* 抓不到就退回手動輸入 */ });

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

          if (!s) {
            setStatus("idle");
            return;
          }

          if (liff.isInClient()) {
            setStatus("liff_auth");
            if (!liff.isLoggedIn()) {
              liff.login();
              return;
            }
            // LIFF 走自動登入,先把 webview 內任何殘留的舊 session 清掉,
            // 避免 fragment 寫入後跟舊 key 撞
            clearSession();
            const idToken = liff.getIDToken();
            if (!idToken) throw new Error("LIFF getIDToken returned null");

            const pairCode = readPairFromUrl();
            await runLiffSession(idToken, s, pairCode);

            if (pairCode) {
              setStatus("pair_done");
              // 嘗試關掉 LINE webview（iOS 通常只是關掉 webview,使用者要自己回桌面）
              try { liff.closeWindow(); } catch { /* noop */ }
              return;
            }
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
        ? `https://liff.line.me/${encodeURIComponent(liffId)}` +
          `?store=${encodeURIComponent(storeId)}` +
          `&pair=${encodeURIComponent(token)}`
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
    <main className="mx-auto flex w-full max-w-md flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-semibold">包子媽生鮮小舖</h1>

      {status === "loading" && <p className="text-base text-zinc-400">載入中…</p>}

      {status === "liff_auth" && (
        <p className="text-base text-zinc-500">LINE 驗證中…請稍候</p>
      )}

      {status === "pair_done" && (
        <div className="w-full rounded-2xl bg-[#06C755]/10 p-5 text-center">
          <div className="text-3xl">✓</div>
          <p className="mt-2 text-base font-medium text-[#067a37]">登入完成</p>
          <p className="mt-1 text-sm text-zinc-600">
            請關閉 LINE 視窗，回到桌面點擊 PWA 圖示。
          </p>
        </div>
      )}

      {status === "idle" && (
        <div className="w-full space-y-6 text-center">
          {error && (
            <div className="w-full rounded-md border border-red-200 bg-red-50 p-3 text-base text-red-800 text-left">
              發生錯誤：{error}
            </div>
          )}

          {!storeId ? (
            <div className="space-y-4">
              <p className="text-base text-zinc-500">歡迎！請選擇您的門市以開始：</p>
              <form onSubmit={handleManualStoreSubmit} className="flex flex-col gap-3">
                {stores.length > 0 ? (
                  <select
                    value={inputStoreId}
                    onChange={(e) => setInputStoreId(e.target.value)}
                    className="w-full appearance-none rounded-md border border-zinc-300 bg-white px-4 py-3 text-lg text-zinc-900 focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
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
                    className="w-full rounded-md border border-zinc-300 px-4 py-3 text-lg focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500 dark:border-zinc-700 dark:bg-zinc-800"
                    autoFocus
                  />
                )}
                <button
                  type="submit"
                  disabled={!inputStoreId}
                  className="w-full rounded-md bg-indigo-600 px-4 py-3 text-base font-medium text-white shadow transition hover:bg-indigo-700 disabled:opacity-50"
                >
                  進入門市
                </button>
              </form>
            </div>
          ) : (
            <div className="space-y-8">
              <div className="space-y-4">
                <p className="text-base text-zinc-500">
                  您目前位於 <span className="font-bold text-zinc-900 dark:text-zinc-100">{stores.find((s) => s.code === storeId)?.name ?? storeId}</span> 門市
                </p>
                <button
                  onClick={start}
                  className="w-full rounded-md bg-[#06C755] px-4 py-3 text-base font-medium text-white shadow hover:bg-[#05b04c] transition"
                >
                  {standalone ? "用 LINE 登入" : "用 LINE 註冊 / 登入"}
                </button>
                {standalone && (
                  <p className="text-xs text-zinc-400">
                    將在 LINE app 中完成登入，再回到此 PWA App。
                  </p>
                )}
              </div>

              {standalone && (
                <>
                  <div className="relative py-4">
                    <div className="absolute inset-0 flex items-center">
                      <span className="w-full border-t border-zinc-200"></span>
                    </div>
                    <div className="relative flex justify-center text-xs uppercase">
                      <span className="bg-white px-2 text-zinc-400 dark:bg-zinc-950">或者</span>
                    </div>
                  </div>

                  <div className="space-y-4 rounded-xl border border-zinc-200 p-4 bg-zinc-50/50">
                    <p className="text-sm text-zinc-500">如果您已在瀏覽器登入，請輸入驗證碼：</p>
                    <form onSubmit={handleSyncSubmit} className="flex gap-2">
                      <input
                        type="text"
                        inputMode="numeric"
                        pattern="[0-9]*"
                        maxLength={6}
                        placeholder="6 位數驗證碼"
                        value={syncCode}
                        onChange={(e) => setSyncCode(e.target.value)}
                        className="flex-1 rounded-md border border-zinc-300 px-3 py-2 text-center font-mono text-xl tracking-widest focus:border-indigo-500 focus:outline-none"
                      />
                      <button
                        type="submit"
                        disabled={syncCode.length !== 6 || syncing}
                        className="rounded-md bg-indigo-600 px-4 py-2 text-base font-medium text-white shadow disabled:opacity-50"
                      >
                        {syncing ? "..." : "驗證"}
                      </button>
                    </form>
                  </div>
                </>
              )}

              <button
                onClick={() => { setStoreId(null); setInputStoreId(""); }}
                className="text-sm text-zinc-400 hover:text-zinc-600 underline"
              >
                更換其他門市
              </button>
            </div>
          )}
        </div>
      )}

      <div className="mt-8 text-center text-xs text-zinc-400 space-y-1">
        <p>包子媽生鮮小舖</p>
        <p>Baozi Ma Group Buying</p>
      </div>
    </main>
  );
}

function readStore(): string | null {
  const sp = new URLSearchParams(window.location.search);
  const s = sp.get("store");
  if (s) return s;
  const raw = sp.get("liff.state");
  if (raw) {
    const inner = new URLSearchParams(raw.startsWith("?") ? raw.slice(1) : raw);
    return inner.get("store");
  }
  return null;
}

async function runLiffSession(
  idToken: string,
  storeId: string,
  pairCode: string | null,
) {
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base) throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");

  const body: Record<string, string> = {
    id_token: idToken,
    store: storeId,
  };
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
  // LIFF 自然登入(沒帶 pair) = 在 LINE webview 內,只停在 /me 會員中心。
  // PWA 端的完整商店體驗在 standalone 才開放。
  window.location.href = `/me#${frag.toString()}`;
}

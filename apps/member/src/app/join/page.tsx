"use client";

// 社群推廣用的註冊落地頁。
//
// 跟首頁（/）的差別是「給誰看」：首頁是已經知道我們是誰的人回來登入；
// /join 是把連結貼到 Facebook 社團 / LINE 群 / IG 限動之後，第一次聽到
// 「包子媽」的人點進來的第一個畫面。所以這頁要先回答「你們是誰、我為什麼要加入」，
// 再把唯一一顆 CTA（用 LINE 註冊）放在最順手的位置。
//
// 登入的實際路徑（LIFF 自動登入 / LINE 內建瀏覽器 / PWA）一律走 useLineLogin，
// 不在這裡重寫 —— 那條路上的每個 workaround 都是踩雷換來的，複製一份就等於
// 之後只會修到其中一份。
//
// 註冊本身不需要表單：後端 liff-session 查不到 binding 又拿到 store 時會直接
// auto-register，所以「用 LINE 登入」＝「用 LINE 註冊」，一顆按鈕就完成。

import { useEffect, useState } from "react";
import { logClientError } from "@/lib/clientLog";
import { LINE_BROWSER_HINT, readParam, sessionFlag, setSessionFlag } from "@/lib/lineAuth";
import { useLineLogin } from "@/lib/useLineLogin";
import Spinner, { LoadingScreen } from "@/components/Spinner";

/** 推廣來源記在這裡，之後 LINE 授權轉一圈回來還讀得到 */
const SRC_KEY = "join_src";
/** 一次瀏覽只記一筆到訪，避免 React 重跑 effect 時灌兩筆 */
const VIEW_LOGGED_KEY = "join_view_logged";

/**
 * 這個人是從哪個社群來的。
 *
 * `?src=fb-中和團購` 這種參數是我們自己在貼文連結上加的，用途只有一個：
 * 事後知道哪個社群真的帶得進人。存進 localStorage 是因為 LINE 授權會把使用者
 * 帶離本站再導回來，URL 上的東西一路上都會被沖掉。
 */
function resolveSrc(): string | null {
  if (typeof window === "undefined") return null;
  const fromUrl = readParam("src") ?? readParam("utm_source");
  if (fromUrl) {
    const v = fromUrl.slice(0, 80);
    try { localStorage.setItem(SRC_KEY, v); } catch { /* noop */ }
    return v;
  }
  try { return localStorage.getItem(SRC_KEY); } catch { return null; }
}

const BENEFITS = [
  {
    emoji: "🥬",
    title: "產地直送的生鮮",
    desc: "每日開團、當日配到門市，不用等宅配、不用怕放到不新鮮。",
  },
  {
    emoji: "🔔",
    title: "開團第一時間就知道",
    desc: "熱門品項常常幾小時就結單，加入後新團一開就會通知你。",
  },
  {
    emoji: "🏠",
    title: "到鄰近門市取貨",
    desc: "免運費、順路帶回家；訂單、取貨進度都在 App 裡看得到。",
  },
];

const STEPS = [
  "用 LINE 一鍵註冊（約 30 秒）",
  "挑選正在開團的商品下單",
  "收到取貨通知後到門市帶回家",
];

export default function JoinPage() {
  const {
    status, setStatus,
    error,
    storeId, chooseStore, stores,
    standalone, lineStuck, pwaLoginUrl, canRetryLiff,
    start, retryLiffLogin,
  } = useLineLogin({ autoSelectSingleStore: true });

  /** 已經有門市時預設收起選單，按「更換」才展開 */
  const [pickingStore, setPickingStore] = useState(false);
  const [shareHint, setShareHint] = useState<string | null>(null);
  const [copiedLink, setCopiedLink] = useState(false);

  useEffect(() => {
    // 到訪紀錄：推廣成效唯一的量測點（client_error_logs 裡以 join_page_view 分群）。
    // 用 info 等級，不是錯誤，只是留一條可以回頭統計的軌跡。
    // 來源不進 state —— 只有寫 log 時才需要，現讀現用就好（順便省一次 render）。
    if (!sessionFlag(VIEW_LOGGED_KEY)) {
      setSessionFlag(VIEW_LOGGED_KEY);
      logClientError(
        "join_page_view",
        "推廣註冊頁到訪",
        {
          src: resolveSrc(),
          store: readParam("store"),
          referrer: document.referrer.slice(0, 200) || null,
        },
        "info",
      );
    }
  }, []);

  const storeName = stores.find((s) => s.code === storeId)?.name ?? storeId;
  const needStore = !storeId;

  const onJoin = () => {
    if (needStore) {
      // 沒門市就按不動 CTA 只會讓人以為壞了 —— 直接把選單打開
      setPickingStore(true);
      return;
    }
    logClientError(
      "join_cta_clicked",
      "推廣註冊頁按下 LINE 註冊",
      { src: resolveSrc(), store: storeId, standalone },
      "info",
    );
    start();
  };

  /** 把這頁分享出去 —— 這頁本身就是要被轉貼的，順手給會員一個轉貼的入口 */
  const onShare = async () => {
    const url = new URL("/join", window.location.origin);
    if (storeId) url.searchParams.set("store", storeId);
    // 二次擴散另外標記，才分得出「我們自己貼的」與「會員幫忙轉的」
    url.searchParams.set("src", "share");
    const link = url.toString();

    const data = {
      title: "包子媽生鮮小舖",
      text: "我在用包子媽生鮮小舖訂生鮮，用 LINE 就能加入，一起買！",
      url: link,
    };
    try {
      if (navigator.share) {
        await navigator.share(data);
        return;
      }
      await navigator.clipboard.writeText(link);
      setCopiedLink(true);
      setTimeout(() => setCopiedLink(false), 3000);
    } catch {
      // 使用者取消分享也會走到這 —— 不是錯誤，給連結讓他自己複製就好
      setShareHint(link);
    }
  };

  const busy = status === "loading" || status === "liff_auth";

  return (
    <main className="mx-auto flex min-h-[100dvh] w-full max-w-md flex-col px-5 pb-12 pt-8">
      {/* ── Hero ─────────────────────────────────────────────── */}
      <div className="overflow-hidden rounded-[20px] shadow-[0_18px_40px_-14px_rgba(158,47,80,0.42)]">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src="/brand/banner.jpg"
          alt="包子媽生鮮小舖 — 新鮮直送・社區團購"
          className="block w-full"
        />
      </div>

      <div className="mt-7 text-center animate-in">
        <span className="inline-block rounded-full bg-[var(--brand-soft)] px-3 py-1 text-[12px] font-semibold tracking-wide text-[var(--brand-deep)]">
          社區團購・免費加入
        </span>
        <h1 className="mt-3 text-[26px] font-bold leading-snug text-[var(--foreground)]">
          用 LINE 加入
          <br />
          <span className="brand-gradient-text">包子媽生鮮小舖</span>
        </h1>
        <p className="mt-3 text-[15px] leading-relaxed text-[var(--secondary-label)]">
          每日開團的產地生鮮，直送你家附近的門市。
          <br />
          不用填帳號密碼，用 LINE 登入就完成註冊。
        </p>
      </div>

      {/* ── CTA ──────────────────────────────────────────────── */}
      <div className="card mt-7 space-y-4 p-5">
        {busy && <LoadingScreen className="py-8" />}

        {status === "pwa_waiting" && (
          <div className="space-y-4 text-center">
            <Spinner size={28} />
            <p className="text-[17px] font-bold text-[var(--foreground)]">請完成 LINE 登入</p>
            <p className="text-[14px] leading-relaxed text-[var(--secondary-label)]">
              完成後請回到本 App，我們會自動帶您進入，不需要輸入任何驗證碼。
            </p>
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
          <div className="text-center">
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-[#06C755]/12 text-[28px] text-[#06C755]">
              ✓
            </div>
            <p className="mt-3 text-[17px] font-bold text-[var(--foreground)]">註冊完成</p>
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
          <>
            {error && (
              <p className="rounded-xl bg-[var(--ios-red)]/10 p-3 text-[13px] leading-relaxed text-[#c4271d]">
                {error}
              </p>
            )}

            {/* 取貨門市 —— 註冊時唯一需要使用者決定的事 */}
            {pickingStore || needStore ? (
              <label className="block space-y-1.5">
                <span className="text-[13px] font-semibold text-[var(--secondary-label)]">
                  選擇取貨門市
                </span>
                {stores.length > 0 ? (
                  <select
                    value={storeId ?? ""}
                    onChange={(e) => {
                      chooseStore(e.target.value || null);
                      setPickingStore(false);
                    }}
                    className="w-full appearance-none rounded-xl border border-[var(--separator)] bg-[var(--background)] px-4 py-3 text-[16px] text-[var(--foreground)] focus:border-[var(--brand)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-soft)]"
                  >
                    <option value="" disabled>請選擇離您最近的門市…</option>
                    {stores.map((s) => (
                      <option key={s.id} value={s.code}>
                        {s.name}（{s.code}）
                      </option>
                    ))}
                  </select>
                ) : (
                  // 門市清單抓不到時不能整頁卡死 —— 退回手動輸入代號
                  <input
                    type="text"
                    placeholder="門市代號，例如 S001"
                    defaultValue={storeId ?? ""}
                    onBlur={(e) => {
                      const v = e.target.value.trim().toUpperCase();
                      if (v) { chooseStore(v); setPickingStore(false); }
                    }}
                    className="w-full rounded-xl border border-[var(--separator)] bg-[var(--background)] px-4 py-3 text-[16px] focus:border-[var(--brand)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-soft)]"
                  />
                )}
              </label>
            ) : (
              <div className="flex items-center justify-between gap-3 rounded-xl bg-[var(--brand-soft)]/60 px-4 py-3">
                <div className="min-w-0">
                  <p className="text-[12px] text-[var(--secondary-label)]">取貨門市</p>
                  <p className="truncate text-[15px] font-semibold text-[var(--brand-deep)]">
                    {storeName}
                  </p>
                </div>
                <button
                  onClick={() => setPickingStore(true)}
                  className="shrink-0 text-[13px] font-medium text-[var(--brand-strong)] underline underline-offset-4"
                >
                  更換
                </button>
              </div>
            )}

            {lineStuck ? (
              <div className="space-y-3">
                <p className="text-[14px] leading-relaxed text-[var(--foreground)]">
                  {LINE_BROWSER_HINT}
                </p>
                <button
                  onClick={onShare}
                  className="w-full rounded-xl brand-gradient px-4 py-3 text-[15px] font-semibold text-white transition active:scale-[0.98]"
                >
                  {copiedLink ? "已複製，請貼到瀏覽器開啟" : "複製本頁連結"}
                </button>
                {canRetryLiff && (
                  <button
                    onClick={retryLiffLogin}
                    className="w-full rounded-xl border border-[var(--separator)] px-4 py-2.5 text-[14px] font-medium text-[var(--secondary-label)] transition active:scale-[0.98]"
                  >
                    仍要在 LINE 內再試一次
                  </button>
                )}
              </div>
            ) : (
              <>
                <button
                  onClick={onJoin}
                  className="flex w-full items-center justify-center gap-2 rounded-xl bg-[#06C755] px-4 py-4 text-[17px] font-bold text-white shadow-[0_10px_24px_-10px_rgba(6,199,85,0.7)] transition active:scale-[0.98]"
                >
                  <svg viewBox="0 0 24 24" fill="currentColor" className="h-6 w-6">
                    <path d="M12 3C6.5 3 2 6.6 2 11c0 3.9 3.5 7.2 8.3 7.9.3.06.7.2.8.45.08.23.05.58.03.81l-.13.8c-.04.24-.19.93.81.51 1-.42 5.4-3.2 7.36-5.47C20.5 14.5 22 12.9 22 11c0-4.4-4.5-8-10-8Z" />
                  </svg>
                  用 LINE 快速註冊
                </button>
                {/* 缺門市時這行是「還差一步」的指示，不是註腳 —— 要看得到。
                    有門市時才降成灰字補充說明。 */}
                <p
                  className={
                    needStore
                      ? "text-center text-[13px] font-medium leading-relaxed text-[var(--brand-strong)]"
                      : "text-center text-[12px] leading-relaxed text-[var(--secondary-label)]"
                  }
                >
                  {needStore
                    ? "請先選擇取貨門市，再用 LINE 完成註冊。"
                    : "已經是會員？同一顆按鈕也會直接帶您登入。"}
                </p>
              </>
            )}

            {/* 社群來的人第一個疑慮就是「會不會被看到我的聊天紀錄」。
                先講清楚拿了什麼、沒拿什麼，轉換率差很多。 */}
            <p className="rounded-xl bg-[var(--background)] p-3 text-[12px] leading-relaxed text-[var(--secondary-label)]">
              我們只會取得您的 LINE 顯示名稱與大頭貼，用來建立會員資料。
              不會讀取您的聊天內容、好友名單，也不會代您發送任何訊息。
            </p>
          </>
        )}
      </div>

      {/* ── 賣點 ─────────────────────────────────────────────── */}
      <section className="mt-9">
        <h2 className="px-1 text-[13px] font-semibold tracking-wide text-[var(--tertiary-label)]">
          加入之後可以做什麼
        </h2>
        <div className="mt-3 space-y-3">
          {BENEFITS.map((b) => (
            <div key={b.title} className="card flex items-start gap-3 p-4">
              <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[var(--brand-soft)] text-[20px]">
                {b.emoji}
              </span>
              <div>
                <p className="text-[15px] font-semibold text-[var(--foreground)]">{b.title}</p>
                <p className="mt-0.5 text-[13px] leading-relaxed text-[var(--secondary-label)]">
                  {b.desc}
                </p>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* ── 流程 ─────────────────────────────────────────────── */}
      <section className="mt-8">
        <h2 className="px-1 text-[13px] font-semibold tracking-wide text-[var(--tertiary-label)]">
          怎麼開始
        </h2>
        <ol className="card mt-3 divide-y divide-[var(--separator)] p-1">
          {STEPS.map((step, i) => (
            <li key={step} className="flex items-center gap-3 px-4 py-3.5">
              <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full brand-gradient text-[13px] font-bold text-white">
                {i + 1}
              </span>
              <span className="text-[14px] text-[var(--foreground)]">{step}</span>
            </li>
          ))}
        </ol>
      </section>

      {/* ── 分享 ─────────────────────────────────────────────── */}
      <section className="mt-8">
        <button
          onClick={onShare}
          className="w-full rounded-xl border border-[var(--separator)] bg-[var(--card-bg)] px-4 py-3 text-[14px] font-semibold text-[var(--brand-strong)] transition active:scale-[0.98]"
        >
          {copiedLink ? "✓ 連結已複製" : "把這頁分享給朋友"}
        </button>
        {shareHint && (
          <p className="mt-2 break-all rounded-xl bg-[var(--background)] p-3 text-[12px] text-[var(--secondary-label)]">
            請長按複製此連結：{shareHint}
          </p>
        )}
      </section>

      <div className="mt-auto pt-10 text-center text-[12px] text-[var(--tertiary-label)]">
        <p className="font-medium">包子媽生鮮小舖</p>
        <p className="mt-0.5 tracking-wide">Baozi Ma Group Buying</p>
      </div>
    </main>
  );
}

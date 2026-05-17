"use client";

import { useEffect, useState } from "react";
import { LoadingScreen } from "@/components/Spinner";

type Env =
  | "loading"
  | "standalone"
  | "ios-safari"
  | "ios-line"
  | "ios-other"
  | "android-chrome"
  | "android-line"
  | "android-other"
  | "desktop";

type BeforeInstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};

function detectEnv(): Env {
  if (typeof window === "undefined") return "loading";
  const ua = navigator.userAgent;

  const isStandalone =
    (window.navigator as { standalone?: boolean }).standalone === true ||
    window.matchMedia("(display-mode: standalone)").matches;
  if (isStandalone) return "standalone";

  const isLine = /Line\//i.test(ua);
  const isIos = /iPad|iPhone|iPod/.test(ua) && !(window as { MSStream?: unknown }).MSStream;
  const isAndroid = /Android/i.test(ua);

  if (isIos) {
    if (isLine) return "ios-line";
    // iOS Chrome / FF / Edge 都是 WebKit 包皮、但都沒 PWA install
    if (/CriOS|FxiOS|EdgiOS/i.test(ua)) return "ios-other";
    return "ios-safari";
  }

  if (isAndroid) {
    if (isLine) return "android-line";
    const isChrome = /Chrome\/|CrMo\//.test(ua) && !/EdgA|SamsungBrowser|FBAN|FBAV/i.test(ua);
    if (isChrome) return "android-chrome";
    return "android-other";
  }

  return "desktop";
}

export default function InstallPage() {
  const [env, setEnv] = useState<Env>("loading");
  const [installPrompt, setInstallPrompt] = useState<BeforeInstallPromptEvent | null>(null);
  const [copyMsg, setCopyMsg] = useState<string | null>(null);
  const [pageUrl, setPageUrl] = useState("");

  useEffect(() => {
    setEnv(detectEnv());
    setPageUrl(window.location.origin + "/install");
  }, []);

  useEffect(() => {
    const handler = (e: Event) => {
      e.preventDefault();
      setInstallPrompt(e as BeforeInstallPromptEvent);
    };
    window.addEventListener("beforeinstallprompt", handler);
    return () => window.removeEventListener("beforeinstallprompt", handler);
  }, []);

  const installAndroid = async () => {
    if (!installPrompt) return;
    await installPrompt.prompt();
    await installPrompt.userChoice;
    setInstallPrompt(null);
  };

  const copyUrl = async () => {
    try {
      await navigator.clipboard.writeText(pageUrl);
      setCopyMsg("✓ 網址已複製,請用 Safari 打開貼上");
    } catch {
      setCopyMsg("無法自動複製,請手動長按網址複製");
    }
    setTimeout(() => setCopyMsg(null), 4000);
  };

  return (
    <main className="mx-auto flex min-h-[100dvh] w-full max-w-md flex-col items-center px-5 pt-10 pb-12">
      {/* 品牌 header */}
      <div className="mb-6 flex flex-col items-center gap-3">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src="/icons/ios/180.png"
          alt=""
          className="h-20 w-20 rounded-2xl shadow-md"
        />
        <h1 className="text-[26px] font-bold text-zinc-900">包子媽生鮮小舖</h1>
        <p className="text-[14px] text-zinc-500">把 App 加入你的手機,讓下單更方便</p>
      </div>

      {env === "loading" && <LoadingScreen className="py-16" />}

      {env === "standalone" && (
        <Card>
          <div className="text-center">
            <div className="text-5xl">✓</div>
            <h2 className="mt-3 text-[20px] font-bold text-zinc-900">已安裝</h2>
            <p className="mt-2 text-[15px] text-zinc-600">你已經在 PWA 裡了</p>
            <a
              href="/shop"
              className="mt-5 inline-block rounded-full bg-[#007aff] px-6 py-3 text-[16px] font-semibold text-white"
            >
              進入商店
            </a>
          </div>
        </Card>
      )}

      {/* iOS 三步圖示 — 任何 iOS 路徑都顯示,讓 LINE / Chrome 內的 user
          看完「請用 Safari 打開」之後也知道接下來要做什麼 */}
      {(env === "ios-safari" || env === "ios-line" || env === "ios-other") && (
        <IosSafariSteps />
      )}

      {(env === "ios-line" || env === "ios-other") && (
        <Card>
          <h2 className="text-[18px] font-bold text-zinc-900">請用 Safari 打開</h2>
          <p className="mt-2 text-[15px] text-zinc-600 leading-relaxed">
            iPhone 上只有 <b>Safari</b> 才能把 App 加入主畫面。
            目前的瀏覽器無法安裝。
          </p>
          <div className="mt-4 space-y-3">
            <Step n={1}>
              點下方按鈕複製網址
            </Step>
            <Step n={2}>
              {env === "ios-line"
                ? "點右上角 ⋯ → 「在 Safari 中開啟」(或長按貼到 Safari 網址列)"
                : "切到 Safari → 網址列長按 → 貼上"}
            </Step>
            <Step n={3}>
              到 Safari 後,按下方分享按鈕 → 加入主畫面
            </Step>
          </div>
          <button
            onClick={copyUrl}
            className="mt-5 w-full rounded-full bg-[#007aff] py-3 text-[16px] font-semibold text-white active:opacity-80"
          >
            複製網址
          </button>
          {copyMsg && (
            <p className="mt-2 text-center text-[13px] text-emerald-600">{copyMsg}</p>
          )}
          <p className="mt-3 break-all rounded-lg bg-zinc-100 p-3 text-center font-mono text-[12px] text-zinc-600">
            {pageUrl}
          </p>
        </Card>
      )}

      {env === "android-chrome" && (
        <Card>
          <h2 className="text-[18px] font-bold text-zinc-900">一鍵安裝</h2>
          <p className="mt-2 text-[15px] text-zinc-600">
            按下方按鈕、確認「安裝」即可加入主畫面。
          </p>
          {installPrompt ? (
            <button
              onClick={installAndroid}
              className="mt-5 w-full rounded-full bg-[#007aff] py-3.5 text-[18px] font-semibold text-white active:opacity-80"
            >
              安裝 App
            </button>
          ) : (
            <>
              <p className="mt-4 text-[14px] text-zinc-500">
                如果按鈕沒出現,請在 Chrome 右上角選單點「安裝應用程式」/「加到主畫面」。
              </p>
            </>
          )}
        </Card>
      )}

      {env === "android-line" && (
        <Card>
          <h2 className="text-[18px] font-bold text-zinc-900">請用 Chrome 打開</h2>
          <p className="mt-2 text-[15px] text-zinc-600">
            LINE 內建瀏覽器無法安裝 App。請改用 Chrome:
          </p>
          <div className="mt-4 space-y-3">
            <Step n={1}>點 LINE 視窗右上角 ⋯ → 「在其他應用程式中打開」→ 選 Chrome</Step>
            <Step n={2}>進入 Chrome 後,看到「安裝 App」按鈕點下去</Step>
          </div>
          <button
            onClick={copyUrl}
            className="mt-5 w-full rounded-full bg-[#7676801f] py-3 text-[15px] font-medium text-zinc-700"
          >
            或複製網址
          </button>
          {copyMsg && (
            <p className="mt-2 text-center text-[13px] text-emerald-600">{copyMsg}</p>
          )}
        </Card>
      )}

      {env === "android-other" && (
        <Card>
          <h2 className="text-[18px] font-bold text-zinc-900">手動安裝</h2>
          <p className="mt-2 text-[15px] text-zinc-600 leading-relaxed">
            在你的瀏覽器選單裡找「加入主畫面」或「安裝應用程式」。
          </p>
          <p className="mt-3 text-[13px] text-zinc-500">
            建議改用 <b>Chrome</b> 取得一鍵安裝。
          </p>
        </Card>
      )}

      {env === "desktop" && (
        <Card>
          <h2 className="text-[18px] font-bold text-zinc-900">用手機掃 QR 安裝</h2>
          <p className="mt-2 text-[15px] text-zinc-600">
            這個 App 是給手機用的。請用手機相機掃下方 QR 碼:
          </p>
          {pageUrl && (
            <div className="mt-4 flex justify-center">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={`https://api.qrserver.com/v1/create-qr-code/?size=320x320&data=${encodeURIComponent(pageUrl)}&format=png&margin=10`}
                alt="QR code"
                width={320}
                height={320}
                className="rounded-2xl border border-zinc-200"
              />
            </div>
          )}
          <p className="mt-3 break-all rounded-lg bg-zinc-100 p-3 text-center font-mono text-[12px] text-zinc-600">
            {pageUrl}
          </p>
        </Card>
      )}

      {/* 桌機也讓你看一眼 iPhone 安裝步驟 — 方便預覽 / 截圖貼海報 */}
      {env === "desktop" && <IosSafariSteps />}
    </main>
  );
}

function Card({ children }: { children: React.ReactNode }) {
  return (
    <div className="w-full rounded-2xl bg-white p-5 shadow-[0_2px_8px_rgba(0,0,0,0.06)]">
      {children}
    </div>
  );
}

function Step({ n, children }: { n: number; children: React.ReactNode }) {
  return (
    <div className="flex gap-3">
      <div className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full bg-[#007aff] text-[14px] font-bold text-white">
        {n}
      </div>
      <div className="flex-1 pt-0.5 text-[15px] leading-relaxed text-zinc-700">{children}</div>
    </div>
  );
}

/** iOS Safari 加入主畫面圖示教學 */
function IosSafariSteps() {
  return (
    <Card>
      <h2 className="text-[18px] font-bold text-zinc-900">把 App 加到主畫面</h2>
      <p className="mt-1 text-[14px] text-zinc-500">三步驟、約 10 秒鐘。</p>

      <div className="mt-5 space-y-6">
        <StepIllustration
          n={1}
          title="點下方分享按鈕"
          hint="iPhone Safari 螢幕底部那個"
        >
          <PhoneStep1 />
        </StepIllustration>

        <StepIllustration
          n={2}
          title="找「加入主畫面」"
          hint="出現選單後往下捲動"
        >
          <PhoneStep2 />
        </StepIllustration>

        <StepIllustration
          n={3}
          title="完成！從桌面圖示開"
          hint="從現在起點包子媽圖示就能下單"
        >
          <PhoneStep3 />
        </StepIllustration>
      </div>
    </Card>
  );
}

function StepIllustration({
  n,
  title,
  hint,
  children,
}: {
  n: number;
  title: string;
  hint: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-start gap-4">
      <div className="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-full bg-[#007aff] text-[15px] font-bold text-white">
        {n}
      </div>
      <div className="flex-1">
        <div className="text-[16px] font-medium text-zinc-900">{title}</div>
        <p className="mt-0.5 text-[13px] text-zinc-500">{hint}</p>
      </div>
      <div className="flex-shrink-0">{children}</div>
    </div>
  );
}

/** Phone 外殼 — 共用框 */
function PhoneShell({ children }: { children: React.ReactNode }) {
  return (
    <svg viewBox="0 0 110 200" className="h-[140px] w-[78px]">
      {/* bezel */}
      <rect x="0.5" y="0.5" width="109" height="199" rx="14" fill="#1c1c1e" />
      <rect x="3" y="3" width="104" height="194" rx="11" fill="#ffffff" />
      {/* notch */}
      <rect x="42" y="3" width="26" height="6" rx="3" fill="#1c1c1e" />
      {children}
    </svg>
  );
}

/** Step 1: Safari 畫面 + 高亮分享按鈕 */
function PhoneStep1() {
  return (
    <PhoneShell>
      {/* 網址列 */}
      <rect x="10" y="14" width="90" height="10" rx="3" fill="#f2f2f7" />
      <rect x="14" y="17" width="60" height="4" rx="1" fill="#c6c6c8" />
      {/* 內容 — 用品牌色塊 + 標題佔位 */}
      <rect x="10" y="30" width="90" height="50" rx="6" fill="#ec6b8c" opacity="0.18" />
      <circle cx="55" cy="55" r="14" fill="#c44464" opacity="0.85" />
      <rect x="20" y="86" width="70" height="4" rx="1" fill="#c6c6c8" />
      <rect x="28" y="94" width="54" height="3" rx="1" fill="#d8d8da" />
      {/* Safari toolbar */}
      <rect x="3" y="170" width="104" height="27" fill="#f7f7f8" />
      <line x1="3" y1="170" x2="107" y2="170" stroke="#d8d8da" strokeWidth="0.5" />
      {/* 4 顆 icon */}
      <g fill="none" stroke="#8e8e93" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M16 178 L20 184 L16 190" />
        <path d="M36 184 L40 178 L40 190 L32 190 Z" />
        {/* Share - highlight */}
        <g stroke="#007aff" strokeWidth="1.6">
          <rect x="50" y="178" width="14" height="14" rx="6" fill="#007aff" fillOpacity="0.12" />
          <path d="M57 181 L57 189" />
          <path d="M53 184 L57 180 L61 184" />
        </g>
        <rect x="74" y="178" width="10" height="14" rx="1" />
        <circle cx="94" cy="184" r="4" />
      </g>
      {/* 箭頭指向分享 */}
      <g fill="#c44464">
        <path d="M77 184 L66 184 L70 180 M66 184 L70 188" stroke="#c44464" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
      </g>
    </PhoneShell>
  );
}

/** Step 2: 分享 sheet + 加入主畫面 highlight */
function PhoneStep2() {
  return (
    <PhoneShell>
      {/* 後方頁面變淡 */}
      <rect x="3" y="3" width="104" height="194" rx="11" fill="#000" opacity="0.18" />
      {/* sheet */}
      <rect x="6" y="60" width="98" height="138" rx="9" fill="#ffffff" />
      {/* drag handle */}
      <rect x="48" y="65" width="14" height="2" rx="1" fill="#d8d8da" />
      {/* 第一排 app icons */}
      <g>
        <rect x="14" y="76" width="20" height="20" rx="4" fill="#06c755" opacity="0.85" />
        <rect x="40" y="76" width="20" height="20" rx="4" fill="#3b5998" opacity="0.85" />
        <rect x="66" y="76" width="20" height="20" rx="4" fill="#1d9bf0" opacity="0.85" />
        <rect x="92" y="76" width="14" height="20" rx="4" fill="#ec6b8c" opacity="0.85" />
      </g>
      <line x1="10" y1="106" x2="100" y2="106" stroke="#e5e5ea" strokeWidth="0.5" />
      {/* action 列表 */}
      <g fill="#1c1c1e">
        <rect x="14" y="112" width="48" height="3" rx="1" />
        <rect x="14" y="124" width="40" height="3" rx="1" />
        <rect x="14" y="136" width="56" height="3" rx="1" />
      </g>
      {/* Add to Home Screen — highlight */}
      <rect x="6" y="146" width="98" height="14" fill="#007aff" fillOpacity="0.1" />
      <rect x="14" y="151" width="55" height="4" rx="1" fill="#1c1c1e" />
      <g stroke="#1c1c1e" strokeWidth="1" fill="none" strokeLinecap="round">
        <rect x="92" y="149" width="8" height="8" rx="1.5" />
        <path d="M96 151 L96 155 M94 153 L98 153" />
      </g>
      {/* 箭頭 */}
      <g stroke="#c44464" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round">
        <path d="M2 153 L9 153 M6 150 L9 153 L6 156" />
      </g>
      <g fill="#1c1c1e">
        <rect x="14" y="170" width="36" height="3" rx="1" />
      </g>
    </PhoneShell>
  );
}

/** Step 3: 桌面圖示 + 包子媽 icon 高亮 */
function PhoneStep3() {
  return (
    <PhoneShell>
      {/* 漸層底 */}
      <defs>
        <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#fde2e9" />
          <stop offset="100%" stopColor="#fce8d6" />
        </linearGradient>
      </defs>
      <rect x="3" y="3" width="104" height="194" rx="11" fill="url(#sky)" />
      {/* 時間 */}
      <text x="55" y="30" textAnchor="middle" fontSize="12" fontWeight="700" fill="#1c1c1e">9:41</text>
      {/* 第一排 app — 普通 */}
      <g>
        <rect x="14" y="55" width="16" height="16" rx="4" fill="#fff" stroke="#0001" strokeWidth="0.5" />
        <rect x="36" y="55" width="16" height="16" rx="4" fill="#fff" stroke="#0001" strokeWidth="0.5" />
        <rect x="58" y="55" width="16" height="16" rx="4" fill="#fff" stroke="#0001" strokeWidth="0.5" />
        <rect x="80" y="55" width="16" height="16" rx="4" fill="#fff" stroke="#0001" strokeWidth="0.5" />
      </g>
      {/* 第二排 — 包子媽 icon highlight */}
      <g>
        <rect x="14" y="83" width="16" height="16" rx="4" fill="#fff" stroke="#0001" strokeWidth="0.5" />
        {/* Real logo embed */}
        <image
          href="/icons/ios/180.png"
          x="35"
          y="80"
          width="22"
          height="22"
          clipPath="inset(0 round 5)"
        />
        {/* 高亮環 */}
        <rect x="33" y="78" width="26" height="26" rx="6" fill="none" stroke="#c44464" strokeWidth="1.4" strokeDasharray="3 2" />
        <rect x="62" y="83" width="16" height="16" rx="4" fill="#fff" stroke="#0001" strokeWidth="0.5" />
        <rect x="84" y="83" width="16" height="16" rx="4" fill="#fff" stroke="#0001" strokeWidth="0.5" />
      </g>
      {/* 包子媽 label */}
      <text x="46" y="111" textAnchor="middle" fontSize="5.5" fill="#1c1c1e" fontWeight="600">包子媽</text>
      {/* 第三排 + 第四排 */}
      <g>
        <rect x="14" y="118" width="16" height="16" rx="4" fill="#fff" opacity="0.7" />
        <rect x="36" y="118" width="16" height="16" rx="4" fill="#fff" opacity="0.7" />
        <rect x="58" y="118" width="16" height="16" rx="4" fill="#fff" opacity="0.7" />
        <rect x="80" y="118" width="16" height="16" rx="4" fill="#fff" opacity="0.7" />
      </g>
      {/* dock */}
      <rect x="10" y="167" width="90" height="22" rx="8" fill="#ffffff" opacity="0.55" />
      <g>
        <rect x="18" y="172" width="14" height="14" rx="3.5" fill="#fff" />
        <rect x="36" y="172" width="14" height="14" rx="3.5" fill="#fff" />
        <rect x="54" y="172" width="14" height="14" rx="3.5" fill="#fff" />
        <rect x="72" y="172" width="14" height="14" rx="3.5" fill="#fff" />
      </g>
    </PhoneShell>
  );
}

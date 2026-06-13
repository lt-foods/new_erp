// 推廣頁（landing page）— 試用租戶註冊的對外入口。
//
// 設計取向（2026-06-13）：版型與文字主導，攝影退為「安靜襯底」——
// 一律去飽和 + 降透明 + 覆蓋層淡出，不做花俏大圖、不堆 icon。
// 圖片來源見 public/landing/CREDITS.md（Unsplash License，商用免標註）。
// 色彩以墨黑/中性為主，輔以克制的橘色當品牌點綴。

import Link from "next/link";
import { withBasePath } from "@/lib/basePath";

export const metadata = {
  title: "Gruppo 購寶｜社區團購的進銷存後台 — 開團、採購、庫存、對帳一站搞定，免費試用 14 天",
  description:
    "整單只是開始。採購進貨、總倉門市庫存、撿貨派貨、會員錢包、月結對帳 — 為社區團購與生鮮小舖打造的 ERP。免費試用 14 天，免信用卡。",
};

// 安靜襯底：去飽和 + 微降透明，讓照片退到文字後面
const MUTED: React.CSSProperties = { filter: "grayscale(0.35) saturate(0.85)", opacity: 0.92 };

const CAPABILITIES: {
  kicker: string;
  title: string;
  desc: string;
  points: string[];
  img: string;
  alt: string;
}[] = [
  {
    kicker: "開團 → 採購",
    title: "收完單，採購單自己長出來",
    desc: "LINE、社團的訂單自動彙總，依供應商拆成請購、採購，跟單不再靠手抄 Excel 對到半夜。",
    points: ["訂單自動整併成請購單", "一鍵轉採購、追到貨", "缺貨短少回頭追到每一張單"],
    img: "/landing/produce.jpg",
    alt: "生鮮蔬果陳列",
  },
  {
    kicker: "庫存 → 多店",
    title: "總倉到門市，一條庫存看到底",
    desc: "總倉進貨、門市調撥、盤點、安全庫存補貨，帳和實貨對得起來；加盟店各看各的，不打架。",
    points: ["總倉與門市即時庫存", "調撥、盤點、自動補貨", "多店分權，加盟店只看自己"],
    img: "/landing/aisle.jpg",
    alt: "賣場通道貨架",
  },
  {
    kicker: "會員 → 對帳",
    title: "錢和會員，每一筆都收得回來",
    desc: "會員錢包、點數、分級價養回購；應收應付、門市月結、零用金，月底結帳不再用猜的。",
    points: ["LINE 會員、錢包、點數", "應收應付與門市月結", "經營成效一頁看懂"],
    img: "/landing/dashboard.jpg",
    alt: "經營數據儀表板",
  },
];

const TRIAL_POINTS: { title: string; desc: string }[] = [
  { title: "14 天全功能", desc: "試用期內功能不設限，用真實流程跑一輪再決定。" },
  { title: "免信用卡", desc: "填商家名稱和 Email 就能開始，不收任何付款資訊。" },
  { title: "到期資料保留", desc: "試用到期只是暫停操作，資料原封不動，開通後接著用。" },
  { title: "隨時一鍵刪除", desc: "不合用？一鍵永久刪除全部資料與帳號，不留痕跡。" },
];

const PLANS: { name: string; price: string; note: string; points: string[]; highlight: boolean }[] = [
  {
    name: "免費試用",
    price: "NT$0",
    note: "14 天",
    points: ["全功能不設限", "免信用卡", "到期資料保留", "隨時一鍵刪除"],
    highlight: false,
  },
  {
    name: "正式方案",
    price: "NT$999",
    note: "／月・年繳 NT$799／月",
    points: ["訂單數量與金額不限", "開團、採購、庫存、財務全模組", "一個總倉＋門市", "Email 支援"],
    highlight: true,
  },
  {
    name: "多店／加盟",
    price: "專人報價",
    note: "依店數規模",
    points: ["多門市與調撥", "加盟店分權與月結", "員工角色權限", "專人導入協助"],
    highlight: false,
  },
];

const FAQS: { q: string; a: string }[] = [
  {
    q: "跟其他「+1 整單」工具有什麼不同？",
    a: "整單工具幫你收單，收完之後呢？採購下給誰、貨進哪個倉、怎麼撿怎麼派、月底跟門市怎麼結 — 這套系統管的是收單之後的整條流程。",
  },
  {
    q: "我只有一家店（或只有我自己），適合嗎？",
    a: "適合。一人團主就用總倉＋一家示範門市跑全流程；之後展店，加門市、開帳號、分權限就好，不用換系統。",
  },
  {
    q: "試用到期資料會怎樣？",
    a: "資料原封保留、只是暫停操作。想繼續就聯絡我們開通；不想用，後台一鍵永久刪除全部資料與帳號。",
  },
  {
    q: "需要綁信用卡或簽約嗎？",
    a: "都不用。Email 驗證完就能用，到期前我們不會收你任何付款資訊。",
  },
];

function Check() {
  return (
    <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth={2} className="mt-0.5 h-4 w-4 shrink-0 text-orange-600 dark:text-orange-500" aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="m4 10.5 3.5 3.5L16 6" />
    </svg>
  );
}

function PrimaryCta({ children }: { children: React.ReactNode }) {
  return (
    <Link
      href="/signup"
      className="inline-flex items-center justify-center rounded-md bg-orange-600 px-6 py-3 text-base font-medium text-white transition hover:bg-orange-700"
    >
      {children}
    </Link>
  );
}

export default function WelcomePage() {
  return (
    <div className="flex flex-1 flex-col bg-white text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
      {/* Header */}
      <header className="sticky top-0 z-20 border-b border-zinc-200/70 bg-white/85 backdrop-blur dark:border-zinc-800/70 dark:bg-zinc-950/85">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-3.5">
          <div className="flex items-baseline gap-1.5">
            <span className="flex items-center gap-2 text-[17px] font-bold tracking-tight">
              <span className="inline-block h-4 w-4 translate-y-0.5 rounded-[5px] bg-orange-600" />
              Gruppo
            </span>
            <span className="text-sm font-medium text-zinc-400 dark:text-zinc-500">購寶</span>
          </div>
          <nav className="flex items-center gap-2 text-sm">
            <Link
              href="/login"
              className="rounded-md px-3 py-1.5 text-zinc-600 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-900"
            >
              登入
            </Link>
            <Link
              href="/signup"
              className="rounded-md bg-zinc-900 px-3 py-1.5 font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
            >
              免費試用
            </Link>
          </nav>
        </div>
      </header>

      {/* Hero — 文字主導，照片淡出於下緣 */}
      <section className="relative overflow-hidden border-b border-zinc-200 dark:border-zinc-800">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={withBasePath("/landing/hero.jpg")}
          alt=""
          aria-hidden
          style={MUTED}
          className="pointer-events-none absolute inset-x-0 bottom-0 h-[55%] w-full object-cover"
        />
        <div className="pointer-events-none absolute inset-0 bg-gradient-to-b from-white via-white/92 to-white/70 dark:from-zinc-950 dark:via-zinc-950/92 dark:to-zinc-950/70" />
        <div className="relative mx-auto max-w-5xl px-6 pb-28 pt-20 sm:pb-40 sm:pt-28">
          <p className="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600 dark:text-orange-500">
            社區團購・生鮮小舖 ERP
          </p>
          <h1 className="mt-4 max-w-2xl text-4xl font-bold leading-[1.15] tracking-tight sm:text-6xl">
            整單只是開始，
            <br />
            後面的進銷存交給系統
          </h1>
          <p className="mt-5 max-w-xl text-base text-zinc-600 sm:text-lg dark:text-zinc-300">
            採購進貨、總倉門市庫存、撿貨派貨、會員錢包、月結對帳 —
            為社區團購打造的一站式後台，告別 Excel 和手抄帳。
          </p>
          <div className="mt-8 flex flex-col items-start gap-3 sm:flex-row sm:items-center">
            <PrimaryCta>免費試用 14 天</PrimaryCta>
            <span className="text-xs text-zinc-500">免信用卡・3 分鐘開好後台</span>
          </div>
        </div>
      </section>

      {/* 定位：整單工具 vs. 我們 */}
      <section className="mx-auto max-w-5xl px-6 py-20">
        <div className="grid gap-10 sm:grid-cols-2 sm:gap-16">
          <div>
            <h2 className="text-sm font-semibold uppercase tracking-wider text-zinc-400">
              「+1 整單」到這裡就停了
            </h2>
            <p className="mt-3 text-lg leading-relaxed text-zinc-500 dark:text-zinc-400">
              收單、成團、通知 — 然後呢？採購、進貨、庫存、撿貨、對帳，
              一樣樣回到你的 Excel 和記憶力。
            </p>
          </div>
          <div>
            <h2 className="text-sm font-semibold uppercase tracking-wider text-orange-600 dark:text-orange-500">
              我們從這裡開始
            </h2>
            <p className="mt-3 text-lg leading-relaxed text-zinc-800 dark:text-zinc-200">
              把收單之後的進、銷、存、財整條接起來，
              從一人團主到多店加盟，同一套系統長大。
            </p>
          </div>
        </div>
      </section>

      {/* 能力：左右交錯圖文，照片安靜襯底 */}
      <section className="border-t border-zinc-200 dark:border-zinc-800">
        <div className="mx-auto max-w-5xl divide-y divide-zinc-200 px-6 dark:divide-zinc-800">
          {CAPABILITIES.map((c, i) => (
            <div
              key={c.title}
              className="grid items-center gap-8 py-16 sm:grid-cols-2 sm:gap-14"
            >
              <div className={i % 2 === 1 ? "sm:order-2" : ""}>
                <p className="text-xs font-semibold uppercase tracking-[0.18em] text-orange-600 dark:text-orange-500">
                  {c.kicker}
                </p>
                <h3 className="mt-3 text-2xl font-semibold tracking-tight sm:text-3xl">{c.title}</h3>
                <p className="mt-3 text-zinc-600 dark:text-zinc-400">{c.desc}</p>
                <ul className="mt-5 space-y-2.5">
                  {c.points.map((p) => (
                    <li key={p} className="flex gap-2.5 text-sm text-zinc-700 dark:text-zinc-300">
                      <Check />
                      {p}
                    </li>
                  ))}
                </ul>
              </div>
              <div className={i % 2 === 1 ? "sm:order-1" : ""}>
                <div className="relative overflow-hidden rounded-xl ring-1 ring-zinc-200 dark:ring-zinc-800">
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img
                    src={withBasePath(c.img)}
                    alt={c.alt}
                    loading="lazy"
                    style={MUTED}
                    className="aspect-[4/3] w-full object-cover"
                  />
                  <div className="pointer-events-none absolute inset-0 bg-zinc-900/[0.04] dark:bg-zinc-950/25" />
                </div>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* 試用承諾 */}
      <section className="border-t border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900/40">
        <div className="mx-auto max-w-5xl px-6 py-20">
          <h2 className="text-2xl font-semibold tracking-tight">試用，沒有套路</h2>
          <div className="mt-10 grid gap-x-10 gap-y-8 sm:grid-cols-2">
            {TRIAL_POINTS.map((p) => (
              <div key={p.title} className="flex gap-3 border-t border-zinc-200 pt-5 dark:border-zinc-800">
                <Check />
                <div>
                  <h3 className="font-semibold">{p.title}</h3>
                  <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{p.desc}</p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* 定價 */}
      <section className="mx-auto max-w-5xl px-6 py-20">
        <div className="flex flex-col items-baseline justify-between gap-2 sm:flex-row">
          <h2 className="text-2xl font-semibold tracking-tight">定價，攤開來講</h2>
          <p className="text-sm text-zinc-500">試用到期由專人開通，不會自動扣款。</p>
        </div>
        <div className="mt-10 grid gap-6 sm:grid-cols-3">
          {PLANS.map((p) => (
            <div
              key={p.name}
              className={
                p.highlight
                  ? "rounded-xl border-2 border-orange-600 bg-white p-6 dark:bg-zinc-900"
                  : "rounded-xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900"
              }
            >
              <div className="flex items-center justify-between">
                <h3 className="font-semibold">{p.name}</h3>
                {p.highlight && (
                  <span className="rounded-full bg-orange-600/10 px-2 py-0.5 text-[11px] font-medium text-orange-600 dark:text-orange-400">
                    最多人選
                  </span>
                )}
              </div>
              <div className="mt-3">
                <span className="text-2xl font-bold tracking-tight">{p.price}</span>
                <span className="ml-1 text-xs text-zinc-500">{p.note}</span>
              </div>
              <ul className="mt-5 space-y-2.5">
                {p.points.map((pt) => (
                  <li key={pt} className="flex gap-2.5 text-sm text-zinc-600 dark:text-zinc-400">
                    <Check />
                    {pt}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </section>

      {/* FAQ */}
      <section className="border-t border-zinc-200 dark:border-zinc-800">
        <div className="mx-auto max-w-3xl px-6 py-20">
          <h2 className="text-2xl font-semibold tracking-tight">常見問題</h2>
          <div className="mt-10 divide-y divide-zinc-200 dark:divide-zinc-800">
            {FAQS.map((f) => (
              <div key={f.q} className="py-6">
                <h3 className="font-semibold">{f.q}</h3>
                <p className="mt-2 text-sm leading-relaxed text-zinc-600 dark:text-zinc-400">{f.a}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* 收尾 CTA — 照片重度淡化為襯底 */}
      <section className="relative overflow-hidden border-t border-zinc-200 dark:border-zinc-800">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={withBasePath("/landing/closing.jpg")}
          alt=""
          aria-hidden
          style={{ filter: "grayscale(0.5) saturate(0.7)", opacity: 0.5 }}
          className="pointer-events-none absolute inset-0 h-full w-full object-cover"
        />
        <div className="pointer-events-none absolute inset-0 bg-white/82 dark:bg-zinc-950/85" />
        <div className="relative mx-auto max-w-5xl px-6 py-24 text-center">
          <h2 className="text-3xl font-bold tracking-tight sm:text-4xl">下一團，用系統開</h2>
          <p className="mx-auto mt-3 max-w-md text-zinc-600 dark:text-zinc-300">
            3 分鐘開好你的後台，14 天免費把整條流程跑過一遍。
          </p>
          <div className="mt-8">
            <PrimaryCta>免費試用 14 天</PrimaryCta>
          </div>
          <p className="mt-4 text-xs text-zinc-500">
            已經有帳號？{" "}
            <Link href="/login" className="underline hover:text-zinc-700 dark:hover:text-zinc-300">
              前往登入
            </Link>
          </p>
        </div>
      </section>

      <footer className="border-t border-zinc-200 px-6 py-8 dark:border-zinc-800">
        <div className="mx-auto flex max-w-5xl flex-col items-center justify-between gap-2 text-xs text-zinc-400 sm:flex-row">
          <div className="flex items-center gap-1.5 font-semibold text-zinc-500 dark:text-zinc-400">
            <span className="inline-block h-3 w-3 rounded-[4px] bg-orange-600" />
            Gruppo <span className="font-medium text-zinc-400">購寶</span>
          </div>
          <span>試用期滿資料保留、可隨時一鍵刪除；詳見註冊頁說明。</span>
        </div>
      </footer>
    </div>
  );
}

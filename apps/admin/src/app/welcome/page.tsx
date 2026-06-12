// 推廣頁（landing page）— 試用租戶註冊的對外入口（SaaS 化）
// 純靜態公開頁。結構參考競品分析（樂樂團購 / 飛比+1 / EasyStore LINE 訂單，
// 2026-06-12）：痛點開場 → 差異化定位 → 功能 → 3 步驟 → 試用承諾 → FAQ → CTA。
// 定位：競品都聚焦「收單整單」，我們主打「收單之後的進銷存財」。
// 對外宣傳統一導到 /welcome；root `/` 仍是登入後 dashboard。

import Link from "next/link";

export const metadata = {
  title: "團購生意的進銷存後台｜開團、採購、庫存、對帳一站搞定，免費試用 14 天",
  description:
    "整單只是開始。採購進貨、總倉門市庫存、撿貨派貨、會員錢包、月結對帳 — 為社區團購打造的 ERP。免費試用 14 天，免信用卡。",
};

const PAINS: { title: string; desc: string }[] = [
  {
    title: "對帳對到半夜",
    desc: "訂單在 LINE、帳在 Excel、錢在心裡，每次結團都像期末考。",
  },
  {
    title: "到貨日大塞車",
    desc: "誰訂了什麼、撿了沒、派去哪家店，全靠紙條和記憶力。",
  },
  {
    title: "庫存是一筆糊塗帳",
    desc: "總倉多少、門市多少、退貨去哪了，沒人說得準。",
  },
  {
    title: "店越開越多，帳越來越亂",
    desc: "加盟店的貨、錢、權限混在一起，出錯找不到人。",
  },
];

const FEATURES: { icon: string; title: string; desc: string }[] = [
  {
    icon: "🛒",
    title: "開團到採購一條龍",
    desc: "開團收單自動彙總成請購單、採購單，跟單不再靠手抄 Excel。",
  },
  {
    icon: "📦",
    title: "撿貨派貨、到店取貨",
    desc: "撿貨清單、派貨工作台、取貨核銷，缺貨短少自動追蹤到單。",
  },
  {
    icon: "🏪",
    title: "總倉與多店庫存",
    desc: "總倉進貨、門市調撥、盤點、安全庫存補貨，帳實一致。",
  },
  {
    icon: "💚",
    title: "會員經營",
    desc: "LINE 會員綁定、儲值錢包、點數回饋、會員分級價，回購靠系統養。",
  },
  {
    icon: "🧾",
    title: "財務不掉鏈",
    desc: "應收應付、門市月結、零用金，每一筆錢對得起來。",
  },
  {
    icon: "👥",
    title: "多店與權限",
    desc: "總部、店長、店員角色分權，加盟店只看自己的資料。",
  },
];

const STEPS: { step: string; title: string; desc: string }[] = [
  {
    step: "1",
    title: "填商家名稱和 Email",
    desc: "3 分鐘開好你的專屬後台，不用裝任何東西。",
  },
  {
    step: "2",
    title: "收信完成驗證",
    desc: "登入就有總倉和示範門市，照著真實流程跑一輪。",
  },
  {
    step: "3",
    title: "開你的第一團",
    desc: "從開團、採購到取貨對帳，試用期內功能不設限。",
  },
];

const TRIAL_POINTS: { title: string; desc: string }[] = [
  {
    title: "14 天全功能",
    desc: "試用期內功能不設限，用真實流程跑一輪再決定。",
  },
  {
    title: "免信用卡",
    desc: "填商家名稱和 Email 就能開始，不收任何付款資訊。",
  },
  {
    title: "到期資料保留",
    desc: "試用到期只是暫停操作，資料原封不動，開通後接著用。",
  },
  {
    title: "隨時一鍵刪除",
    desc: "不合用？一鍵永久刪除你的全部資料與帳號，不留痕跡。",
  },
];

const FAQS: { q: string; a: string }[] = [
  {
    q: "跟其他「+1 整單」工具有什麼不同？",
    a: "整單工具幫你收單，收完之後呢？採購要下給誰、貨進到哪個倉、怎麼撿怎麼派、月底跟門市怎麼結 — 這套系統管的是收單之後的整條流程。",
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

function CtaButton({ children }: { children: React.ReactNode }) {
  return (
    <Link
      href="/signup"
      className="inline-block rounded-md bg-zinc-900 px-6 py-3 text-base font-medium text-white transition hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
    >
      {children}
    </Link>
  );
}

export default function WelcomePage() {
  return (
    <div className="flex flex-1 flex-col bg-white text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
      {/* Header */}
      <header className="flex items-center justify-between border-b border-zinc-200 px-6 py-4 dark:border-zinc-800">
        <div className="text-lg font-semibold tracking-tight">團購生意管理後台</div>
        <nav className="flex items-center gap-3 text-sm">
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
      </header>

      {/* Hero */}
      <section className="mx-auto w-full max-w-3xl px-6 py-16 text-center sm:py-24">
        <h1 className="text-3xl font-bold leading-tight tracking-tight sm:text-5xl">
          整單只是開始，
          <br />
          之後的事這套系統替你扛
        </h1>
        <p className="mx-auto mt-4 max-w-xl text-base text-zinc-600 sm:text-lg dark:text-zinc-400">
          採購進貨、總倉門市庫存、撿貨派貨、會員錢包、月結對帳 —
          為社區團購與生鮮小舖打造的進銷存後台，告別 Excel 和手抄帳。
        </p>
        <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <CtaButton>免費試用 14 天</CtaButton>
          <span className="text-xs text-zinc-500">免信用卡・3 分鐘開好後台</span>
        </div>
      </section>

      {/* Pain points */}
      <section className="border-t border-zinc-200 bg-zinc-50 px-6 py-16 dark:border-zinc-800 dark:bg-zinc-900/50">
        <div className="mx-auto max-w-4xl">
          <h2 className="text-center text-2xl font-semibold">這些場景，你一定不陌生</h2>
          <div className="mt-10 grid gap-6 sm:grid-cols-2">
            {PAINS.map((p) => (
              <div
                key={p.title}
                className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900"
              >
                <h3 className="font-semibold">😵 {p.title}</h3>
                <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{p.desc}</p>
              </div>
            ))}
          </div>
          <p className="mt-8 text-center text-sm text-zinc-600 dark:text-zinc-400">
            「+1 整單」工具收完單就下班了 — 真正累人的，是收單之後的進、銷、存、財。
          </p>
        </div>
      </section>

      {/* Features */}
      <section className="px-6 py-16">
        <div className="mx-auto max-w-4xl">
          <h2 className="text-center text-2xl font-semibold">生意每個環節，都有人接住</h2>
          <div className="mt-10 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
            {FEATURES.map((f) => (
              <div
                key={f.title}
                className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900"
              >
                <div className="text-2xl">{f.icon}</div>
                <h3 className="mt-2 font-semibold">{f.title}</h3>
                <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{f.desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* 3 steps */}
      <section className="border-t border-zinc-200 bg-zinc-50 px-6 py-16 dark:border-zinc-800 dark:bg-zinc-900/50">
        <div className="mx-auto max-w-4xl">
          <h2 className="text-center text-2xl font-semibold">三步驟，今天就開始</h2>
          <div className="mt-10 grid gap-6 sm:grid-cols-3">
            {STEPS.map((s) => (
              <div key={s.step} className="text-center">
                <div className="mx-auto flex h-10 w-10 items-center justify-center rounded-full bg-zinc-900 text-lg font-bold text-white dark:bg-zinc-50 dark:text-zinc-900">
                  {s.step}
                </div>
                <h3 className="mt-3 font-semibold">{s.title}</h3>
                <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{s.desc}</p>
              </div>
            ))}
          </div>
          <div className="mt-10 text-center">
            <CtaButton>免費試用 14 天</CtaButton>
          </div>
        </div>
      </section>

      {/* Trial points */}
      <section className="px-6 py-16">
        <div className="mx-auto max-w-4xl">
          <h2 className="text-center text-2xl font-semibold">試用，沒有套路</h2>
          <div className="mt-10 grid gap-6 sm:grid-cols-2">
            {TRIAL_POINTS.map((p) => (
              <div key={p.title} className="flex gap-3">
                <span className="mt-0.5 text-green-600 dark:text-green-400">✓</span>
                <div>
                  <h3 className="font-semibold">{p.title}</h3>
                  <p className="mt-0.5 text-sm text-zinc-600 dark:text-zinc-400">{p.desc}</p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* FAQ */}
      <section className="border-t border-zinc-200 bg-zinc-50 px-6 py-16 dark:border-zinc-800 dark:bg-zinc-900/50">
        <div className="mx-auto max-w-3xl">
          <h2 className="text-center text-2xl font-semibold">常見問題</h2>
          <div className="mt-10 space-y-6">
            {FAQS.map((f) => (
              <div key={f.q}>
                <h3 className="font-semibold">{f.q}</h3>
                <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{f.a}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Bottom CTA */}
      <section className="border-t border-zinc-200 px-6 py-16 text-center dark:border-zinc-800">
        <h2 className="text-2xl font-semibold">下一團，用系統開</h2>
        <div className="mt-6">
          <CtaButton>免費試用 14 天</CtaButton>
        </div>
        <p className="mt-3 text-xs text-zinc-500">
          已經有帳號？{" "}
          <Link href="/login" className="underline hover:text-zinc-700 dark:hover:text-zinc-300">
            前往登入
          </Link>
        </p>
      </section>

      <footer className="border-t border-zinc-200 px-6 py-6 text-center text-xs text-zinc-400 dark:border-zinc-800">
        試用期滿資料保留、可隨時一鍵刪除；詳見註冊頁說明。
      </footer>
    </div>
  );
}

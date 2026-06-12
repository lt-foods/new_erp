// 推廣頁（landing page）— 試用租戶註冊的對外入口（SaaS 化）
// 純靜態公開頁：Hero + 功能亮點（對齊實際模組）+ 試用說明 + CTA。
// 對外宣傳統一導到 /welcome；root `/` 仍是登入後 dashboard。

import Link from "next/link";

export const metadata = {
  title: "社區團購生意的一站式管理後台｜免費試用 14 天",
  description:
    "開團、採購、撿貨派貨、到店取貨、會員錢包點數、多店管理 — 一套後台搞定。免費試用 14 天，免信用卡。",
};

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
          開團、跟單、取貨、對帳
          <br />
          一套後台搞定
        </h1>
        <p className="mx-auto mt-4 max-w-xl text-base text-zinc-600 sm:text-lg dark:text-zinc-400">
          為社區團購與生鮮小舖打造的 ERP：從開團收單到採購進貨、
          撿貨派貨、會員錢包，告別 Excel 和手抄帳。
        </p>
        <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <Link
            href="/signup"
            className="w-full rounded-md bg-zinc-900 px-6 py-3 text-base font-medium text-white transition hover:bg-zinc-800 sm:w-auto dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            免費試用 14 天
          </Link>
          <span className="text-xs text-zinc-500">免信用卡・3 分鐘開好後台</span>
        </div>
      </section>

      {/* Features */}
      <section className="border-t border-zinc-200 bg-zinc-50 px-6 py-16 dark:border-zinc-800 dark:bg-zinc-900/50">
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

      {/* Bottom CTA */}
      <section className="border-t border-zinc-200 px-6 py-16 text-center dark:border-zinc-800">
        <h2 className="text-2xl font-semibold">下一團，用系統開</h2>
        <Link
          href="/signup"
          className="mt-6 inline-block rounded-md bg-zinc-900 px-6 py-3 text-base font-medium text-white transition hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          免費試用 14 天
        </Link>
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

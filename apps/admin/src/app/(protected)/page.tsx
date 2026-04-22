import Link from "next/link";

export default function Home() {
  return (
    <div className="flex flex-1 items-center justify-center bg-zinc-50 p-8 font-sans dark:bg-zinc-950">
      <main className="w-full max-w-3xl space-y-8">
        <header>
          <h1 className="text-3xl font-semibold tracking-tight">new_erp — 團購店 ERP</h1>
          <p className="mt-2 text-zinc-600 dark:text-zinc-400">
            admin console · scaffold v0（static export · Supabase client-only）
          </p>
        </header>

        <section className="grid gap-4 sm:grid-cols-2">
          <ModuleCard
            title="商品模組"
            href="/products"
            desc="SKU / 條碼 / 價格（總部成本 + 門市覆寫）"
          />
          <ModuleCard
            title="開團總表"
            href="/campaigns/matrix"
            desc="store × product matrix（v0.2）"
          />
          <ModuleCard
            title="揀貨波次"
            href="/picking-waves"
            desc="admin 合併團購訂單、產生出貨（v0.2）"
          />
          <ModuleCard
            title="分店首頁"
            href="/portal"
            desc="加盟店店長每日入口（v0.2）"
          />
        </section>

        <footer className="text-xs text-zinc-500 dark:text-zinc-500">
          <p>
            <span className="font-mono">Next 16 · React 19 · Tailwind 4</span>{" "}
            ·{" "}
            <Link href="https://github.com/www161616/new_erp" className="underline">
              GitHub
            </Link>
          </p>
        </footer>
      </main>
    </div>
  );
}

function ModuleCard({ title, href, desc }: { title: string; href: string; desc: string }) {
  return (
    <Link
      href={href}
      className="block rounded-lg border border-zinc-200 bg-white p-5 shadow-sm transition hover:shadow-md dark:border-zinc-800 dark:bg-zinc-900"
    >
      <h2 className="text-lg font-semibold">{title}</h2>
      <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{desc}</p>
    </Link>
  );
}

import type { Metadata } from "next";
import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";
import { FEATURE_PAGES } from "@/lib/content";
import { BRAND_NAME, CONTACT } from "@/lib/site";

export const metadata: Metadata = {
  title: "功能總覽 — 團購全鏈路一個系統包辦",
  description: `${BRAND_NAME} 功能總覽：開團接龍下單、撿貨派貨 WMS、庫存採購、會員 App、加盟總部統管。團購店與加盟總部需要的，一個系統全包。`,
  alternates: { canonical: "/features/" },
};

export default function FeaturesIndex() {
  return (
    <>
      <Nav />
      <main className="mx-auto max-w-6xl px-5 py-16">
        <nav className="text-sm text-muted">
          <a href="/" className="hover:text-foreground">首頁</a>
          <span className="mx-2">/</span>
          <span className="text-foreground">功能</span>
        </nav>
        <h1 className="mt-4 text-4xl font-extrabold tracking-tight md:text-5xl">
          團購全鏈路，一個系統包辦
        </h1>
        <p className="mt-4 max-w-2xl text-lg text-muted">
          從開團到對帳，每一步都串在一起。點進各模組看它怎麼解決團購店的日常痛點。
        </p>

        <div className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURE_PAGES.map((f) => (
            <a
              key={f.slug}
              href={`/features/${f.slug}/`}
              className="group rounded-2xl border bg-background p-6 transition hover:border-brand hover:shadow-md"
            >
              <div className="text-3xl">{f.icon}</div>
              <h2 className="mt-4 text-lg font-bold group-hover:text-brand-dark">
                {f.name}
              </h2>
              <p className="mt-2 text-sm leading-relaxed text-muted">{f.lead}</p>
              <span className="mt-4 inline-block text-sm font-semibold text-brand">
                了解更多 →
              </span>
            </a>
          ))}
        </div>

        <div className="mt-16 rounded-3xl bg-surface p-10 text-center">
          <h2 className="text-2xl font-extrabold">準備好把流程交給系統了嗎？</h2>
          <p className="mt-3 text-muted">免費試用 14 天，免綁卡。</p>
          <a
            href={CONTACT.trialUrl}
            className="mt-6 inline-block rounded-full bg-brand px-7 py-3.5 text-base font-bold text-white shadow-md transition hover:bg-brand-dark"
          >
            立即免費試用
          </a>
        </div>
      </main>
      <Footer />
    </>
  );
}

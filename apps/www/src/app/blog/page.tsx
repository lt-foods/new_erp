import type { Metadata } from "next";
import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";
import { BLOG_POSTS } from "@/lib/content";
import { BRAND_NAME } from "@/lib/site";

export const metadata: Metadata = {
  title: "部落格 — 團購經營知識",
  description: `${BRAND_NAME} 部落格：團購店經營、撿貨出貨、對帳、系統選擇等實戰知識，幫你把團購做得更輕鬆。`,
  alternates: { canonical: "/blog/" },
};

export default function BlogIndex() {
  return (
    <>
      <Nav />
      <main className="mx-auto max-w-3xl px-5 py-16">
        <nav className="text-sm text-muted">
          <a href="/" className="hover:text-foreground">首頁</a>
          <span className="mx-2">/</span>
          <span className="text-foreground">部落格</span>
        </nav>
        <h1 className="mt-4 text-4xl font-extrabold tracking-tight md:text-5xl">
          團購經營知識
        </h1>
        <p className="mt-4 text-lg text-muted">
          把團購做得更輕鬆的實戰心得——選系統、顧出貨、不漏單、不算錯錢。
        </p>

        <div className="mt-12 divide-y border-y">
          {BLOG_POSTS.map((p) => (
            <a key={p.slug} href={`/blog/${p.slug}/`} className="group block py-7">
              <time className="text-xs text-muted">{p.date}</time>
              <h2 className="mt-2 text-xl font-bold group-hover:text-brand-dark">
                {p.title}
              </h2>
              <p className="mt-2 text-sm leading-relaxed text-muted">{p.lead}</p>
              <span className="mt-3 inline-block text-sm font-semibold text-brand">
                閱讀全文 →
              </span>
            </a>
          ))}
        </div>
      </main>
      <Footer />
    </>
  );
}

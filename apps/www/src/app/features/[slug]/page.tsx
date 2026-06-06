import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";
import { FEATURE_PAGES, getFeature } from "@/lib/content";
import { BRAND_NAME, SITE_URL, CONTACT } from "@/lib/site";

export function generateStaticParams() {
  return FEATURE_PAGES.map((f) => ({ slug: f.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const f = getFeature(slug);
  if (!f) return {};
  return {
    title: f.metaTitle,
    description: f.metaDescription,
    keywords: f.keywords,
    alternates: { canonical: `/features/${f.slug}/` },
    openGraph: { title: f.metaTitle, description: f.metaDescription },
  };
}

export default async function FeatureDetail({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const f = getFeature(slug);
  if (!f) notFound();

  const breadcrumb = {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: [
      { "@type": "ListItem", position: 1, name: "首頁", item: `${SITE_URL}/` },
      { "@type": "ListItem", position: 2, name: "功能", item: `${SITE_URL}/features/` },
      { "@type": "ListItem", position: 3, name: f.name, item: `${SITE_URL}/features/${f.slug}/` },
    ],
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(breadcrumb) }}
      />
      <Nav />
      <main className="mx-auto max-w-3xl px-5 py-16">
        <nav className="text-sm text-muted">
          <a href="/" className="hover:text-foreground">首頁</a>
          <span className="mx-2">/</span>
          <a href="/features/" className="hover:text-foreground">功能</a>
          <span className="mx-2">/</span>
          <span className="text-foreground">{f.name}</span>
        </nav>

        <div className="mt-6 text-4xl">{f.icon}</div>
        <h1 className="mt-4 text-3xl font-extrabold tracking-tight md:text-4xl">
          {f.title}
        </h1>
        <p className="mt-4 text-lg text-muted">{f.lead}</p>

        <div className="mt-8 rounded-2xl border bg-surface p-6">
          <div className="text-sm font-bold">核心能力</div>
          <ul className="mt-3 space-y-2 text-sm">
            {f.capabilities.map((c) => (
              <li key={c} className="flex gap-2">
                <span className="text-brand">✓</span>
                <span>{c}</span>
              </li>
            ))}
          </ul>
        </div>

        <div className="mt-10 space-y-8">
          {f.sections.map((s) => (
            <section key={s.h}>
              <h2 className="text-xl font-bold">{s.h}</h2>
              <p className="mt-3 leading-relaxed text-muted">{s.p}</p>
            </section>
          ))}
        </div>

        <div className="mt-14 rounded-3xl bg-brand p-10 text-center text-white">
          <h2 className="text-2xl font-extrabold">用 {BRAND_NAME} 試試看</h2>
          <p className="mt-3 text-white/90">免費試用 14 天，免綁卡。</p>
          <div className="mt-6 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <a
              href={CONTACT.trialUrl}
              className="w-full rounded-full bg-white px-7 py-3.5 text-base font-bold text-brand-dark transition hover:bg-white/90 sm:w-auto"
            >
              立即免費試用
            </a>
            <a
              href="/features/"
              className="w-full rounded-full border border-white/40 px-7 py-3.5 text-base font-bold text-white transition hover:bg-white/10 sm:w-auto"
            >
              看其他功能
            </a>
          </div>
        </div>
      </main>
      <Footer />
    </>
  );
}

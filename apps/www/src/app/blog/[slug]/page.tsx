import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";
import { BLOG_POSTS, getPost } from "@/lib/content";
import { BRAND_NAME, SITE_URL, CONTACT } from "@/lib/site";

export function generateStaticParams() {
  return BLOG_POSTS.map((p) => ({ slug: p.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const post = getPost(slug);
  if (!post) return {};
  return {
    title: post.metaTitle,
    description: post.metaDescription,
    keywords: post.keywords,
    alternates: { canonical: `/blog/${post.slug}/` },
    openGraph: {
      type: "article",
      title: post.metaTitle,
      description: post.metaDescription,
      publishedTime: post.date,
    },
  };
}

export default async function BlogPost({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const post = getPost(slug);
  if (!post) notFound();

  const ld = [
    {
      "@context": "https://schema.org",
      "@type": "Article",
      headline: post.title,
      description: post.metaDescription,
      datePublished: post.date,
      dateModified: post.date,
      author: { "@type": "Organization", name: BRAND_NAME },
      publisher: { "@type": "Organization", name: BRAND_NAME },
      mainEntityOfPage: `${SITE_URL}/blog/${post.slug}/`,
    },
    {
      "@context": "https://schema.org",
      "@type": "BreadcrumbList",
      itemListElement: [
        { "@type": "ListItem", position: 1, name: "首頁", item: `${SITE_URL}/` },
        { "@type": "ListItem", position: 2, name: "部落格", item: `${SITE_URL}/blog/` },
        { "@type": "ListItem", position: 3, name: post.title, item: `${SITE_URL}/blog/${post.slug}/` },
      ],
    },
  ];

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(ld) }}
      />
      <Nav />
      <main className="mx-auto max-w-3xl px-5 py-16">
        <nav className="text-sm text-muted">
          <a href="/" className="hover:text-foreground">首頁</a>
          <span className="mx-2">/</span>
          <a href="/blog/" className="hover:text-foreground">部落格</a>
          <span className="mx-2">/</span>
          <span className="text-foreground">{post.title}</span>
        </nav>

        <article className="mt-6">
          <time className="text-sm text-muted">{post.date}</time>
          <h1 className="mt-2 text-3xl font-extrabold tracking-tight md:text-4xl">
            {post.title}
          </h1>
          <p className="mt-5 text-lg leading-relaxed text-muted">{post.lead}</p>

          <div className="mt-8 space-y-8">
            {post.sections.map((s) => (
              <section key={s.h}>
                <h2 className="text-xl font-bold">{s.h}</h2>
                <p className="mt-3 leading-relaxed text-muted">{s.p}</p>
              </section>
            ))}
          </div>
        </article>

        <div className="mt-14 rounded-3xl bg-surface p-10 text-center">
          <h2 className="text-2xl font-extrabold">想試試專為團購打造的系統？</h2>
          <p className="mt-3 text-muted">{BRAND_NAME}・免費試用 14 天，免綁卡。</p>
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

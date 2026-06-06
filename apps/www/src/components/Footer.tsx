import { BRAND_NAME, SUB_TAGLINE, CONTACT } from "@/lib/site";
import { FEATURE_PAGES, BLOG_POSTS } from "@/lib/content";

export function Footer() {
  return (
    <footer className="border-t bg-surface">
      <div className="mx-auto grid max-w-6xl gap-10 px-5 py-14 sm:grid-cols-2 lg:grid-cols-4">
        <div>
          <div className="text-lg font-extrabold text-brand">{BRAND_NAME}</div>
          <p className="mt-3 text-sm text-muted">{SUB_TAGLINE}</p>
          <a
            href={`mailto:${CONTACT.email}`}
            className="mt-3 inline-block text-sm text-muted hover:text-foreground"
          >
            {CONTACT.email}
          </a>
        </div>

        <div>
          <div className="text-sm font-bold">功能</div>
          <ul className="mt-3 space-y-2 text-sm text-muted">
            {FEATURE_PAGES.map((f) => (
              <li key={f.slug}>
                <a href={`/features/${f.slug}/`} className="hover:text-foreground">
                  {f.name}
                </a>
              </li>
            ))}
          </ul>
        </div>

        <div>
          <div className="text-sm font-bold">部落格</div>
          <ul className="mt-3 space-y-2 text-sm text-muted">
            {BLOG_POSTS.map((p) => (
              <li key={p.slug}>
                <a href={`/blog/${p.slug}/`} className="hover:text-foreground">
                  {p.title}
                </a>
              </li>
            ))}
          </ul>
        </div>

        <div>
          <div className="text-sm font-bold">開始使用</div>
          <ul className="mt-3 space-y-2 text-sm text-muted">
            <li><a href="/#pricing" className="hover:text-foreground">定價方案</a></li>
            <li><a href="/#faq" className="hover:text-foreground">常見問題</a></li>
            <li><a href={CONTACT.trialUrl} className="hover:text-foreground">免費試用</a></li>
            <li><a href={CONTACT.demoUrl} className="hover:text-foreground">預約 Demo</a></li>
          </ul>
        </div>
      </div>
      <div className="border-t">
        <div className="mx-auto max-w-6xl px-5 py-5 text-center text-xs text-muted">
          © {new Date().getFullYear()} {BRAND_NAME}・{SUB_TAGLINE}
        </div>
      </div>
    </footer>
  );
}

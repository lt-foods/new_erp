import { BRAND_NAME, CONTACT } from "@/lib/site";

export function Nav() {
  return (
    <header className="sticky top-0 z-50 border-b bg-background/80 backdrop-blur">
      <div className="mx-auto flex max-w-6xl items-center justify-between px-5 py-4">
        <a href="/" className="text-xl font-extrabold tracking-tight">
          <span className="text-brand">{BRAND_NAME}</span>
        </a>
        <nav className="hidden gap-7 text-sm font-medium text-muted md:flex">
          <a href="/features/" className="hover:text-foreground">功能</a>
          <a href="/#pricing" className="hover:text-foreground">定價</a>
          <a href="/blog/" className="hover:text-foreground">部落格</a>
          <a href="/#faq" className="hover:text-foreground">常見問題</a>
        </nav>
        <a
          href={CONTACT.trialUrl}
          className="rounded-full bg-brand px-4 py-2 text-sm font-bold text-white shadow-sm transition hover:bg-brand-dark"
        >
          免費試用
        </a>
      </div>
    </header>
  );
}

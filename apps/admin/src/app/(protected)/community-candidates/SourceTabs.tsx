"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

/** 廠商來源的兩個分頁：LINE 群組（記事本爬蟲）與 網站（登入廠商網站爬商品）。側欄只有一個「廠商來源」入口。 */
const TABS = [
  { href: "/community-candidates/supplier-groups", label: "LINE 群組", hint: "廠商在 LINE 群組記事本貼的開團文" },
  { href: "/community-candidates/vendor-sites", label: "網站", hint: "登入廠商網站抓商品（shop2000 等）" },
];

export default function SourceTabs() {
  const pathname = usePathname();
  return (
    <nav className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800" aria-label="廠商來源">
      {TABS.map((t) => {
        const active = pathname?.startsWith(t.href);
        return (
          <Link
            key={t.href}
            href={t.href}
            title={t.hint}
            aria-current={active ? "page" : undefined}
            className={`-mb-px border-b-2 px-3 py-2 text-sm ${
              active
                ? "border-zinc-900 font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
                : "border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
            }`}
          >
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}

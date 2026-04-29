"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const tabs = [
  { href: "/overview",    label: "總覽" },
  { href: "/orders",      label: "我的訂單" },
  { href: "/settlements", label: "我的結單" },
  { href: "/me",          label: "我" },
];

export default function MemberTabBar() {
  const pathname = usePathname() ?? "";
  return (
    <nav className="flex border-b border-zinc-200 bg-white">
      {tabs.map((t) => {
        const active = pathname.startsWith(t.href);
        return (
          <Link
            key={t.href}
            href={t.href}
            className={`relative flex-1 px-2 py-3 text-center text-base transition-colors ${
              active
                ? "font-medium text-pink-600"
                : "text-zinc-500 hover:text-zinc-700"
            }`}
          >
            {t.label}
            {active && (
              <span className="absolute inset-x-3 bottom-0 h-0.5 bg-pink-600" />
            )}
          </Link>
        );
      })}
    </nav>
  );
}

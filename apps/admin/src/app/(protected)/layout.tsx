"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, type ReactNode } from "react";
import { useAuth } from "@/components/AuthProvider";
import { ThemeToggle } from "@/components/ThemeToggle";

const NAV_ITEMS: { href: string; label: string; match: RegExp }[] = [
  { href: "/products",  label: "商品",   match: /^\/products/  },
  { href: "/members",   label: "會員",   match: /^\/members/   },
  { href: "/campaigns", label: "開團",   match: /^\/campaigns/ },
  { href: "/orders",    label: "訂單",   match: /^\/orders/    },
  { href: "/suppliers", label: "供應商", match: /^\/suppliers/ },
];

export default function ProtectedLayout({ children }: { children: ReactNode }) {
  const { session, loading, user, signOut } = useAuth();
  const router = useRouter();
  const pathname = usePathname();

  useEffect(() => {
    if (loading) return;
    if (!session) {
      const next = encodeURIComponent(pathname || "/");
      router.replace(`/login?next=${next}`);
    }
  }, [loading, session, pathname, router]);

  if (loading || !session) {
    return (
      <div className="flex flex-1 items-center justify-center text-sm text-zinc-500">
        載入中…
      </div>
    );
  }

  async function onLogout() {
    await signOut();
    router.replace("/login");
  }

  return (
    <div className="flex min-h-full flex-1 flex-col">
      <header className="flex items-center justify-between border-b border-zinc-200 bg-white px-6 py-3 dark:border-zinc-800 dark:bg-zinc-900">
        <nav className="flex items-center gap-4 text-sm">
          <Link href="/" className="font-semibold">
            new_erp
          </Link>
          {NAV_ITEMS.map((it) => {
            const active = it.match.test(pathname || "");
            return (
              <Link
                key={it.href}
                href={it.href}
                className={
                  active
                    ? "rounded-md bg-zinc-100 px-2 py-1 font-medium text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100"
                    : "rounded-md px-2 py-1 text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
                }
              >
                {it.label}
              </Link>
            );
          })}
        </nav>
        <div className="flex items-center gap-3 text-sm">
          <ThemeToggle />
          <span className="text-zinc-500">{user?.email}</span>
          <button
            onClick={onLogout}
            className="rounded-md border border-zinc-300 px-3 py-1 text-zinc-700 transition hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
          >
            登出
          </button>
        </div>
      </header>
      <main className="flex flex-1 flex-col">{children}</main>
    </div>
  );
}

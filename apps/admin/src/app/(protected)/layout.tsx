"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, type ReactNode } from "react";
import { useAuth } from "@/components/AuthProvider";
import { ThemeToggle } from "@/components/ThemeToggle";

type NavItem = { href: string; label: string; match: RegExp };
type NavGroup = { title?: string; items: NavItem[] };

const NAV: NavGroup[] = [
  {
    items: [
      { href: "/", label: "儀表板", match: /^\/$/ },
    ],
  },
  {
    title: "核心業務",
    items: [
      { href: "/orders", label: "訂單", match: /^\/orders/ },
      { href: "/pickup", label: "取貨", match: /^\/pickup/ },
      { href: "/campaigns", label: "開團", match: /^\/campaigns/ },
      { href: "/products", label: "商品", match: /^\/products/ },
      { href: "/members", label: "會員", match: /^\/members/ },
    ],
  },
  {
    title: "進銷存",
    items: [
      { href: "/suppliers", label: "供應商", match: /^\/suppliers/ },
      { href: "/purchase/requests", label: "採購單", match: /^\/purchase\/requests/ },
      { href: "/purchase/orders", label: "採購訂單", match: /^\/purchase\/orders/ },
      { href: "/restock", label: "補貨申請", match: /^\/restock(?!\/inbox)/ },
      { href: "/restock/inbox", label: "補貨申請 (HQ)", match: /^\/restock\/inbox/ },
      { href: "/picking/workstation", label: "撿貨工作站", match: /^\/picking\/workstation/ },
      { href: "/picking/history", label: "撿貨歷史", match: /^\/picking\/history/ },
      { href: "/transfers/dispatch", label: "總倉派貨", match: /^\/transfers\/dispatch|^\/transfers$|^\/transfers\/?$/ },
      { href: "/transfers/inbox", label: "收貨待辦", match: /^\/transfers\/inbox/ },
      { href: "/transfers/free", label: "自由轉貨", match: /^\/transfers\/free/ },
      { href: "/inventory/mutual-aid", label: "互助交流板", match: /^\/inventory\/mutual-aid/ },
      { href: "/transfers/aid", label: "互助轉移單", match: /^\/transfers\/aid/ },
      { href: "/transfers/settlement", label: "月結算", match: /^\/transfers\/settlement/ },
    ],
  },
  {
    title: "財務",
    items: [
      { href: "/finance/receivables", label: "HQ 應收", match: /^\/finance\/receivables(?!\/print)/ },
    ],
  },
  {
    title: "社群選品",
    items: [
      { href: "/community-candidates", label: "候選池", match: /^\/community-candidates(?!\/calendar)/ },
      { href: "/community-candidates/calendar", label: "週曆", match: /^\/community-candidates\/calendar/ },
    ],
  },
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
    <div className="flex min-h-full flex-1">
      <aside className="hidden w-52 shrink-0 flex-col border-r border-zinc-200 bg-zinc-50 md:flex print:hidden dark:border-zinc-800 dark:bg-zinc-950">
        <div className="border-b border-zinc-200 px-4 py-4 dark:border-zinc-800">
          <Link href="/" className="block">
            <div className="text-lg font-semibold tracking-tight">new_erp</div>
            <div className="text-xs text-zinc-500">團購店管理</div>
          </Link>
          <div className="mt-2 inline-flex items-center gap-1 rounded-full border border-zinc-300 bg-white px-2 py-0.5 text-[10px] text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400">
            <span className="h-1.5 w-1.5 rounded-full bg-amber-400" /> 開發版
          </div>
        </div>

        <nav className="flex-1 overflow-y-auto px-2 py-3 text-sm">
          {NAV.map((g, gi) => (
            <div key={gi} className="mb-4">
              {g.title && (
                <div className="px-2 pb-1 text-[10px] font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500">
                  {g.title}
                </div>
              )}
              <ul className="space-y-0.5">
                {g.items.map((it) => {
                  const active = it.match.test(pathname || "");
                  return (
                    <li key={it.href}>
                      <Link
                        href={it.href}
                        className={
                          active
                            ? "flex items-center justify-between rounded-md bg-zinc-900 px-3 py-2 text-white dark:bg-zinc-100 dark:text-zinc-900"
                            : "flex items-center justify-between rounded-md px-3 py-2 text-zinc-700 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-900"
                        }
                      >
                        <span>{it.label}</span>
                        {active && <span className="text-xs opacity-60">›</span>}
                      </Link>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))}
        </nav>

        <div className="border-t border-zinc-200 p-3 text-xs dark:border-zinc-800">
          <div className="mb-2 truncate text-zinc-500" title={user?.email ?? ""}>
            {user?.email}
          </div>
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <button
              onClick={onLogout}
              className="flex-1 rounded-md border border-zinc-300 px-2 py-1 text-zinc-700 transition hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
            >
              登出
            </button>
          </div>
        </div>
      </aside>

      {/* Mobile bar */}
      <div className="md:hidden print:hidden">
        <header className="flex items-center justify-between border-b border-zinc-200 bg-white px-4 py-2 dark:border-zinc-800 dark:bg-zinc-900">
          <Link href="/" className="font-semibold">new_erp</Link>
          <div className="flex items-center gap-2 text-sm">
            <ThemeToggle />
            <button
              onClick={onLogout}
              className="rounded-md border border-zinc-300 px-2 py-1 text-zinc-700 dark:border-zinc-700 dark:text-zinc-300"
            >
              登出
            </button>
          </div>
        </header>
      </div>

      <main className="flex flex-1 flex-col">{children}</main>
    </div>
  );
}

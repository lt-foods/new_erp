"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useUnreadNotifications } from "@/lib/useUnreadNotifications";

type Tab = {
  href: string;
  label: string;
  showBadge?: boolean;
  /** 凸起中央鍵（現貨專區）：畫成往上浮出 bar 的品牌漸層圓鈕 */
  raised?: boolean;
  icon: (active: boolean) => React.ReactNode;
};

const stroke = (active: boolean) => (active ? "currentColor" : "currentColor");

const tabs: Tab[] = [
  {
    href: "/shop",
    label: "商品",
    icon: (active) => (
      <svg viewBox="0 0 24 24" fill={active ? "currentColor" : "none"} stroke={stroke(active)} strokeWidth={active ? 0 : 1.8} className="h-7 w-7">
        <rect x="3.5" y="3.5" width="7.5" height="7.5" rx="1.5" strokeLinejoin="round" />
        <rect x="13" y="3.5" width="7.5" height="7.5" rx="1.5" strokeLinejoin="round" />
        <rect x="3.5" y="13" width="7.5" height="7.5" rx="1.5" strokeLinejoin="round" />
        <rect x="13" y="13" width="7.5" height="7.5" rx="1.5" strokeLinejoin="round" />
      </svg>
    ),
  },
  {
    href: "/orders",
    label: "訂單",
    icon: (active) => (
      <svg viewBox="0 0 24 24" fill={active ? "currentColor" : "none"} stroke={stroke(active)} strokeWidth={active ? 0 : 1.8} className="h-7 w-7">
        <path strokeLinecap="round" strokeLinejoin="round" d="M5 7h14l-1.2 11.1A2 2 0 0 1 15.8 20H8.2a2 2 0 0 1-2-1.9L5 7Zm3 0V5a4 4 0 0 1 8 0v2" />
      </svg>
    ),
  },
  {
    // 現貨專區站正中間（5 格的第 3 格）。必須是獨立頂層路由 —— 掛在 /shop/...
    // 底下的話，下面 startsWith 的 active 判斷會讓「商品」tab 一起亮。
    href: "/spot",
    label: "現貨專區",
    raised: true,
    icon: () => (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.9} className="h-7 w-7">
        <path strokeLinecap="round" strokeLinejoin="round" d="M3 8.5 12 4l9 4.5v7L12 20l-9-4.5v-7Z" />
        <path strokeLinecap="round" strokeLinejoin="round" d="m3 8.5 9 4.5 9-4.5M12 13v7" />
      </svg>
    ),
  },
  {
    href: "/notifications",
    label: "通知",
    showBadge: true,
    icon: (active) => (
      <svg viewBox="0 0 24 24" fill={active ? "currentColor" : "none"} stroke={stroke(active)} strokeWidth={active ? 0 : 1.8} className="h-7 w-7">
        <path strokeLinecap="round" strokeLinejoin="round" d="M6 16V11a6 6 0 1 1 12 0v5l1.5 2H4.5L6 16Z" />
        <path strokeLinecap="round" strokeLinejoin="round" d="M10 20a2 2 0 0 0 4 0" />
      </svg>
    ),
  },
  {
    href: "/me",
    label: "我",
    icon: (active) => (
      <svg viewBox="0 0 24 24" fill={active ? "currentColor" : "none"} stroke={stroke(active)} strokeWidth={active ? 0 : 1.8} className="h-7 w-7">
        <path strokeLinecap="round" strokeLinejoin="round" d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8a7 7 0 0 1 14 0v1H5v-1Z" />
      </svg>
    ),
  },
];

export default function MemberTabBar() {
  const pathname = usePathname() ?? "";
  const { count: unreadCount } = useUnreadNotifications();

  // LINE LIFF 內建瀏覽器現在也走完整商店,tab bar 一律顯示(standalone / 一般瀏覽器 / LINE 皆同)。
  // 商品詳細頁有自己的 sticky 下單 bar、會跟 tab bar 打架,直接隱藏。
  if (pathname.startsWith("/shop/c/")) return null;

  return (
    <nav
      className="fixed inset-x-0 bottom-0 z-30 border-t border-[var(--separator)] bg-white/80 backdrop-blur-xl"
      style={{
        paddingBottom: "max(env(safe-area-inset-bottom), 20px)",
        boxShadow: "0 -8px 24px -16px rgba(158,47,80,0.25)",
      }}
    >
      <ul className="mx-auto flex max-w-md items-stretch">
        {tabs.map((t) => {
          const active = pathname.startsWith(t.href);
          const showBadge = t.showBadge && unreadCount > 0;
          const badgeText = unreadCount > 99 ? "99+" : String(unreadCount);

          // 凸起中央鍵：圓鈕往上浮出 bar，用白色外圈打穿邊線。
          // 文字仍留在原本位置，五格的 label 基線才會齊。
          if (t.raised) {
            return (
              <li key={t.href} className="flex-1">
                <Link
                  href={t.href}
                  className={`flex flex-col items-center justify-center gap-1 px-1 pb-2.5 pt-2.5 text-[12px] font-semibold transition-colors duration-200 ${
                    active ? "text-[var(--brand-strong)]" : "text-[var(--ios-gray)]"
                  }`}
                >
                  {/* 外層維持和其他 tab 相同的 h-9 佔位，label 基線才會齊；
                      圓鈕用 absolute 往上溢出，凸出 bar 上緣約 14px。 */}
                  <span className="relative flex h-9 w-14 items-center justify-center">
                    <span
                      className={`brand-gradient absolute -top-6 flex h-14 w-14 items-center justify-center rounded-full text-white ring-4 ring-white transition-all duration-300 ${
                        active
                          ? "scale-100 shadow-[0_10px_22px_-6px_rgba(158,47,80,0.75)]"
                          : "scale-95 shadow-[0_6px_16px_-6px_rgba(158,47,80,0.5)]"
                      }`}
                    >
                      {t.icon(active)}
                    </span>
                  </span>
                  <span>{t.label}</span>
                </Link>
              </li>
            );
          }

          return (
            <li key={t.href} className="flex-1">
              <Link
                href={t.href}
                className={`flex flex-col items-center justify-center gap-1 px-1 pb-2.5 pt-2.5 text-[12px] font-semibold transition-colors duration-200 ${
                  active ? "text-[var(--brand-strong)]" : "text-[var(--ios-gray)]"
                }`}
              >
                <span
                  className={`relative flex h-9 w-[52px] items-center justify-center rounded-full transition-all duration-300 ${
                    active ? "bg-[var(--brand-soft)] scale-100" : "bg-transparent scale-90"
                  }`}
                >
                  {t.icon(active)}
                  {showBadge && (
                    <span
                      className="absolute right-1 -top-0.5 flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-[var(--ios-red)] px-1 text-[11px] font-semibold leading-none text-white ring-2 ring-white"
                      aria-label={`${unreadCount} 則未讀`}
                    >
                      {badgeText}
                    </span>
                  )}
                </span>
                <span>{t.label}</span>
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

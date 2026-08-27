"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";
import { useAuth } from "@/components/AuthProvider";
import { ThemeToggle } from "@/components/ThemeToggle";
import { ReleaseNotesProvider, ReleaseNotesBell } from "@/components/ReleaseNotes";
import { TrialBanner, TrialExpiredScreen } from "@/components/TrialGate";
import { getTenantName } from "@/lib/tenant";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import PresenceBeacon from "@/components/PresenceBeacon";

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
      { href: "/campaigns", label: "開團", match: /^\/campaigns/ },
      { href: "/campaigns/import", label: "匯入開團", match: /^\/campaigns\/import/ },
      { href: "/products", label: "商品", match: /^\/products/ },
      { href: "/suppliers", label: "供應商", match: /^\/suppliers/ },
    ],
  },
  {
    title: "分店業務",
    items: [
      { href: "/orders", label: "訂單", match: /^\/orders/ },
      { href: "/pickup", label: "取貨", match: /^\/pickup/ },
      { href: "/wms/inbound", label: "收貨", match: /^\/wms\/inbound|^\/transfers\/inbox/ },
      { href: "/members", label: "會員", match: /^\/members/ },
      { href: "/wms/transfers", label: "內部調撥", match: /^\/wms\/transfers|^\/transfers\/free|^\/transfers\/dispatch|^\/transfers$|^\/transfers\/?$/ },
      { href: "/restock", label: "補貨申請", match: /^\/restock(?!\/inbox)/ },
      { href: "/inventory/mutual-aid", label: "互助交流板", match: /^\/inventory\/mutual-aid/ },
    ],
  },
  {
    title: "進銷存",
    items: [
      { href: "/purchase/requests", label: "請購單", match: /^\/purchase\/requests/ },
      { href: "/purchase/orders", label: "採購單", match: /^\/purchase\/orders/ },
      { href: "/inventory", label: "庫存總覽", match: /^\/inventory(?!\/mutual-aid|\/reorder-rules|\/stocktake|\/deductions)/ },
      { href: "/inventory/deductions", label: "庫存減抵單", match: /^\/inventory\/deductions/ },
      { href: "/inventory/reorder-rules", label: "補貨規則", match: /^\/inventory\/reorder-rules/ },
      { href: "/inventory/stocktake", label: "盤點", match: /^\/inventory\/stocktake/ },
    ],
  },
  {
    title: "倉儲 (WMS)",
    items: [
      { href: "/hq/inbox", label: "總倉收件匣", match: /^\/hq\/inbox/ },
      { href: "/wms/receiving", label: "進貨待辦", match: /^\/wms\/receiving/ },
      // 選單順序＝工作流程順序：先在草稿上挑好給樓下撿，撿完確定了才到工作台建正式單。
      // ⚠ 路徑刻意不放在 /wms/picking 底下 —— 派貨工作台的 match 是 ^\/wms\/picking(?!\/history)，
      //   /wms/picking-drafts 之類的路徑會一起命中，兩個選單項會同時亮起來。
      { href: "/picking/drafts", label: "撿貨草稿", match: /^\/picking\/drafts/ },
      { href: "/wms/picking", label: "派貨工作台", match: /^\/wms\/picking(?!\/history)|^\/picking\/workstation/ },
    ],
  },
  {
    title: "財務",
    items: [
      { href: "/finance/daily", label: "日結報表", match: /^\/finance\/daily/ },
      { href: "/finance/receivables", label: "HQ 應收", match: /^\/finance\/receivables(?!\/print)/ },
      { href: "/transfers/settlement", label: "月結算", match: /^\/transfers\/settlement/ },
    ],
  },
  {
    title: "分析",
    items: [
      { href: "/analytics/regions", label: "地區偏好", match: /^\/analytics\/regions/ },
      { href: "/analytics/members", label: "會員分析", match: /^\/analytics\/members/ },
      { href: "/analytics/products", label: "商品分析", match: /^\/analytics\/products/ },
    ],
  },
  {
    title: "社群選品",
    items: [
      { href: "/community-candidates", label: "候選池", match: /^\/community-candidates(?!\/calendar)/ },
      { href: "/community-candidates/calendar", label: "週曆", match: /^\/community-candidates\/calendar/ },
    ],
  },
  {
    title: "設定",
    items: [
      { href: "/piaopiao-publishers", label: "漂漂館上架員", match: /^\/piaopiao-publishers/ },
      { href: "/staff", label: "員工管理", match: /^\/staff/ },
      { href: "/stores", label: "門市", match: /^\/stores/ },
      { href: "/fb-pages", label: "FB 粉絲團", match: /^\/fb-pages/ },
    ],
  },
];

// 只 owner / admin 看得到的 group title 清單
const ADMIN_ONLY_GROUPS = new Set(["設定"]);

function canManageStaff(user: { app_metadata?: Record<string, unknown> } | null | undefined): boolean {
  const r = user?.app_metadata?.role;
  return r === "owner" || r === "admin";
}

function filterNavForRole(nav: NavGroup[], user: { app_metadata?: Record<string, unknown> } | null | undefined): NavGroup[] {
  if (canManageStaff(user)) return nav;
  return nav.filter((g) => !g.title || !ADMIN_ONLY_GROUPS.has(g.title));
}

const NAV_COLLAPSE_KEY = "new_erp-nav-collapsed";

// 分店帳號 (app_metadata.stores 有值且不含「總倉」) 隱藏的項目
const BRANCH_HIDDEN_HREFS = new Set([
  "/hq/inbox",            // 總倉收件匣
  "/products",            // 商品主檔 (HQ 管理)
  "/suppliers",           // 供應商 (HQ 管理)
  "/purchase/requests",   // 請購單 (PR)
  "/purchase/orders",     // 採購單 (PO)
  "/wms/receiving",       // 進貨待辦 (HQ)
  "/picking/drafts",      // 撿貨草稿 (HQ；比照派貨工作台，RLS 也只開給總部角色)
  "/wms/picking",         // 派貨工作台
  // /wms/inbound 跟 /wms/transfers 不在這裡 — 分店要用,屬於分店業務
  "/finance/receivables", // HQ 應收
  "/stores",              // 門市設定 (HQ 管理)
  "/fb-pages",            // 粉絲團設定 (HQ 管理)
]);
const BRANCH_HIDDEN_GROUPS = new Set([
  "社群選品", // 整個 group 隱藏
  "分析",     // 跨店客群 / 商品分析，加盟店不看別家（比照 /products）
]);

function isBranchUser(user: { app_metadata?: Record<string, unknown> } | null | undefined): boolean {
  const stores = user?.app_metadata?.stores;
  if (!Array.isArray(stores) || stores.length === 0) return false;
  return !stores.includes("總倉");
}

function filterNavForBranch(nav: NavGroup[]): NavGroup[] {
  return nav
    .filter((g) => !g.title || !BRANCH_HIDDEN_GROUPS.has(g.title))
    .map((g) => ({
      ...g,
      items: g.items
        .filter((it) => !BRANCH_HIDDEN_HREFS.has(it.href))
        // 分店帳號看到的是店家核對介面，選單改叫「月結對帳」
        .map((it) => (it.href === "/transfers/settlement" ? { ...it, label: "月結對帳" } : it)),
    }))
    .filter((g) => g.items.length > 0);
}

// 側欄選單通知小數字：換頁/回到視窗/對應操作後（refreshEvent）重抓。
// 月結對帳待辦數（分店：待核對+待匯款；總部：待處理爭議+待確認收款）
export const SETTLEMENT_BADGE_REFRESH_EVENT = "settlement-badge-refresh";
// 分店收貨待辦數（已派出 shipped、還沒收的調撥單）
export const INBOUND_BADGE_REFRESH_EVENT = "inbound-badge-refresh";
// 互助交流板進行中貼文數
export const AID_BADGE_REFRESH_EVENT = "aid-badge-refresh";

function useNavBadgeCount(
  enabled: boolean,
  pathname: string | null,
  rpc: "rpc_settlement_action_count" | "rpc_inbound_pending_count" | "rpc_aid_board_active_count",
  refreshEvent: string,
): number {
  const [count, setCount] = useState(0);

  useEffect(() => {
    if (!enabled) return;
    let cancelled = false;
    const load = async () => {
      try {
        const { data } = await getSupabase().rpc(rpc);
        if (!cancelled && typeof data === "number") setCount(data);
      } catch {
        /* badge 失敗不影響操作 */
      }
    };
    void load();
    const onRefresh = () => { void load(); };
    window.addEventListener("focus", onRefresh);
    window.addEventListener(refreshEvent, onRefresh);
    return () => {
      cancelled = true;
      window.removeEventListener("focus", onRefresh);
      window.removeEventListener(refreshEvent, onRefresh);
    };
  }, [enabled, pathname, rpc, refreshEvent]);

  return count;
}

function NavBadge({ count }: { count: number }) {
  if (count <= 0) return null;
  return (
    <span className="inline-flex h-4 min-w-4 items-center justify-center rounded-full bg-red-500 px-1 text-[10px] font-semibold leading-none text-white">
      {count > 99 ? "99+" : count}
    </span>
  );
}

// 分店未收貨提醒橫幅（比照 TrialBanner 的樣式）。
//
// 為什麼側欄那顆 NavBadge 不夠：它只是一個數字，① 不講後果 ② 手機版要先點漢堡
// 開抽屜才看得到（見下方 mobile drawer）③ 桌機把「分店業務」那組收合起來也看不到。
// 這條橫幅每一頁都在，並且把「不按收貨會怎樣」寫出來。
//
// 數字沿用側欄 badge 的 inboundCount（rpc_inbound_pending_count）＝自己店為
// dest_location、status='shipped' 的調撥單張數 — 不另外查一次。
// 收貨頁本身不顯示（人已經在那頁了，重複提醒沒有意義）。
function InboundReminderBanner({ count }: { count: number }) {
  if (count <= 0) return null;
  return (
    <Link
      href="/wms/inbound"
      className="flex flex-wrap items-center justify-center gap-x-2 gap-y-0.5 border-b border-amber-200 bg-amber-50 px-4 py-1.5 text-center text-xs text-amber-800 transition hover:bg-amber-100 print:hidden dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300 dark:hover:bg-amber-900"
    >
      <span>
        ⚠️ 你有 <span className="font-semibold">{count}</span> 張貨還沒按收貨
      </span>
      <span className="opacity-80">
        按收貨，貨才會進你店的庫存；庫存不夠時客人可能取不到。
      </span>
      <span className="font-medium underline underline-offset-2">去收貨 →</span>
    </Link>
  );
}

export default function ProtectedLayout({ children }: { children: ReactNode }) {
  const { session, loading, user, signOut, tenant } = useAuth();
  const router = useRouter();
  const pathname = usePathname();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const tenantName = tenant?.name ?? getTenantName();
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const branchUser = isBranchUser(user);
  const settlementCount = useNavBadgeCount(
    !!session, pathname, "rpc_settlement_action_count", SETTLEMENT_BADGE_REFRESH_EVENT,
  );
  // 收貨 badge 只服務分店帳號；HQ 在 /wms/inbound 看的是全分店監控，不掛通知
  const inboundCount = useNavBadgeCount(
    !!session && branchUser, pathname, "rpc_inbound_pending_count", INBOUND_BADGE_REFRESH_EVENT,
  );
  // 互助交流板 badge：分店帳號看到全 tenant 進行中貼文數（跨店佈告欄）
  const aidCount = useNavBadgeCount(
    !!session && branchUser, pathname, "rpc_aid_board_active_count", AID_BADGE_REFRESH_EVENT,
  );
  const navBadges: Record<string, number> = {
    "/transfers/settlement": settlementCount,
    "/wms/inbound": inboundCount,
    "/inventory/mutual-aid": aidCount,
  };

  // 載入 collapsed groups (localStorage)
  useEffect(() => {
    try {
      const raw = localStorage.getItem(NAV_COLLAPSE_KEY);
      if (raw) setCollapsed(new Set(JSON.parse(raw) as string[]));
    } catch { /* noop */ }
  }, []);

  function toggleGroup(title: string) {
    setCollapsed((cur) => {
      const next = new Set(cur);
      if (next.has(title)) next.delete(title);
      else next.add(title);
      try {
        localStorage.setItem(NAV_COLLAPSE_KEY, JSON.stringify(Array.from(next)));
      } catch { /* noop */ }
      return next;
    });
  }

  useEffect(() => {
    if (loading) return;
    if (!session) {
      const next = encodeURIComponent(pathname || "/");
      router.replace(`/login?next=${next}`);
    }
  }, [loading, session, pathname, router]);

  // Auto-close drawer when route changes
  useEffect(() => {
    setDrawerOpen(false);
  }, [pathname]);

  // ESC closes drawer + lock body scroll while open
  useEffect(() => {
    if (!drawerOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setDrawerOpen(false);
    };
    document.addEventListener("keydown", onKey);
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prevOverflow;
    };
  }, [drawerOpen]);

  if (loading || !session) {
    return (
      <div className="flex flex-1 items-center justify-center text-sm text-zinc-500">
        載入中…
      </div>
    );
  }

  // 試用到期 / 已刪除：整頁擋住（後端另有 _current_tenant_id 防線）
  if (tenant && (tenant.status === "suspended" || tenant.status === "deleted")) {
    return <TrialExpiredScreen tenant={tenant} />;
  }

  async function onLogout() {
    await signOut();
    router.replace("/login");
  }

  const visibleNav = filterNavForRole(branchUser ? filterNavForBranch(NAV) : NAV, user);

  return (
    <ReleaseNotesProvider>
    <PresenceBeacon />
    <div className="flex min-h-full flex-1 flex-col md:flex-row">
      <aside className="hidden w-52 shrink-0 flex-col border-r border-zinc-200 bg-zinc-50 md:flex print:hidden dark:border-zinc-800 dark:bg-zinc-950">
        <div className="border-b border-zinc-200 px-4 py-4 dark:border-zinc-800">
          <div className="flex items-start justify-between gap-2">
            <Link href="/" className="block">
              <div className="text-lg font-semibold tracking-tight">{tenantName}</div>
              <div className="text-xs text-zinc-500">管理頁面</div>
            </Link>
            <ReleaseNotesBell />
          </div>
          <div className="mt-2 inline-flex items-center gap-1 rounded-full border border-zinc-300 bg-white px-2 py-0.5 text-[10px] text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400">
            <span className="h-1.5 w-1.5 rounded-full bg-amber-400" /> 開發版
          </div>
        </div>

        <nav className="flex-1 overflow-y-auto px-2 py-3 text-sm">
          {visibleNav.map((g, gi) => {
            const groupHasActive = g.items.some((it) => it.match.test(pathname || ""));
            const isCollapsed = g.title ? collapsed.has(g.title) && !groupHasActive : false;
            return (
              <div key={gi} className="mb-4">
                {g.title && (
                  <SpinButton
                    type="button"
                    onClick={() => toggleGroup(g.title!)}
                    className="flex w-full items-center justify-between rounded px-2 pb-1.5 pt-0.5 text-xs font-semibold tracking-wider text-zinc-500 hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-200"
                  >
                    <span>{g.title}</span>
                    <span className="text-xs opacity-60">{isCollapsed ? "▸" : "▾"}</span>
                  </SpinButton>
                )}
                {!isCollapsed && (
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
                            <span className="flex items-center gap-1.5">
                              <NavBadge count={navBadges[it.href] ?? 0} />
                              {active && <span className="text-xs opacity-60">›</span>}
                            </span>
                          </Link>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </div>
            );
          })}
        </nav>

        <div className="border-t border-zinc-200 p-3 text-xs dark:border-zinc-800">
          <div className="mb-2 truncate text-zinc-500" title={user?.email ?? ""}>
            {user?.email}
          </div>
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <SpinButton
              onClick={onLogout}
              className="flex-1 rounded-md border border-zinc-300 px-2 py-1 text-zinc-700 transition hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
            >
              登出
            </SpinButton>
          </div>
        </div>
      </aside>

      {/* Mobile bar */}
      <div className="md:hidden print:hidden">
        <header className="flex items-center justify-between border-b border-zinc-200 bg-white px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex items-center gap-2">
            <SpinButton
              onClick={() => setDrawerOpen(true)}
              aria-label="開啟選單"
              className="-ml-1 inline-flex h-9 w-9 items-center justify-center rounded-md text-zinc-700 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="h-5 w-5">
                <line x1="3" y1="6" x2="21" y2="6" />
                <line x1="3" y1="12" x2="21" y2="12" />
                <line x1="3" y1="18" x2="21" y2="18" />
              </svg>
            </SpinButton>
            <Link href="/" className="font-semibold">{tenantName}</Link>
          </div>
          <div className="flex items-center gap-2 text-sm">
            <ReleaseNotesBell />
            <ThemeToggle />
          </div>
        </header>
      </div>

      {/* Mobile drawer */}
      {drawerOpen && (
        <div className="fixed inset-0 z-50 md:hidden print:hidden" role="dialog" aria-modal="true">
          <div
            className="absolute inset-0 bg-zinc-900/50 backdrop-blur-sm"
            onClick={() => setDrawerOpen(false)}
            aria-hidden
          />
          <aside className="absolute left-0 top-0 flex h-full w-72 max-w-[85vw] flex-col border-r border-zinc-200 bg-zinc-50 shadow-xl dark:border-zinc-800 dark:bg-zinc-950">
            <div className="flex items-start justify-between border-b border-zinc-200 px-4 py-4 dark:border-zinc-800">
              <Link href="/" onClick={() => setDrawerOpen(false)} className="block">
                <div className="text-lg font-semibold tracking-tight">{tenantName}</div>
                <div className="text-xs text-zinc-500">管理頁面</div>
              </Link>
              <SpinButton
                onClick={() => setDrawerOpen(false)}
                aria-label="關閉選單"
                className="-mr-1 inline-flex h-8 w-8 items-center justify-center rounded-md text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
              >
                ✕
              </SpinButton>
            </div>

            <nav className="flex-1 overflow-y-auto px-2 py-3 text-sm">
              {visibleNav.map((g, gi) => {
                const groupHasActive = g.items.some((it) => it.match.test(pathname || ""));
                const isCollapsed = g.title ? collapsed.has(g.title) && !groupHasActive : false;
                return (
                  <div key={gi} className="mb-4">
                    {g.title && (
                      <SpinButton
                        type="button"
                        onClick={() => toggleGroup(g.title!)}
                        className="flex w-full items-center justify-between rounded px-2 pb-1.5 pt-0.5 text-xs font-semibold tracking-wider text-zinc-500 hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-200"
                      >
                        <span>{g.title}</span>
                        <span className="text-xs opacity-60">{isCollapsed ? "▸" : "▾"}</span>
                      </SpinButton>
                    )}
                    {!isCollapsed && (
                      <ul className="space-y-0.5">
                        {g.items.map((it) => {
                          const active = it.match.test(pathname || "");
                          return (
                            <li key={it.href}>
                              <Link
                                href={it.href}
                                onClick={() => setDrawerOpen(false)}
                                className={
                                  active
                                    ? "flex items-center justify-between rounded-md bg-zinc-900 px-3 py-2 text-white dark:bg-zinc-100 dark:text-zinc-900"
                                    : "flex items-center justify-between rounded-md px-3 py-2 text-zinc-700 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-900"
                                }
                              >
                                <span>{it.label}</span>
                                <span className="flex items-center gap-1.5">
                                  <NavBadge count={navBadges[it.href] ?? 0} />
                                  {active && <span className="text-xs opacity-60">›</span>}
                                </span>
                              </Link>
                            </li>
                          );
                        })}
                      </ul>
                    )}
                  </div>
                );
              })}
            </nav>

            <div className="border-t border-zinc-200 p-3 text-xs dark:border-zinc-800">
              <div className="mb-2 truncate text-zinc-500" title={user?.email ?? ""}>
                {user?.email}
              </div>
              <SpinButton
                onClick={onLogout}
                className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-zinc-700 transition hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
              >
                登出
              </SpinButton>
            </div>
          </aside>
        </div>
      )}

      {/* min-w-0：允許 main 在 flex row 內收縮，寬表才會在自己的 overflow-x-auto 容器內出現水平捲軸，而非把整頁撐爆 */}
      <main className="flex min-w-0 flex-1 flex-col">
        {tenant?.status === "trial" && <TrialBanner tenant={tenant} />}
        {branchUser && !(pathname ?? "").startsWith("/wms/inbound") && (
          <InboundReminderBanner count={inboundCount} />
        )}
        {children}
      </main>
    </div>
    </ReleaseNotesProvider>
  );
}

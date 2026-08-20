"use client";

import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession, loginPath } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import PullToRefresh from "@/components/PullToRefresh";
import CampaignCard, { type CampaignSummary } from "@/components/CampaignCard";
import Countdown from "@/components/Countdown";
import ShopBannerCarousel from "@/components/ShopBannerCarousel";
import { cleanCampaignText } from "@/lib/text";
import { setCampaignHints } from "@/lib/campaignHints";

type SortKey = "new" | "hot" | "recent";
/** 商城的兩個世界：一般團購（暖玫瑰）/ 漂漂館（夢幻紫）。 */
type WorldKey = "group" | "piaopiao";

/** 漂漂館公開清單（piaopiao-api list_public_campaigns，免登入）回的欄位 */
type PiaoCampaign = {
  id: number;
  name: string;
  cover_image_url: string | null;
  end_at: string | null;
  min_price: number;
  max_price: number;
};

/**
 * 模組層快取：client 端 SPA 導航（/shop ↔ /shop/c/[id]）期間都存活，
 * 「進詳情再返回」時列表瞬間還原（資料 + 排序 + 捲動位置）——不 remount
 * 重抓、不閃 skeleton、不歸零。整頁 hard reload 才清空（屆時本就該抓新）。
 *
 * 為何不是 next.config 的 staleTimes：那只快取 server payload，不保留
 * client 端 useState；返回仍會 remount→useEffect 重抓，治不了這個症狀。
 */
type ShopCache = {
  campaigns: CampaignSummary[];
  sortBy: SortKey;
  world: WorldKey;
  scrollY: number;
  pendingPickupCount: number;
  ts: number;
};
let shopCache: ShopCache | null = null;
// 漂漂館清單另一份快取（免登入公開 API，第一次切到該分頁才抓）
let piaoCache: { items: PiaoCampaign[]; ts: number } | null = null;
// 返回時若資料已超過這個毫秒數，背景靜默重抓（不擋畫面、不動捲動）。
const SHOP_REVALIDATE_MS = 60_000;

// useLayoutEffect 在 SSR/prerender 會噪 warning；只有 client 端用它，
// 才能在 paint 前還原捲動（避免先閃到頂端再跳）。
const useIsoLayoutEffect =
  typeof window !== "undefined" ? useLayoutEffect : useEffect;

export default function ShopPage() {
  const router = useRouter();
  const [campaigns, setCampaigns] = useState<CampaignSummary[]>(() => {
    const cached = shopCache?.campaigns ?? [];
    // 同步 hint 給詳情頁預填 (從快取還原時也要塞回 hint Map)
    if (cached.length > 0) setCampaignHints(cached);
    return cached;
  });
  const [pendingPickupCount, setPendingPickupCount] = useState<number>(
    () => shopCache?.pendingPickupCount ?? 0,
  );
  const [loading, setLoading] = useState(() => shopCache == null);
  const [err, setErr] = useState<string | null>(null);
  const [sortBy, setSortBy] = useState<SortKey>(
    () => shopCache?.sortBy ?? "new",
  );
  const [world, setWorld] = useState<WorldKey>(() => shopCache?.world ?? "group");
  const [query, setQuery] = useState("");
  const [piaoItems, setPiaoItems] = useState<PiaoCampaign[]>(
    () => piaoCache?.items ?? [],
  );
  const [piaoLoading, setPiaoLoading] = useState(false);
  const [piaoErr, setPiaoErr] = useState<string | null>(null);

  const fetchCampaigns = useCallback(
    async (silent = false) => {
      const s = getSession();
      if (!s || !s.memberId) {
        router.replace(loginPath());
        return;
      }
      if (!silent) setErr(null);
      try {
        const d = await callLiffApi<{ campaigns: CampaignSummary[]; pending_pickup_count?: number }>(
          s.token,
          { action: "list_active_campaigns" },
        );
        setCampaigns(d.campaigns);
        setCampaignHints(d.campaigns);
        const pickupCount = d.pending_pickup_count ?? 0;
        setPendingPickupCount(pickupCount);
        shopCache = {
          campaigns: d.campaigns,
          sortBy: shopCache?.sortBy ?? "new",
          world: shopCache?.world ?? "group",
          scrollY: shopCache?.scrollY ?? 0,
          pendingPickupCount: pickupCount,
          ts: Date.now(),
        };
      } catch (e) {
        // 背景重抓失敗時不蓋掉已顯示的快取內容
        if (!silent) setErr(e instanceof Error ? e.message : String(e));
      }
    },
    [router],
  );

  // 漂漂館清單：免登入公開 API（同 /piaopiao 獨立入口那支）
  const fetchPiao = useCallback(async (silent = false) => {
    const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
    if (!base) {
      setPiaoErr("系統尚未設定連線");
      return;
    }
    if (!silent) setPiaoErr(null);
    try {
      const res = await fetch(`${base}/functions/v1/piaopiao-api`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "list_public_campaigns" }),
      });
      const body = await res.json();
      if (!res.ok) throw new Error((body as { error?: string }).error || "讀取失敗");
      const items = (body as { campaigns: PiaoCampaign[] }).campaigns;
      setPiaoItems(items);
      piaoCache = { items, ts: Date.now() };
    } catch (e) {
      if (!silent) setPiaoErr(e instanceof Error ? e.message : String(e));
    }
  }, []);

  // 切到漂漂館世界才抓（首次顯示 skeleton；快取偏舊就背景靜默更新）
  useEffect(() => {
    if (shopCache) shopCache.world = world;
    if (world !== "piaopiao") return;
    if (piaoCache == null) {
      setPiaoLoading(true);
      void fetchPiao().finally(() => setPiaoLoading(false));
    } else if (Date.now() - piaoCache.ts > SHOP_REVALIDATE_MS) {
      void fetchPiao(true);
    }
  }, [world, fetchPiao]);

  // 首次進站才抓 + 顯示 skeleton；從詳情返回時用快取瞬間還原，
  // 只有資料偏舊才背景靜默更新。
  useEffect(() => {
    consumeFragmentToSession();
    if (shopCache == null) {
      (async () => {
        await fetchCampaigns();
        setLoading(false);
      })();
    } else if (Date.now() - shopCache.ts > SHOP_REVALIDATE_MS) {
      void fetchCampaigns(true);
    }
  }, [fetchCampaigns]);

  // 返回時把捲動位置還原到離開前（paint 前做，無閃動）。
  useIsoLayoutEffect(() => {
    if (shopCache && shopCache.campaigns.length > 0) {
      window.scrollTo(0, shopCache.scrollY);
    }
  }, []);

  // 持續記錄捲動位置與排序，供下次返回還原。
  useEffect(() => {
    const onScroll = () => {
      if (shopCache) shopCache.scrollY = window.scrollY;
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    if (shopCache) shopCache.sortBy = sortBy;
  }, [sortBy]);

  // 前端防線：擋掉內部 sentinel 活動（campaign_no 以 __ 開頭，如
  // __INTERNAL_RESTOCK__「【內部】補貨申請」）。後端 liff-api 也有濾，
  // 這層確保即使 edge function 還沒部署也不會外漏給顧客。
  const visible = campaigns.filter((c) => !c.campaign_no.startsWith("__"));

  // 置頂 banner 分組規則：
  // - 兩個類別同時有 → 群組顯示（每類一張總覽 banner，連到該專區）
  // - 只有一個類別有  → 攤平該類別（每團一張 banner，連到該團）
  // ShopBannerCarousel 已內建 4s 輪詢。
  const foodTrains = visible.filter((c) => c.close_type === "food_train");
  const flashes = visible.filter((c) =>
    c.close_type === "fast"
    || c.close_type === "limited"
    || (Number(c.total_cap_qty ?? 0) > 0 && c.close_type !== "food_train")
    || (c.has_item_cap === true && c.close_type !== "food_train"),
  );
  const groupMode = foodTrains.length > 0 && flashes.length > 0;

  // 排序：最新(id 大→小，無 created_at 用 id 近似) / 最熱銷(全分店訂單數)
  // / 近期售出(近 7 天訂單數)。tie-break 回退 id desc 保持穩定。
  const sorted = [...visible].sort((a, b) => {
    if (sortBy === "hot") return (b.order_count - a.order_count) || (b.id - a.id);
    if (sortBy === "recent") return (b.recent_order_count - a.recent_order_count) || (b.id - a.id);
    return b.id - a.id;
  });

  // 搜尋：對當前世界的清單做前端過濾（清單本來就整批在手上，不用打 API）
  const q = query.trim().toLowerCase();
  const searching = q !== "";
  const matchName = (name: string) =>
    !searching
    || cleanCampaignText(name).toLowerCase().includes(q)
    || name.toLowerCase().includes(q);
  const shown = sorted.filter((c) => matchName(c.name));
  const shownPiao = piaoItems.filter((c) => matchName(c.name));

  const headerContent = (
    <div className="space-y-2.5">
      {/* 搜尋列（取代原本的「商品」大標題，momo 式頂欄） */}
      <div className="flex items-center gap-2.5">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src="/brand/logo.jpg"
          alt=""
          aria-hidden
          className="h-9 w-9 shrink-0 rounded-full object-cover shadow-[0_2px_8px_-2px_var(--brand-glow)] ring-1 ring-white/70"
        />
        <div className="relative flex-1">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth={2.2}
            className="pointer-events-none absolute left-3.5 top-1/2 h-[17px] w-[17px] -translate-y-1/2 text-[var(--brand)]"
            aria-hidden
          >
            <circle cx="11" cy="11" r="7" />
            <path strokeLinecap="round" d="m20 20-3.2-3.2" />
          </svg>
          {/* text-[16px]：iPhone 點輸入框不觸發自動縮放的下限 */}
          <input
            type="text"
            inputMode="search"
            enterKeyHint="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={world === "piaopiao" ? "搜尋漂漂館商品" : "搜尋團購商品"}
            className="h-10 w-full appearance-none rounded-full border border-[color-mix(in_srgb,var(--brand)_35%,transparent)] bg-white/90 pl-10 pr-9 text-[16px] text-[var(--foreground)] shadow-[0_2px_10px_-4px_var(--brand-glow)] outline-none transition-colors placeholder:text-[var(--tertiary-label)] focus:border-[var(--brand)]"
          />
          {query !== "" && (
            <button
              type="button"
              onClick={() => setQuery("")}
              aria-label="清除搜尋"
              className="absolute right-2.5 top-1/2 flex h-6 w-6 -translate-y-1/2 items-center justify-center rounded-full bg-[var(--ios-gray)]/70 text-[12px] font-bold text-white"
            >
              ✕
            </button>
          )}
        </div>
      </div>
      {/* 世界分頁：切換整站配色跟著換（data-world → globals.css 變數組） */}
      <div className="flex items-end gap-6 px-1">
        {([
          ["group", "團購商品", "💕"],
          ["piaopiao", "漂漂館", "🫧"],
        ] as const).map(([key, label, emoji]) => {
          const active = world === key;
          return (
            <button
              key={key}
              type="button"
              onClick={() => setWorld(key)}
              className={`relative pb-1.5 transition-all duration-200 ${
                active
                  ? "text-[19px] font-bold text-[var(--brand-strong)]"
                  : "text-[17px] font-medium text-[var(--secondary-label)]"
              }`}
            >
              {label} {emoji}
              <span
                className={`absolute inset-x-1 bottom-0 h-[3px] rounded-full brand-gradient transition-opacity duration-200 ${
                  active ? "opacity-100" : "opacity-0"
                }`}
                aria-hidden
              />
            </button>
          );
        })}
      </div>
    </div>
  );

  return (
    <PageShell
      world={world === "piaopiao" ? "piaopiao" : "main"}
      headerContent={headerContent}
    >
      <PullToRefresh onRefresh={world === "piaopiao" ? fetchPiao : fetchCampaigns}>
      <div className="space-y-5 px-4 pt-3 pb-6">
        {world === "piaopiao" ? (
          <PiaoWorld
            loading={piaoLoading}
            err={piaoErr}
            items={shownPiao}
            searching={searching}
            query={query.trim()}
          />
        ) : (
        <>
        {loading && (
          <div className="space-y-5">
            <div className="aspect-[16/8] w-full animate-pulse rounded-2xl bg-[var(--brand-soft)]/60" />
            <div className="grid grid-cols-2 gap-3">
              {[0, 1, 2, 3].map((i) => (
                <div key={i} className="card overflow-hidden">
                  <div className="aspect-square w-full animate-pulse bg-[var(--brand-soft)]/50" />
                  <div className="space-y-2 p-3">
                    <div className="h-3.5 w-4/5 animate-pulse rounded bg-black/5" />
                    <div className="h-5 w-1/2 animate-pulse rounded bg-black/5" />
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {err && (
          <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[15px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && visible.length === 0 && (
          <div className="flex flex-col items-center py-20 text-center">
            <div
              className="flex h-24 w-24 items-center justify-center rounded-full text-5xl"
              style={{
                background:
                  "linear-gradient(135deg, var(--brand-soft) 0%, #fff4f6 100%)",
              }}
            >
              🛒
            </div>
            <p className="mt-4 text-[17px] font-semibold text-[var(--foreground)]">
              目前沒有進行中的團購
            </p>
            <p className="mt-1 text-[14px] text-[var(--secondary-label)]">
              下拉重新整理，新團開跑會在這裡出現
            </p>
          </div>
        )}

        {/* 取貨提醒條 — 該會員有 status='ready' 的訂單時才出現（搜尋中讓位給結果） */}
        {!searching && pendingPickupCount > 0 && (
          <Link
            href="/orders"
            className="flex items-center gap-3 rounded-2xl bg-amber-50 px-4 py-3 text-amber-900 shadow-[0_2px_8px_-4px_rgba(245,158,11,0.4)] active:opacity-80 dark:bg-amber-950 dark:text-amber-100"
          >
            <span className="text-[20px]">🎁</span>
            <span className="flex-1 text-[15px] font-semibold">
              你有 {pendingPickupCount} 筆訂單可取貨
            </span>
            <span className="text-[20px] text-amber-700/70 dark:text-amber-300/70">›</span>
          </Link>
        )}

        {/* 主題 banner 跑馬燈 — 兩類同時有就群組總覽, 只有一類就攤平每團一張, auto-play 4s */}
        {!searching && (
        <ShopBannerCarousel
          banners={
            groupMode
              ? [
                  {
                    key: "food_train_stack",
                    node: <FoodTrainStackBanner campaigns={foodTrains} />,
                  },
                  {
                    key: "flash_group",
                    node: <FlashGroupBanner hero={flashes[0]} />,
                  },
                ]
              : foodTrains.length > 0
                ? foodTrains.map((c) => ({
                    key: `food_train_${c.id}`,
                    node: <FoodTrainItemBanner campaign={c} />,
                  }))
                : flashes.map((c) => ({
                    key: `flash_${c.id}`,
                    node: <FlashItemBanner campaign={c} />,
                  }))
          }
        />
        )}

        {/* 團購商品 + 排序（分頁標籤已經寫著「團購商品」，這裡只留排序＋數量） */}
        {visible.length > 0 && (
          <section>
            <div className="flex items-center justify-between gap-2 px-1 pb-3">
              <div className="flex gap-2">
                {([
                  ["new", "最新"],
                  ["hot", "最熱銷"],
                  ["recent", "近期售出"],
                ] as const).map(([v, label]) => {
                  const active = sortBy === v;
                  return (
                    <button
                      key={v}
                      onClick={() => setSortBy(v)}
                      className={`rounded-full px-4 py-1.5 text-[14px] transition-colors ${
                        active
                          ? "brand-gradient font-bold text-white shadow-[0_6px_14px_-6px_var(--brand-glow)]"
                          : "border border-[var(--separator)] bg-[var(--card-bg)] font-medium text-[var(--secondary-label)] active:bg-[var(--brand-soft)]/40"
                      }`}
                    >
                      {label}
                    </button>
                  );
                })}
              </div>
              <span className="shrink-0 text-[13px] font-medium text-[var(--secondary-label)]">
                {shown.length} 團
              </span>
            </div>
            {searching && shown.length === 0 ? (
              <SearchEmpty query={query.trim()} />
            ) : (
              <div className="grid grid-cols-2 gap-3">
                {shown.map((c, i) => (
                  <div
                    key={c.id}
                    className="animate-in"
                    style={{ animationDelay: `${Math.min(i, 8) * 55}ms` }}
                  >
                    <CampaignCard campaign={c} />
                  </div>
                ))}
              </div>
            )}
          </section>
        )}
        </>
        )}
      </div>
      </PullToRefresh>
    </PageShell>
  );
}

/** 搜尋無結果（兩個世界共用；顏色吃當下世界的變數） */
function SearchEmpty({ query }: { query: string }) {
  return (
    <div className="flex flex-col items-center py-16 text-center">
      <div
        className="flex h-20 w-20 items-center justify-center rounded-full text-4xl"
        style={{
          background:
            "linear-gradient(135deg, var(--brand-soft) 0%, var(--card-bg) 100%)",
        }}
      >
        🔍
      </div>
      <p className="mt-4 text-[17px] font-semibold text-[var(--foreground)]">
        找不到「{query}」相關商品
      </p>
      <p className="mt-1 text-[14px] text-[var(--secondary-label)]">
        換個關鍵字試試看
      </p>
    </div>
  );
}

/** 漂漂館世界的內容區（清單卡連到 /piaopiao/c/[id]，沿用既有詳情頁） */
function PiaoWorld({
  loading,
  err,
  items,
  searching,
  query,
}: {
  loading: boolean;
  err: string | null;
  items: PiaoCampaign[];
  searching: boolean;
  query: string;
}) {
  return (
    <>
      {/* 世界門面 hero — 紫色漸層，強化「換了一個世界」的第一眼 */}
      {!searching && (
        <div className="animate-in relative overflow-hidden rounded-2xl brand-gradient p-5 text-white shadow-[0_10px_28px_-10px_var(--brand-glow)]">
          <div
            className="pointer-events-none absolute -right-8 -top-10 h-32 w-32 rounded-full bg-white/20 blur-2xl"
            aria-hidden
          />
          <div
            className="pointer-events-none absolute bottom-1 right-4 text-[46px] opacity-35"
            aria-hidden
          >
            🫧
          </div>
          <div className="text-[13px] font-medium text-white/85">獨立選物專區</div>
          <div className="mt-0.5 text-[26px] font-bold tracking-wide">漂漂館 ✨</div>
          <div className="mt-1 text-[13px] text-white/85">
            商品由漂漂館嚴選上架・訂單與取貨照原系統處理
          </div>
        </div>
      )}

      {loading && (
        <div className="grid grid-cols-2 gap-3">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="card overflow-hidden">
              <div className="aspect-square w-full animate-pulse bg-[var(--brand-soft)]/50" />
              <div className="space-y-2 p-3">
                <div className="h-3.5 w-4/5 animate-pulse rounded bg-black/5" />
                <div className="h-5 w-1/2 animate-pulse rounded bg-black/5" />
              </div>
            </div>
          ))}
        </div>
      )}

      {err && (
        <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[15px] text-[#c4271d]">
          {err}
        </div>
      )}

      {!loading && !err && items.length === 0 && (
        searching ? (
          <SearchEmpty query={query} />
        ) : (
          <div className="flex flex-col items-center py-16 text-center">
            <div
              className="flex h-24 w-24 items-center justify-center rounded-full text-5xl"
              style={{
                background:
                  "linear-gradient(135deg, var(--brand-soft) 0%, var(--card-bg) 100%)",
              }}
            >
              🫧
            </div>
            <p className="mt-4 text-[17px] font-semibold text-[var(--foreground)]">
              目前沒有進行中的漂漂館商品
            </p>
            <p className="mt-1 text-[14px] text-[var(--secondary-label)]">
              下拉重新整理，新商品上架會在這裡出現
            </p>
          </div>
        )
      )}

      {items.length > 0 && (
        <section>
          <div className="flex items-baseline justify-between px-1 pb-2.5">
            <h2 className="text-[17px] font-bold text-[var(--foreground)]">
              {searching ? "搜尋結果" : "漂漂館商品"}
            </h2>
            <span className="text-[13px] font-medium text-[var(--secondary-label)]">
              {items.length} 檔
            </span>
          </div>
          <div className="grid grid-cols-2 gap-3">
            {items.map((c, i) => (
              <div
                key={c.id}
                className="animate-in"
                style={{ animationDelay: `${Math.min(i, 8) * 55}ms` }}
              >
                <PiaoCard item={c} />
              </div>
            ))}
          </div>
        </section>
      )}
    </>
  );
}

/** 漂漂館商品卡：欄位比團購卡少（公開 API 只回名稱/圖/價/結單），
 *  視覺對齊 CampaignCard 的 grid 卡，價格吃世界漸層（紫）。 */
function PiaoCard({ item }: { item: PiaoCampaign }) {
  const priceText = item.min_price > 0
    ? `$${item.min_price.toLocaleString()}${item.max_price > item.min_price ? " 起" : ""}`
    : "—";
  return (
    <Link
      href={`/piaopiao/c/${item.id}`}
      className="card block overflow-hidden transition-transform duration-200 active:scale-[0.97]"
    >
      <div className="relative aspect-square w-full">
        {item.cover_image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={item.cover_image_url}
            alt=""
            className="absolute inset-0 h-full w-full object-cover"
          />
        ) : (
          <div
            className="absolute inset-0 flex items-center justify-center text-4xl"
            style={{
              background:
                "linear-gradient(135deg, var(--brand-soft) 0%, var(--card-bg) 100%)",
            }}
          >
            🫧
          </div>
        )}
      </div>
      <div className="space-y-1 px-3 py-2.5">
        <h3 className="line-clamp-2 min-h-[2.6em] text-[16px] font-semibold leading-tight text-[var(--foreground)]">
          {cleanCampaignText(item.name)}
        </h3>
        <div className="brand-gradient-text text-[24px] font-extrabold tabular-nums leading-none">
          {priceText}
        </div>
        {item.end_at && (
          <div className="inline-flex items-center gap-1 rounded-md bg-[var(--brand-soft)] px-1.5 py-0.5 text-[12px] font-semibold tabular-nums text-[var(--brand-strong)]">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.2} className="h-3 w-3 shrink-0">
              <circle cx="12" cy="12" r="9" />
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 7.5V12l3 2" />
            </svg>
            <Countdown target={item.end_at} compact />
          </div>
        )}
      </div>
    </Link>
  );
}

function priceText(c: CampaignSummary): string {
  if (c.min_price <= 0) return "—";
  return `$${c.min_price.toLocaleString()}${c.max_price > c.min_price ? " 起" : ""}`;
}

/**
 * 美食列車群組 banner — 把多團美食列車輪詢顯示在同一張 banner 內。
 * 每 3.5s 切下一團, 封面用淡入淡出, 底部 dots 指示目前是第幾團。
 * 點整張卡 → 進「當下顯示」那團的詳情頁 (像蝦皮商城內部 banner)。
 *
 * 只有 1 團時不開輪詢, 也不畫 dots, 退化成靜態 banner。
 */
function FoodTrainStackBanner({ campaigns }: { campaigns: CampaignSummary[] }) {
  const [idx, setIdx] = useState(0);

  useEffect(() => {
    if (campaigns.length <= 1) return;
    const id = setInterval(() => {
      setIdx((i) => (i + 1) % campaigns.length);
    }, 3500);
    return () => clearInterval(id);
  }, [campaigns.length]);

  // campaigns 長度變動時 (背景 revalidate) 把 idx 拉回合法範圍
  const safeIdx = Math.min(idx, campaigns.length - 1);
  const current = campaigns[safeIdx];
  if (!current) return null;

  return (
    <Link
      href="/shop/food-train"
      className="block overflow-hidden rounded-2xl shadow-[0_10px_28px_-10px_rgba(5,150,105,0.5)] transition-transform duration-200 active:scale-[0.985]"
    >
      <div className="relative aspect-[16/8] w-full bg-gradient-to-br from-emerald-500 via-emerald-600 to-teal-700">
        {/* 各團封面疊在一起 crossfade, 當前那張顯示, 其他全透明 */}
        {campaigns.map((c, i) =>
          c.cover_image_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              key={c.id}
              src={c.cover_image_url}
              alt=""
              className={`absolute inset-0 h-full w-full object-cover transition-opacity duration-700 ${
                i === safeIdx ? "opacity-55" : "opacity-0"
              }`}
            />
          ) : null,
        )}

        {/* 暗化 + 光暈 — 讓白字在任何封面上都讀得清 */}
        <div className="absolute inset-0 bg-gradient-to-t from-emerald-950/70 via-emerald-900/15 to-transparent" />
        <div className="absolute inset-0 bg-[radial-gradient(120%_80%_at_100%_0%,rgba(255,255,255,0.3)_0%,transparent_55%)]" />

        <div className="absolute inset-0 flex flex-col justify-between p-4">
          <div className="flex items-start justify-between gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-emerald-700/55 px-3 py-1 shadow-sm backdrop-blur">
              <span className="text-[15px]">🚂</span>
              <span className="text-[14px] font-bold text-white">美食列車</span>
            </span>
            {current.end_at && (
              <span className="rounded-full bg-black/45 px-2.5 py-1 text-[12px] font-semibold tabular-nums text-white backdrop-blur">
                <Countdown target={current.end_at} compact />
              </span>
            )}
          </div>

          <div className="space-y-1">
            <div className="text-[12px] font-medium text-white/85">
              {campaigns.length > 1
                ? `嚴選美食 · ${campaigns.length} 團熱賣中`
                : "嚴選美食 · 限時開團"}
            </div>
            <div className="line-clamp-1 text-[18px] font-bold text-white drop-shadow">
              {cleanCampaignText(current.name)}
            </div>
            <div className="flex items-end justify-between gap-2">
              <div className="text-[24px] font-extrabold tabular-nums text-white drop-shadow leading-none">
                {priceText(current)}
              </div>
              {campaigns.length > 1 && (
                <div className="flex items-center gap-1.5 pb-1">
                  {campaigns.map((c, i) => (
                    <span
                      key={c.id}
                      aria-hidden
                      className={`h-1.5 rounded-full transition-all duration-300 ${
                        i === safeIdx ? "w-5 bg-white" : "w-1.5 bg-white/55"
                      }`}
                    />
                  ))}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </Link>
  );
}

function FlashGroupBanner({ hero }: { hero: CampaignSummary }) {
  return (
    <Link
      href="/shop/flash"
      className="block overflow-hidden rounded-2xl shadow-[0_10px_28px_-10px_rgba(158,47,80,0.5)] transition-transform duration-200 active:scale-[0.985]"
    >
      <div className="relative aspect-[16/8] w-full brand-gradient">
        {hero.cover_image_url && (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={hero.cover_image_url}
            alt=""
            className="absolute inset-0 h-full w-full object-cover opacity-35 mix-blend-overlay"
          />
        )}
        <div className="absolute inset-0 bg-[radial-gradient(120%_80%_at_100%_0%,rgba(255,255,255,0.35)_0%,transparent_55%)]" />
        <div className="absolute inset-0 flex flex-col justify-between p-4">
          <div className="flex items-center gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-white/22 px-3 py-1 backdrop-blur">
              <span className="text-[16px]">⚡</span>
              <span className="text-[16px] font-bold text-white">限時專區</span>
            </span>
          </div>
          <div className="space-y-0.5">
            <div className="text-[13px] font-medium text-white/90">最快結單 · 手刀搶</div>
            <div className="text-[26px] font-bold tabular-nums text-white drop-shadow">
              {hero.end_at ? <Countdown target={hero.end_at} compact /> : "—"}
            </div>
          </div>
        </div>
        <div className="absolute right-4 top-1/2 -translate-y-1/2 text-[28px] text-white/85">›</div>
      </div>
    </Link>
  );
}

function FoodTrainItemBanner({ campaign }: { campaign: CampaignSummary }) {
  return (
    <Link
      href={`/shop/c/${campaign.id}`}
      className="block overflow-hidden rounded-2xl shadow-[0_10px_28px_-10px_rgba(5,150,105,0.5)] transition-transform duration-200 active:scale-[0.985]"
    >
      <div className="relative aspect-[16/8] w-full bg-gradient-to-br from-emerald-500 via-emerald-600 to-teal-600">
        {campaign.cover_image_url && (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={campaign.cover_image_url}
            alt=""
            className="absolute inset-0 h-full w-full object-cover opacity-55"
          />
        )}
        <div className="absolute inset-0 bg-gradient-to-t from-emerald-950/75 via-emerald-900/15 to-transparent" />
        <div className="absolute inset-0 flex flex-col justify-between p-4">
          <div className="flex items-center gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-emerald-600/85 px-3 py-1 shadow-sm backdrop-blur">
              <span className="text-[15px]">🚂</span>
              <span className="text-[14px] font-bold text-white">美食列車</span>
            </span>
          </div>
          <div className="flex items-end justify-between gap-3">
            <div className="min-w-0 flex-1">
              <div className="line-clamp-1 text-[17px] font-bold text-white drop-shadow">
                {cleanCampaignText(campaign.name)}
              </div>
              <div className="text-[24px] font-extrabold tabular-nums text-white drop-shadow">
                {priceText(campaign)}
              </div>
            </div>
            {campaign.end_at && (
              <div className="shrink-0 rounded-full bg-black/35 px-2.5 py-1 text-[13px] font-semibold tabular-nums text-white backdrop-blur">
                <Countdown target={campaign.end_at} compact />
              </div>
            )}
          </div>
        </div>
      </div>
    </Link>
  );
}

function FlashItemBanner({ campaign }: { campaign: CampaignSummary }) {
  return (
    <Link
      href={`/shop/c/${campaign.id}`}
      className="block overflow-hidden rounded-2xl shadow-[0_10px_28px_-10px_rgba(158,47,80,0.5)] transition-transform duration-200 active:scale-[0.985]"
    >
      <div className="relative aspect-[16/8] w-full brand-gradient">
        {campaign.cover_image_url && (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={campaign.cover_image_url}
            alt=""
            className="absolute inset-0 h-full w-full object-cover opacity-55"
          />
        )}
        <div className="absolute inset-0 bg-gradient-to-t from-black/55 via-transparent to-transparent" />
        <div className="absolute inset-0 flex flex-col justify-between p-4">
          <div className="flex items-center gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-white/22 px-3 py-1 shadow-sm backdrop-blur">
              <span className="text-[15px]">⚡</span>
              <span className="text-[14px] font-bold text-white">限時</span>
            </span>
          </div>
          <div className="flex items-end justify-between gap-3">
            <div className="min-w-0 flex-1">
              <div className="line-clamp-1 text-[17px] font-bold text-white drop-shadow">
                {cleanCampaignText(campaign.name)}
              </div>
              <div className="text-[24px] font-extrabold tabular-nums text-white drop-shadow">
                {priceText(campaign)}
              </div>
            </div>
            {campaign.end_at && (
              <div className="shrink-0 rounded-full bg-black/35 px-2.5 py-1 text-[13px] font-semibold tabular-nums text-white backdrop-blur">
                <Countdown target={campaign.end_at} compact />
              </div>
            )}
          </div>
        </div>
      </div>
    </Link>
  );
}

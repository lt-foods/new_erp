"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import PullToRefresh from "@/components/PullToRefresh";
import CampaignCard, { type CampaignSummary } from "@/components/CampaignCard";
import Countdown from "@/components/Countdown";

export default function ShopPage() {
  const router = useRouter();
  const [campaigns, setCampaigns] = useState<CampaignSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [sortBy, setSortBy] = useState<"new" | "hot" | "recent">("new");

  const fetchCampaigns = useCallback(async () => {
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace("/");
      return;
    }
    setErr(null);
    try {
      const d = await callLiffApi<{ campaigns: CampaignSummary[] }>(s.token, {
        action: "list_active_campaigns",
      });
      setCampaigns(d.campaigns);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  }, [router]);

  useEffect(() => {
    consumeFragmentToSession();
    (async () => {
      await fetchCampaigns();
      setLoading(false);
    })();
  }, [fetchCampaigns]);

  // 前端防線：擋掉內部 sentinel 活動（campaign_no 以 __ 開頭，如
  // __INTERNAL_RESTOCK__「【內部】補貨申請」）。後端 liff-api 也有濾，
  // 這層確保即使 edge function 還沒部署也不會外漏給顧客。
  const visible = campaigns.filter((c) => !c.campaign_no.startsWith("__"));

  // 「限時專區」banner 只在真的有快閃團(close_type='fast')時才出現。
  // /shop/flash 那頁只撈 close_type='fast'，若這裡用 visible[0](任何團)
  // 當 hero，會出現 banner 但點進去是空的。清單已 by end_at asc 排序，
  // find 取到的就是最快結單的快閃團。
  const hero = visible.find((c) => c.close_type === "fast");

  // 排序：最新(id 大→小，無 created_at 用 id 近似) / 最熱銷(全分店訂單數)
  // / 近期售出(近 7 天訂單數)。tie-break 回退 id desc 保持穩定。
  const sorted = [...visible].sort((a, b) => {
    if (sortBy === "hot") return (b.order_count - a.order_count) || (b.id - a.id);
    if (sortBy === "recent") return (b.recent_order_count - a.recent_order_count) || (b.id - a.id);
    return b.id - a.id;
  });

  return (
    <PageShell title="商品">
      <PullToRefresh onRefresh={fetchCampaigns}>
      <div className="space-y-5 px-4 pt-3 pb-6">
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

        {/* 限時專區 banner */}
        {hero && (
          <Link
            href="/shop/flash"
            className="block overflow-hidden rounded-2xl shadow-[0_10px_28px_-10px_rgba(158,47,80,0.5)] transition-transform duration-200 active:scale-[0.985]"
          >
            <div className="relative">
              <div className="relative aspect-[16/8] w-full brand-gradient">
                {hero.cover_image_url && (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={hero.cover_image_url}
                    alt=""
                    className="absolute inset-0 h-full w-full object-cover opacity-35 mix-blend-overlay"
                  />
                )}
                {/* 光澤 */}
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
            </div>
          </Link>
        )}

        {/* 團購商品 + 排序 */}
        {visible.length > 0 && (
          <section>
            <div className="flex items-baseline justify-between px-1 pb-2.5">
              <h2 className="text-[22px] font-bold tracking-tight text-[var(--foreground)]">
                團購商品 💕
              </h2>
              <span className="text-[13px] font-medium text-[var(--secondary-label)]">
                {visible.length} 團
              </span>
            </div>
            <div className="flex gap-2 px-1 pb-3">
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
                        ? "brand-gradient font-bold text-white shadow-[0_6px_14px_-6px_rgba(158,47,80,0.6)]"
                        : "border border-[var(--separator)] bg-[var(--card-bg)] font-medium text-[var(--secondary-label)] active:bg-[var(--brand-soft)]/40"
                    }`}
                  >
                    {label}
                  </button>
                );
              })}
            </div>
            <div className="grid grid-cols-2 gap-3">
              {sorted.map((c, i) => (
                <div
                  key={c.id}
                  className="animate-in"
                  style={{ animationDelay: `${Math.min(i, 8) * 55}ms` }}
                >
                  <CampaignCard campaign={c} />
                </div>
              ))}
            </div>
          </section>
        )}
      </div>
      </PullToRefresh>
    </PageShell>
  );
}

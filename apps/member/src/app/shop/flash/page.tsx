"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import CampaignCard, {
  campaignBadgeLabel,
  campaignRemaining,
  campaignSoldOut,
  type CampaignSummary,
} from "@/components/CampaignCard";
import Countdown from "@/components/Countdown";

export default function FlashPage() {
  const router = useRouter();
  const [campaigns, setCampaigns] = useState<CampaignSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace("/");
      return;
    }
    (async () => {
      try {
        const d = await callLiffApi<{ campaigns: CampaignSummary[] }>(s.token, {
          action: "list_active_campaigns",
          close_type: "fast",
        });
        // 已 sort by end_at asc 從 backend, 就直接用
        setCampaigns(d.campaigns);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  const hero = campaigns[0];

  return (
    <PageShell title="限時專區">
      {/* 結束於 sticky banner */}
      {hero && hero.end_at && (
        <div className="sticky top-[78px] z-10 -mt-1 flex items-center justify-between gap-3 bg-gradient-to-r from-[#ff3b30] to-[#ff9500] px-4 py-2.5 text-white shadow">
          <div className="text-[15px] font-medium">最快結束於</div>
          <div className="text-[20px] font-bold">
            <Countdown target={hero.end_at} compact className="text-white" />
          </div>
        </div>
      )}

      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && (
          <p className="px-1 text-[16px] text-[var(--tertiary-label)]">載入中…</p>
        )}

        {err && (
          <div className="rounded-2xl bg-[#ff3b30]/10 p-3 text-[15px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && campaigns.length === 0 && (
          <div className="overflow-hidden rounded-2xl bg-gradient-to-br from-[#ff3b30]/8 to-[#ff9500]/8 p-6 text-center">
            <div className="text-5xl">📣</div>
            <h2 className="mt-3 text-[18px] font-semibold text-[var(--foreground)]">
              目前沒有快團
            </h2>
            <p className="mt-2 whitespace-pre-line text-[15px] leading-relaxed text-[var(--secondary-label)]">
              店長正在挑下一波熱門商品中{"\n"}快團一上架會即時通知你
            </p>
            <a
              href="/shop"
              className="mt-5 inline-block rounded-full bg-[var(--brand-strong)] px-5 py-2 text-[15px] font-medium text-white active:opacity-80"
            >
              先看看其他商品 →
            </a>
          </div>
        )}

        {hero && (
          <CampaignCard campaign={hero} variant="hero" />
        )}

        {campaigns.slice(1).map((c) => (
          <FlashRow key={c.id} campaign={c} />
        ))}
      </div>
    </PageShell>
  );
}

/** 限時專區的橫向 row(像第三張截圖蝦皮樣式) */
function FlashRow({ campaign }: { campaign: CampaignSummary }) {
  const priceText = campaign.min_price > 0
    ? `$${campaign.min_price.toLocaleString()}${campaign.max_price > campaign.min_price ? " 起" : ""}`
    : "—";
  const label = campaignBadgeLabel(campaign);
  const isLimited = label?.includes("限量");
  const remaining = campaignRemaining(campaign);
  const soldOut = campaignSoldOut(campaign);

  return (
    <a
      href={`/shop/c/${campaign.id}`}
      className={`flex gap-3 overflow-hidden rounded-2xl bg-[var(--card-bg)] p-3 shadow-[0_1px_2px_rgba(0,0,0,0.04)] active:opacity-90 ${
        soldOut ? "opacity-60" : ""
      }`}
    >
      <div className="relative h-24 w-24 flex-shrink-0 overflow-hidden rounded-xl bg-[#7676801a]">
        {campaign.cover_image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={campaign.cover_image_url}
            alt=""
            className="absolute inset-0 h-full w-full object-cover"
          />
        ) : (
          <div className="absolute inset-0 flex items-center justify-center text-3xl">📦</div>
        )}
        {soldOut ? (
          <span className="absolute left-1 top-1 rounded bg-zinc-700 px-1.5 py-0.5 text-[11px] font-medium text-white shadow">
            已搶購一空
          </span>
        ) : label ? (
          <span
            className={`absolute left-1 top-1 rounded px-1.5 py-0.5 text-[11px] font-medium text-white shadow ${
              isLimited ? "bg-[#ff3b30]" : "bg-[#ff9500]"
            }`}
          >
            {label}
          </span>
        ) : null}
      </div>
      <div className="min-w-0 flex-1 space-y-1">
        <h3 className="line-clamp-2 text-[17px] font-semibold leading-tight text-[var(--foreground)]">
          {campaign.name}
        </h3>
        <div className="text-[24px] font-bold tabular-nums text-[var(--brand-strong)] leading-none">
          {priceText}
        </div>
        <div className="flex items-center justify-between gap-2 text-[13px] text-[var(--secondary-label)]">
          <span>
            共 {campaign.item_count} 項
            {isLimited && remaining !== null && !soldOut && (
              <span className="ml-2 font-medium text-[#c4271d]">· 剩 {remaining} 份</span>
            )}
          </span>
          {campaign.end_at && !soldOut && <Countdown target={campaign.end_at} />}
        </div>
      </div>
      <div className="flex items-center text-[var(--ios-gray)] text-[24px]">›</div>
    </a>
  );
}

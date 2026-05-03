"use client";

import Link from "next/link";
import Countdown from "./Countdown";

export type CampaignSummary = {
  id: number;
  campaign_no: string;
  name: string;
  description: string | null;
  cover_image_url: string | null;
  close_type: "regular" | "fast" | "limited" | string;
  total_cap_qty: number | null;
  end_at: string | null;
  pickup_deadline: string | null;
  item_count: number;
  min_price: number;
  max_price: number;
};

/** 依 close_type + end_at + total_cap_qty 算出短標籤 */
export function campaignBadgeLabel(c: CampaignSummary): string | null {
  const hasCap = (c.total_cap_qty ?? 0) > 0;
  const hasEnd = !!c.end_at;
  if (c.close_type === "fast" && hasCap) return "限量限時";
  if (c.close_type === "fast" || hasEnd) return "限時";
  if (c.close_type === "limited" || hasCap) return "限量";
  return null;
}

/**
 * 蝦皮風卡片 + Uber Eats 大字級。
 * variant=hero 用在限時專區頭一張(更大)、grid 用在列表。
 */
export default function CampaignCard({
  campaign,
  variant = "grid",
}: {
  campaign: CampaignSummary;
  variant?: "grid" | "hero";
}) {
  const href = `/shop/c/${campaign.id}`;
  const priceText = campaign.min_price > 0
    ? `$${campaign.min_price.toLocaleString()}${campaign.max_price > campaign.min_price ? " 起" : ""}`
    : "—";

  if (variant === "hero") {
    return (
      <Link
        href={href}
        className="block overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_2px_8px_rgba(0,0,0,0.08)] active:opacity-90"
      >
        <div className="relative aspect-[16/9] w-full bg-[#7676801a]">
          {campaign.cover_image_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={campaign.cover_image_url}
              alt=""
              className="absolute inset-0 h-full w-full object-cover"
            />
          ) : (
            <div className="absolute inset-0 flex items-center justify-center text-5xl">📦</div>
          )}
          {(() => {
            const label = campaignBadgeLabel(campaign);
            if (!label && !campaign.end_at) return null;
            const isLimited = label?.includes("限量");
            return (
              <div
                className={`absolute left-3 top-3 inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-[14px] font-medium text-white backdrop-blur ${
                  isLimited ? "bg-[#ff3b30]/80" : "bg-black/65"
                }`}
              >
                {label && <span>{label}</span>}
                {campaign.end_at && <Countdown target={campaign.end_at} compact />}
                {isLimited && campaign.total_cap_qty && (
                  <span className="text-[12px] opacity-90">· {campaign.total_cap_qty} 份</span>
                )}
              </div>
            );
          })()}
        </div>
        <div className="space-y-1.5 px-4 py-3">
          <h3 className="text-[22px] font-bold leading-tight text-[var(--foreground)]">
            {campaign.name}
          </h3>
          <div className="flex items-baseline justify-between gap-2">
            <span className="text-[28px] font-bold tabular-nums text-[var(--brand-strong)] leading-none">
              {priceText}
            </span>
            <span className="text-[13px] text-[var(--secondary-label)]">
              共 {campaign.item_count} 項
            </span>
          </div>
        </div>
      </Link>
    );
  }

  return (
    <Link
      href={href}
      className="block overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)] active:opacity-90"
    >
      <div className="relative aspect-square w-full bg-[#7676801a]">
        {campaign.cover_image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={campaign.cover_image_url}
            alt=""
            className="absolute inset-0 h-full w-full object-cover"
          />
        ) : (
          <div className="absolute inset-0 flex items-center justify-center text-4xl">📦</div>
        )}
      </div>
      <div className="space-y-1 px-3 py-2.5">
        <div className="flex items-center gap-1.5">
          {(() => {
            const label = campaignBadgeLabel(campaign);
            if (!label) return null;
            const isLimited = label.includes("限量");
            return (
              <span
                className={`shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium ${
                  isLimited ? "bg-[#ff3b30]/15 text-[#c4271d]" : "bg-[#ff9500]/15 text-[#9a5800]"
                }`}
              >
                {label}
              </span>
            );
          })()}
          <h3 className="line-clamp-2 min-w-0 flex-1 text-[17px] font-semibold leading-tight text-[var(--foreground)]">
            {campaign.name}
          </h3>
        </div>
        <div className="text-[24px] font-bold tabular-nums text-[var(--brand-strong)] leading-none">
          {priceText}
        </div>
        {campaign.end_at && (
          <div className="text-[13px] text-[var(--secondary-label)]">
            <Countdown target={campaign.end_at} />
          </div>
        )}
      </div>
    </Link>
  );
}

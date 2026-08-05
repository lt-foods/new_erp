"use client";

import Link from "next/link";
import Countdown from "./Countdown";
import ViewCount from "./ViewCount";
import { cleanCampaignText } from "@/lib/text";

export type CampaignSummary = {
  id: number;
  campaign_no: string;
  name: string;
  description: string | null;
  cover_image_url: string | null;
  close_type: "regular" | "fast" | "limited" | "food_train" | string;
  total_cap_qty: number | null;
  ordered_qty: number;
  /** 全分店訂單數（最熱銷排序用）。後端未部署前可能為 0。 */
  order_count: number;
  /** 近 7 天訂單數（近期售出排序用）。 */
  recent_order_count: number;
  /** 總瀏覽次數。後端未部署前可能沒有這個欄位（當 0 處理、不顯示）。 */
  view_count?: number;
  end_at: string | null;
  pickup_deadline: string | null;
  item_count: number;
  min_price: number;
  max_price: number;
};

/** 依 close_type + total_cap_qty 算出短標籤。
 *  「限時」只給真正的快閃團（close_type='fast'，即限時專區那種）。
 *  一般團幾乎都有結單日(end_at)，有結單日 ≠ 限時，否則每張卡都被貼標、
 *  標籤就失去意義（卡片本來就會單獨顯示倒數）。 */
export function campaignBadgeLabel(c: CampaignSummary): string | null {
  const hasCap = (c.total_cap_qty ?? 0) > 0;
  if (c.close_type === "food_train") return "美食列車";
  if (c.close_type === "fast" && hasCap) return "限量限時";
  if (c.close_type === "fast") return "限時";
  if (c.close_type === "limited" || hasCap) return "限量";
  return null;
}

/** 限量類活動還剩幾份;沒設 cap 回 null */
export function campaignRemaining(c: CampaignSummary): number | null {
  const cap = Number(c.total_cap_qty ?? 0);
  if (cap <= 0) return null;
  return Math.max(0, cap - Number(c.ordered_qty ?? 0));
}

export function campaignSoldOut(c: CampaignSummary): boolean {
  const cap = Number(c.total_cap_qty ?? 0);
  if (cap <= 0) return false;
  return Number(c.ordered_qty ?? 0) >= cap;
}

/** 沒有封面圖時的暖色品牌底（取代灰底 📦） */
function CoverFallback({ size }: { size: "sm" | "lg" }) {
  return (
    <div
      className="absolute inset-0 flex items-center justify-center"
      style={{
        background:
          "linear-gradient(135deg, var(--brand-soft) 0%, #fff4f6 55%, #ffffff 100%)",
      }}
    >
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="var(--brand)"
        strokeWidth={1.4}
        className={size === "lg" ? "h-14 w-14 opacity-70" : "h-10 w-10 opacity-70"}
      >
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          d="M5 8h14l-1 11a2 2 0 0 1-2 1.8H8A2 2 0 0 1 6 19L5 8Z"
        />
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          d="M9 8V6.5a3 3 0 0 1 6 0V8"
        />
      </svg>
    </div>
  );
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
        className="card block overflow-hidden transition-transform duration-200 active:scale-[0.985]"
      >
        <div className="relative aspect-[16/9] w-full">
          {campaign.cover_image_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={campaign.cover_image_url}
              alt=""
              className="absolute inset-0 h-full w-full object-cover"
            />
          ) : (
            <CoverFallback size="lg" />
          )}
          {(() => {
            const label = campaignBadgeLabel(campaign);
            const remaining = campaignRemaining(campaign);
            const soldOut = campaignSoldOut(campaign);
            if (!label && !campaign.end_at) return null;
            const isLimited = label?.includes("限量");
            const isFoodTrain = campaign.close_type === "food_train";
            return (
              <div
                className={`absolute left-3 top-3 inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-[14px] font-semibold text-white shadow-sm backdrop-blur ${
                  soldOut ? "bg-zinc-700/85"
                  : isFoodTrain ? "bg-emerald-600/95"
                  : isLimited ? "bg-[var(--ios-red)]/90"
                  : "bg-black/55"
                }`}
              >
                {soldOut ? (
                  <span>已搶購一空</span>
                ) : (
                  <>
                    {label && <span>{label}</span>}
                    {campaign.end_at && !isFoodTrain && <Countdown target={campaign.end_at} compact />}
                    {isLimited && remaining !== null && (
                      <span className="text-[12px] opacity-90">· 剩 {remaining} 份</span>
                    )}
                  </>
                )}
              </div>
            );
          })()}
        </div>
        <div className="space-y-1.5 px-4 py-3.5">
          <h3 className="text-[22px] font-bold leading-tight text-[var(--foreground)]">
            {cleanCampaignText(campaign.name)}
          </h3>
          <div className="flex items-baseline justify-between gap-2">
            <span className="brand-gradient-text text-[28px] font-extrabold tabular-nums leading-none">
              {priceText}
            </span>
            <span className="text-[13px] text-[var(--secondary-label)]">
              共 {campaign.item_count} 項
            </span>
          </div>
          <div className="flex items-center justify-between gap-2 text-[14px] font-medium text-[var(--secondary-label)]">
            <ViewCount count={campaign.view_count} />
            {campaign.ordered_qty > 0 && (
              <span className="ml-auto">
                已訂購 {campaign.ordered_qty.toLocaleString()} 件
              </span>
            )}
          </div>
        </div>
      </Link>
    );
  }

  return (
    <Link
      href={href}
      className="card block overflow-hidden transition-transform duration-200 active:scale-[0.97]"
    >
      <div className="relative aspect-square w-full">
        {campaign.cover_image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={campaign.cover_image_url}
            alt=""
            className="absolute inset-0 h-full w-full object-cover"
          />
        ) : (
          <CoverFallback size="sm" />
        )}
        {(() => {
          const label = campaignBadgeLabel(campaign);
          const soldOut = campaignSoldOut(campaign);
          if (soldOut) {
            return (
              <span className="absolute left-2 top-2 rounded-full bg-zinc-700/80 px-2 py-0.5 text-[11px] font-semibold text-white backdrop-blur">
                已搶購一空
              </span>
            );
          }
          if (!label) return null;
          const isLimited = label?.includes("限量");
          const isFoodTrain = campaign.close_type === "food_train";
          return (
            <span
              className={`absolute left-2 top-2 rounded-full px-2 py-0.5 text-[11px] font-semibold text-white shadow-sm backdrop-blur ${
                isFoodTrain ? "bg-emerald-600/95"
                : isLimited ? "bg-[var(--ios-red)]/90"
                : "bg-[var(--ios-orange)]/90"
              }`}
            >
              {label}
            </span>
          );
        })()}
      </div>
      <div className="space-y-1 px-3 py-2.5">
        <h3 className="line-clamp-2 min-h-[2.6em] text-[16px] font-semibold leading-tight text-[var(--foreground)]">
          {cleanCampaignText(campaign.name)}
        </h3>
        {(() => {
          const remaining = campaignRemaining(campaign);
          if (remaining === null || campaignSoldOut(campaign)) return null;
          return (
            <div className="inline-flex items-center rounded-full bg-[var(--ios-red)]/10 px-2 py-0.5 text-[12px] font-medium text-[#c4271d]">
              僅剩 {remaining} 份
            </div>
          );
        })()}
        <div className="flex items-baseline justify-between gap-2">
          <div className="brand-gradient-text text-[24px] font-extrabold tabular-nums leading-none">
            {priceText}
          </div>
          {/* 已訂購 / 瀏覽數直向堆疊在價格右邊 —— 卡片是兩欄格線，
              跟倒數同一列會擠爆（倒數字串長達「14 天 23:19:10」）。 */}
          <div className="flex shrink-0 flex-col items-end gap-0.5 text-[12px] font-medium text-[var(--secondary-label)]">
            {campaign.ordered_qty > 0 && (
              <span>已訂購 {campaign.ordered_qty.toLocaleString()} 件</span>
            )}
            <ViewCount count={campaign.view_count} />
          </div>
        </div>
        {campaign.end_at && (
          <div className="inline-flex items-center gap-1 rounded-md bg-[var(--brand-soft)] px-1.5 py-0.5 text-[12px] font-semibold tabular-nums text-[var(--brand-strong)]">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.2} className="h-3 w-3 shrink-0">
              <circle cx="12" cy="12" r="9" />
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 7.5V12l3 2" />
            </svg>
            <Countdown target={campaign.end_at} compact />
          </div>
        )}
      </div>
    </Link>
  );
}

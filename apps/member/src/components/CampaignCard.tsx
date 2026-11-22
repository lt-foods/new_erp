"use client";

import { thumb } from "@/lib/imageUrl";
import Link from "next/link";
import Countdown from "./Countdown";
import OrderedCount from "./OrderedCount";
import ViewCount from "./ViewCount";
import SalePrice from "./SalePrice";
import { cleanCampaignText } from "@/lib/text";

export type CampaignSummary = {
  id: number;
  campaign_no: string;
  name: string;
  description: string | null;
  cover_image_url: string | null;
  close_type: "regular" | "fast" | "limited" | "food_train" | string;
  /** 店家自開團的主辦店；非 null = 這團只有該店的會員看得到。
   *  後端未部署前可能沒有這個欄位（當 null 處理 = 一般團）。 */
  owner_store_id?: number | null;
  total_cap_qty: number | null;
  has_item_cap?: boolean;
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
  /** 卡片那個最低價的原價（比售價高才有值）；有值就在售價旁畫刪除線。後端未部署前沒有這個欄位。 */
  min_price_original?: number | null;
  /** 優惠標籤（後台每團自己打，例：獨家優惠）；沒有就不顯示。 */
  promo_label?: string | null;
};

/** 這團是不是門市自己開的（只有該店會員看得到，貨由門市自己備）。 */
export function isStoreCampaign(c: CampaignSummary): boolean {
  return c.owner_store_id != null;
}

/** 依 close_type + total_cap_qty 算出短標籤。
 *  「限時」只給真正的快閃團（close_type='fast'，即限時專區那種）。
 *  一般團幾乎都有結單日(end_at)，有結單日 ≠ 限時，否則每張卡都被貼標、
 *  標籤就失去意義（卡片本來就會單獨顯示倒數）。 */
export function campaignBadgeLabel(c: CampaignSummary): string | null {
  const hasCap = (c.total_cap_qty ?? 0) > 0 || c.has_item_cap === true;
  // 門市自開團優先：那是「誰開的」，比「怎麼結單」更能解釋這張卡為什麼只有你看得到
  if (isStoreCampaign(c)) return "門市限定";
  if (c.close_type === "food_train") return "美食列車";
  if (c.close_type === "fast" && hasCap) return "限時限量";
  if (c.close_type === "fast") return "限時";
  if (c.close_type === "limited" || hasCap) return "限時限量";
  return null;
}

/** 要畫刪除線的原價；沒有、或不比售價高就回 null。 */
export function campaignOriginalPrice(c: CampaignSummary): number | null {
  const orig = Number(c.min_price_original ?? 0);
  return c.min_price > 0 && orig > c.min_price ? orig : null;
}

/** 圖片右上角的優惠標籤（「獨家優惠」那種）。售完的團不貼：都買不到了還喊優惠只會惹人煩。 */
function PromoLabel({ campaign, size }: { campaign: CampaignSummary; size: "sm" | "lg" }) {
  const label = (campaign.promo_label ?? "").trim();
  if (!label || campaignSoldOut(campaign)) return null;
  return (
    <span
      className={`absolute z-[1] rounded-full bg-gradient-to-r from-[#ff3b30] to-[#ff7a00] font-bold text-white shadow-md ${
        size === "lg" ? "right-3 top-3 px-3 py-1 text-[14px]" : "right-2 top-2 px-2 py-0.5 text-[11px]"
      }`}
    >
      {label}
    </span>
  );
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
  const originalPrice = campaignOriginalPrice(campaign);
  const priceSuffix = campaign.max_price > campaign.min_price ? "起" : undefined;

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
              src={thumb(campaign.cover_image_url, 800) ?? undefined}
              alt=""
              loading="lazy"
              decoding="async"
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
            const isStore = isStoreCampaign(campaign);
            const isLimited = !isStore && label?.includes("限量");
            const isFoodTrain = campaign.close_type === "food_train";
            return (
              <div
                className={`absolute left-3 top-3 inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-[14px] font-semibold text-white shadow-sm backdrop-blur ${
                  soldOut ? "bg-zinc-700/85"
                  : isStore ? "bg-indigo-600/90"
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
          <PromoLabel campaign={campaign} size="lg" />
        </div>
        <div className="space-y-1.5 px-4 py-3.5">
          <h3 className="text-[22px] font-bold leading-tight text-[var(--foreground)]">
            {cleanCampaignText(campaign.name)}
          </h3>
          <div className="flex items-baseline justify-between gap-2">
            {originalPrice !== null ? (
              <SalePrice price={campaign.min_price} original={originalPrice} suffix={priceSuffix} size="lg" layout="inline" className="self-center" />
            ) : (
              <span className="brand-gradient-text text-[28px] font-extrabold tabular-nums leading-none">
                {priceText}
              </span>
            )}
            <span className="text-[13px] text-[var(--secondary-label)]">
              共 {campaign.item_count} 項
            </span>
          </div>
          {(campaign.ordered_qty > 0 || (campaign.view_count ?? 0) > 0) && (
            <div className="flex items-center justify-between gap-2 text-[14px] font-medium text-[var(--secondary-label)]">
              <ViewCount count={campaign.view_count} />
              <OrderedCount count={campaign.ordered_qty} size="md" className="ml-auto" />
            </div>
          )}
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
            src={thumb(campaign.cover_image_url, 800) ?? undefined}
            alt=""
            loading="lazy"
            decoding="async"
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
          const isStore = isStoreCampaign(campaign);
          const isLimited = !isStore && label?.includes("限量");
          const isFoodTrain = campaign.close_type === "food_train";
          return (
            <span
              className={`absolute left-2 top-2 rounded-full px-2 py-0.5 text-[11px] font-semibold text-white shadow-sm backdrop-blur ${
                isStore ? "bg-indigo-600/90"
                : isFoodTrain ? "bg-emerald-600/95"
                : isLimited ? "bg-[var(--ios-red)]/90"
                : "bg-[var(--ios-orange)]/90"
              }`}
            >
              {label}
            </span>
          );
        })()}
        <PromoLabel campaign={campaign} size="sm" />
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
        {/* 價格一律在右、已訂購／瀏覽數在左（老闆 2026-11-22：特價的樣稿是這樣排，
            「沒特價的金額位置也放右邊」—— 有沒有特價都同一個位置，整排卡片才對得齊）。
            已訂購／瀏覽數直向堆疊：卡片是兩欄格線，跟倒數同一列會擠爆（倒數字串長達「14 天 23:19:10」）。
            flex-wrap：四位數的價格放不下時，價格自己掉到下一列靠右，不會把卡片撐破。 */}
        <div className="flex flex-wrap items-end justify-between gap-x-1 gap-y-1.5">
          <div className="flex flex-col items-start gap-1 pb-0.5">
            <OrderedCount count={campaign.ordered_qty} size="sm" />
            <ViewCount count={campaign.view_count} />
          </div>
          {originalPrice !== null ? (
            // 特價：原價疊在售價上面（老闆 2026-11-22 的樣稿）
            <SalePrice price={campaign.min_price} original={originalPrice} suffix={priceSuffix} size="md" className="ml-auto" />
          ) : (
            <div className="brand-gradient-text ml-auto whitespace-nowrap text-[24px] font-extrabold tabular-nums leading-none">
              {priceText}
            </div>
          )}
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

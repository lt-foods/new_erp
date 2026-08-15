"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useParams, useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession, loginPath } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import Spinner from "@/components/Spinner";
import Countdown from "@/components/Countdown";
import OrderedCount from "@/components/OrderedCount";
import ViewCount from "@/components/ViewCount";
import ShareButtons from "@/components/ShareButtons";
import SkuThumb from "@/components/SkuThumb";
import { campaignShareUrl } from "@/lib/shareLink";
import { cleanCampaignText } from "@/lib/text";
import { getCampaignHint } from "@/lib/campaignHints";
import { logCaught } from "@/lib/clientLog";
import { detectClientChannel } from "@/lib/clientChannel";

/** 把 children 渲染到 document.body（保證 fixed 相對 viewport）。 */
function Portal({ enabled, children }: { enabled: boolean; children: React.ReactNode }) {
  if (!enabled || typeof document === "undefined") return null;
  return createPortal(children, document.body);
}

type CampaignDetail = {
  id: number;
  campaign_no: string;
  name: string;
  description: string | null;
  cover_image_url: string | null;
  status: string;
  close_type: string | null;
  end_at: string | null;
  pickup_deadline: string | null;
  total_cap_qty: number | null;
  /** 總瀏覽次數。後端未部署 track_campaign_view 前可能沒有這個欄位。 */
  view_count?: number;
  /**
   * 還能不能下單。false = 已結單 / 已下架，只放行「自己買過這團」的會員回頭看
   * （從訂單卡點進來的路徑），畫面要收掉所有下單入口。
   * 舊版後端沒有這個欄位 → undefined，一律當可下單（那時候不可下單的團根本 404）。
   */
  available?: boolean;
};

type Item = {
  campaign_item_id: number;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  image_url: string | null;
  unit_price: number;
  cap_qty: number | null;
  ordered_qty: number;
};

function itemRemaining(item: Item): number | null {
  const cap = Number(item.cap_qty ?? 0);
  if (cap <= 0) return null;
  return Math.max(0, cap - Number(item.ordered_qty ?? 0));
}

function itemOrderMax(item: Item, campaignRemaining: number | null, currentQty: number): number {
  const remaining = itemRemaining(item);
  const itemMax = remaining ?? 999;
  const campaignMax = campaignRemaining == null ? 999 : currentQty + campaignRemaining;
  return Math.max(0, Math.min(itemMax, campaignMax));
}

export default function CampaignDetailClient() {
  const router = useRouter();
  const params = useParams();
  const id = Number(params?.id);

  // 從列表帶過來的摘要 (名稱 / 封面 / 倒數 / 起跳價), mount 時就可以畫出
  // 標題 + hero, 不用等完整 detail API 回來。沒有 hint 就 fallback 到
  // 原本的 loading screen。
  const hint = useMemo(() => (id ? getCampaignHint(id) : undefined), [id]);

  const [campaign, setCampaign] = useState<CampaignDetail | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [heroImages, setHeroImages] = useState<string[]>([]);
  const [qtyMap, setQtyMap] = useState<Record<number, number>>({});
  const [err, setErr] = useState<string | null>(null);
  // 瀏覽次數：先用列表 hint 的值墊著，detail / track 回來再蓋掉（含本次瀏覽）
  const [viewCount, setViewCount] = useState<number>(() => hint?.view_count ?? 0);

  // confirm sheet
  const [sheetOpen, setSheetOpen] = useState(false);
  const [notes, setNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [doneOrderNo, setDoneOrderNo] = useState<string | null>(null);
  // 把常駐下單列 / sheet portal 到 body，確保一定釘在 viewport（不受任何祖先
  // transform / filter 形成的 containing block 影響、不用滑到底才看得到）
  const [mounted, setMounted] = useState(false);
  useEffect(() => {
    const timer = window.setTimeout(() => setMounted(true), 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace(loginPath());
      return;
    }
    if (!id) return;
    (async () => {
      try {
        const d = await callLiffApi<{
          campaign: CampaignDetail;
          items: Item[];
          hero_images?: string[];
        }>(s.token, {
          action: "get_campaign_detail",
          campaign_id: id,
        });
        setCampaign(d.campaign);
        setItems(d.items);
        setHeroImages(d.hero_images ?? []);
        if (typeof d.campaign.view_count === "number") {
          setViewCount(d.campaign.view_count);
        }
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      }
    })();
  }, [id, router]);

  // 記一次瀏覽，並拿回含本次的最新計數。
  // 同會員同商品 30 分鐘內在後端去重，所以「返回列表再點進來」不會灌水。
  //
  // 已結單的團不記：那些瀏覽是團友回頭看自己的訂單，不是還在考慮要不要買的人，
  // 記下去會讓「熱門度」被結單後的回訪灌水。
  const trackedRef = useRef<number | null>(null);
  useEffect(() => {
    if (!id || trackedRef.current === id) return;
    if (!campaign || campaign.available === false) return;
    const s = getSession();
    if (!s || !s.memberId) return;
    trackedRef.current = id;
    (async () => {
      try {
        const r = await callLiffApi<{ view_count: number }>(s.token, {
          action: "track_campaign_view",
          campaign_id: id,
        });
        if (typeof r.view_count === "number") setViewCount(r.view_count);
      } catch (e) {
        // 瀏覽數是附加資訊，記不到不能影響購物；但要留痕，
        // 否則「數字一直是 0」只會在會員手機上重現得出來。
        logCaught("track_campaign_view_failed", e, { campaign_id: id });
      }
    })();
  }, [id, campaign]);

  const totalQty = useMemo(
    () => Object.values(qtyMap).reduce((s, n) => s + (n || 0), 0),
    [qtyMap],
  );

  const totalAmount = useMemo(() => {
    let sum = 0;
    for (const it of items) {
      const q = qtyMap[it.campaign_item_id] ?? 0;
      sum += q * Number(it.unit_price);
    }
    return sum;
  }, [items, qtyMap]);

  // 已結單 / 已下架的團（只有買過的會員從訂單卡點得進來）：整頁收成唯讀。
  const readOnly = campaign?.available === false;
  const orderedQtyTotal = items.reduce((s, it) => s + Number(it.ordered_qty ?? 0), 0);
  const campaignRemaining = useMemo(() => {
    const cap = Number(campaign?.total_cap_qty ?? 0);
    if (cap <= 0) return null;
    return Math.max(0, cap - orderedQtyTotal);
  }, [campaign?.total_cap_qty, orderedQtyTotal]);
  const hasAvailableItem = items.some((it) => itemOrderMax(it, campaignRemaining, 0) > 0);

  const setQty = (ciId: number, q: number, cap: number | null, orderedQty = 0) => {
    const currentQty = qtyMap[ciId] ?? 0;
    const maxByItem = cap != null ? Math.max(0, cap - orderedQty) : 999;
    const maxByCampaign = campaignRemaining == null ? 999 : currentQty + campaignRemaining;
    const max = Math.min(maxByItem, maxByCampaign);
    const next = Math.max(0, Math.min(max, q));
    setQtyMap((prev) => ({ ...prev, [ciId]: next }));
  };

  const submit = async () => {
    const s = getSession();
    if (!s) return;
    const ordered = Object.entries(qtyMap)
      .map(([k, v]) => ({ campaign_item_id: Number(k), qty: Number(v) }))
      .filter((x) => x.qty > 0);
    if (ordered.length === 0) {
      alert("請先選擇數量");
      return;
    }
    setSubmitting(true);
    try {
      const r = await callLiffApi<{ order_no: string }>(s.token, {
        action: "place_member_order",
        campaign_id: id,
        items: ordered,
        notes: notes.trim() || null,
        // 下單通路 → customer_order_items.source（後台折線圖分 App / 商城兩條線）。
        // 在這裡取而不是進 callLiffApi：只有「下單」這個動作要記通路。
        client: detectClientChannel(),
      });
      setDoneOrderNo(r.order_no);
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      const soldOut = message.includes("sold out");
      // 售完是熱團的正常結果不記；其餘下單失敗會員只看得到 alert，一定要留 log
      // （2026-08-14 線上 RPC 沒部署、全 APP 下單掛掉，client_error_logs 一筆都沒有）。
      if (!soldOut) {
        logCaught("place_member_order_failed", e, {
          campaign_id: id,
          items: ordered.length,
        });
      }
      const friendly = soldOut ? "已售完或數量不足，請重新整理後再選。" : message;
      alert(`下單失敗：${friendly}`);
    } finally {
      setSubmitting(false);
    }
  };

  // 顯示用的合成資料: 有完整 detail 就用 detail, 還沒回來就 fallback 到 hint。
  // 這樣 mount 時就能畫標題 / 封面 / 倒數, 不會空白等 API。
  const displayName = campaign?.name ?? hint?.name ?? "";
  const displayCover = campaign?.cover_image_url ?? hint?.cover_image_url ?? null;
  const displayEndAt = campaign?.end_at ?? hint?.end_at ?? null;
  const displayDescription = campaign?.description ?? hint?.description ?? null;
  const hintPriceText = hint && hint.min_price > 0
    ? `$${hint.min_price.toLocaleString()}${hint.max_price > hint.min_price ? " 起" : ""}`
    : null;

  const heroImageList: string[] =
    heroImages.length > 0
      ? heroImages
      : items[0]?.image_url
        ? [items[0].image_url]
        : displayCover
          ? [displayCover]
          : [];

  const showShell = !!campaign || !!hint;

  const minItemPrice = useMemo(() => {
    const prices = items
      .map((it) => Number(it.unit_price))
      .filter((n) => Number.isFinite(n) && n > 0);
    return prices.length > 0 ? Math.min(...prices) : null;
  }, [items]);

  // 分享用的網址與文案。網址一律重組（不能用 location.href，那上面可能還掛著
  // 登入用的 fragment），文案給團名 + 起跳價，其餘（縮圖 / 說明）由連結自己的
  // og tag 補完，見 page.tsx 的 generateMetadata。
  const shareUrl = campaignShareUrl(id);
  const shareTitle = cleanCampaignText(displayName);
  const shareText = [
    shareTitle,
    minItemPrice != null ? `$${minItemPrice.toLocaleString()} 起` : hintPriceText,
  ].filter(Boolean).join("｜");

  return (
    <PageShell title={cleanCampaignText(displayName) || "商品"}>
      {/* 唯讀模式沒有常駐下單列，底部不用留它的位置 */}
      <div className={`space-y-4 px-0 ${readOnly ? "pb-10" : "pb-[160px]"}`}>
        {err && (
          <div className="mx-4 rounded-2xl bg-[#ff3b30]/10 p-3 text-[15px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!showShell && !err && (
          <div className="flex justify-center py-20">
            <Spinner size={28} />
          </div>
        )}

        {showShell && (
          <>
            {/* 封面 carousel — 有 hint 時先顯示列表封面, detail 回來再換成完整圖集 */}
            <div className="relative">
              <HeroCarousel images={heroImageList} />
              {/* 已結單的團不畫倒數（Countdown 過期會回「已結束」，包在「剩 …」裡
                  變成「剩 已結束」）；改標一顆狀態膠囊。 */}
              {readOnly ? (
                <div className="absolute right-3 top-3 rounded-full bg-black/70 px-3 py-1 text-[14px] font-medium text-white backdrop-blur">
                  已結單
                </div>
              ) : displayEndAt && (
                <div className="absolute right-3 top-3 rounded-full bg-black/70 px-3 py-1 text-[14px] font-medium text-white backdrop-blur">
                  剩 <Countdown target={displayEndAt} compact className="text-white" />
                </div>
              )}
            </div>

            {/* 標題 + 描述 */}
            <div className="space-y-2 px-4">
              <div className="flex items-start justify-between gap-3">
                <h1 className="flex-1 text-[26px] font-bold leading-tight text-[var(--foreground)]">
                  {cleanCampaignText(displayName)}
                </h1>
                <OrderedCount
                  count={orderedQtyTotal}
                  size="lg"
                  className="mt-1.5 shrink-0"
                />
              </div>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <ViewCount count={viewCount} size="md" />
                <ShareButtons url={shareUrl} title={shareTitle} text={shareText} />
              </div>

              {readOnly && (
                <div className="rounded-2xl bg-zinc-100 px-4 py-3 text-[15px] text-[var(--secondary-label)]">
                  本團已結單，這裡只能查看商品內容。
                  <br />
                  你的訂單狀態請看「訂單」分頁。
                </div>
              )}

              {!readOnly && campaignRemaining !== null && (
                <div className={`inline-flex rounded-full px-3 py-1 text-[14px] font-semibold ${
                  campaignRemaining > 0
                    ? "bg-[var(--brand-soft)] text-[var(--brand-strong)]"
                    : "bg-zinc-100 text-zinc-600"
                }`}>
                  {campaignRemaining > 0 ? `本團剩 ${campaignRemaining} 份` : "本團已售完"}
                </div>
              )}

              {displayDescription && (() => {
                const desc = cleanCampaignText(displayDescription);
                if (!desc) return null;
                return (
                  <div className="rounded-2xl bg-[var(--card-bg)] p-4 shadow-[var(--shadow-card)]">
                    <p className="whitespace-pre-wrap text-[15px] leading-7 text-[var(--foreground)]">
                      {desc}
                    </p>
                  </div>
                );
              })()}
              {campaign?.pickup_deadline && (
                <p className="text-[14px] text-[var(--tertiary-label)]">
                  取貨期限：{campaign.pickup_deadline}
                </p>
              )}
            </div>

            {/* SKU 列表 */}
            <section className="px-4">
              <h2 className="pb-2 pt-1 text-[20px] font-bold text-[var(--foreground)]">
                商品項目
              </h2>
              <div className="card overflow-hidden">
                {!campaign ? (
                  // detail 還沒回來: 顯示 skeleton (用 hint 的價格區間先佔位)
                  <ItemSkeleton priceText={hintPriceText} />
                ) : items.length === 0 ? (
                  <div className="px-4 py-8 text-center text-[15px] text-[var(--tertiary-label)]">
                    尚無商品
                  </div>
                ) : (
                  items.map((it, idx) => {
                    const q = qtyMap[it.campaign_item_id] ?? 0;
                    const remaining = itemRemaining(it);
                    // 唯讀模式（已結單）不談售完 / 剩餘 —— 那是「還能不能買」的語言，
                    // 團都結了再標「售完」只會讓回頭看訂單的客人以為是自己沒買到。
                    const soldOut = !readOnly && itemOrderMax(it, campaignRemaining, q) <= 0 && q === 0;
                    return (
                      <div
                        key={it.campaign_item_id}
                        className={`flex items-center gap-3 px-4 py-3.5 ${idx === items.length - 1 ? "" : "border-b border-[var(--separator)]"} ${soldOut ? "opacity-60" : ""}`}
                      >
                        <SkuThumb url={it.image_url} />
                        <div className="min-w-0 flex-1">
                          <div className="line-clamp-2 text-[16px] font-medium leading-tight text-[var(--foreground)]">
                            {it.product_name ?? `品項#${it.sku_id}`}
                          </div>
                          {it.variant_name && (
                            <div className="text-[13px] text-[var(--secondary-label)]">{it.variant_name}</div>
                          )}
                          <div className="mt-1 flex items-baseline gap-2">
                            <div className="text-[18px] font-bold tabular-nums text-[var(--brand-strong)] leading-none">
                              ${Number(it.unit_price).toLocaleString()}
                            </div>
                            {it.ordered_qty > 0 && (
                              <div className="inline-flex items-baseline gap-1 text-[12px] font-medium text-[var(--secondary-label)]">
                                已售出
                                <span className="text-[14px] font-bold tabular-nums leading-none text-[var(--foreground)]">
                                  {it.ordered_qty}
                                </span>
                              </div>
                            )}
                          </div>
                          {!readOnly && remaining !== null && (
                            <div className={`mt-1 text-[12px] font-semibold ${remaining > 0 ? "text-[#c4271d]" : "text-zinc-500"}`}>
                              {remaining > 0 ? `剩 ${remaining} 份` : "此規格已售完"}
                            </div>
                          )}
                        </div>
                        {soldOut ? (
                          <span className="shrink-0 rounded-full bg-zinc-100 px-2.5 py-1 text-[13px] font-semibold text-zinc-600">
                            售完
                          </span>
                        ) : q > 0 && (
                          <span className="shrink-0 rounded-full bg-[var(--brand-soft)] px-2.5 py-1 text-[13px] font-semibold text-[var(--brand-strong)]">
                            已選 ×{q}
                          </span>
                        )}
                      </div>
                    );
                  })
                )}
              </div>
            </section>
          </>
        )}
      </div>

      {/* 常駐底部購買列 — portal 到 body，永遠釘在 viewport（蝦皮式，免滑到底）*/}
      <Portal enabled={mounted && !!campaign && items.length > 0 && !readOnly}>
        <div
          className="fixed inset-x-0 bottom-0 z-40 border-t border-[var(--separator)] bg-white/95 backdrop-blur-xl"
          style={{ paddingBottom: "max(env(safe-area-inset-bottom), 10px)" }}
        >
          <div className="mx-auto flex max-w-md items-center gap-3 px-4 pt-3">
            {totalQty > 0 && (
              <div className="shrink-0">
                <div className="text-[12px] text-[var(--secondary-label)]">總計 {totalQty} 件</div>
                <div className="text-[24px] font-bold tabular-nums text-[var(--brand-strong)] leading-none">
                  ${totalAmount.toLocaleString()}
                </div>
              </div>
            )}
            <button
              onClick={() => setSheetOpen(true)}
              disabled={!hasAvailableItem}
              className={`flex-1 rounded-full py-3.5 text-[17px] font-bold text-white transition-transform active:scale-[0.99] ${
                hasAvailableItem
                  ? "brand-gradient shadow-[0_8px_20px_-8px_rgba(158,47,80,0.6)]"
                  : "bg-zinc-400 opacity-60 shadow-none"
              }`}
            >
              {!hasAvailableItem ? "已售完" : totalQty > 0 ? "送出訂單" : "選擇規格・立即下單"}
            </button>
          </div>
        </div>
      </Portal>

      {/* Shopee 式選購 sheet — 規格 + 數量 + 大鈕送出，全在這個彈窗 */}
      <Portal enabled={mounted && sheetOpen && !!campaign}>
        <BuySheet
          campaignName={cleanCampaignText(campaign?.name)}
          items={items}
          qtyMap={qtyMap}
          onQty={setQty}
          totalQty={totalQty}
          totalAmount={totalAmount}
          campaignRemaining={campaignRemaining}
          notes={notes}
          onNotes={setNotes}
          onClose={() => setSheetOpen(false)}
          onSubmit={submit}
          submitting={submitting}
        />
      </Portal>

      {/* Done sheet */}
      <Portal enabled={mounted && !!doneOrderNo}>
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 px-6">
          <div className="w-full max-w-sm rounded-2xl bg-white p-6 text-center">
            <div className="text-5xl">✅</div>
            <h3 className="mt-3 text-[22px] font-bold text-[var(--foreground)]">下單成功</h3>
            <p className="mt-1 font-mono text-[14px] text-[var(--secondary-label)]">
              {doneOrderNo}
            </p>
            {/* 下單成功是最想揪人的那一刻，順手給一個分享入口 */}
            <div className="mt-5 rounded-2xl bg-[var(--brand-soft)] p-3">
              <p className="text-[14px] font-medium text-[var(--brand-deep)]">
                揪朋友一起買
              </p>
              <ShareButtons
                url={shareUrl}
                title={shareTitle}
                text={shareText}
                className="mt-2 flex flex-col items-center"
              />
            </div>

            <div className="mt-4 flex gap-2">
              <button
                onClick={() => router.push("/orders")}
                className="flex-1 rounded-xl bg-[#7676801f] py-3 text-[16px] font-medium text-[var(--foreground)] active:bg-[#76768033]"
              >
                查看訂單
              </button>
              <button
                onClick={() => router.push("/shop")}
                className="flex-1 rounded-xl bg-[var(--ios-blue)] py-3 text-[16px] font-semibold text-white active:opacity-80"
              >
                繼續逛
              </button>
            </div>
          </div>
        </div>
      </Portal>
    </PageShell>
  );
}

function HeroCarousel({ images }: { images: string[] }) {
  const ref = useRef<HTMLDivElement | null>(null);
  const [idx, setIdx] = useState(0);
  const [zoomSrc, setZoomSrc] = useState<string | null>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const handler = () => {
      const w = el.clientWidth;
      if (w > 0) setIdx(Math.round(el.scrollLeft / w));
    };
    el.addEventListener("scroll", handler, { passive: true });
    return () => el.removeEventListener("scroll", handler);
  }, []);

  // 鎖死成只能水平。一摸到 carousel 就判定方向,
  // 垂直壓倒水平 → preventDefault 阻擋頁面滾動。
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let startX = 0;
    let startY = 0;
    let dir: "h" | "v" | null = null;

    const onStart = (e: TouchEvent) => {
      startX = e.touches[0].clientX;
      startY = e.touches[0].clientY;
      dir = null;
    };
    const onMove = (e: TouchEvent) => {
      const dx = e.touches[0].clientX - startX;
      const dy = e.touches[0].clientY - startY;
      if (dir === null) {
        if (Math.abs(dx) > 6 || Math.abs(dy) > 6) {
          dir = Math.abs(dx) > Math.abs(dy) ? "h" : "v";
        }
      }
      if (dir === "v" && e.cancelable) e.preventDefault();
    };

    el.addEventListener("touchstart", onStart, { passive: true });
    el.addEventListener("touchmove", onMove, { passive: false });
    return () => {
      el.removeEventListener("touchstart", onStart);
      el.removeEventListener("touchmove", onMove);
    };
  }, []);

  if (images.length === 0) {
    return (
      <div className="flex aspect-[4/3] w-full items-center justify-center bg-[#7676801a] text-6xl">
        📦
      </div>
    );
  }

  return (
    <>
      <div
        ref={ref}
        className="hide-scrollbar flex aspect-[4/3] w-full snap-x snap-mandatory overflow-x-auto scroll-smooth"
        style={{ scrollbarWidth: "none", touchAction: "pan-x" }}
      >
        {images.map((url, i) => (
          <div
            key={`${url}-${i}`}
            className="relative h-full w-full flex-shrink-0 snap-center bg-[#7676801a]"
          >
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={url}
              alt=""
              onClick={() => setZoomSrc(url)}
              className="absolute inset-0 h-full w-full cursor-zoom-in object-cover"
            />
          </div>
        ))}
      </div>
      {images.length > 1 && (
        <div className="absolute bottom-3 left-1/2 z-10 flex -translate-x-1/2 items-center gap-1.5 rounded-full bg-black/35 px-2.5 py-1 backdrop-blur-sm">
          {images.map((_, i) => (
            <span
              key={i}
              aria-hidden
              className={`h-1.5 rounded-full transition-all ${
                i === idx ? "w-4 bg-white" : "w-1.5 bg-white/60"
              }`}
            />
          ))}
        </div>
      )}
      <Portal enabled={!!zoomSrc}>
        <div
          className="fixed inset-0 z-[60] flex items-center justify-center bg-black/90"
          onClick={() => setZoomSrc(null)}
        >
          <button
            type="button"
            aria-label="關閉"
            onClick={() => setZoomSrc(null)}
            className="absolute right-4 flex h-9 w-9 items-center justify-center rounded-full bg-white/15 text-[20px] text-white backdrop-blur"
            style={{ top: "calc(env(safe-area-inset-top) + 12px)" }}
          >
            ✕
          </button>
          {zoomSrc && (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={zoomSrc}
              alt=""
              onClick={(e) => e.stopPropagation()}
              className="max-h-[90vh] max-w-[94vw] object-contain"
            />
          )}
        </div>
      </Portal>
    </>
  );
}

/** 詳情 API 還沒回來時的 SKU 列 skeleton, 給 hint 預填用 */
function ItemSkeleton({ priceText }: { priceText: string | null }) {
  return (
    <>
      {[0, 1, 2].map((i) => (
        <div
          key={i}
          className={`flex items-center gap-3 px-4 py-3.5 ${i === 2 ? "" : "border-b border-[var(--separator)]"}`}
        >
          <div className="h-14 w-14 shrink-0 animate-pulse rounded-xl bg-[var(--brand-soft)]/60" />
          <div className="min-w-0 flex-1 space-y-2">
            <div className="h-4 w-4/5 animate-pulse rounded bg-black/5" />
            <div className="h-3 w-1/2 animate-pulse rounded bg-black/5" />
            {i === 0 && priceText && (
              <div className="text-[16px] font-bold tabular-nums text-[var(--brand-strong)] leading-none">
                {priceText}
              </div>
            )}
          </div>
        </div>
      ))}
    </>
  );
}

function Stepper({
  qty,
  onChange,
  max,
}: {
  qty: number;
  onChange: (q: number) => void;
  max: number;
}) {
  if (max <= 0 && qty === 0) {
    return (
      <span className="shrink-0 rounded-full bg-zinc-100 px-3 py-1.5 text-[13px] font-semibold text-zinc-600">
        售完
      </span>
    );
  }
  if (qty === 0) {
    return (
      <button
        onClick={() => onChange(1)}
        className="flex h-9 w-9 items-center justify-center rounded-full bg-[var(--ios-blue)] text-white text-[22px] font-light leading-none active:opacity-80"
      >
        +
      </button>
    );
  }
  return (
    <div className="flex items-center gap-2">
      <button
        onClick={() => onChange(qty - 1)}
        className="flex h-8 w-8 items-center justify-center rounded-full bg-[#7676801a] text-[18px] font-medium text-[var(--foreground)] active:bg-[#76768033]"
      >
        −
      </button>
      <span className="min-w-[1.5em] text-center text-[18px] font-semibold tabular-nums text-[var(--foreground)]">
        {qty}
      </span>
      <button
        onClick={() => onChange(qty + 1)}
        disabled={qty >= max}
        className="flex h-8 w-8 items-center justify-center rounded-full bg-[var(--ios-blue)] text-[18px] font-medium text-white active:opacity-80 disabled:opacity-40"
      >
        +
      </button>
    </div>
  );
}

/** 蝦皮式選購 sheet：規格(SKU)逐項選數量 + 備註 + 底部大鈕送出，全在這個彈窗。 */
function BuySheet({
  campaignName,
  items,
  qtyMap,
  onQty,
  totalQty,
  totalAmount,
  campaignRemaining,
  notes,
  onNotes,
  onClose,
  onSubmit,
  submitting,
}: {
  campaignName: string;
  items: Item[];
  qtyMap: Record<number, number>;
  onQty: (ciId: number, q: number, cap: number | null, orderedQty?: number) => void;
  totalQty: number;
  totalAmount: number;
  campaignRemaining: number | null;
  notes: string;
  onNotes: (v: string) => void;
  onClose: () => void;
  onSubmit: () => void;
  submitting: boolean;
}) {
  return (
    <div
      className="fixed inset-0 z-50 flex flex-col justify-end bg-black/40"
      onClick={() => !submitting && onClose()}
    >
      <div
        className="flex max-h-[88vh] flex-col rounded-t-3xl bg-[var(--background)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Drag handle + header */}
        <div className="shrink-0">
          <div className="flex justify-center pt-2.5">
            <div className="h-1 w-10 rounded-full bg-[#7676804d]" />
          </div>
          <div className="flex items-start justify-between gap-3 px-5 pb-3 pt-3">
            <div className="min-w-0">
              <h2 className="text-[22px] font-bold text-[var(--foreground)]">選擇商品</h2>
              <p className="mt-0.5 line-clamp-1 text-[14px] text-[var(--secondary-label)]">
                {campaignName}
              </p>
            </div>
            <button
              onClick={onClose}
              disabled={submitting}
              aria-label="關閉"
              className="-mr-1 flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-[#7676801f] text-[18px] text-[var(--ios-gray)] active:bg-[#76768033]"
            >
              ✕
            </button>
          </div>
        </div>

        {/* 可捲動：規格逐項選數量 + 備註 */}
        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto px-4 pb-4">
          <section className="card overflow-hidden">
            {items.length === 0 ? (
              <div className="px-4 py-8 text-center text-[15px] text-[var(--tertiary-label)]">
                尚無商品
              </div>
            ) : (
              items.map((it, idx) => {
                const q = qtyMap[it.campaign_item_id] ?? 0;
                const remaining = itemRemaining(it);
                const max = itemOrderMax(it, campaignRemaining, q);
                const soldOut = max <= 0 && q === 0;
                return (
                  <div
                    key={it.campaign_item_id}
                    className={`flex items-center gap-3 px-4 py-3.5 ${
                      idx === items.length - 1 ? "" : "border-b border-[var(--separator)]"
                    } ${q > 0 ? "bg-[var(--brand-soft)]/40" : ""} ${soldOut ? "opacity-60" : ""}`}
                  >
                    <SkuThumb url={it.image_url} />
                    <div className="min-w-0 flex-1">
                      <div className="line-clamp-2 text-[15px] font-medium leading-tight text-[var(--foreground)]">
                        {it.product_name ?? `品項#${it.sku_id}`}
                      </div>
                      {it.variant_name && (
                        <div className="text-[13px] text-[var(--secondary-label)]">
                          {it.variant_name}
                        </div>
                      )}
                      <div className="mt-1 flex items-baseline gap-2">
                        <div className="text-[18px] font-bold tabular-nums text-[var(--brand-strong)] leading-none">
                          ${Number(it.unit_price).toLocaleString()}
                        </div>
                        {it.ordered_qty > 0 && (
                          <div className="inline-flex items-baseline gap-1 text-[12px] font-medium text-[var(--secondary-label)]">
                            已售出
                            <span className="text-[14px] font-bold tabular-nums leading-none text-[var(--foreground)]">
                              {it.ordered_qty}
                            </span>
                          </div>
                          )}
                        </div>
                        {remaining !== null && (
                          <div className={`mt-1 text-[12px] font-semibold ${remaining > 0 ? "text-[#c4271d]" : "text-zinc-500"}`}>
                            {remaining > 0 ? `剩 ${remaining} 份` : "此規格已售完"}
                          </div>
                        )}
                      </div>
                      <Stepper
                        qty={q}
                        onChange={(nq) => onQty(it.campaign_item_id, nq, it.cap_qty, it.ordered_qty)}
                        max={max}
                      />
                  </div>
                );
              })
            )}
          </section>

          <section className="card px-4 py-3">
            <div className="text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">取貨</div>
            <div className="mt-1 text-[16px] text-[var(--foreground)]">您的主要門市（自動配貨）</div>
            <div className="mt-0.5 text-[12px] text-[var(--tertiary-label)]">
              如需更改取貨點請與店家聯繫
            </div>
          </section>

          <section className="card px-4 py-3">
            <div className="text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">備註</div>
            <textarea
              value={notes}
              onChange={(e) => onNotes(e.target.value)}
              placeholder="想跟店家說的話（可選）"
              maxLength={200}
              rows={2}
              className="mt-1 w-full resize-none bg-transparent text-[16px] text-[var(--foreground)] outline-none placeholder:text-[var(--tertiary-label)]"
            />
          </section>
        </div>

        {/* 釘在 sheet 底的送出列（蝦皮式大鈕）*/}
        <div
          className="shrink-0 border-t border-[var(--separator)] bg-[var(--card-bg)] px-4 pt-3"
          style={{ paddingBottom: "max(env(safe-area-inset-bottom), 12px)" }}
        >
          <div className="flex items-center gap-3">
            <div className="shrink-0">
              <div className="text-[12px] text-[var(--secondary-label)]">
                合計 {totalQty} 件
              </div>
              <div className="text-[24px] font-bold tabular-nums text-[var(--brand-strong)] leading-none">
                ${totalAmount.toLocaleString()}
              </div>
            </div>
            <button
              onClick={onSubmit}
              disabled={submitting || totalQty === 0}
              className="flex flex-1 items-center justify-center gap-2 rounded-full brand-gradient py-3.5 text-[18px] font-bold text-white shadow-[0_8px_20px_-8px_rgba(158,47,80,0.6)] transition-transform active:scale-[0.99] disabled:opacity-40 disabled:shadow-none"
            >
              {submitting ? (
                <Spinner size={20} onColor />
              ) : totalQty === 0 ? (
                "請先選擇商品"
              ) : (
                "送出訂單"
              )}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

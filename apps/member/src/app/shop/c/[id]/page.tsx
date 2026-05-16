"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useParams, useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import Countdown from "@/components/Countdown";

/** 清掉 legacy LINE 匯入殘留的佔位字 (emoji)/(heart)，並收斂多餘空白。
 *  刻意只動這兩個明確雜訊 token —— (A)/(B)/($)/（暗色）等是有意義內容，不碰。 */
function cleanDescription(raw: string): string {
  return raw
    .replace(/\(heart\)/gi, "♥")
    .replace(/\(emoji\)/gi, "")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

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
  end_at: string | null;
  pickup_deadline: string | null;
  order_count: number;
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

export default function CampaignDetailPage() {
  const router = useRouter();
  const params = useParams();
  const id = Number(params?.id);

  const [campaign, setCampaign] = useState<CampaignDetail | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [heroImages, setHeroImages] = useState<string[]>([]);
  const [qtyMap, setQtyMap] = useState<Record<number, number>>({});
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  // confirm sheet
  const [sheetOpen, setSheetOpen] = useState(false);
  const [notes, setNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [doneOrderNo, setDoneOrderNo] = useState<string | null>(null);
  // 把常駐下單列 / sheet portal 到 body，確保一定釘在 viewport（不受任何祖先
  // transform / filter 形成的 containing block 影響、不用滑到底才看得到）
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace("/");
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
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [id, router]);

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

  const setQty = (ciId: number, q: number, cap: number | null) => {
    const max = cap != null ? cap : 999;
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
      });
      setDoneOrderNo(r.order_no);
    } catch (e) {
      alert(`下單失敗：${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <PageShell title={campaign?.name ?? "商品"}>
      <div className="space-y-4 px-0 pb-[160px]">
        {loading && (
          <p className="px-5 pt-2 text-[16px] text-[var(--tertiary-label)]">載入中…</p>
        )}

        {err && (
          <div className="mx-4 rounded-2xl bg-[#ff3b30]/10 p-3 text-[15px] text-[#c4271d]">
            {err}
          </div>
        )}

        {campaign && (
          <>
            {/* 封面 carousel — 顯示 campaign cover + 所有 SKU 商品圖 */}
            <div className="relative">
              <HeroCarousel
                images={
                  heroImages.length > 0
                    ? heroImages
                    : items[0]?.image_url
                      ? [items[0].image_url]
                      : campaign.cover_image_url
                        ? [campaign.cover_image_url]
                        : []
                }
              />
              {campaign.end_at && (
                <div className="absolute right-3 top-3 rounded-full bg-black/70 px-3 py-1 text-[14px] font-medium text-white backdrop-blur">
                  剩 <Countdown target={campaign.end_at} compact className="text-white" />
                </div>
              )}
            </div>

            {/* 標題 + 描述 */}
            <div className="space-y-2 px-4">
              <div className="flex items-start justify-between gap-3">
                <h1 className="flex-1 text-[26px] font-bold leading-tight text-[var(--foreground)]">
                  {campaign.name}
                </h1>
                {campaign.order_count > 0 && (
                  <div className="mt-1.5 shrink-0 rounded-lg bg-[var(--tertiary-label)]/10 px-2 py-1 text-[13px] font-semibold text-[var(--secondary-label)]">
                    {campaign.order_count} 筆訂單
                  </div>
                )}
              </div>
              {campaign.description && (() => {
                const desc = cleanDescription(campaign.description);
                if (!desc) return null;
                return (
                  <div className="rounded-2xl bg-[var(--card-bg)] p-4 shadow-[var(--shadow-card)]">
                    <p className="whitespace-pre-wrap text-[15px] leading-7 text-[var(--foreground)]">
                      {desc}
                    </p>
                  </div>
                );
              })()}
              {campaign.pickup_deadline && (
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
                {items.length === 0 ? (
                  <div className="px-4 py-8 text-center text-[15px] text-[var(--tertiary-label)]">
                    尚無商品
                  </div>
                ) : (
                  items.map((it, idx) => {
                    const q = qtyMap[it.campaign_item_id] ?? 0;
                    return (
                      <div
                        key={it.campaign_item_id}
                        className={`flex items-center gap-3 px-4 py-3.5 ${idx === items.length - 1 ? "" : "border-b border-[var(--separator)]"}`}
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
                              <div className="text-[13px] font-medium text-[var(--tertiary-label)]">
                                已售出 {it.ordered_qty}
                              </div>
                            )}
                          </div>
                        </div>
                        {q > 0 && (
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
      <Portal enabled={mounted && !!campaign && items.length > 0}>
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
              className="flex-1 rounded-full brand-gradient py-3.5 text-[17px] font-bold text-white shadow-[0_8px_20px_-8px_rgba(158,47,80,0.6)] transition-transform active:scale-[0.99]"
            >
              {totalQty > 0 ? "送出訂單" : "選擇規格・立即下單"}
            </button>
          </div>
        </div>
      </Portal>

      {/* Shopee 式選購 sheet — 規格 + 數量 + 大鈕送出，全在這個彈窗 */}
      <Portal enabled={mounted && sheetOpen && !!campaign}>
        <BuySheet
          campaignName={campaign?.name ?? ""}
          items={items}
          qtyMap={qtyMap}
          onQty={setQty}
          totalQty={totalQty}
          totalAmount={totalAmount}
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
            <div className="mt-5 flex gap-2">
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

function SkuThumb({ url }: { url: string | null }) {
  if (url) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={url} alt="" className="h-14 w-14 shrink-0 rounded-xl object-cover" />;
  }
  return (
    <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-xl bg-[var(--brand-soft)] text-[var(--brand)]">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.4} className="h-6 w-6">
        <path strokeLinecap="round" strokeLinejoin="round" d="M5 8h14l-1 11a2 2 0 0 1-2 1.8H8A2 2 0 0 1 6 19L5 8Z" />
        <path strokeLinecap="round" strokeLinejoin="round" d="M9 8V6.5a3 3 0 0 1 6 0V8" />
      </svg>
    </div>
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
  notes,
  onNotes,
  onClose,
  onSubmit,
  submitting,
}: {
  campaignName: string;
  items: Item[];
  qtyMap: Record<number, number>;
  onQty: (ciId: number, q: number, cap: number | null) => void;
  totalQty: number;
  totalAmount: number;
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
                return (
                  <div
                    key={it.campaign_item_id}
                    className={`flex items-center gap-3 px-4 py-3.5 ${
                      idx === items.length - 1 ? "" : "border-b border-[var(--separator)]"
                    } ${q > 0 ? "bg-[var(--brand-soft)]/40" : ""}`}
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
                          <div className="text-[12px] text-[var(--tertiary-label)]">
                            已售出 {it.ordered_qty}
                          </div>
                        )}
                      </div>
                    </div>
                    <Stepper
                      qty={q}
                      onChange={(nq) => onQty(it.campaign_item_id, nq, it.cap_qty)}
                      max={it.cap_qty ?? 999}
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
              className="flex-1 rounded-full brand-gradient py-3.5 text-[18px] font-bold text-white shadow-[0_8px_20px_-8px_rgba(158,47,80,0.6)] transition-transform active:scale-[0.99] disabled:opacity-40 disabled:shadow-none"
            >
              {submitting ? "送出中…" : totalQty === 0 ? "請先選擇商品" : "送出訂單"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { useParams, useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import { LoadingScreen } from "@/components/Spinner";
import Countdown from "@/components/Countdown";
import { cleanCampaignText } from "@/lib/text";
import { isInLiffClient, sendLineInquiry, spotInquiryHref } from "@/lib/lineInquiry";
import { type SpotProduct, spotProductTitle } from "@/components/SpotProductCard";

/** 把 children 渲染到 document.body（保證 fixed 相對 viewport）。同 /shop/c/[id]。 */
function Portal({ enabled, children }: { enabled: boolean; children: React.ReactNode }) {
  if (!enabled || typeof document === "undefined") return null;
  return createPortal(children, document.body);
}

/** 詳情頁比列表多回 description 與整組 images */
type SpotDetail = SpotProduct & {
  description: string | null;
  images: string[];
};

type Resp = {
  item: SpotDetail;
  my_store_id: number;
  my_store_name: string | null;
  my_store_line_oa_id: string | null;
};

/**
 * 現貨商品詳情。
 *
 * 金額規則同列表：本店顯示 `$xxx`、跨店顯示鎖頭（後端就不回跨店金額）。
 * 底部常駐一顆「用 LINE 詢問店家」，訊息本文由 lib/lineInquiry 組
 * —— 跨店那套範本不帶金額。
 */
export default function SpotDetailPage() {
  const router = useRouter();
  const params = useParams();
  const id = Number(params?.id);

  // 網址帶進來的 id 不合法就不用發請求，直接落到下面「已經不在架上」的空狀態
  const validId = Number.isFinite(id) && id > 0;

  const [item, setItem] = useState<SpotDetail | null>(null);
  const [lineOaId, setLineOaId] = useState<string | null>(null);
  const [loading, setLoading] = useState(() => validId);
  const [err, setErr] = useState<string | null>(null);
  const [mounted, setMounted] = useState(false);
  // App 有 PWA / LIFF 兩種跑法，CTA 的行為不一樣：
  //   LIFF → liff.sendMessages 直送當前聊天室，人留在 App 裡
  //   PWA  → line.me universal link 跳去 LINE 開對話並預填
  // 偵測是非同步的，還沒回來之前先當 PWA（那條路哪裡都能用）。
  const [inLiff, setInLiff] = useState(false);
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [sendErr, setSendErr] = useState<string | null>(null);

  // portal 要等 client mount（同 /shop/c/[id] 的做法，避免 hydration 對不上）
  useEffect(() => setMounted(true), []);

  useEffect(() => {
    isInLiffClient().then(setInLiff).catch(() => {});
  }, []);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace("/");
      return;
    }
    if (!validId) return;
    (async () => {
      try {
        const d = await callLiffApi<Resp>(s.token, { action: "get_spot_product", id });
        setItem(d.item);
        setLineOaId(d.my_store_line_oa_id ?? null);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router, id, validId]);

  const title = item ? spotProductTitle(item) : "";
  const subject = item
    ? {
        title,
        storeName: item.store_name,
        isMyStore: item.is_my_store,
        unitPrice: item.unit_price,
      }
    : null;
  const href = subject ? spotInquiryHref(lineOaId, subject) : null;

  // LIFF 直送不需要 LINE@ id（送進當前聊天室即可），所以只要在 LIFF 裡就給按鈕；
  // PWA 那條一定要有 id 才畫得出連結。
  const canInquire = !!subject && (inLiff || !!href);

  const onSend = async () => {
    if (!subject || sending) return;
    setSending(true);
    setSendErr(null);
    const r = await sendLineInquiry(lineOaId, subject);
    setSending(false);
    if (r === "sent_in_liff") setSent(true);
    else if (r === "failed") setSendErr("送不出去，請直接私訊店家");
  };

  return (
    <PageShell title="現貨商品">
      {/* 底部有常駐詢問列（約 88px）。PageShell 本身已留 104px，
          這裡再補一段當緩衝，字級放大或說明換行也不會被蓋到。 */}
      <div className="space-y-4 px-4 pt-3 pb-8">
        {loading && <LoadingScreen />}

        {err && (
          <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[15px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && !item && (
          <div className="flex flex-col items-center py-16 text-center">
            <p className="text-[17px] font-semibold text-[var(--foreground)]">
              這個現貨已經不在架上了
            </p>
            <p className="mt-1 text-[14px] text-[var(--secondary-label)]">
              可能已被其他分店認領、過期或下架
            </p>
            <button
              type="button"
              onClick={() => router.replace("/spot")}
              className="mt-5 rounded-full brand-gradient px-5 py-2 text-[15px] font-semibold text-white active:opacity-80"
            >
              回現貨專區
            </button>
          </div>
        )}

        {item && (
          <>
            <ImageStrip images={item.images} />

            <div className="space-y-2.5">
              <span
                className={`inline-flex max-w-full items-center truncate rounded-full px-2.5 py-1 text-[12px] font-semibold text-white ${
                  item.is_my_store ? "bg-[var(--brand)]" : "bg-zinc-600"
                }`}
              >
                {item.is_my_store ? "本店釋出" : `${item.store_name ?? "他店"} 釋出`}
              </span>

              <h2 className="text-[24px] font-bold leading-tight text-[var(--foreground)]">
                {title}
              </h2>

              {item.is_my_store ? (
                <div className="brand-gradient-text text-[32px] font-extrabold tabular-nums leading-none">
                  {item.unit_price != null ? `$${item.unit_price.toLocaleString()}` : "—"}
                </div>
              ) : (
                <div className="inline-flex items-center gap-1.5 rounded-lg bg-black/5 px-2.5 py-1.5 text-[14px] font-medium text-[var(--secondary-label)] dark:bg-white/10">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} className="h-4 w-4 shrink-0">
                    <rect x="4" y="10.5" width="16" height="10" rx="2" />
                    <path strokeLinecap="round" d="M8 10.5V7a4 4 0 1 1 8 0v3.5" />
                  </svg>
                  跨店 · 金額不顯示
                </div>
              )}
            </div>

            <dl className="card divide-y divide-[var(--separator)] px-4 text-[15px]">
              <Row label="可提供數量">
                <span className="font-semibold tabular-nums">
                  {item.qty_remaining.toLocaleString()}
                  {item.unit ?? ""}
                </span>
              </Row>
              <Row label="釋出分店">
                <span className="font-semibold">{item.store_name ?? "—"}</span>
              </Row>
              <Row label="剩餘時間">
                <span className="font-semibold tabular-nums text-[var(--brand-strong)]">
                  <Countdown target={item.expires_at} compact />
                </span>
              </Row>
              {item.sku_code && (
                <Row label="商品編號">
                  <span className="font-mono text-[13px] text-[var(--secondary-label)]">
                    {item.sku_code}
                  </span>
                </Row>
              )}
            </dl>

            {/* description 來自後台 TipTap，存的是 HTML —— 直接印會露出 <p>/<br>。
                走全站共用的 cleanCampaignText 轉純文字（同 /shop/c/[id] 的做法）。 */}
            {item.description && (() => {
              const desc = cleanCampaignText(item.description);
              if (!desc) return null;
              return (
                <section className="card px-4 py-3">
                  <h3 className="pb-1.5 text-[15px] font-bold text-[var(--foreground)]">商品說明</h3>
                  <p className="whitespace-pre-line text-[15px] leading-relaxed text-[var(--secondary-label)]">
                    {desc}
                  </p>
                </section>
              );
            })()}

            <p className="px-1 text-[13px] leading-relaxed text-[var(--secondary-label)]">
              {item.is_my_store
                ? "這是本店現貨，數量有限，先問先得。"
                : "這是其他分店的現貨，金額不顯示；想要的話按下面問你的店，由店家幫你調貨。"}
            </p>
          </>
        )}
      </div>

      {/* 常駐底部詢問列 — portal 到 body，永遠釘在 viewport（同 /shop/c/[id] 的做法）。
          LIFF 走 sendMessages 直送（不需要 LINE@ id），PWA 走 universal link；
          兩條都不成立時整條不出現，寧可少一顆按鈕也不要點下去跳空白。 */}
      <Portal enabled={mounted && canInquire}>
        <div
          className="fixed inset-x-0 bottom-0 z-40 border-t border-[var(--separator)] bg-white/95 backdrop-blur-xl"
          style={{ paddingBottom: "max(env(safe-area-inset-bottom), 10px)" }}
        >
          <div className="mx-auto max-w-md px-4 pt-3">
            {sent ? (
              <div className="rounded-2xl bg-[#06C755]/10 px-4 py-3 text-center">
                <p className="text-[15px] font-bold text-[#04833a]">已送出詢問訊息</p>
                <p className="pt-0.5 text-[13px] text-[var(--secondary-label)]">
                  店家收到後會在 LINE 回覆你
                </p>
              </div>
            ) : inLiff ? (
              // LIFF：直接把文字送進當前 LINE 聊天室，人留在 App 裡
              <button
                type="button"
                onClick={onSend}
                disabled={sending}
                className="flex w-full items-center justify-center gap-2 rounded-full bg-[#06C755] py-3.5 text-[17px] font-bold text-white shadow-[0_8px_20px_-8px_rgba(6,199,85,0.7)] transition-transform active:scale-[0.99] disabled:opacity-60"
              >
                <LineGlyph />
                {sending ? "傳送中…" : "用 LINE 詢問店家"}
              </button>
            ) : (
              // PWA / 一般瀏覽器：跳去 LINE 開對話並預填文字
              <a
                href={href ?? "#"}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center justify-center gap-2 rounded-full bg-[#06C755] py-3.5 text-[17px] font-bold text-white shadow-[0_8px_20px_-8px_rgba(6,199,85,0.7)] transition-transform active:scale-[0.99]"
              >
                <LineGlyph />
                用 LINE 詢問店家
              </a>
            )}
            {sendErr && (
              <p className="pt-1.5 text-center text-[12px] text-[#c4271d]">{sendErr}</p>
            )}
            {!sent && !sendErr && (
              <p className="pt-1.5 text-center text-[12px] text-[var(--secondary-label)]">
                {inLiff
                  ? "會以你的身分把詢問訊息傳進這個 LINE 對話"
                  : "會帶一段詢問訊息到你所在店家的 LINE，送出前可以自己改"}
              </p>
            )}
          </div>
        </div>
      </Portal>
    </PageShell>
  );
}

function LineGlyph() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className="h-5 w-5 shrink-0" aria-hidden>
      <path d="M12 3C6.98 3 3 6.34 3 10.4c0 3.63 3.05 6.67 7.18 7.27.28.06.66.19.76.42.09.22.06.55.03.77l-.12.73c-.04.22-.17.86.76.47.93-.4 5-2.95 6.82-5.05C19.7 13.6 21 12.15 21 10.4 21 6.34 17.02 3 12 3Z" />
    </svg>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between py-2.5">
      <dt className="text-[var(--secondary-label)]">{label}</dt>
      <dd className="text-[var(--foreground)]">{children}</dd>
    </div>
  );
}

/** 商品圖橫向捲動 + 頁碼點。只有一張就當靜態圖，沒有圖就畫品牌底箱子。 */
function ImageStrip({ images }: { images: string[] }) {
  const [idx, setIdx] = useState(0);

  if (images.length === 0) {
    return (
      <div
        className="flex aspect-[4/3] w-full items-center justify-center rounded-2xl"
        style={{
          background: "linear-gradient(135deg, var(--brand-soft) 0%, #fff4f6 55%, #ffffff 100%)",
        }}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="var(--brand)" strokeWidth={1.3} className="h-16 w-16 opacity-75">
          <path strokeLinecap="round" strokeLinejoin="round" d="M3 8.5 12 4l9 4.5v7L12 20l-9-4.5v-7Z" />
          <path strokeLinecap="round" strokeLinejoin="round" d="m3 8.5 9 4.5 9-4.5M12 13v7" />
        </svg>
      </div>
    );
  }

  return (
    <div className="relative">
      <div
        className="hide-scrollbar flex aspect-[4/3] w-full snap-x snap-mandatory overflow-x-auto rounded-2xl"
        onScroll={(e) => {
          const el = e.currentTarget;
          const w = el.clientWidth || 1;
          setIdx(Math.round(el.scrollLeft / w));
        }}
      >
        {images.map((src) => (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            key={src}
            src={src}
            alt=""
            className="h-full w-full shrink-0 snap-center object-cover"
          />
        ))}
      </div>
      {images.length > 1 && (
        <div className="absolute bottom-3 left-1/2 flex -translate-x-1/2 items-center gap-1.5 rounded-full bg-black/35 px-2.5 py-1 backdrop-blur-sm">
          {images.map((src, i) => (
            <span
              key={src}
              aria-hidden
              className={`h-1.5 rounded-full transition-all duration-200 ${
                i === Math.min(idx, images.length - 1) ? "w-4 bg-white" : "w-1.5 bg-white/60"
              }`}
            />
          ))}
        </div>
      )}
    </div>
  );
}

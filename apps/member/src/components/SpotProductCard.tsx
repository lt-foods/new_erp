"use client";

import Link from "next/link";

/**
 * 現貨專區商品（互助交流板「我有庫存可提供」）在會員端的資料形狀。
 *
 * unit_price 只有 is_my_store=true 時才會有值 —— 跨店的金額後端就不放進
 * response（見 liff-api 的 listSpotProducts），這裡拿到的一定是 null。
 */
export type SpotProduct = {
  id: number;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  unit: string | null;
  image_url: string | null;
  store_id: number;
  store_name: string | null;
  qty_remaining: number;
  expires_at: string;
  is_my_store: boolean;
  unit_price: number | null;
  /** 原價（來源訂單單價）。只在「店家有改價且改得比原價低」時才有值，
   *  會員端據此畫刪除線。跨店一律 null（金額隱藏）。 */
  original_price: number | null;
};

export function spotProductTitle(p: SpotProduct): string {
  const base = p.product_name ?? p.sku_code ?? "商品";
  return p.variant_name ? `${base}／${p.variant_name}` : base;
}

/** 沒有商品圖時的暖色品牌底（和 CampaignCard 的回退一致，換成箱子圖示） */
function CoverFallback() {
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
        className="h-10 w-10 opacity-70"
      >
        <path strokeLinecap="round" strokeLinejoin="round" d="M3 8.5 12 4l9 4.5v7L12 20l-9-4.5v-7Z" />
        <path strokeLinecap="round" strokeLinejoin="round" d="m3 8.5 9 4.5 9-4.5M12 13v7" />
      </svg>
    </div>
  );
}

/**
 * 現貨卡。整張卡連到 /spot/[id] 詳情頁，LINE 詢問在詳情頁裡（卡片上不再放
 * CTA —— 兩顆可點區域疊在一張小卡上很容易誤觸）。
 *
 * 金額顯示規則：
 *   - 自己所在店家釋出 → 顯示金額
 *   - 其他分店釋出     → 金額隱藏，改顯示「跨店 · 金額不顯示」
 * 後端已經不回跨店金額，這層只負責畫面表達。
 */
export default function SpotProductCard({ item }: { item: SpotProduct }) {
  const title = spotProductTitle(item);
  const qtyText = `${item.qty_remaining.toLocaleString()}${item.unit ?? ""}`;

  return (
    <Link
      href={`/spot/${item.id}`}
      className="card flex h-full flex-col overflow-hidden transition-transform duration-200 active:scale-[0.97]"
    >
      <div className="relative aspect-square w-full">
        {item.image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={item.image_url}
            alt=""
            className="absolute inset-0 h-full w-full object-cover"
          />
        ) : (
          <CoverFallback />
        )}
        <span
          className={`absolute left-2 top-2 max-w-[calc(100%-1rem)] truncate rounded-full px-2 py-0.5 text-[11px] font-semibold text-white shadow-sm backdrop-blur ${
            item.is_my_store ? "bg-[var(--brand)]/90" : "bg-black/55"
          }`}
        >
          {item.is_my_store ? "本店釋出" : `${item.store_name ?? "他店"} 釋出`}
        </span>
      </div>

      <div className="flex flex-1 flex-col gap-1 px-3 py-2.5">
        <h3 className="line-clamp-2 min-h-[2.6em] text-[16px] font-semibold leading-tight text-[var(--foreground)]">
          {title}
        </h3>

        <div className="inline-flex w-fit items-center rounded-full bg-emerald-50 px-2 py-0.5 text-[12px] font-medium text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300">
          可提供 {qtyText}
        </div>

        <div className="mt-auto pt-1">
          {item.is_my_store ? (
            <div className="flex items-baseline gap-1.5">
              <span className="brand-gradient-text text-[24px] font-extrabold tabular-nums leading-none">
                {item.unit_price != null ? `$${item.unit_price.toLocaleString()}` : "—"}
              </span>
              {item.original_price != null && (
                <s className="text-[14px] font-medium tabular-nums text-[var(--secondary-label)]">
                  ${item.original_price.toLocaleString()}
                </s>
              )}
            </div>
          ) : (
            <div className="inline-flex items-center gap-1 rounded-md bg-black/5 px-1.5 py-1 text-[12px] font-medium text-[var(--secondary-label)] dark:bg-white/10">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} className="h-3.5 w-3.5 shrink-0">
                <rect x="4" y="10.5" width="16" height="10" rx="2" />
                <path strokeLinecap="round" d="M8 10.5V7a4 4 0 1 1 8 0v3.5" />
              </svg>
              跨店 · 金額不顯示
            </div>
          )}
        </div>
      </div>
    </Link>
  );
}

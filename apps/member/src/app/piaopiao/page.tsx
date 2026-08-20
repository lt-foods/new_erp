"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import PageShell from "@/components/PageShell";

type Campaign = { id: number; name: string; cover_image_url: string | null; end_at: string | null; min_price: number; max_price: number };

export default function PiaopiaoShopPage() {
  const [items, setItems] = useState<Campaign[]>([]);
  const [error, setError] = useState("");
  useEffect(() => {
    const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
    if (!base) { setError("系統尚未設定連線"); return; }
    void fetch(`${base}/functions/v1/piaopiao-api`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "list_public_campaigns" }) })
      .then(async (response) => { const body = await response.json(); if (!response.ok) throw new Error(body.error || "讀取失敗"); return body as { campaigns: Campaign[] }; })
      .then((r) => setItems(r.campaigns))
      .catch((e) => setError(e instanceof Error ? e.message : "讀取失敗"));
  }, []);
  return (
    <PageShell title="漂漂館" hideTabs fallbackHref="/piaopiao" world="piaopiao">
      <div className="space-y-4 px-4 pb-8 pt-3">
        <p className="rounded-2xl bg-[var(--brand-soft)] px-4 py-3 text-[15px] leading-6 text-[var(--brand-deep)]">漂漂館獨立專區・商品由漂漂館上架，訂單與取貨照原系統處理。</p>
        {error && <p className="rounded-xl bg-red-50 p-3 text-red-700">{error}</p>}
        {!error && items.length === 0 && <p className="py-16 text-center text-zinc-500">目前沒有進行中的漂漂館商品</p>}
        <div className="grid grid-cols-2 gap-3">
          {items.map((item) => (
            <Link key={item.id} href={`/piaopiao/c/${item.id}`} className="card overflow-hidden active:scale-[0.99]">
              <div className="aspect-square bg-[var(--brand-soft)]">
                {item.cover_image_url ? <img src={item.cover_image_url} alt="" className="h-full w-full object-cover" /> : <div className="flex h-full items-center justify-center text-4xl">🫧</div>}
              </div>
              <div className="space-y-1 p-3">
                <p className="line-clamp-2 min-h-10 text-[15px] font-semibold leading-5">{item.name}</p>
                <p className="font-bold text-[var(--brand-strong)]">${item.min_price.toLocaleString()}{item.max_price > item.min_price ? " 起" : ""}</p>
              </div>
            </Link>
          ))}
        </div>
      </div>
    </PageShell>
  );
}

"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession, loginPath, setPostLoginReturn } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";

type Campaign = { id: number; name: string; cover_image_url: string | null; end_at: string | null; min_price: number; max_price: number };

export default function PiaopiaoShopPage() {
  const router = useRouter();
  const [items, setItems] = useState<Campaign[]>([]);
  const [error, setError] = useState("");
  useEffect(() => {
    consumeFragmentToSession();
    const session = getSession();
    if (!session?.memberId) { setPostLoginReturn("/piaopiao"); router.replace(loginPath()); return; }
    void callLiffApi<{ campaigns: Campaign[] }>(session.token, { action: "list_active_campaigns", sales_channel: "piaopiao" })
      .then((r) => setItems(r.campaigns))
      .catch((e) => setError(e instanceof Error ? e.message : "讀取失敗"));
  }, [router]);
  return (
    <PageShell title="漂漂館" hideTabs fallbackHref="/piaopiao">
      <div className="space-y-4 px-4 pb-8 pt-3">
        <p className="rounded-2xl bg-rose-50 px-4 py-3 text-[15px] leading-6 text-rose-900">漂漂館獨立專區・商品由漂漂館上架，訂單與取貨照原系統處理。</p>
        {error && <p className="rounded-xl bg-red-50 p-3 text-red-700">{error}</p>}
        {!error && items.length === 0 && <p className="py-16 text-center text-zinc-500">目前沒有進行中的漂漂館商品</p>}
        <div className="grid grid-cols-2 gap-3">
          {items.map((item) => (
            <Link key={item.id} href={`/piaopiao/c/${item.id}`} className="overflow-hidden rounded-2xl bg-white shadow-sm ring-1 ring-black/5 active:scale-[0.99]">
              <div className="aspect-square bg-rose-50">
                {item.cover_image_url ? <img src={item.cover_image_url} alt="" className="h-full w-full object-cover" /> : <div className="flex h-full items-center justify-center text-4xl">🛍️</div>}
              </div>
              <div className="space-y-1 p-3">
                <p className="line-clamp-2 min-h-10 text-[15px] font-semibold leading-5">{item.name}</p>
                <p className="font-bold text-rose-700">${item.min_price.toLocaleString()}{item.max_price > item.min_price ? " 起" : ""}</p>
              </div>
            </Link>
          ))}
        </div>
      </div>
    </PageShell>
  );
}

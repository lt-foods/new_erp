"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import MemberTabBar from "@/components/MemberTabBar";

type Overview = {
  store: {
    id: number;
    code: string;
    name: string;
    banner_url: string | null;
    description: string | null;
    payment_methods_text: string | null;
    shipping_methods_text: string | null;
  };
  receivable_amount: number;
  active_orders_count: number;
};

export default function OverviewPage() {
  const router = useRouter();
  const [data, setData] = useState<Overview | null>(null);
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
        const d = await callLiffApi<Overview>(s.token, { action: "get_overview" });
        setData(d);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  return (
    <main className="mx-auto w-full max-w-md">
      <MemberTabBar />

      <div className="space-y-4 p-4">
        {loading && <p className="text-sm text-zinc-400">載入中…</p>}

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            {err}
          </div>
        )}

        {data && (
          <>
            {data.store.banner_url ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img
                src={data.store.banner_url}
                alt=""
                className="h-40 w-full rounded-md object-cover"
              />
            ) : (
              <div className="flex h-32 items-center justify-center rounded-md bg-pink-100 text-pink-700">
                <span className="text-lg font-medium">{data.store.name}</span>
              </div>
            )}

            <h1 className="text-xl font-semibold text-pink-600">{data.store.name}</h1>

            {data.store.description && (
              <section>
                <h2 className="text-sm font-medium text-pink-600">📢 賣場介紹</h2>
                <p className="mt-1 whitespace-pre-wrap text-sm text-zinc-600">
                  {data.store.description}
                </p>
              </section>
            )}

            {(data.store.payment_methods_text || data.store.shipping_methods_text) && (
              <section>
                <h2 className="text-sm font-medium text-pink-600">🛒 付款、出貨方式</h2>
                {data.store.payment_methods_text && (
                  <p className="mt-1 whitespace-pre-wrap text-sm text-zinc-600">
                    {data.store.payment_methods_text}
                  </p>
                )}
                {data.store.shipping_methods_text && (
                  <p className="mt-1 whitespace-pre-wrap text-sm text-zinc-600">
                    {data.store.shipping_methods_text}
                  </p>
                )}
              </section>
            )}

            <section>
              <h2 className="text-sm text-pink-600">未結單金額</h2>
              <div className="mt-2 rounded-md border border-pink-100 bg-white p-6 text-center">
                <span className="text-2xl font-semibold text-pink-600">
                  {Number(data.receivable_amount).toLocaleString()}元
                </span>
              </div>
            </section>

            {data.active_orders_count > 0 && (
              <button
                onClick={() => router.push("/orders")}
                className="w-full rounded-md border border-pink-200 bg-pink-50 p-3 text-sm text-pink-700 hover:bg-pink-100"
              >
                你有 {data.active_orders_count} 筆進行中訂單 →
              </button>
            )}
          </>
        )}
      </div>
    </main>
  );
}

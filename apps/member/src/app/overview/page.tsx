"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import { PushNotificationManager } from "@/components/PushNotificationManager";
import { usePushNotification } from "@/lib/usePushNotification";

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
  const pushState = usePushNotification(getSession()?.token ?? null);

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
    <PageShell title={data?.store.name ?? "總覽"}>
      <div className="space-y-4 px-4 pt-2 pb-6">
        {loading && (
          <p className="px-1 text-[15px] text-[var(--tertiary-label)]">載入中…</p>
        )}

        {err && (
          <div className="rounded-2xl bg-[#ff3b30]/10 p-3 text-[14px] text-[#c4271d]">
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
                className="h-44 w-full rounded-2xl object-cover"
              />
            ) : null}

            {/* 逛商品入口 */}
            <button
              onClick={() => router.push("/shop")}
              className="block w-full overflow-hidden rounded-2xl bg-gradient-to-r from-[var(--brand-strong)] to-[#ff9500] p-5 text-left text-white shadow-[0_2px_8px_rgba(0,0,0,0.08)] active:opacity-90"
            >
              <div className="flex items-center justify-between gap-3">
                <div>
                  <div className="text-[14px] font-medium opacity-90">立即下單</div>
                  <div className="mt-0.5 text-[24px] font-bold leading-tight">逛商品 →</div>
                  <div className="mt-1 text-[13px] opacity-85">看本店進行中的團購活動</div>
                </div>
                <div className="text-5xl">🛒</div>
              </div>
            </button>

            {/* 未結金額卡 */}
            <section className="rounded-2xl bg-[var(--card-bg)] px-5 py-4 shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
              <div className="text-[14px] text-[var(--secondary-label)]">未結單金額</div>
              <div className="mt-1 flex items-baseline gap-1">
                <span className="text-[40px] font-semibold tabular-nums text-[var(--brand-strong)] leading-none">
                  ${Number(data.receivable_amount).toLocaleString()}
                </span>
              </div>
              {data.active_orders_count > 0 && (
                <button
                  onClick={() => router.push("/orders")}
                  className="mt-3 flex w-full items-center justify-between rounded-xl bg-[#7676801a] px-3 py-3 text-[16px] text-[var(--foreground)] active:bg-[#76768033]"
                >
                  <span>進行中訂單 {data.active_orders_count} 筆</span>
                  <span className="text-[var(--ios-gray)]">›</span>
                </button>
              )}
            </section>

            {/* 賣場介紹 */}
            {data.store.description && (
              <Section title="賣場介紹">
                <p className="whitespace-pre-wrap px-4 py-3.5 text-[16px] leading-relaxed text-[var(--foreground)]">
                  {data.store.description}
                </p>
              </Section>
            )}

            {/* 付款 / 出貨 */}
            {(data.store.payment_methods_text || data.store.shipping_methods_text) && (
              <Section title="付款・出貨方式">
                {data.store.payment_methods_text && (
                  <div className="border-b border-[var(--separator)] px-4 py-3.5">
                    <div className="text-[14px] text-[var(--secondary-label)]">付款</div>
                    <p className="mt-0.5 whitespace-pre-wrap text-[16px] text-[var(--foreground)]">
                      {data.store.payment_methods_text}
                    </p>
                  </div>
                )}
                {data.store.shipping_methods_text && (
                  <div className="px-4 py-3.5">
                    <div className="text-[14px] text-[var(--secondary-label)]">出貨</div>
                    <p className="mt-0.5 whitespace-pre-wrap text-[16px] text-[var(--foreground)]">
                      {data.store.shipping_methods_text}
                    </p>
                  </div>
                )}
              </Section>
            )}

            <PushNotificationManager state={pushState} />
          </>
        )}
      </div>
    </PageShell>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <div className="px-4 pb-1 pt-2 text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">
        {title}
      </div>
      <div className="overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
        {children}
      </div>
    </section>
  );
}

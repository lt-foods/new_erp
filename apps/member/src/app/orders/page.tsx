"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import SubTabs from "@/components/SubTabs";
import OrderCard, { type OrderRow } from "@/components/OrderCard";

type Tab = "pending" | "arrived" | "history";

export default function OrdersPage() {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("pending");
  const [activeOrders, setActiveOrders] = useState<OrderRow[]>([]);
  const [historyOrders, setHistoryOrders] = useState<OrderRow[]>([]);
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
      setLoading(true);
      setErr(null);
      try {
        const [active, history] = await Promise.all([
          callLiffApi<{ orders: OrderRow[] }>(s.token, { action: "list_my_orders", tab: "active" }),
          callLiffApi<{ orders: OrderRow[] }>(s.token, { action: "list_my_orders", tab: "history" }),
        ]);
        setActiveOrders(active.orders);
        setHistoryOrders(history.orders);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  const pending = activeOrders.filter((o) => !o.arrived);
  const arrived = activeOrders.filter((o) => o.arrived);
  const display = tab === "pending" ? pending : tab === "arrived" ? arrived : historyOrders;
  const emptyLabel = tab === "pending" ? "未到貨" : tab === "arrived" ? "已到貨" : "已完成";

  return (
    <PageShell title="我的訂單">
      <SubTabs
        value={tab}
        onChange={(v) => setTab(v as Tab)}
        options={[
          { value: "pending", label: "未到貨", count: pending.length },
          { value: "arrived", label: "已到貨", count: arrived.length },
          { value: "history", label: "訂單紀錄", count: historyOrders.length },
        ]}
      />

      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && (
          <p className="px-1 text-[15px] text-[var(--tertiary-label)]">載入中…</p>
        )}

        {err && (
          <div className="rounded-2xl bg-[#ff3b30]/10 p-3 text-[14px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && display.length === 0 && (
          <div className="py-16 text-center">
            <div className="text-3xl">📦</div>
            <p className="mt-2 text-[15px] text-[var(--tertiary-label)]">
              目前沒有{emptyLabel}訂單
            </p>
          </div>
        )}

        {display.map((o) => (
          <OrderCard key={o.id} order={o} />
        ))}
      </div>
    </PageShell>
  );
}

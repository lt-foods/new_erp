"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import MemberTabBar from "@/components/MemberTabBar";
import SubTabs from "@/components/SubTabs";
import OrderCard, { type OrderRow } from "@/components/OrderCard";

type Tab = "active" | "history";

export default function OrdersPage() {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("active");
  const [orders, setOrders] = useState<OrderRow[]>([]);
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
        const d = await callLiffApi<{ orders: OrderRow[] }>(s.token, {
          action: "list_my_orders",
          tab,
        });
        setOrders(d.orders);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [tab, router]);

  return (
    <main className="mx-auto w-full max-w-md">
      <MemberTabBar />
      <SubTabs
        value={tab}
        onChange={(v) => setTab(v as Tab)}
        options={[
          { value: "active",  label: "未完成" },
          { value: "history", label: "訂單紀錄" },
        ]}
      />

      <div className="space-y-3 p-4">
        {loading && <p className="text-base text-zinc-400">載入中…</p>}

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-base text-red-800">
            {err}
          </div>
        )}

        {!loading && !err && orders.length === 0 && (
          <p className="py-12 text-center text-base text-zinc-400">
            目前沒有{tab === "active" ? "未完成" : "已完成"}訂單
          </p>
        )}

        {orders.map((o) => (
          <OrderCard key={o.id} order={o} />
        ))}
      </div>
    </main>
  );
}

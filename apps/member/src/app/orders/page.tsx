"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import Spinner, { LoadingScreen } from "@/components/Spinner";
import SubTabs from "@/components/SubTabs";
import OrderCard, { type OrderRow } from "@/components/OrderCard";

type Tab = "pending" | "arrived" | "history";
type ListResp = { orders: OrderRow[]; has_more: boolean; next_cursor: number | null };

export default function OrdersPage() {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("pending");
  const [activeOrders, setActiveOrders] = useState<OrderRow[]>([]);
  const [historyOrders, setHistoryOrders] = useState<OrderRow[]>([]);
  const [historyHasMore, setHistoryHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
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
          callLiffApi<ListResp>(s.token, { action: "list_my_orders", tab: "active" }),
          callLiffApi<ListResp>(s.token, { action: "list_my_orders", tab: "history", limit: 30 }),
        ]);
        setActiveOrders(active.orders);
        setHistoryOrders(history.orders);
        setHistoryHasMore(Boolean(history.has_more));
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  async function loadMoreHistory() {
    if (loadingMore || historyOrders.length === 0) return;
    const s = getSession();
    if (!s) return;
    setLoadingMore(true);
    try {
      const beforeId = historyOrders[historyOrders.length - 1].id;
      const r = await callLiffApi<ListResp>(s.token, {
        action: "list_my_orders",
        tab: "history",
        limit: 30,
        before_id: beforeId,
      });
      setHistoryOrders((prev) => [...prev, ...r.orders]);
      setHistoryHasMore(Boolean(r.has_more));
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoadingMore(false);
    }
  }

  const pending = activeOrders.filter((o) => !o.arrived);
  const arrived = activeOrders.filter((o) => o.arrived);
  const display = tab === "pending" ? pending : tab === "arrived" ? arrived : historyOrders;
  const emptyLabel = tab === "pending" ? "未到貨" : tab === "arrived" ? "已到貨" : "已完成";
  const historyCountLabel = historyHasMore ? `${historyOrders.length}+` : historyOrders.length;

  return (
    <PageShell title="我的訂單">
      <SubTabs
        value={tab}
        onChange={(v) => setTab(v as Tab)}
        options={[
          { value: "pending", label: "未到貨", count: pending.length },
          { value: "arrived", label: "已到貨", count: arrived.length },
          { value: "history", label: "訂單紀錄", count: historyCountLabel },
        ]}
      />

      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && <LoadingScreen />}

        {err && (
          <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[14px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && display.length === 0 && (
          <div className="flex flex-col items-center py-20 text-center">
            <div
              className="flex h-24 w-24 items-center justify-center rounded-full text-5xl"
              style={{ background: "linear-gradient(135deg, var(--brand-soft) 0%, #fff4f6 100%)" }}
            >
              📦
            </div>
            <p className="mt-4 text-[16px] font-semibold text-[var(--foreground)]">
              目前沒有{emptyLabel}訂單
            </p>
          </div>
        )}

        {display.map((o, i) => (
          <div
            key={o.id}
            className="animate-in"
            style={{ animationDelay: `${Math.min(i, 8) * 50}ms` }}
          >
            <OrderCard order={o} />
          </div>
        ))}

        {tab === "history" && historyHasMore && !loading && (
          <button
            onClick={loadMoreHistory}
            disabled={loadingMore}
            className="flex w-full items-center justify-center gap-2 rounded-2xl border border-[var(--separator)] bg-[var(--card-bg)] px-4 py-3 text-[15px] text-[var(--brand-strong)] active:bg-[#76768033] disabled:opacity-50"
          >
            {loadingMore ? <Spinner size={18} /> : "載入更多"}
          </button>
        )}
      </div>
    </PageShell>
  );
}

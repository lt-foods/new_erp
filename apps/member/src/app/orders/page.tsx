"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession, loginPath } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import { LoadingScreen } from "@/components/Spinner";
import SubTabs from "@/components/SubTabs";
import OrderCard, { orderPhase, type OrderRow } from "@/components/OrderCard";

// 蝦皮式分頁。我們取貨時付現金，所以沒有「待付款」；「待收貨」＝到店「待取貨」。
// 分桶跟卡片右上角的狀態字共用 orderPhase()，兩邊永遠一致。
// 「不成立」（斷貨取消）跟「已轉讓」目前先整批隱藏（連「全部」也不出現），
// 之後要開再把 HIDDEN_PHASES 拿掉、補回 void 分頁。
type Tab = "all" | "waiting" | "pickup" | "done";

const TAB_LABEL: Record<Tab, string> = {
  all: "全部",
  waiting: "待到貨",
  pickup: "待取貨",
  done: "已完成",
};

const HIDDEN_PHASES = new Set(["void", "transferred"]);

export default function OrdersPage() {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("all");
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace(loginPath());
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
        // 「全部」要照時間混排，不是先進行中再歷史；隱藏的階段在這裡就過濾掉
        setOrders(
          [...active.orders, ...history.orders]
            .filter((o) => !HIDDEN_PHASES.has(orderPhase(o).phase))
            .sort(
              (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
            ),
        );
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  const buckets = useMemo(() => {
    const b: Record<Tab, OrderRow[]> = { all: orders, waiting: [], pickup: [], done: [] };
    for (const o of orders) {
      const { phase } = orderPhase(o);
      // orders 進來前已濾掉 HIDDEN_PHASES，這裡只剩三個分頁的階段
      if (phase === "waiting" || phase === "pickup" || phase === "done") b[phase].push(o);
    }
    return b;
  }, [orders]);

  const display = buckets[tab];

  return (
    <PageShell title="我的訂單">
      <SubTabs
        variant="scroll"
        value={tab}
        onChange={(v) => setTab(v as Tab)}
        options={(Object.keys(TAB_LABEL) as Tab[]).map((t) => ({
          value: t,
          label: TAB_LABEL[t],
          // 「全部」不掛數字；待到貨/待取貨掛數字提醒還有幾筆
          count: t === "all" || t === "done" ? undefined : buckets[t].length,
        }))}
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
              {tab === "all" ? "目前沒有訂單" : `目前沒有「${TAB_LABEL[tab]}」的訂單`}
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
      </div>
    </PageShell>
  );
}

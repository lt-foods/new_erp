"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession, loginPath } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import { LoadingScreen } from "@/components/Spinner";
import SubTabs from "@/components/SubTabs";
import OrderCard, { type OrderRow } from "@/components/OrderCard";

type Tab = "pending" | "arrived" | "history";

function fmtAmount(n: number): string {
  return Number(n ?? 0).toLocaleString();
}

/**
 * 一個分頁的金額加總。
 *
 * 排除 cancelled / expired 的訂單：「未到貨」刻意保留斷貨整單取消的訂單讓客人看得到
 * （listMyOrders 的 filter），那種單不用付錢，算進去總金額就會跟每張卡上的
 * 應付金額加起來對不上。品項層級的斷貨排除已經在 DB 做掉了（20260808000010），
 * 這裡只要顧單頭。
 */
function sumOrders(list: OrderRow[]) {
  const active = list.filter((o) => !["cancelled", "expired"].includes(String(o.status ?? "")));
  return {
    count: active.length,
    payable: active.reduce((s, o) => s + Number(o.payable_amount ?? 0), 0),
    // balance_due = 應付 − 已扣儲值金。舊版 edge function 沒回這欄時退回「沒付款就是全額」。
    unpaid: active.reduce(
      (s, o) => s + Number(o.balance_due ?? (o.paid ? 0 : o.payable_amount) ?? 0),
      0,
    ),
  };
}

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
  const totals = sumOrders(display);

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
        {loading && <LoadingScreen />}

        {/* 這個分頁的總金額 — 客人最常問的就是「這些加起來多少錢」 */}
        {!loading && !err && totals.count > 0 && (
          <div className="card flex items-center justify-between gap-3 px-4 py-3">
            <div className="min-w-0">
              <div className="text-[16px] text-[var(--foreground)]">
                {tab === "history" ? "訂單總金額" : "應付總金額"}
              </div>
              <div className="mt-0.5 text-[13px] text-[var(--secondary-label)]">
                共 {totals.count} 筆訂單
                {totals.unpaid > 0 && totals.unpaid !== totals.payable && (
                  <>
                    <span className="mx-1.5 text-[var(--tertiary-label)]">·</span>
                    尚未付款 ${fmtAmount(totals.unpaid)}
                  </>
                )}
              </div>
            </div>
            <span className="flex-shrink-0 text-[26px] font-semibold tabular-nums text-[var(--brand-strong)]">
              ${fmtAmount(totals.payable)}
            </span>
          </div>
        )}

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
      </div>
    </PageShell>
  );
}

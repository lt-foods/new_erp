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
// 「不成立」（斷貨取消）要顯示 —— 團友得知道那筆單為什麼消失（⛔ 斷貨說明）。
// 「已轉讓」目前先隱藏（連「全部」也不出現），之後要開再把它移出 HIDDEN_PHASES。
type Tab = "all" | "waiting" | "pickup" | "done" | "void";

const TAB_LABEL: Record<Tab, string> = {
  all: "全部",
  waiting: "待到貨",
  pickup: "待取貨",
  done: "已完成",
  void: "不成立",
};

const HIDDEN_PHASES = new Set(["transferred"]);

function fmtAmount(n: number): string {
  return Number(n ?? 0).toLocaleString();
}

/**
 * 一個分頁的金額加總。
 *
 * 排除 cancelled / expired 的訂單：「全部」分頁刻意保留斷貨整單取消的訂單讓客人
 * 看得到（也有自己的「不成立」分頁），那種單不用付錢，算進去總金額就會跟每張卡上的
 * 應付金額加起來對不上；「不成立」分頁全是這種單，count=0 → 總金額卡整張不顯示。
 * 品項層級的斷貨排除已經在 DB 做掉了（20260808000010），這裡只要顧單頭。
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
    const b: Record<Tab, OrderRow[]> = { all: orders, waiting: [], pickup: [], done: [], void: [] };
    for (const o of orders) {
      const { phase } = orderPhase(o);
      // orders 進來前已濾掉 HIDDEN_PHASES（已轉讓），剩下的都有自己的分頁
      if (phase !== "transferred") b[phase].push(o);
    }
    return b;
  }, [orders]);

  const display = buckets[tab];
  const totals = sumOrders(display);

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

        {/* 這個分頁的總金額 — 客人最常問的就是「這些加起來多少錢」 */}
        {!loading && !err && totals.count > 0 && (
          <div className="card flex items-center justify-between gap-3 px-4 py-3">
            <div className="min-w-0">
              <div className="text-[16px] text-[var(--foreground)]">
                {tab === "done" ? "訂單總金額" : "應付總金額"}
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

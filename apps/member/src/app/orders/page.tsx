"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession, loginPath } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import { LoadingScreen } from "@/components/Spinner";
import SubTabs from "@/components/SubTabs";
import OrderCard, {
  orderPhase,
  splitOrderByPhase,
  unpickedSubtotal,
  type OrderPhase,
  type OrderRow,
} from "@/components/OrderCard";
import PickupVisitGroup from "@/components/PickupVisitGroup";
import { buildDoneGroups, countGroupOrders, takeGroupOrders } from "@/lib/pickups";

// 蝦皮式分頁。我們取貨時付現金，所以沒有「待付款」；「待收貨」＝到店「待取貨」。
// 分桶跟卡片右上角的狀態字共用 orderPhase()，兩邊永遠一致。
// 「不成立」分頁 2026-08-17 應店家要求拿掉（大多時候是空的）。單子**沒有**藏：
// 取消 / 逾期的單仍出現在「全部」，紅字「訂單不成立」＋ ⛔ 斷貨說明照畫 ——
// 團友還是得知道那筆單為什麼消失。要連「全部」也不出現才加進 HIDDEN_PHASES。
// 「已轉讓」目前先隱藏（連「全部」也不出現），之後要開再把它移出 HIDDEN_PHASES。
//
// 「全部」放最後、預設落在「待到貨」（2026-08-13 門市回報）：預設開在「全部」時
// 待取貨跟還沒到貨的單混排，客人以為全部到貨就跑來，結果要的那件還在路上。
type Tab = "all" | "waiting" | "pickup" | "done";

const TAB_LABEL: Record<Tab, string> = {
  waiting: "待到貨",
  pickup: "待取貨",
  done: "已完成",
  all: "全部",
};

const HIDDEN_PHASES = new Set(["transferred"]);

// 一頁 10 筆，捲到底自動再顯示 10 筆。資料（半年內全部；liff-api 逐頁撈到見底，
// 不再砍最新 100 筆 —— 重度團友半年 200+ 張，砍尾巴會讓已完成的舊單「消失」）
// 一開始就整批在手上，這裡分頁的是「渲染」—— 一次畫 100 張 OrderCard 才是卡頓的來源。
const PAGE_SIZE = 10;

function fmtAmount(n: number): string {
  return Number(n ?? 0).toLocaleString();
}

/**
 * 一個分頁的金額加總。**只有「待到貨」「待取貨」會顯示這張卡**（見 showTotals）：
 * 「全部」混著幾十張早就取貨付清的已完成單，掛一個「應付總金額」會讓團友以為
 * 還欠那麼多（2026-08-11 會員 109814 的回報：$13,845 裡有 $9,959 是歷史已完成單，
 * 真正沒領的只有 $3,886）；「已完成」則根本沒有應付。與其在「全部」
 * 解釋口徑，不如不顯示 —— 應付金額只出現在真的還有貨要領的分頁。
 *
 * 「應付」一律用 outstanding_amount（＝還沒領走的貨），**不可以用 payable_amount**。
 * 取貨當下就收現金，已取貨的單早就付清了，payable_amount 是「這張單本身多少錢」，
 * 不是「還欠多少」（2026-08-11 團友 528204 的災情，20260810000000 有完整脈絡）。
 *
 * 排除 cancelled / expired 是保險：待到貨 / 待取貨兩個分桶本來就不含它們，
 * 但口徑寫在這裡，之後誰把這張卡開到別的分頁也不會把不用付錢的單算進去。
 */
function sumOrders(list: OrderRow[]) {
  const active = list.filter((o) => !["cancelled", "expired"].includes(String(o.status ?? "")));
  return {
    count: active.length,
    amount: active.reduce(
      (s, o) => s + Number(o.outstanding_amount ?? o.payable_amount ?? 0),
      0,
    ),
    // 這個分頁裡有沒有「已經領走一部分」的單 —— 有的話總金額不等於
    // 各卡的應付金額相加，要在副標講清楚，不然團友手動加總又會對不上。
    hasPicked: active.some(
      (o) => Number(o.outstanding_amount ?? o.payable_amount ?? 0) < Number(o.payable_amount ?? 0),
    ),
  };
}

export default function OrdersPage() {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("waiting");
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

  // 依**品項行**分桶，不是整張單（2026-08-14）。短收之後一張單常常是
  // 「一件已領走、一件根本還沒到」—— 整張塞「待取貨」等於叫客人來拿沒到的貨。
  // 所以一張單會拆成數個分身，各自進自己的分頁（例：已取的行 → 已完成、
  // 沒到貨的行 → 待到貨）。「全部」維持整張單不拆。
  const buckets = useMemo(() => {
    const b: Record<Tab, OrderRow[]> = { all: orders, waiting: [], pickup: [], done: [] };
    for (const o of orders) {
      const parts = splitOrderByPhase(o);
      // 應付金額要**分攤**到各分身，不能每個分身都掛整張單的 outstanding ——
      // 一張單同時出現在「待到貨」和「待取貨」時會被算兩次
      //（CLAUDE.md：未結金額重複計算是踩過的雷）。
      // 依「該分身未取貨值 / 整張單未取貨值」等比分攤，兩頁相加仍等於原本的 outstanding。
      const wholeUnpicked = unpickedSubtotal(o.items);
      const outstanding = Number(o.outstanding_amount ?? o.payable_amount ?? 0);
      for (const [phase, part] of parts) {
        // 已轉讓不出現在任何分頁；「不成立」分頁已拿掉，void 分身沒地方去
        //（整張取消 / 逾期的單照樣以整單型態出現在「全部」，不會消失）
        if (phase === "transferred" || phase === "void") continue;
        b[phase as Exclude<Tab, "all">].push({
          ...part,
          outstanding_amount:
            wholeUnpicked > 0
              ? (outstanding * unpickedSubtotal(part.items)) / wholeUnpicked
              : 0,
        });
      }
    }
    return b;
  }, [orders]);

  const [visible, setVisible] = useState(PAGE_SIZE);

  // 「已完成」改依「那一次到店結單」分組 —— 客人一趟拿走好幾個團的貨、當場付一次
  // 現金，平鋪的訂單列表拼不回那一次到底拿了什麼（見 lib/pickups.ts）。
  // 一張單分兩次取完會拆成兩張卡，所以這一頁的卡片數 ≠ bucket.length，
  // 分頁要照節點自己算。
  const doneGroups = useMemo(() => buildDoneGroups(buckets.done), [buckets.done]);

  const bucket = buckets[tab];
  const isDone = tab === "done";
  const display = isDone ? [] : bucket.slice(0, visible);
  const displayGroups = isDone ? takeGroupOrders(doneGroups, visible) : [];
  const cardCount = isDone ? countGroupOrders(doneGroups) : bucket.length;
  const hasMore = cardCount > visible;
  // 總金額卡只在「待到貨」「待取貨」出現（理由見 sumOrders 註解），照整個分頁算
  const showTotals = tab === "waiting" || tab === "pickup";
  const totals = sumOrders(bucket);

  // 捲到底自動載入下一頁（sentinel 進到視窗下方 300px 內就先載，捲起來無縫）
  const sentinelRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (!hasMore) return;
    const el = sentinelRef.current;
    if (!el) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) setVisible((v) => v + PAGE_SIZE);
      },
      { rootMargin: "300px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [hasMore, tab, loading]);

  return (
    <PageShell title="我的訂單">
      <SubTabs
        variant="scroll"
        value={tab}
        onChange={(v) => {
          setTab(v as Tab);
          setVisible(PAGE_SIZE); // 換分頁回到第一頁
        }}
        options={(Object.keys(TAB_LABEL) as Tab[]).map((t) => ({
          value: t,
          label: TAB_LABEL[t],
          // 「全部」不掛數字；待到貨/待取貨掛數字提醒還有幾筆
          count: t === "all" || t === "done" ? undefined : buckets[t].length,
        }))}
      />

      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && <LoadingScreen />}

        {/* 這個分頁的應付總金額 — 客人最常問的就是「這些加起來多少錢」。
            只在待到貨 / 待取貨出現：其他分頁掛金額只會誤導（見 sumOrders） */}
        {!loading && !err && showTotals && totals.count > 0 && (
          <div className="card flex items-center justify-between gap-3 px-4 py-3">
            <div className="min-w-0">
              <div className="text-[16px] text-[var(--foreground)]">應付總金額</div>
              <div className="mt-0.5 text-[13px] text-[var(--secondary-label)]">
                共 {totals.count} 筆訂單
                {totals.hasPicked && (
                  <>
                    <span className="mx-1.5 text-[var(--tertiary-label)]">·</span>
                    已取貨的不計（取貨時付現）
                  </>
                )}
              </div>
            </div>
            <span className="flex-shrink-0 text-[26px] font-semibold tabular-nums text-[var(--brand-strong)]">
              ${fmtAmount(totals.amount)}
            </span>
          </div>
        )}

        {err && (
          <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[14px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && cardCount === 0 && (
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

        {/* 已完成：一次到店結單包成一個外框，裡面是那一次拿走的訂單卡。
            對不到取貨紀錄的（舊資料 / liff-api 還沒補上 pickups）visit 是 null，
            不畫外框、維持原本平鋪的樣子。 */}
        {isDone &&
          displayGroups.map((g, i) => (
            <div
              key={g.key}
              className="animate-in"
              style={{ animationDelay: `${Math.min(i, 8) * 50}ms` }}
            >
              {g.visit ? (
                <PickupVisitGroup visit={g.visit}>
                  {/* 同一張單在同一次結單裡可能有兩片（店員分兩下結同一張單），
                      key 不能只用 order.id */}
                  {g.orders.map((o) => (
                    <OrderCard
                      key={`${o.id}:${o.items[0]?.id ?? 0}`}
                      order={o}
                      viewPhase="done"
                      inGroup
                    />
                  ))}
                </PickupVisitGroup>
              ) : (
                <div className="space-y-3">
                  {g.orders.map((o) => (
                    <OrderCard key={`${o.id}:${o.items[0]?.id ?? 0}`} order={o} viewPhase="done" />
                  ))}
                </div>
              )}
            </div>
          ))}

        {!isDone &&
          display.map((o, i) => (
            <div
              key={o.id}
              className="animate-in"
              style={{ animationDelay: `${Math.min(i % PAGE_SIZE, 8) * 50}ms` }}
            >
              {/* 分身卡的右上角狀態字要講「這一頁」的語意；「全部」不拆頁，維持整張單的狀態 */}
              <OrderCard order={o} viewPhase={tab === "all" ? undefined : (tab as OrderPhase)} />
            </div>
          ))}

        {!loading && hasMore && (
          <div ref={sentinelRef} className="py-4 text-center text-[13px] text-[var(--ios-gray)]">
            載入更多…
          </div>
        )}
        {!loading && !hasMore && cardCount > PAGE_SIZE && (
          <div className="py-4 text-center text-[13px] text-[var(--tertiary-label)]">
            已顯示全部 {cardCount} 筆
          </div>
        )}
      </div>
    </PageShell>
  );
}

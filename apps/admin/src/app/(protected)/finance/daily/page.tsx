"use client";

// 日結報表：依日期 × 分店統計「已取走品項」的金額（已完成 + 部分取貨已取走的部分）。
// 口徑 = rpc_daily_pickup_settlement（picked_up 逐行、qty×單價、不扣折扣、
// 排除內部容器單），與 /orders KPI「今日取貨金額」同一套，兩邊數字對得起來。
// 分店帳號鎖自己店（比照 /pickup 的 branchLocked 慣例）；HQ 可切全部分店。

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { useDefaultStoreFromUser, useUserBranchStoreId } from "@/lib/useDefaultStoreFromUser";
import { useMyStores, useRole } from "@/lib/role";
import { orderStatusLabel } from "@/lib/orderStatus";
import { withBasePath } from "@/lib/basePath";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";

type Store = { id: number; code: string; name: string };

type DayRow = {
  ymd: string;
  store_id: number;
  store_name: string;
  orders: number;
  qty: number;
  amount: number;
  completed_orders: number;
  completed_amount: number;
  partial_orders: number;
  partial_amount: number;
  other_amount: number;
};

type OrderRow = {
  ymd: string;
  store_id: number;
  store_name: string;
  order_id: number;
  order_no: string;
  status: string;
  member_name: string | null;
  item_count: number;
  qty: number;
  amount: number;
  picked_at: string;
};

type Report = {
  date_from: string;
  date_to: string;
  days: DayRow[];
  orders: OrderRow[];
  orders_total: number;
  orders_truncated: boolean;
};

function localYmd(d = new Date()): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${dd}`;
}

function addDays(ymd: string, n: number): string {
  const d = new Date(`${ymd}T12:00:00`);
  d.setDate(d.getDate() + n);
  return localYmd(d);
}

function money(n: number): string {
  return `$${Math.round(Number(n)).toLocaleString()}`;
}

export default function DailySettlementPage() {
  const today = localYmd();
  const [dateFrom, setDateFrom] = useState(today);
  const [dateTo, setDateTo] = useState(today);
  const [storeFilter, setStoreFilter] = useState<string>("");

  const [stores, setStores] = useState<Store[]>([]);
  const [report, setReport] = useState<Report | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 分店帳號鎖自己店（比照 /pickup）：錢的報表不給跨店看
  const role = useRole();
  const myStores = useMyStores();
  const branchLocked =
    (role === "store_manager" || role === "store_staff") &&
    myStores.length > 0 &&
    !myStores.includes("總倉");
  const branchStoreId = useUserBranchStoreId(stores);
  useDefaultStoreFromUser(stores, storeFilter, setStoreFilter, !branchLocked);

  useEffect(() => {
    if (branchLocked && branchStoreId != null && storeFilter !== String(branchStoreId)) {
      setStoreFilter(String(branchStoreId));
    }
  }, [branchLocked, branchStoreId, storeFilter]);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const { data } = await sb.from("stores").select("id, code, name").order("name");
      setStores((data ?? []) as Store[]);
    })();
  }, []);

  useEffect(() => {
    // 分店帳號要等鎖店解析完成才打，避免先閃一下全站金額
    if (branchLocked && branchStoreId == null) return;
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e1 } = await sb.rpc("rpc_daily_pickup_settlement", {
          p_store_id: storeFilter ? Number(storeFilter) : null,
          p_date_from: dateFrom,
          p_date_to: dateTo,
        });
        if (cancelled) return;
        if (e1) { setError(e1.message); return; }
        setError(null);
        setReport(data as Report);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [storeFilter, dateFrom, dateTo, branchLocked, branchStoreId]);

  const totals = useMemo(() => {
    const t = {
      orders: 0, qty: 0, amount: 0,
      completedOrders: 0, completedAmount: 0,
      partialOrders: 0, partialAmount: 0,
      otherAmount: 0,
    };
    for (const d of report?.days ?? []) {
      t.orders += Number(d.orders);
      t.qty += Number(d.qty);
      t.amount += Number(d.amount);
      t.completedOrders += Number(d.completed_orders);
      t.completedAmount += Number(d.completed_amount);
      t.partialOrders += Number(d.partial_orders);
      t.partialAmount += Number(d.partial_amount);
      t.otherAmount += Number(d.other_amount);
    }
    return t;
  }, [report]);

  const multiDay = dateFrom !== dateTo;
  const showStoreCol = !storeFilter;
  const lockedStoreName = branchLocked
    ? stores.find((s) => s.id === branchStoreId)?.name ?? myStores[0] ?? ""
    : "";

  function setRange(from: string, to: string) {
    setDateFrom(from);
    setDateTo(to);
  }

  const quickRanges: { label: string; from: string; to: string }[] = [
    { label: "今天", from: today, to: today },
    { label: "昨天", from: addDays(today, -1), to: addDays(today, -1) },
    { label: "近 7 天", from: addDays(today, -6), to: today },
    { label: "本月", from: `${today.slice(0, 8)}01`, to: today },
  ];

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">日結報表</h1>
        <p className="text-sm text-zinc-500">
          每天實際取走的貨（已完成＋部分取貨已取走的部分）＝當天收的現金。
          {loading ? " 載入中…" : ""}
        </p>
      </header>

      <div className="flex flex-wrap items-center gap-2">
        {quickRanges.map((r) => {
          const active = dateFrom === r.from && dateTo === r.to;
          return (
            <SpinButton
              key={r.label}
              onClick={() => setRange(r.from, r.to)}
              className={`rounded-md border px-3 py-1.5 text-sm ${
                active
                  ? "border-blue-500 bg-blue-50 font-medium text-blue-700 dark:border-blue-600 dark:bg-blue-950 dark:text-blue-300"
                  : "border-zinc-300 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
              }`}
            >
              {r.label}
            </SpinButton>
          );
        })}
        <div className="flex items-center gap-1 text-sm">
          <DatePicker
            value={dateFrom}
            onChange={(v) => { setDateFrom(v); if (v > dateTo) setDateTo(v); }}
            className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-left text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
          <span className="text-zinc-400">～</span>
          <DatePicker
            value={dateTo}
            onChange={(v) => { setDateTo(v); if (v < dateFrom) setDateFrom(v); }}
            className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-left text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </div>
        {branchLocked ? (
          <span className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-1.5 text-sm text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-300">
            {lockedStoreName || "本店"}
          </span>
        ) : (
          <select
            value={storeFilter}
            onChange={(e) => setStoreFilter(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">全部分店</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>{s.code} {s.name}</option>
            ))}
          </select>
        )}
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="取貨金額" value={money(totals.amount)} accent="positive" />
        <Stat
          label={`已完成訂單（${totals.completedOrders} 張）`}
          value={money(totals.completedAmount)}
        />
        <Stat
          label={`部分取貨訂單（${totals.partialOrders} 張）`}
          value={money(totals.partialAmount)}
        />
        <Stat label="取貨件數" value={`${Math.round(totals.qty).toLocaleString()} 件`} />
      </div>
      {totals.otherAmount > 0 && (
        <p className="text-xs text-amber-600">
          ⚠ 另有 {money(totals.otherAmount)} 取貨掛在非「已完成／部分取貨」狀態的訂單上（可能剛被轉單或人工改過狀態）。
        </p>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{error}</p>
        </div>
      )}

      {(multiDay || showStoreCol) && (
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <Th>日期</Th>
                {showStoreCol && <Th>分店</Th>}
                <Th className="text-right">單數</Th>
                <Th className="text-right">件數</Th>
                <Th className="text-right">已完成</Th>
                <Th className="text-right">部分取貨</Th>
                <Th className="text-right">取貨金額</Th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {report === null ? (
                <tr><td colSpan={7} className="p-3 text-center text-zinc-500">載入中…</td></tr>
              ) : report.days.length === 0 ? (
                <tr><td colSpan={7} className="p-6 text-center text-zinc-500">這段期間沒有取貨。</td></tr>
              ) : report.days.map((d) => (
                <tr key={`${d.ymd}-${d.store_id}`} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="text-xs">{d.ymd}</Td>
                  {showStoreCol && <Td className="text-xs">{d.store_name}</Td>}
                  <Td className="text-right font-mono">{d.orders}</Td>
                  <Td className="text-right font-mono">{Math.round(Number(d.qty))}</Td>
                  <Td className="text-right font-mono">{money(d.completed_amount)}</Td>
                  <Td className="text-right font-mono">{Number(d.partial_amount) > 0 ? money(d.partial_amount) : "—"}</Td>
                  <Td className="text-right font-mono font-medium">{money(d.amount)}</Td>
                </tr>
              ))}
            </tbody>
            {report !== null && report.days.length > 1 && (
              <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <Td className="text-xs font-medium" colSpan={showStoreCol ? 2 : 1}>合計</Td>
                  <Td className="text-right font-mono font-medium">{totals.orders}</Td>
                  <Td className="text-right font-mono font-medium">{Math.round(totals.qty)}</Td>
                  <Td className="text-right font-mono font-medium">{money(totals.completedAmount)}</Td>
                  <Td className="text-right font-mono font-medium">{totals.partialAmount > 0 ? money(totals.partialAmount) : "—"}</Td>
                  <Td className="text-right font-mono font-semibold">{money(totals.amount)}</Td>
                </tr>
              </tfoot>
            )}
          </table>
        </div>
      )}

      <div>
        <div className="mb-2 flex items-center justify-between">
          <span className="text-sm font-medium">
            取貨訂單明細（{report?.orders_total ?? 0} 筆
            {report?.orders_truncated ? `，僅顯示最近 ${report.orders.length} 筆` : ""}）
          </span>
        </div>
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <Th>取貨時間</Th>
                <Th>訂單編號</Th>
                {showStoreCol && <Th>分店</Th>}
                <Th>會員</Th>
                <Th>狀態</Th>
                <Th className="text-right">品項</Th>
                <Th className="text-right">數量</Th>
                <Th className="text-right">金額</Th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {report === null ? (
                <tr><td colSpan={8} className="p-3 text-center text-zinc-500">載入中…</td></tr>
              ) : report.orders.length === 0 ? (
                <tr><td colSpan={8} className="p-6 text-center text-zinc-500">這段期間沒有取貨。</td></tr>
              ) : report.orders.map((o) => (
                <tr key={`${o.order_id}-${o.ymd}`} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="whitespace-nowrap text-xs text-zinc-500">
                    {multiDay ? `${o.ymd} ` : ""}
                    {new Date(o.picked_at).toLocaleTimeString("zh-TW", { hour: "2-digit", minute: "2-digit", hour12: false })}
                  </Td>
                  <Td className="font-mono text-xs">
                    <a
                      href={withBasePath(`/orders?q=${encodeURIComponent(o.order_no)}&storeId=${o.store_id}`)}
                      className="text-blue-600 hover:underline dark:text-blue-400"
                    >
                      {o.order_no}
                    </a>
                  </Td>
                  {showStoreCol && <Td className="text-xs">{o.store_name}</Td>}
                  <Td className="text-xs">{o.member_name ?? "—"}</Td>
                  <Td>
                    <span className={`inline-block rounded px-2 py-0.5 text-xs ${
                      o.status === "completed"
                        ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                        : o.status === "partially_completed"
                        ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                        : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
                    }`}>
                      {orderStatusLabel(o.status)}
                    </span>
                  </Td>
                  <Td className="text-right font-mono">{o.item_count}</Td>
                  <Td className="text-right font-mono">{Math.round(Number(o.qty))}</Td>
                  <Td className="text-right font-mono">{money(o.amount)}</Td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <p className="text-xs text-zinc-400">
        金額＝取走品項的 數量 × 單價（不含折扣、運費），與訂單頁「今日取貨金額」同口徑；
        部分取貨的訂單只計已取走的品項。內部單（RR-／【內部】xx 店）不計。
        撤銷取貨後自動從報表移除。
      </p>
    </div>
  );
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: "positive" | "negative" | "neutral" }) {
  const cls =
    accent === "positive" ? "text-emerald-600" :
    accent === "negative" ? "text-rose-600" :
    "text-zinc-700 dark:text-zinc-200";
  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-1 text-base font-medium ${cls}`}>{value}</div>
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "", colSpan }: { children: React.ReactNode; className?: string; colSpan?: number }) {
  return <td colSpan={colSpan} className={`px-3 py-2 ${className}`}>{children}</td>;
}

"use client";

// 分店端「每日進貨對帳」— 不用等月結送單就看得到金額。
// 店家當天被問「今日進貨總共多少錢？」時，直接開這頁報數字。
//
// 金額口徑與月結對帳單完全相同（分店價；空中轉出/退貨沖回為負值），
// 每日金額加總 = 該月月結的貨款金額（不含總部人工調整）。
// 資料走 rpc_store_inbound_daily_summary / rpc_store_inbound_day_items
// （20260803000000），分店帳號只查得到自己店。

import Link from "next/link";
import { Fragment, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { useAuth } from "@/components/AuthProvider";
import Spinner, { LoadingBlock } from "@/components/Spinner";

type StoreRow = { id: number; name: string; location_id: number | null };

type DaySummary = { date: string; line_count: number; amount: number };
type Summary = {
  store_id: number;
  store_name: string;
  month: string;
  days: DaySummary[];
  month_amount: number;
  month_lines: number;
};

type DayItem = {
  transfer_id: number;
  transfer_no: string | null;
  transfer_item_id: number;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  qty: number;
  unit_branch_price: number;
  amount: number;
  entry_type: "hq_inbound" | "air_in" | "air_out" | "free_in" | "free_out" | "return_out";
  description: string | null;
  missing_price: boolean;
  received_at: string;
};
type DayDetail = { store_id: number; store_name: string; date: string; items: DayItem[]; total: number };

const ENTRY_TYPE_LABEL: Record<DayItem["entry_type"], string> = {
  hq_inbound: "總倉進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
  free_in: "自由轉入",
  free_out: "自由轉出",
  return_out: "退貨沖回",
};

// 負數寫成 -$130（不是 $-130）：退貨沖回那行店家一眼看得懂是扣款
const money = (n: number) =>
  `${Number(n) < 0 ? "-" : ""}$${Math.abs(Number(n)).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}`;
const qtyText = (n: number) => Number(n).toLocaleString("zh-TW", { maximumFractionDigits: 3 });

// 台北時區的今天 / 本月（伺服器與瀏覽器時區都可能不是 +08，統一換算）
function taipeiParts(d = new Date()) {
  const s = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Taipei",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(d); // YYYY-MM-DD
  return { date: s, month: s.slice(0, 7) };
}

function weekday(dateStr: string) {
  const wd = ["日", "一", "二", "三", "四", "五", "六"];
  // 用 UTC 解析純日期字串，避免本機時區把日期推前一天
  return wd[new Date(`${dateStr}T00:00:00Z`).getUTCDay()];
}

export default function StoreDailyInboundPage() {
  const { user } = useAuth();
  const today = useMemo(() => taipeiParts(), []);
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [pickedStoreId, setPickedStoreId] = useState<number | null>(null);
  const [month, setMonth] = useState(today.month);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [loading, setLoading] = useState(false);
  // undefined = 還沒手動點過（沿用「今天預設展開」）；null = 使用者自己收合了
  const [openDateOverride, setOpenDateOverride] = useState<string | null | undefined>(undefined);
  const [detail, setDetail] = useState<DayDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await getSupabase()
        .from("stores")
        .select("id, name, location_id")
        .not("location_id", "is", null)
        .order("name");
      if (!cancelled) setStores((data ?? []) as StoreRow[]);
    })();
    return () => { cancelled = true; };
  }, []);

  // 分店帳號：只列自己綁定的店；HQ / 總倉：全部店可選
  const selectableStores = useMemo(() => {
    const userStores = user?.app_metadata?.stores as unknown;
    if (!Array.isArray(userStores) || userStores.length === 0) return stores;
    if (userStores.includes("總倉")) return stores;
    return stores.filter((s) => userStores.includes(s.name));
  }, [user, stores]);
  const storeId = pickedStoreId ?? selectableStores[0]?.id ?? null;

  useEffect(() => {
    if (storeId === null) return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      const { data, error: e } = await getSupabase().rpc("rpc_store_inbound_daily_summary", {
        p_store_id: storeId,
        p_month: `${month}-01`,
      });
      if (cancelled) return;
      setLoading(false);
      if (e) { setError(e.message); setSummary(null); return; }
      setError(null);
      setSummary(data as unknown as Summary);
    })();
    return () => { cancelled = true; };
  }, [storeId, month]);

  // 當月列表裡今天那列（今天不在本月時為 undefined）
  const todayRow = useMemo(
    () => summary?.days.find((d) => d.date === today.date),
    [summary, today.date],
  );
  const isCurrentMonth = month === today.month;

  // 沒手動點過時，今天有貨就預設展開 → 店家一進來就看得到今日明細
  const openDate = openDateOverride === undefined
    ? (isCurrentMonth && todayRow ? today.date : null)
    : openDateOverride;

  useEffect(() => {
    if (openDate === null || storeId === null) return;
    let cancelled = false;
    (async () => {
      setDetailLoading(true);
      setDetail(null);
      const { data, error: e } = await getSupabase().rpc("rpc_store_inbound_day_items", {
        p_store_id: storeId,
        p_date: openDate,
      });
      if (cancelled) return;
      setDetailLoading(false);
      if (e) { setError(e.message); setDetail(null); return; }
      setError(null);
      setDetail(data as unknown as DayDetail);
    })();
    return () => { cancelled = true; };
  }, [openDate, storeId]);

  function toggleDay(date: string) {
    setOpenDateOverride(openDate === date ? null : date);
  }

  if (selectableStores.length === 0 && stores.length > 0) {
    return (
      <div className="flex flex-1 flex-col gap-4 p-6">
        <p className="rounded-md border border-amber-300 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
          此帳號未綁定分店，請聯絡總部設定。
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">每日進貨對帳</h1>
          <p className="text-sm text-zinc-500">
            當日收到的所有品項、分店價與當日總金額，收完貨馬上看得到，不用等月結送單。
            金額口徑與月結對帳單相同（空中轉出／退貨沖回為負值），每日加總 = 該月月結貨款。
          </p>
        </div>
        <Link
          href="/transfers/settlement"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          回月結對帳
        </Link>
      </header>

      <div className="flex flex-wrap items-end gap-3">
        {selectableStores.length > 1 && (
          <label className="text-sm">
            <span className="mb-1 block text-xs text-zinc-500">分店</span>
            <select
              value={storeId ?? ""}
              onChange={(e) => { setPickedStoreId(Number(e.target.value) || null); setOpenDateOverride(undefined); }}
              className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            >
              {selectableStores.map((s) => (
                <option key={s.id} value={s.id}>{s.name}</option>
              ))}
            </select>
          </label>
        )}
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">月份</span>
          <input
            type="month"
            value={month}
            max={today.month}
            onChange={(e) => { setMonth(e.target.value || today.month); setOpenDateOverride(undefined); }}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        {!isCurrentMonth && (
          <button
            type="button"
            onClick={() => { setMonth(today.month); setOpenDateOverride(undefined); }}
            className="rounded-md border border-zinc-300 px-3 py-2 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            回到本月
          </button>
        )}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{error}</p>
        </div>
      )}

      {/* 今日 / 本月兩張數字卡：店家最常被問的兩個數 */}
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="rounded-md border border-zinc-200 p-4 dark:border-zinc-800">
          <p className="text-xs text-zinc-500">今日進貨金額（{today.date}）</p>
          <p className="mt-1 font-mono text-2xl">
            {loading ? <Spinner /> : isCurrentMonth ? money(todayRow?.amount ?? 0) : "—"}
          </p>
          <p className="mt-1 text-xs text-zinc-500">
            {isCurrentMonth ? `${todayRow?.line_count ?? 0} 個品項` : "切到本月才顯示"}
          </p>
        </div>
        <div className="rounded-md border border-zinc-200 p-4 dark:border-zinc-800">
          <p className="text-xs text-zinc-500">{summary?.month ?? month} 累計貨款</p>
          <p className="mt-1 font-mono text-2xl">
            {loading ? <Spinner /> : money(summary?.month_amount ?? 0)}
          </p>
          <p className="mt-1 text-xs text-zinc-500">
            {summary?.month_lines ?? 0} 個品項{isCurrentMonth ? "（本月未結，會隨收貨變動）" : ""}
          </p>
        </div>
      </div>

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">日期</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">品項數</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">當日金額</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">明細</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {loading ? (
              <tr><td colSpan={4} className="p-6"><LoadingBlock /></td></tr>
            ) : !summary || summary.days.length === 0 ? (
              <tr><td colSpan={4} className="p-6 text-center text-zinc-500">這個月還沒有收貨紀錄。</td></tr>
            ) : summary.days.map((d) => (
              <Fragment key={d.date}>
              <tr className={openDate === d.date ? "bg-zinc-50 dark:bg-zinc-900" : undefined}>
                <td className="px-3 py-2 font-mono text-xs">
                  {d.date}（{weekday(d.date)}）
                  {d.date === today.date && (
                    <span className="ml-2 rounded bg-blue-100 px-1.5 py-0.5 text-[10px] text-blue-800 dark:bg-blue-950 dark:text-blue-300">今天</span>
                  )}
                </td>
                <td className="px-3 py-2 text-right font-mono text-zinc-500">{d.line_count}</td>
                <td className={`px-3 py-2 text-right font-mono ${d.amount < 0 ? "text-emerald-600" : ""}`}>{money(d.amount)}</td>
                <td className="px-3 py-2 text-right">
                  <button
                    type="button"
                    onClick={() => toggleDay(d.date)}
                    className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                  >
                    {openDate === d.date ? "收合" : "看明細"}
                  </button>
                </td>
              </tr>
              {openDate === d.date && (
                <tr>
                  <td colSpan={4} className="px-3 pb-3">
                    <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
                      {detailLoading || !detail ? (
                        <div className="p-4"><LoadingBlock /></div>
                      ) : detail.items.length === 0 ? (
                        <p className="p-4 text-center text-xs text-zinc-500">當日無明細。</p>
                      ) : (
                        <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
                          <thead className="bg-zinc-50 dark:bg-zinc-900">
                            <tr>
                              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">品項</th>
                              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">類別</th>
                              <th className="px-2 py-1.5 text-right font-medium text-zinc-500">數量</th>
                              <th className="px-2 py-1.5 text-right font-medium text-zinc-500">分店價</th>
                              <th className="px-2 py-1.5 text-right font-medium text-zinc-500">小計</th>
                              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">單號</th>
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                            {detail.items.map((it) => (
                              <tr key={`${it.entry_type}-${it.transfer_item_id}`}>
                                <td className="px-2 py-1.5">
                                  <span className="font-medium">{it.product_name ?? `SKU #${it.sku_id}`}</span>
                                  {it.variant_name && <span className="text-zinc-500"> {it.variant_name}</span>}
                                  {it.sku_code && <span className="ml-1 font-mono text-[10px] text-zinc-400">{it.sku_code}</span>}
                                  {it.missing_price && (
                                    <span className="ml-1 rounded bg-red-100 px-1 py-0.5 text-[10px] text-red-800 dark:bg-red-950 dark:text-red-300">
                                      未設分店價
                                    </span>
                                  )}
                                </td>
                                <td className="px-2 py-1.5 text-zinc-500">{ENTRY_TYPE_LABEL[it.entry_type]}</td>
                                <td className="px-2 py-1.5 text-right font-mono">{qtyText(it.qty)}</td>
                                <td className="px-2 py-1.5 text-right font-mono">
                                  {it.entry_type === "free_in" || it.entry_type === "free_out" ? "估價" : money(it.unit_branch_price)}
                                </td>
                                <td className={`px-2 py-1.5 text-right font-mono ${it.amount < 0 ? "text-emerald-600" : ""}`}>
                                  {money(it.amount)}
                                </td>
                                <td className="px-2 py-1.5 font-mono text-[10px] text-zinc-500">{it.transfer_no ?? `#${it.transfer_id}`}</td>
                              </tr>
                            ))}
                          </tbody>
                          <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                            <tr>
                              <td className="px-2 py-1.5 font-medium" colSpan={4}>當日合計</td>
                              <td className="px-2 py-1.5 text-right font-mono font-semibold">{money(detail.total)}</td>
                              <td />
                            </tr>
                          </tfoot>
                        </table>
                      )}
                    </div>
                  </td>
                </tr>
              )}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-zinc-500">
        註：金額為分店價（總倉賣斷給分店的價格），不含總部月結時的人工調整（運費分攤、折讓等）。
        正式應付金額以每月的月結對帳單為準。
      </p>
    </div>
  );
}

"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import {
  TransferReceiveModal,
  TRANSFER_TYPE_LABEL,
  parseWaveId,
  type Transfer,
  type Wave,
} from "@/components/TransferReceiveModal";

type Location = { id: number; name: string };

type ItemAgg = {
  itemCount: number;
  totalShipped: number;
  totalReceived: number;
};

const STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  confirmed: "已確認",
  shipped: "已派貨",
  received: "已收貨",
  cancelled: "已取消",
  closed: "已結案",
};

const STATUS_COLOR: Record<string, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  shipped: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  received: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  closed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-400",
};

export default function TransfersListPage() {
  const [transfers, setTransfers] = useState<Transfer[] | null>(null);
  const [locations, setLocations] = useState<Map<number, string>>(new Map());
  const [waves, setWaves] = useState<Map<number, Wave>>(new Map());
  const [aggs, setAggs] = useState<Map<number, ItemAgg>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [opening, setOpening] = useState<Transfer | null>(null);

  // Filters
  const [statusFilter, setStatusFilter] = useState<string>("all");
  const [typeFilter, setTypeFilter] = useState<string>("all");
  const [srcFilter, setSrcFilter] = useState<number | "all">("all");
  const [dstFilter, setDstFilter] = useState<number | "all">("all");
  const [varianceFilter, setVarianceFilter] = useState<"all" | "shortage" | "match">("all");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("transfers")
          .select(
            "id, transfer_no, source_location, dest_location, status, transfer_type, shipped_at, received_at, notes",
          )
          .order("id", { ascending: false })
          .limit(200);
        if (e) throw new Error(e.message);
        const rows = (data as Transfer[] | null) ?? [];

        const locIds = Array.from(
          new Set(rows.flatMap((r) => [r.source_location, r.dest_location])),
        );
        const locMap = new Map<number, string>();
        if (locIds.length > 0) {
          const { data: locs } = await sb
            .from("locations")
            .select("id, name")
            .in("id", locIds);
          for (const l of (locs as Location[] | null) ?? []) {
            locMap.set(l.id, l.name);
          }
        }

        const waveIds = Array.from(
          new Set(rows.map((r) => parseWaveId(r.transfer_no)).filter((x): x is number => x !== null)),
        );
        const waveMap = new Map<number, Wave>();
        if (waveIds.length > 0) {
          const { data: ws } = await sb
            .from("picking_waves")
            .select("id, wave_code, wave_date, created_at")
            .in("id", waveIds);
          for (const w of (ws as Wave[] | null) ?? []) waveMap.set(w.id, w);
        }

        const aggMap = new Map<number, ItemAgg>();
        const tIds = rows.map((r) => r.id);
        if (tIds.length > 0) {
          const { data: itemRows } = await sb
            .from("transfer_items")
            .select("transfer_id, qty_shipped, qty_received")
            .in("transfer_id", tIds);
          for (const r of (itemRows as
            | { transfer_id: number; qty_shipped: number; qty_received: number }[]
            | null) ?? []) {
            const cur = aggMap.get(r.transfer_id) ?? {
              itemCount: 0,
              totalShipped: 0,
              totalReceived: 0,
            };
            cur.itemCount += 1;
            cur.totalShipped += Number(r.qty_shipped);
            cur.totalReceived += Number(r.qty_received);
            aggMap.set(r.transfer_id, cur);
          }
        }

        if (!cancelled) {
          setTransfers(rows);
          setLocations(locMap);
          setWaves(waveMap);
          setAggs(aggMap);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick]);

  const srcOptions = useMemo(() => {
    const set = new Map<number, string>();
    for (const t of transfers ?? []) {
      set.set(t.source_location, locations.get(t.source_location) ?? `#${t.source_location}`);
    }
    return Array.from(set.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }, [transfers, locations]);

  const dstOptions = useMemo(() => {
    const set = new Map<number, string>();
    for (const t of transfers ?? []) {
      set.set(t.dest_location, locations.get(t.dest_location) ?? `#${t.dest_location}`);
    }
    return Array.from(set.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }, [transfers, locations]);

  const filtered = useMemo(() => {
    return (transfers ?? []).filter((t) => {
      if (statusFilter !== "all" && t.status !== statusFilter) return false;
      if (typeFilter !== "all" && t.transfer_type !== typeFilter) return false;
      if (srcFilter !== "all" && t.source_location !== srcFilter) return false;
      if (dstFilter !== "all" && t.dest_location !== dstFilter) return false;
      if (varianceFilter !== "all") {
        const a = aggs.get(t.id);
        if (!a) return false;
        const v = a.totalReceived - a.totalShipped;
        if (varianceFilter === "shortage" && v >= 0) return false;
        if (varianceFilter === "match" && v !== 0) return false;
      }
      return true;
    });
  }, [transfers, statusFilter, typeFilter, srcFilter, dstFilter, varianceFilter, aggs]);

  const summary = useMemo(() => {
    const total = filtered.length;
    let pending = 0;
    let received = 0;
    let shortageCount = 0;
    let totalVariance = 0;
    for (const t of filtered) {
      if (t.status === "shipped") pending += 1;
      if (t.status === "received") received += 1;
      const a = aggs.get(t.id);
      if (a) {
        const v = a.totalReceived - a.totalShipped;
        if (t.status === "received" && v < 0) {
          shortageCount += 1;
          totalVariance += v;
        }
      }
    }
    return { total, pending, received, shortageCount, totalVariance };
  }, [filtered, aggs]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">調撥單列表</h1>
          <p className="text-sm text-zinc-500">
            {transfers === null
              ? "載入中…"
              : `共 ${summary.total} 張 · 待收 ${summary.pending} · 已收 ${summary.received}` +
                (summary.shortageCount > 0
                  ? ` · 短收 ${summary.shortageCount} 張 (合計 ${summary.totalVariance})`
                  : "")}
          </p>
        </div>
        <a
          href="/transfers/inbox"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          → 收貨待辦
        </a>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex flex-wrap items-end gap-3 rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
        <FilterSelect label="狀態" value={statusFilter} onChange={setStatusFilter}>
          <option value="all">全部</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </FilterSelect>
        <FilterSelect label="類型" value={typeFilter} onChange={setTypeFilter}>
          <option value="all">全部</option>
          {Object.entries(TRANSFER_TYPE_LABEL).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </FilterSelect>
        <FilterSelect
          label="來源"
          value={String(srcFilter)}
          onChange={(v) => setSrcFilter(v === "all" ? "all" : Number(v))}
        >
          <option value="all">全部</option>
          {srcOptions.map(([id, name]) => (
            <option key={id} value={id}>
              {name}
            </option>
          ))}
        </FilterSelect>
        <FilterSelect
          label="目的地"
          value={String(dstFilter)}
          onChange={(v) => setDstFilter(v === "all" ? "all" : Number(v))}
        >
          <option value="all">全部</option>
          {dstOptions.map(([id, name]) => (
            <option key={id} value={id}>
              {name}
            </option>
          ))}
        </FilterSelect>
        <FilterSelect
          label="差異"
          value={varianceFilter}
          onChange={(v) => setVarianceFilter(v as "all" | "shortage" | "match")}
        >
          <option value="all">全部</option>
          <option value="shortage">僅短收</option>
          <option value="match">無差異</option>
        </FilterSelect>
      </div>

      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>單號</Th>
              <Th>類型</Th>
              <Th>來源 → 目的地</Th>
              <Th>撿貨單號</Th>
              <Th>派出時間</Th>
              <Th className="text-right">品項</Th>
              <Th className="text-right">出貨 / 實收</Th>
              <Th className="text-right">差異</Th>
              <Th>狀態</Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {transfers !== null && filtered.length === 0 && (
              <tr>
                <td colSpan={10} className="p-6 text-center text-sm text-zinc-500">
                  沒有符合條件的 transfer。
                </td>
              </tr>
            )}
            {filtered.map((t) => {
              const a = aggs.get(t.id);
              const variance = a ? a.totalReceived - a.totalShipped : 0;
              const wid = parseWaveId(t.transfer_no);
              const wave = wid !== null ? waves.get(wid) : undefined;
              const isShipped = t.status === "shipped";
              return (
                <tr key={t.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                  <td className="whitespace-nowrap px-3 py-2 font-mono text-xs">{t.transfer_no}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-zinc-600 dark:text-zinc-300">
                    {TRANSFER_TYPE_LABEL[t.transfer_type] ?? t.transfer_type}
                  </td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs">
                    <span>{locations.get(t.source_location) ?? `#${t.source_location}`}</span>
                    <span className="mx-1 text-zinc-400">→</span>
                    <span className="font-medium">
                      {locations.get(t.dest_location) ?? `#${t.dest_location}`}
                    </span>
                  </td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs">
                    {wave ? (
                      <a
                        href={`/picking/history?wave=${wave.id}`}
                        className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                        title={`配送日 ${wave.wave_date}`}
                      >
                        {wave.wave_code}
                      </a>
                    ) : (
                      <span className="text-zinc-400">—</span>
                    )}
                  </td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-zinc-600 dark:text-zinc-300">
                    {t.shipped_at ? new Date(t.shipped_at).toLocaleString("zh-TW") : "—"}
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs">
                    {a?.itemCount ?? 0}
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs">
                    <span>{a?.totalShipped ?? 0}</span>
                    <span className="mx-1 text-zinc-400">/</span>
                    <span>{a?.totalReceived ?? 0}</span>
                  </td>
                  <td
                    className={`px-3 py-2 text-right font-mono text-xs font-semibold ${
                      variance === 0
                        ? "text-zinc-400"
                        : variance < 0
                        ? "text-red-600 dark:text-red-400"
                        : "text-purple-600 dark:text-purple-400"
                    }`}
                  >
                    {variance === 0 ? "—" : variance > 0 ? `+${variance}` : `${variance}`}
                  </td>
                  <td className="px-3 py-2">
                    <span
                      className={`inline-block rounded px-2 py-0.5 text-xs ${
                        STATUS_COLOR[t.status] ?? ""
                      }`}
                    >
                      {STATUS_LABEL[t.status] ?? t.status}
                    </span>
                  </td>
                  <td className="px-3 py-2 text-right">
                    {isShipped ? (
                      <button
                        onClick={() => setOpening(t)}
                        className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-700"
                      >
                        收貨
                      </button>
                    ) : (
                      <button
                        onClick={() => setOpening(t)}
                        className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                      >
                        看明細
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {opening && (
        <TransferReceiveModal
          transfer={opening}
          srcName={locations.get(opening.source_location) ?? `#${opening.source_location}`}
          dstName={locations.get(opening.dest_location) ?? `#${opening.dest_location}`}
          wave={(() => {
            const wid = parseWaveId(opening.transfer_no);
            return wid !== null ? waves.get(wid) ?? null : null;
          })()}
          onClose={() => setOpening(null)}
          onSubmitted={() => {
            setOpening(null);
            setReloadTick((t) => t + 1);
          }}
        />
      )}
    </div>
  );
}

function FilterSelect({
  label,
  value,
  onChange,
  children,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  children: React.ReactNode;
}) {
  return (
    <label className="flex flex-col gap-1 text-xs">
      <span className="text-zinc-500">{label}</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
      >
        {children}
      </select>
    </label>
  );
}

function Th({
  children,
  className = "",
}: {
  children?: React.ReactNode;
  className?: string;
}) {
  return (
    <th
      className={`whitespace-nowrap px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}
    >
      {children}
    </th>
  );
}

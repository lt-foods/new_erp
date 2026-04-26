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

export default function TransfersInboxPage() {
  const [transfers, setTransfers] = useState<Transfer[] | null>(null);
  const [locations, setLocations] = useState<Map<number, string>>(new Map());
  const [waves, setWaves] = useState<Map<number, Wave>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [opening, setOpening] = useState<Transfer | null>(null);
  const [locationFilter, setLocationFilter] = useState<number | "all">("all");
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

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
          .in("status", ["shipped", "received"])
          .order("shipped_at", { ascending: false })
          .limit(100);
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

        if (!cancelled) {
          setTransfers(rows);
          setLocations(locMap);
          setWaves(waveMap);
          setError(null);
          const auto = new Set<string>();
          for (const r of rows) {
            if (r.status !== "shipped") continue;
            const wid = parseWaveId(r.transfer_no);
            auto.add(wid !== null ? `wave-${wid}` : "other");
          }
          setExpanded(auto);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick]);

  const destOptions = useMemo(() => {
    const set = new Map<number, string>();
    for (const t of transfers ?? []) {
      set.set(t.dest_location, locations.get(t.dest_location) ?? `#${t.dest_location}`);
    }
    return Array.from(set.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }, [transfers, locations]);

  const filtered = useMemo(
    () =>
      (transfers ?? []).filter(
        (t) => locationFilter === "all" || t.dest_location === locationFilter,
      ),
    [transfers, locationFilter],
  );

  const groups = useMemo(() => {
    const map = new Map<
      string,
      { label: string; subLabel: string; transfers: Transfer[]; sortKey: number }
    >();
    for (const t of filtered) {
      const wid = parseWaveId(t.transfer_no);
      const key = wid !== null ? `wave-${wid}` : "other";
      let entry = map.get(key);
      if (!entry) {
        const w = wid !== null ? waves.get(wid) : undefined;
        entry = {
          label: w?.wave_code ?? (wid !== null ? `WAVE-${wid}` : "其他 transfer"),
          subLabel: w ? `配送日 ${w.wave_date}` : "",
          transfers: [],
          sortKey: w ? new Date(w.created_at).getTime() : 0,
        };
        map.set(key, entry);
      }
      entry.transfers.push(t);
    }
    return Array.from(map.entries())
      .sort((a, b) => b[1].sortKey - a[1].sortKey)
      .map(([key, v]) => ({ key, ...v }));
  }, [filtered, waves]);

  function toggle(key: string) {
    setExpanded((cur) => {
      const next = new Set(cur);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">收貨</h1>
          <p className="text-sm text-zinc-500">
            {transfers === null
              ? "載入中…"
              : (() => {
                  const pending = filtered.filter((t) => t.status === "shipped").length;
                  const done = filtered.length - pending;
                  return `待收 ${pending} · 已收 ${done}`;
                })()}
          </p>
        </div>
        <label className="flex items-center gap-2 text-sm">
          <span className="text-zinc-500">分店</span>
          <select
            value={String(locationFilter)}
            onChange={(e) =>
              setLocationFilter(e.target.value === "all" ? "all" : Number(e.target.value))
            }
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="all">全部</option>
            {destOptions.map(([id, name]) => (
              <option key={id} value={id}>
                {name}
              </option>
            ))}
          </select>
        </label>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {transfers !== null && groups.length === 0 && (
        <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          沒有符合條件的 transfer。
        </div>
      )}

      <div className="flex flex-col gap-2">
        {groups.map((g) => {
          const open = expanded.has(g.key);
          const pendingCount = g.transfers.filter((t) => t.status === "shipped").length;
          const doneCount = g.transfers.length - pendingCount;
          return (
            <section
              key={g.key}
              className="overflow-hidden rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
            >
              <button
                onClick={() => toggle(g.key)}
                className="flex w-full items-center justify-between gap-3 px-4 py-2 text-left hover:bg-zinc-50 dark:hover:bg-zinc-950"
              >
                <div className="flex items-center gap-3">
                  <span className="text-zinc-400">{open ? "▾" : "▸"}</span>
                  <div>
                    <div className="font-mono text-sm font-semibold">{g.label}</div>
                    {g.subLabel && (
                      <div className="text-[11px] text-zinc-500">{g.subLabel}</div>
                    )}
                  </div>
                </div>
                <div className="flex items-center gap-2 text-xs">
                  {pendingCount > 0 && (
                    <span className="rounded bg-amber-100 px-2 py-0.5 text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                      待收 {pendingCount}
                    </span>
                  )}
                  {doneCount > 0 && (
                    <span className="rounded bg-emerald-100 px-2 py-0.5 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                      已收 {doneCount}
                    </span>
                  )}
                </div>
              </button>

              {open && (
                <div className="overflow-x-auto border-t border-zinc-200 dark:border-zinc-800">
                  <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                    <thead className="bg-zinc-50 dark:bg-zinc-950">
                      <tr>
                        <Th>分店</Th>
                        <Th>單號</Th>
                        <Th>類型</Th>
                        <Th>派出時間</Th>
                        <Th>狀態</Th>
                        <Th></Th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                      {g.transfers.map((t) => {
                        const isShipped = t.status === "shipped";
                        return (
                          <tr key={t.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                            <td className="px-3 py-2 text-sm font-medium">
                              {locations.get(t.dest_location) ?? `#${t.dest_location}`}
                            </td>
                            <td className="px-3 py-2 font-mono text-xs">{t.transfer_no}</td>
                            <td className="px-3 py-2 text-xs text-zinc-600 dark:text-zinc-300">
                              {TRANSFER_TYPE_LABEL[t.transfer_type] ?? t.transfer_type}
                            </td>
                            <td className="px-3 py-2 text-xs text-zinc-600 dark:text-zinc-300">
                              {t.shipped_at
                                ? new Date(t.shipped_at).toLocaleString("zh-TW")
                                : "—"}
                            </td>
                            <td className="px-3 py-2">
                              {isShipped ? (
                                <span className="inline-block rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                                  待收
                                </span>
                              ) : (
                                <span className="inline-block rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                                  ✓ 已收
                                  {t.received_at && (
                                    <span className="ml-1">
                                      {new Date(t.received_at).toLocaleString("zh-TW", {
                                        dateStyle: "short",
                                        timeStyle: "short",
                                      })}
                                    </span>
                                  )}
                                </span>
                              )}
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
              )}
            </section>
          );
        })}
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

function Th({ children }: { children?: React.ReactNode }) {
  return (
    <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">
      {children}
    </th>
  );
}

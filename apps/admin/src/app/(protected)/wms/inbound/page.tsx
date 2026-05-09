"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import {
  TransferReceiveModal,
  TRANSFER_TYPE_LABEL,
  parseWaveId,
  type Transfer,
  type Wave,
} from "@/components/TransferReceiveModal";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";

type Location = { id: number; name: string };
type StoreLite = { id: number; location_id: number | null };
type ItemSummary = { lines: number; totalQty: number; names: string[] };

export default function TransfersInboxPage() {
  const [transfers, setTransfers] = useState<Transfer[] | null>(null);
  const [locations, setLocations] = useState<Map<number, string>>(new Map());
  const [waves, setWaves] = useState<Map<number, Wave>>(new Map());
  const [itemSummary, setItemSummary] = useState<Map<number, ItemSummary>>(new Map());
  const [locationToStore, setLocationToStore] = useState<Map<number, number>>(new Map());
  const [transferCampaigns, setTransferCampaigns] = useState<Map<number, number[]>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [opening, setOpening] = useState<Transfer | null>(null);
  const [locationFilter, setLocationFilter] = useState<number | "all">("all");
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [doneLimit, setDoneLimit] = useState(50);
  const [doneTotal, setDoneTotal] = useState(0);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [batchBusy, setBatchBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        // 拆兩個 query 防止 NULL shipped_at 的 received 把 limit 用滿、擠掉真正待收的 shipped
        const [{ data: pendingData, error: e1 }, { data: doneData, error: e2, count: doneCount }] = await Promise.all([
          sb
            .from("transfers")
            .select(
              "id, transfer_no, source_location, dest_location, status, transfer_type, shipped_at, received_at, notes",
            )
            .eq("status", "shipped")
            .order("shipped_at", { ascending: false, nullsFirst: false }),
          sb
            .from("transfers")
            .select(
              "id, transfer_no, source_location, dest_location, status, transfer_type, shipped_at, received_at, notes",
              { count: "exact" },
            )
            .eq("status", "received")
            .order("received_at", { ascending: false, nullsFirst: false })
            .limit(doneLimit),
        ]);
        if (e1) throw new Error(e1.message);
        if (e2) throw new Error(e2.message);
        if (!cancelled) setDoneTotal(doneCount ?? 0);
        const rows = ([...(pendingData ?? []), ...(doneData ?? [])] as Transfer[]);

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

        // 抓 transfer_items + skus 用於顯示「商品/數量」
        const summary = new Map<number, ItemSummary>();
        if (rows.length > 0) {
          const transferIds = rows.map((r) => r.id);
          const { data: tiRows } = await sb
            .from("transfer_items")
            .select("transfer_id, sku_id, qty_shipped")
            .in("transfer_id", transferIds);
          const items = (tiRows ?? []) as { transfer_id: number; sku_id: number; qty_shipped: number }[];
          const skuIds = Array.from(new Set(items.map((it) => it.sku_id)));
          const skuNameMap = new Map<number, string>();
          if (skuIds.length > 0) {
            const { data: skuRows } = await sb
              .from("skus")
              .select("id, product_name, variant_name")
              .in("id", skuIds);
            for (const s of (skuRows ?? []) as { id: number; product_name: string | null; variant_name: string | null }[]) {
              const label = `${s.product_name ?? ""}${s.variant_name ? ` / ${s.variant_name}` : ""}`.trim() || `#${s.id}`;
              skuNameMap.set(s.id, label);
            }
          }
          for (const tid of transferIds) summary.set(tid, { lines: 0, totalQty: 0, names: [] });
          for (const it of items) {
            const cur = summary.get(it.transfer_id) ?? { lines: 0, totalQty: 0, names: [] };
            cur.lines += 1;
            cur.totalQty += Number(it.qty_shipped);
            cur.names.push(`${skuNameMap.get(it.sku_id) ?? `#${it.sku_id}`} × ${Number(it.qty_shipped)}`);
            summary.set(it.transfer_id, cur);
          }
        }

        // location → store mapping (for /orders link filter)
        const locStoreMap = new Map<number, number>();
        if (locIds.length > 0) {
          const { data: storeRows } = await sb
            .from("stores")
            .select("id, location_id")
            .in("location_id", locIds);
          for (const s of (storeRows ?? []) as StoreLite[]) {
            if (s.location_id) locStoreMap.set(s.location_id, s.id);
          }
        }

        // 抓每張 transfer 涵蓋的 campaign_ids（用於 /orders link 多選 filter）
        const tcMap = new Map<number, number[]>();
        await Promise.allSettled(
          rows.map(async (r) => {
            const { data: cs } = await sb.rpc("rpc_get_campaigns_for_transfer", {
              p_transfer_id: r.id,
            });
            const ids = ((cs as { campaign_id: number }[] | null) ?? [])
              .map((x) => Number(x.campaign_id))
              .filter((x) => Number.isFinite(x));
            tcMap.set(r.id, ids);
          }),
        );

        if (!cancelled) {
          setTransfers(rows);
          setLocations(locMap);
          setWaves(waveMap);
          setItemSummary(summary);
          setLocationToStore(locStoreMap);
          setTransferCampaigns(tcMap);
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
  }, [reloadTick, doneLimit]);

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

  function toggleSelected(id: number) {
    setSelected((cur) => {
      const next = new Set(cur);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  const pendingIds = useMemo(
    () =>
      (transfers ?? [])
        .filter((t) => t.status === "shipped" && (locationFilter === "all" || t.dest_location === locationFilter))
        .map((t) => t.id),
    [transfers, locationFilter],
  );

  function selectAllPending() {
    setSelected(new Set(pendingIds));
  }
  function clearSelection() {
    setSelected(new Set());
  }

  // 單筆全收 — 直接 confirm + RPC,跟批次邏輯一樣(p_lines=null)
  async function quickReceive(t: Transfer) {
    const dest = locations.get(t.dest_location) ?? `#${t.dest_location}`;
    if (!confirm(`確認收貨 ${t.transfer_no}(送到 ${dest})?\n\n以「全收」(實收 = 派出量,無破損)處理。需要調整數量請點「調整」。`)) return;
    setBatchBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_receive_transfer", {
        p_transfer_id: t.id,
        p_lines: null,
        p_operator: operator,
        p_notes: null,
      });
      if (e) throw new Error(translateRpcError(e));
      setReloadTick((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBatchBusy(false);
    }
  }

  async function batchReceive() {
    if (selected.size === 0) return;
    if (!confirm(`確認批次收貨 ${selected.size} 筆?\n\n所有品項都將以「全收」(實收 = 派出量,無破損)處理。需要編輯數量請點個別「收貨」按鈕。`)) return;
    setBatchBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      const ids = Array.from(selected);
      const results = await Promise.allSettled(
        ids.map((id) =>
          sb.rpc("rpc_receive_transfer", {
            p_transfer_id: id,
            p_lines: null,
            p_operator: operator,
            p_notes: "批次收貨",
          }),
        ),
      );

      let okCount = 0;
      const failures: { id: number; error: string }[] = [];
      results.forEach((r, i) => {
        if (r.status === "fulfilled" && !r.value.error) okCount += 1;
        else {
          const errMsg = r.status === "fulfilled"
            ? translateRpcError(r.value.error)
            : (r.reason instanceof Error ? r.reason.message : String(r.reason));
          failures.push({ id: ids[i], error: errMsg });
        }
      });

      if (failures.length === 0) {
        alert(`✅ 批次收貨完成:${okCount} 筆`);
      } else {
        const failBrief = failures.slice(0, 5).map((f) => `  #${f.id}: ${f.error}`).join("\n");
        alert(
          `⚠ 部分成功:\n` +
          `成功 ${okCount} 筆 / 失敗 ${failures.length} 筆\n\n` +
          `失敗(前 5):\n${failBrief}` +
          (failures.length > 5 ? `\n…(還有 ${failures.length - 5} 筆)` : ""),
        );
      }
      setSelected(new Set());
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBatchBusy(false);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">📦 收貨待辦</h1>
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

      {/* 批次工具列 */}
      {pendingIds.length > 0 && (
        <div className="flex flex-wrap items-center gap-3 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
          <span className="text-xs text-zinc-500">
            {selected.size > 0
              ? `已選 ${selected.size} / ${pendingIds.length} 筆待收`
              : `待收 ${pendingIds.length} 筆`}
          </span>
          <SpinButton
            type="button"
            onClick={selectAllPending}
            disabled={selected.size === pendingIds.length}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            全選待收
          </SpinButton>
          {selected.size > 0 && (
            <SpinButton
              type="button"
              onClick={clearSelection}
              className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              清空
            </SpinButton>
          )}
          <SpinButton
            type="button"
            onClick={batchReceive}
            disabled={selected.size === 0 || batchBusy}
            className="ml-auto rounded-md bg-emerald-600 px-4 py-1.5 text-sm font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            {batchBusy ? "處理中…" : `✓ 批次收貨${selected.size > 0 ? ` (${selected.size})` : ""}`}
          </SpinButton>
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
              <SpinButton
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
              </SpinButton>

              {open && (
                <ul className="divide-y divide-zinc-200 border-t border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
                  {g.transfers.map((t) => {
                    const isShipped = t.status === "shipped";
                    const summary = itemSummary.get(t.id);
                    const storeId = locationToStore.get(t.dest_location);
                    const cids = transferCampaigns.get(t.id) ?? [];
                    const isSelected = selected.has(t.id);
                    return (
                      <li
                        key={t.id}
                        className={`flex flex-wrap items-start gap-3 px-4 py-2.5 transition hover:bg-zinc-50 dark:hover:bg-zinc-950 ${isShipped ? "" : "opacity-70"} ${isSelected ? "bg-blue-50 dark:bg-blue-950/30" : ""}`}
                      >
                        {isShipped ? (
                          <input
                            type="checkbox"
                            checked={isSelected}
                            onChange={() => toggleSelected(t.id)}
                            className="mt-1.5 cursor-pointer"
                            title="勾選後可批次收貨"
                          />
                        ) : (
                          <div className="w-4 mt-1.5" />
                        )}
                        <div className="flex-1 min-w-0">
                          <div className="flex flex-wrap items-baseline gap-2">
                            <span className="font-medium">{locations.get(t.dest_location) ?? `#${t.dest_location}`}</span>
                            <span className="font-mono text-[11px] text-zinc-500">{t.transfer_no}</span>
                            <span className="text-[10px] text-zinc-400">{TRANSFER_TYPE_LABEL[t.transfer_type] ?? t.transfer_type}</span>
                            {isShipped ? (
                              <span className="inline-flex rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">待收</span>
                            ) : (
                              <span className="inline-flex rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] font-medium text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                                ✓ 已收
                                {t.received_at && <span className="ml-1 font-normal opacity-70">{new Date(t.received_at).toLocaleDateString("zh-TW")}</span>}
                              </span>
                            )}
                          </div>
                          {summary && summary.lines > 0 && (
                            <div className="mt-0.5 flex flex-wrap items-baseline gap-x-3 text-xs text-zinc-600 dark:text-zinc-300" title={summary.names.join("\n")}>
                              <span className="text-zinc-500">{summary.lines} 項 / 共 {summary.totalQty} 件</span>
                              <span className="truncate">
                                {summary.names.slice(0, 2).join("、")}
                                {summary.names.length > 2 && <span className="text-zinc-400"> … +{summary.names.length - 2}</span>}
                              </span>
                              {storeId && (
                                <Link
                                  href={`/orders?${(() => {
                                    const qs = new URLSearchParams({ storeId: String(storeId) });
                                    if (cids.length > 0) qs.set("campaignIds", cids.join(","));
                                    return qs.toString();
                                  })()}`}
                                  className="text-[11px] text-blue-600 hover:underline dark:text-blue-400"
                                  title={cids.length > 0 ? `關聯 ${cids.length} 個開團` : undefined}
                                >
                                  → 訂單{cids.length > 0 ? `(${cids.length} 團)` : ""}
                                </Link>
                              )}
                            </div>
                          )}
                          {t.shipped_at && (
                            <div className="mt-0.5 text-[10px] text-zinc-400">派出 {new Date(t.shipped_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}</div>
                          )}
                        </div>
                        <div className="flex shrink-0 items-center gap-1">
                          {isShipped ? (
                            <>
                              <SpinButton
                                onClick={() => quickReceive(t)}
                                disabled={batchBusy}
                                className="rounded-md bg-emerald-600 px-4 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                                title="直接全收(實收 = 派出量,無破損)"
                              >
                                收貨
                              </SpinButton>
                              <SpinButton
                                onClick={() => setOpening(t)}
                                className="rounded-md border border-zinc-300 px-2 py-1.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                                title="調整數量 / 標記破損 / 短收"
                              >
                                ✎ 調整
                              </SpinButton>
                            </>
                          ) : (
                            <SpinButton
                              onClick={() => setOpening(t)}
                              className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                            >
                              看明細
                            </SpinButton>
                          )}
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}
            </section>
          );
        })}
      </div>

      {/* 已收歷史分頁:目前 doneLimit 比 doneTotal 少時顯示 */}
      {doneLimit < doneTotal && (
        <div className="flex items-center justify-center gap-3 py-2 text-xs text-zinc-500">
          <span>已顯示 {Math.min(doneLimit, doneTotal)} / {doneTotal} 筆已收歷史</span>
          <SpinButton
            onClick={() => setDoneLimit((n) => n + 50)}
            className="rounded-md border border-zinc-300 px-3 py-1.5 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            載入更多 (+50)
          </SpinButton>
          <SpinButton
            onClick={() => setDoneLimit(doneTotal)}
            className="rounded-md border border-zinc-300 px-3 py-1.5 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            載入全部
          </SpinButton>
        </div>
      )}

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

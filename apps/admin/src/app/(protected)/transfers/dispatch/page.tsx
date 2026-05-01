"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";

type Transfer = {
  id: number;
  transfer_no: string;
  source_location: number;
  dest_location: number;
  status: string;
  transfer_type: string;
  shipping_temp: string | null;
  is_air_transfer: boolean;
  hq_notes: string | null;
  notes: string | null;
  shipped_at: string | null;
  received_at: string | null;
  created_at: string;
};

type TransferItem = {
  id: number;
  transfer_id: number;
  sku_id: number;
  qty_requested: number;
  qty_shipped: number;
  qty_received: number;
  damage_qty: number;
  description: string | null;
};

type Sku = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

type Loc = { id: number; name: string };

type TabKey = "pending" | "arrived" | "distributed" | "received" | "air" | "all";

const TAB_LABEL: Record<TabKey, string> = {
  pending: "待審核",
  arrived: "已到總倉",
  distributed: "已配送",
  received: "已收到",
  air: "空中轉",
  all: "全部",
};

const TEMP_LABEL: Record<string, string> = {
  frozen: "❄️ 冷凍",
  chilled: "📦 冷藏",
  ambient: "🌡 常溫",
  mixed: "🔀 混溫",
};

function classifyTab(t: Transfer, hq: number | null): TabKey | null {
  if (t.is_air_transfer) return "air";
  if (t.status === "draft" || t.status === "confirmed") return "pending";
  if (hq !== null && t.dest_location === hq && t.status === "received") return "arrived";
  if (hq !== null && t.source_location === hq && t.status === "shipped") return "distributed";
  if (hq === null || t.dest_location !== hq) {
    if (t.status === "received") return "received";
  }
  return null;
}

export default function HqDispatchPage() {
  const [transfers, setTransfers] = useState<Transfer[] | null>(null);
  const [items, setItems] = useState<Map<number, TransferItem[]>>(new Map());
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [locs, setLocs] = useState<Map<number, string>>(new Map());
  const [hqLoc, setHqLoc] = useState<number | null>(null);
  const [tab, setTab] = useState<TabKey>("pending");
  const [srcFilter, setSrcFilter] = useState<number | "all">("all");
  const [dstFilter, setDstFilter] = useState<number | "all">("all");
  const [searchSku, setSearchSku] = useState("");
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [reloadTick, setReloadTick] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [damageOpen, setDamageOpen] = useState<Transfer | null>(null);
  const [editingNotes, setEditingNotes] = useState<Map<number, string>>(new Map());

  // Phase 1: 輕量載入 headers + locations + HQ id（給 counts / 篩選器用）
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();

        const { data: hqRows } = await sb
          .from("locations")
          .select("id")
          .eq("type", "central_warehouse")
          .eq("is_active", true)
          .limit(1);
        const hqId = ((hqRows as { id: number }[] | null) ?? [])[0]?.id ?? null;

        const { data: tRows, error: e } = await sb
          .from("transfers")
          .select(
            "id, transfer_no, source_location, dest_location, status, transfer_type, shipping_temp, is_air_transfer, hq_notes, notes, shipped_at, received_at, created_at",
          )
          .order("id", { ascending: false })
          .limit(500);
        if (e) throw new Error(e.message);
        const trs = (tRows as Transfer[] | null) ?? [];

        const locIds = Array.from(
          new Set(trs.flatMap((t) => [t.source_location, t.dest_location])),
        );
        const locMap = new Map<number, string>();
        if (locIds.length > 0) {
          const { data: lRows } = await sb
            .from("locations")
            .select("id, name")
            .in("id", locIds);
          for (const l of (lRows as Loc[] | null) ?? []) locMap.set(l.id, l.name);
        }

        if (!cancelled) {
          setTransfers(trs);
          setLocs(locMap);
          setHqLoc(hqId);
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

  // Phase 2: 切到 tab 時、抓當前 tab 的 transfers items + skus（lazy）
  useEffect(() => {
    if (!transfers || transfers.length === 0) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      // 重算當前 tab 要顯示的 transfer ids
      const tIds = transfers
        .filter((t) => tab === "all" || classifyTab(t, hqLoc) === tab)
        .map((t) => t.id);
      if (tIds.length === 0) {
        if (!cancelled) {
          setItems(new Map());
          setSkus(new Map());
        }
        return;
      }
      const { data: itRows } = await sb
        .from("transfer_items")
        .select("id, transfer_id, sku_id, qty_requested, qty_shipped, qty_received, damage_qty, description")
        .in("transfer_id", tIds);
      const its = (itRows as TransferItem[] | null) ?? [];
      const itMap = new Map<number, TransferItem[]>();
      for (const it of its) {
        const arr = itMap.get(it.transfer_id) ?? [];
        arr.push(it);
        itMap.set(it.transfer_id, arr);
      }
      const skuIds = Array.from(new Set(its.map((i) => i.sku_id)));
      const skuMap = new Map<number, Sku>();
      if (skuIds.length > 0) {
        const { data: skuRows } = await sb
          .from("skus")
          .select("id, sku_code, product_name, variant_name")
          .in("id", skuIds);
        for (const s of (skuRows as Sku[] | null) ?? []) skuMap.set(s.id, s);
      }
      if (!cancelled) {
        setItems(itMap);
        setSkus(skuMap);
      }
    })();
    return () => { cancelled = true; };
  }, [tab, transfers, hqLoc]);

  // Tab counts
  const tabCounts = useMemo(() => {
    const c: Record<TabKey, number> = {
      pending: 0,
      arrived: 0,
      distributed: 0,
      received: 0,
      air: 0,
      all: 0,
    };
    for (const t of transfers ?? []) {
      c.all += 1;
      const k = classifyTab(t, hqLoc);
      if (k) c[k] += 1;
    }
    return c;
  }, [transfers, hqLoc]);

  // Filtered
  const filtered = useMemo(() => {
    const search = searchSku.trim().toLowerCase();
    return (transfers ?? []).filter((t) => {
      if (tab !== "all" && classifyTab(t, hqLoc) !== tab) return false;
      if (srcFilter !== "all" && t.source_location !== srcFilter) return false;
      if (dstFilter !== "all" && t.dest_location !== dstFilter) return false;
      if (search) {
        const its = items.get(t.id) ?? [];
        const hit = its.some((it) => {
          const s = skus.get(it.sku_id);
          return (
            (s?.sku_code ?? "").toLowerCase().includes(search) ||
            (s?.product_name ?? "").toLowerCase().includes(search) ||
            (s?.variant_name ?? "").toLowerCase().includes(search)
          );
        });
        if (!hit) return false;
      }
      return true;
    });
  }, [transfers, hqLoc, tab, srcFilter, dstFilter, searchSku, items, skus]);

  // Loc options derived
  const srcOpts = useMemo(() => {
    const set = new Map<number, string>();
    for (const t of transfers ?? [])
      set.set(t.source_location, locs.get(t.source_location) ?? `#${t.source_location}`);
    return Array.from(set.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }, [transfers, locs]);
  const dstOpts = useMemo(() => {
    const set = new Map<number, string>();
    for (const t of transfers ?? [])
      set.set(t.dest_location, locs.get(t.dest_location) ?? `#${t.dest_location}`);
    return Array.from(set.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }, [transfers, locs]);

  // Selected helpers
  const toggle = (id: number) =>
    setSelected((s) => {
      const next = new Set(s);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const toggleAll = () => {
    if (selected.size === filtered.length) setSelected(new Set());
    else setSelected(new Set(filtered.map((t) => t.id)));
  };

  // Batch RPCs
  const callBatchArrive = async () => {
    if (!hqLoc) return setError("找不到 HQ location");
    if (selected.size === 0) return setError("沒有選中任何單");
    setBusy(true);
    try {
      const sb = getSupabase();
      const { data, error: e } = await sb.rpc("rpc_transfer_arrive_at_hq_batch", {
        p_transfer_ids: Array.from(selected),
        p_hq_location_id: hqLoc,
        p_operator: (await sb.auth.getUser()).data.user?.id,
      });
      if (e) throw new Error(e.message);
      const res = data as { processed: number; succeeded: number[]; failed: { id: number; reason: string }[] };
      alert(
        `批次到倉：${res.succeeded.length} 成功 / ${res.failed.length} 失敗\n` +
          (res.failed.length ? res.failed.map((f) => `  #${f.id}: ${f.reason}`).join("\n") : ""),
      );
      setSelected(new Set());
      setReloadTick((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const callBatchDistribute = async () => {
    if (!hqLoc) return setError("找不到 HQ location");
    if (selected.size === 0) return setError("沒有選中任何單");
    setBusy(true);
    try {
      const sb = getSupabase();
      const { data, error: e } = await sb.rpc("rpc_transfer_distribute_batch", {
        p_transfer_ids: Array.from(selected),
        p_hq_location_id: hqLoc,
        p_operator: (await sb.auth.getUser()).data.user?.id,
      });
      if (e) throw new Error(e.message);
      const res = data as { processed: number; succeeded: number[]; failed: { id: number; reason: string }[] };
      alert(
        `批次配送：${res.succeeded.length} 成功 / ${res.failed.length} 失敗\n` +
          (res.failed.length ? res.failed.map((f) => `  #${f.id}: ${f.reason}`).join("\n") : ""),
      );
      setSelected(new Set());
      setReloadTick((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const callBatchDelete = async () => {
    if (selected.size === 0) return setError("沒有選中任何單");
    if (!confirm(`確定刪除 ${selected.size} 筆 draft 調撥單？`)) return;
    setBusy(true);
    try {
      const sb = getSupabase();
      const { data, error: e } = await sb.rpc("rpc_transfer_batch_delete", {
        p_transfer_ids: Array.from(selected),
        p_operator: (await sb.auth.getUser()).data.user?.id,
      });
      if (e) throw new Error(e.message);
      const res = data as { processed: number; deleted: number[]; failed: { id: number; reason: string }[] };
      alert(
        `批次刪除：${res.deleted.length} 成功 / ${res.failed.length} 失敗\n` +
          (res.failed.length ? res.failed.map((f) => `  #${f.id}: ${f.reason}`).join("\n") : ""),
      );
      setSelected(new Set());
      setReloadTick((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const saveHqNotes = async (transferId: number) => {
    const newVal = editingNotes.get(transferId);
    if (newVal === undefined) return;
    try {
      const sb = getSupabase();
      const { error: e } = await sb
        .from("transfers")
        .update({ hq_notes: newVal })
        .eq("id", transferId);
      if (e) throw new Error(e.message);
      setEditingNotes((m) => {
        const next = new Map(m);
        next.delete(transferId);
        return next;
      });
      setReloadTick((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">總倉調度中心</h1>
        <p className="text-sm text-zinc-500">
          {transfers === null ? "載入中…" : `共 ${transfers.length} 張`}
          {hqLoc === null ? " · ⚠️ 未找到 HQ location" : ""}
        </p>
      </header>

      {/* Tabs */}
      <div className="flex flex-wrap gap-2 border-b border-zinc-200 dark:border-zinc-800">
        {(Object.keys(TAB_LABEL) as TabKey[]).map((k) => (
          <button
            key={k}
            onClick={() => {
              setTab(k);
              setSelected(new Set());
            }}
            className={`-mb-px border-b-2 px-3 py-2 text-sm ${
              tab === k
                ? "border-blue-600 font-semibold text-blue-700 dark:text-blue-300"
                : "border-transparent text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
            }`}
          >
            {TAB_LABEL[k]} <span className="ml-1 text-xs text-zinc-400">{tabCounts[k]}</span>
          </button>
        ))}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* Filters + batch buttons */}
      <div className="flex flex-wrap items-end gap-3 rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
        <FilterSelect
          label="轉出店"
          value={String(srcFilter)}
          onChange={(v) => setSrcFilter(v === "all" ? "all" : Number(v))}
        >
          <option value="all">全部</option>
          {srcOpts.map(([id, name]) => (
            <option key={id} value={id}>
              {name}
            </option>
          ))}
        </FilterSelect>
        <FilterSelect
          label="轉入店"
          value={String(dstFilter)}
          onChange={(v) => setDstFilter(v === "all" ? "all" : Number(v))}
        >
          <option value="all">全部</option>
          {dstOpts.map(([id, name]) => (
            <option key={id} value={id}>
              {name}
            </option>
          ))}
        </FilterSelect>
        <label className="flex flex-col gap-1 text-xs">
          <span className="text-zinc-500">商品搜尋</span>
          <input
            value={searchSku}
            onChange={(e) => setSearchSku(e.target.value)}
            placeholder="商品編號 / 名稱"
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="ml-auto flex items-center gap-2">
          <span className="text-xs text-zinc-500">
            {selected.size > 0 ? `已選 ${selected.size}` : ""}
          </span>
          <button
            disabled={busy || selected.size === 0 || tab !== "distributed"}
            onClick={callBatchArrive}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
            title={tab !== "distributed" ? "切到「已配送」tab 才能批次到倉" : ""}
          >
            批次到倉
          </button>
          <button
            disabled={busy || selected.size === 0 || tab !== "pending"}
            onClick={callBatchDistribute}
            className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
            title={tab !== "pending" ? "切到「待審核」tab 才能批次配送" : ""}
          >
            批次配送
          </button>
          <button
            disabled={busy || selected.size === 0 || tab !== "pending"}
            onClick={callBatchDelete}
            className="rounded-md bg-red-600 px-3 py-1.5 text-xs font-semibold text-white disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
            title={tab !== "pending" ? "只能刪 draft (待審核) 的單" : ""}
          >
            批次刪除
          </button>
        </div>
      </div>

      {/* Table */}
      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>
                <input
                  type="checkbox"
                  checked={filtered.length > 0 && selected.size === filtered.length}
                  onChange={toggleAll}
                />
              </Th>
              <Th>單號 / 時間</Th>
              <Th>來源 → 目的</Th>
              <Th>商品</Th>
              <Th>溫層</Th>
              <Th>總倉備註</Th>
              <Th>操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {transfers !== null && filtered.length === 0 && (
              <tr>
                <td colSpan={7} className="p-6 text-center text-sm text-zinc-500">
                  目前沒有資料
                </td>
              </tr>
            )}
            {filtered.map((t) => {
              const its = items.get(t.id) ?? [];
              return (
                <tr key={t.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                  <td className="px-3 py-2">
                    <input
                      type="checkbox"
                      checked={selected.has(t.id)}
                      onChange={() => toggle(t.id)}
                    />
                  </td>
                  <td className="px-3 py-2 text-xs">
                    <div className="font-mono">{t.transfer_no}</div>
                    <div className="text-zinc-400">
                      {new Date(t.created_at).toLocaleString("zh-TW")}
                    </div>
                  </td>
                  <td className="px-3 py-2 text-xs">
                    <span>{locs.get(t.source_location) ?? `#${t.source_location}`}</span>
                    <span className="mx-1 text-zinc-400">→</span>
                    <span className="font-medium">
                      {locs.get(t.dest_location) ?? `#${t.dest_location}`}
                    </span>
                    {t.is_air_transfer && (
                      <span className="ml-1 rounded bg-amber-100 px-1 text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                        空中轉
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-xs">
                    {its.length === 0 ? (
                      <span className="text-zinc-400">—</span>
                    ) : (
                      <div className="space-y-0.5">
                        {its.slice(0, 3).map((it) => {
                          const s = skus.get(it.sku_id);
                          // 虛擬轉貨：line description 優先；真實 SKU 走 product_name
                          const label = it.description?.trim()
                            ? it.description
                            : (s?.product_name ?? "?") + (s?.variant_name ? "-" + s.variant_name : "");
                          return (
                            <div key={it.id}>
                              {label}
                              <span className="ml-1 text-zinc-400">×{it.qty_requested}</span>
                              {it.damage_qty > 0 && (
                                <span className="ml-1 text-red-600">
                                  (損壞 {it.damage_qty})
                                </span>
                              )}
                            </div>
                          );
                        })}
                        {its.length > 3 && (
                          <div className="text-zinc-400">…還有 {its.length - 3} 項</div>
                        )}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2 text-xs">
                    {t.shipping_temp ? TEMP_LABEL[t.shipping_temp] ?? t.shipping_temp : "—"}
                  </td>
                  <td className="px-3 py-2 text-xs">
                    <input
                      defaultValue={t.hq_notes ?? ""}
                      onChange={(e) =>
                        setEditingNotes((m) => new Map(m).set(t.id, e.target.value))
                      }
                      onBlur={() =>
                        editingNotes.has(t.id) ? saveHqNotes(t.id) : undefined
                      }
                      placeholder="輸入總倉備註…"
                      className="w-full rounded border border-zinc-200 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-800"
                    />
                  </td>
                  <td className="px-3 py-2 text-right">
                    {t.status === "received" && (
                      <button
                        onClick={() => setDamageOpen(t)}
                        className="rounded-md border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
                      >
                        登記損壞
                      </button>
                    )}
                    <Link
                      href={`/transfers?id=${t.id}`}
                      className="ml-2 text-xs text-blue-600 hover:underline dark:text-blue-400"
                    >
                      看明細
                    </Link>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {damageOpen && (
        <DamageModal
          transfer={damageOpen}
          items={items.get(damageOpen.id) ?? []}
          skus={skus}
          onClose={() => setDamageOpen(null)}
          onSubmitted={() => {
            setDamageOpen(null);
            setReloadTick((n) => n + 1);
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

function Th({ children }: { children?: React.ReactNode }) {
  return (
    <th className="whitespace-nowrap px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">
      {children}
    </th>
  );
}

function DamageModal({
  transfer,
  items,
  skus,
  onClose,
  onSubmitted,
}: {
  transfer: Transfer;
  items: TransferItem[];
  skus: Map<number, Sku>;
  onClose: () => void;
  onSubmitted: () => void;
}) {
  const [tiId, setTiId] = useState<number | null>(items[0]?.id ?? null);
  const [qty, setQty] = useState("");
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const submit = async () => {
    if (!tiId) {
      setErr("請選擇明細");
      return;
    }
    const q = Number(qty);
    if (!Number.isFinite(q) || q <= 0) {
      setErr("請輸入損壞數量 > 0");
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { error: e } = await sb.rpc("rpc_register_damage", {
        p_transfer_item_id: tiId,
        p_damage_qty: q,
        p_notes: notes || null,
        p_operator: (await sb.auth.getUser()).data.user?.id,
      });
      if (e) throw new Error(e.message);
      onSubmitted();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal open={true} onClose={onClose} title={`登記損壞 — ${transfer.transfer_no}`}>
      <div className="space-y-3 p-4">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-500">明細</span>
          <select
            value={tiId ?? ""}
            onChange={(e) => setTiId(Number(e.target.value))}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
          >
            {items.map((it) => {
              const s = skus.get(it.sku_id);
              const remaining = it.qty_received - it.damage_qty;
              return (
                <option key={it.id} value={it.id}>
                  {(s?.product_name ?? "?") + (s?.variant_name ? "-" + s.variant_name : "")}
                  {" — 已收 "}
                  {it.qty_received}
                  {" / 已損 "}
                  {it.damage_qty}
                  {" / 剩 "}
                  {remaining}
                </option>
              );
            })}
          </select>
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-500">損壞數量</span>
          <input
            type="number"
            min="0.001"
            step="0.001"
            value={qty}
            onChange={(e) => setQty(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-500">備註</span>
          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            rows={3}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="flex justify-end gap-2">
          <button
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
          >
            取消
          </button>
          <button
            onClick={submit}
            disabled={busy}
            className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-semibold text-white disabled:bg-zinc-300"
          >
            登記
          </button>
        </div>
      </div>
    </Modal>
  );
}

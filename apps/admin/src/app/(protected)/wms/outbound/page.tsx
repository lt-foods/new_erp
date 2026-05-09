"use client";

import Link from "next/link";
import { Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { TransferReceiveModal, parseWaveId, type Wave } from "@/components/TransferReceiveModal";
import { Modal } from "@/components/Modal";
import { PickModal, WAVE_STATUS_LABEL, WAVE_STATUS_COLOR, type PickWave } from "@/components/PickModal";
import SpinButton from "@/components/SpinButton";

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

type TabKey = "picking" | "pending" | "arrived" | "distributed" | "received" | "air" | "all";

const TAB_LABEL: Record<TabKey, string> = {
  picking: "撿貨",
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
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <HqDispatchContent />
    </Suspense>
  );
}

function HqDispatchContent() {
  const searchParams = useSearchParams();
  const deepLinkId = searchParams.get("id");
  const initialTab = (searchParams.get("tab") as TabKey | null) ?? "picking";
  const deepLinkWave = searchParams.get("wave");

  const [transfers, setTransfers] = useState<Transfer[] | null>(null);
  const [items, setItems] = useState<Map<number, TransferItem[]>>(new Map());
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [locs, setLocs] = useState<Map<number, string>>(new Map());
  const [hqLoc, setHqLoc] = useState<number | null>(null);
  const [tab, setTab] = useState<TabKey>(initialTab);
  const [srcFilter, setSrcFilter] = useState<number | "all">("all");
  const [dstFilter, setDstFilter] = useState<number | "all">("all");
  const [searchSku, setSearchSku] = useState("");
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [reloadTick, setReloadTick] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [damageOpen, setDamageOpen] = useState<Transfer | null>(null);
  const [detailOpen, setDetailOpen] = useState<Transfer | null>(null);
  const [waves, setWaves] = useState<Map<number, Wave>>(new Map());
  const [editingNotes, setEditingNotes] = useState<Map<number, string>>(new Map());

  // === 撿貨 tab 用:wave list + 編輯 modal + 直接派貨 ===
  const [pickWaves, setPickWaves] = useState<PickWave[] | null>(null);
  const [editingWave, setEditingWave] = useState<PickWave | null>(null);
  const [dispatchingWaveId, setDispatchingWaveId] = useState<number | null>(null);

  // 載入「未派貨」的 waves(draft / picking / picked) — 撿貨 tab 顯示用
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("picking_waves")
          .select("id, wave_code, wave_date, status, store_count, item_count, total_qty, note, created_at, source_po_id")
          .in("status", ["draft", "picking", "picked"])
          .order("created_at", { ascending: false })
          .limit(100);
        if (e) throw new Error(e.message);
        const waveRows = (data as Omit<PickWave, "expected_total" | "actual_total" | "source_po_no">[] | null) ?? [];

        const poIds = Array.from(new Set(waveRows.map((w) => w.source_po_id).filter((x): x is number => x !== null)));
        const poNoMap = new Map<number, string>();
        if (poIds.length) {
          const { data: poRows } = await sb
            .from("purchase_orders")
            .select("id, po_no")
            .in("id", poIds);
          for (const p of (poRows as { id: number; po_no: string }[] | null) ?? []) {
            poNoMap.set(p.id, p.po_no);
          }
        }

        const waveIds = waveRows.map((w) => w.id);
        // item_count 用 distinct sku_id;wave_items 是 (store × sku) row
        const totals = new Map<number, { expected: number; actual: number; skus: Set<number> }>();
        if (waveIds.length > 0) {
          const { data: itemRows } = await sb
            .from("picking_wave_items")
            .select("wave_id, sku_id, qty, picked_qty")
            .in("wave_id", waveIds);
          for (const r of (itemRows as { wave_id: number; sku_id: number; qty: number; picked_qty: number | null }[] | null) ?? []) {
            const cur = totals.get(r.wave_id) ?? { expected: 0, actual: 0, skus: new Set<number>() };
            cur.expected += Number(r.qty);
            cur.actual += Number(r.picked_qty ?? r.qty);
            cur.skus.add(r.sku_id);
            totals.set(r.wave_id, cur);
          }
        }

        if (cancelled) return;
        const enriched: PickWave[] = waveRows.map((r) => {
          const t = totals.get(r.id);
          return {
            ...r,
            total_qty: Number(r.total_qty),
            expected_total: t?.expected ?? 0,
            actual_total: t?.actual ?? 0,
            item_count: t?.skus.size ?? r.item_count,
            source_po_no: r.source_po_id ? (poNoMap.get(r.source_po_id) ?? null) : null,
          };
        });
        setPickWaves(enriched);
      } catch (e) {
        if (!cancelled) setError(translateRpcError(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick]);

  // Deep link ?wave=N — 自動開 PickModal
  useEffect(() => {
    if (!deepLinkWave || !pickWaves || editingWave) return;
    const id = Number(deepLinkWave);
    const target = pickWaves.find((w) => w.id === id);
    if (target) {
      setTab("picking");
      setEditingWave(target);
    }
  }, [deepLinkWave, pickWaves]); // eslint-disable-line react-hooks/exhaustive-deps

  // 直接派貨 — 不開 modal,自動 confirm_picked + generate_transfer
  async function directDispatchWave(w: PickWave) {
    if (!hqLoc) {
      setError("找不到總倉 location,請確認倉庫設定");
      return;
    }
    const needsConfirm = w.status !== "picked";
    const diff = w.actual_total - w.expected_total;
    const diffMsg = diff === 0
      ? ""
      : diff > 0
        ? `\n⚠ 實分 多 ${diff}(超撿)`
        : `\n⚠ 實分 少 ${-diff}(短缺,部分店家拿不到應有量)`;
    const msg =
      `確認派貨出倉 ${w.wave_code}?\n` +
      `${w.store_count} 間分店 · 應發 ${w.expected_total} / 實分 ${w.actual_total}${diffMsg}\n\n` +
      (needsConfirm
        ? "目前狀態為「" + (WAVE_STATUS_LABEL[w.status] ?? w.status) + "」,將自動 確認撿貨完成 + 派貨出倉。"
        : "將從總倉建立 transfer 並出庫。");
    if (!confirm(msg)) return;
    setDispatchingWaveId(w.id);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      if (needsConfirm) {
        const { error: e1 } = await sb.rpc("rpc_confirm_picked", {
          p_wave_id: w.id,
          p_operator: operator,
        });
        if (e1) throw new Error(e1.message);
      }
      const { error: e2 } = await sb.rpc("generate_transfer_from_wave", {
        p_wave_id: w.id,
        p_hq_location_id: hqLoc,
        p_operator: operator,
      });
      if (e2) throw new Error(e2.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setDispatchingWaveId(null);
    }
  }

  async function cancelWave(w: PickWave) {
    const reason = prompt(`取消撿貨單 ${w.wave_code} — 取消原因(選填,會留 audit log):`);
    if (reason === null) return;
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");
      const { error: e } = await sb.rpc("rpc_cancel_picking_wave", {
        p_wave_id: w.id,
        p_operator: operator,
        p_reason: reason.trim() || null,
      });
      if (e) throw new Error(translateRpcError(e));
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    }
  }

  // 撿貨 wave 依日期分組(顯示用)
  const groupedWaves = useMemo(() => {
    const map = new Map<string, PickWave[]>();
    for (const w of pickWaves ?? []) {
      const arr = map.get(w.wave_date) ?? [];
      arr.push(w);
      map.set(w.wave_date, arr);
    }
    return Array.from(map.entries())
      .sort((a, b) => b[0].localeCompare(a[0]))
      .map(([date, ws]) => ({
        date,
        waves: ws.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()),
      }));
  }, [pickWaves]);

  // Deep link:?id=X → 載入完自動開 detail modal
  useEffect(() => {
    if (!deepLinkId || !transfers || detailOpen) return;
    const id = Number(deepLinkId);
    const t = transfers.find((x) => x.id === id);
    if (t) {
      setTab("all"); // 切到「全部」確保看得到
      setDetailOpen(t);
    }
  }, [deepLinkId, transfers]); // eslint-disable-line react-hooks/exhaustive-deps

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

        const waveIds = Array.from(
          new Set(trs.map((t) => parseWaveId(t.transfer_no)).filter((x): x is number => x !== null)),
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
          setTransfers(trs);
          setLocs(locMap);
          setWaves(waveMap);
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
      picking: pickWaves?.length ?? 0,
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
  }, [transfers, hqLoc, pickWaves]);

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
      if (e) throw new Error(translateRpcError(e));
      const res = data as { processed: number; succeeded: number[]; failed: { id: number; reason: string }[] };
      alert(
        `批次到倉：${res.succeeded.length} 成功 / ${res.failed.length} 失敗\n` +
          (res.failed.length ? res.failed.map((f) => `  #${f.id}: ${translateRpcError(f.reason)}`).join("\n") : ""),
      );
      setSelected(new Set());
      setReloadTick((n) => n + 1);
    } catch (e) {
      setError(translateRpcError(e));
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
      if (e) throw new Error(translateRpcError(e));
      const res = data as { processed: number; succeeded: number[]; failed: { id: number; reason: string }[] };
      alert(
        `批次配送：${res.succeeded.length} 成功 / ${res.failed.length} 失敗\n` +
          (res.failed.length ? res.failed.map((f) => `  #${f.id}: ${translateRpcError(f.reason)}`).join("\n") : ""),
      );
      setSelected(new Set());
      setReloadTick((n) => n + 1);
    } catch (e) {
      setError(translateRpcError(e));
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
          (res.failed.length ? res.failed.map((f) => `  #${f.id}: ${translateRpcError(f.reason)}`).join("\n") : ""),
      );
      setSelected(new Set());
      setReloadTick((n) => n + 1);
    } catch (e) {
      setError(translateRpcError(e));
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
        <h1 className="text-xl font-semibold">📤 出貨集貨</h1>
        <p className="text-sm text-zinc-500">
          {transfers === null ? "載入中…" : `共 ${transfers.length} 張`}
          {hqLoc === null ? " · ⚠️ 未找到 HQ location" : ""}
        </p>
      </header>

      {/* Tabs */}
      <div className="flex flex-wrap gap-2 border-b border-zinc-200 dark:border-zinc-800">
        {(Object.keys(TAB_LABEL) as TabKey[]).map((k) => (
          <SpinButton
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
          </SpinButton>
        ))}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* === 撿貨 tab — 派貨工作台拆出來、未派貨的 wave === */}
      {tab === "picking" && (
        <div className="flex flex-col gap-3">
          {pickWaves === null ? (
            <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
              載入中…
            </div>
          ) : pickWaves.length === 0 ? (
            <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
              目前沒有待派貨的撿貨單。請至{" "}
              <Link href="/wms/picking" className="text-blue-600 hover:underline dark:text-blue-400">
                派貨工作台
              </Link>{" "}
              拆單。
            </div>
          ) : (
            groupedWaves.map((g) => (
              <section
                key={g.date}
                className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
              >
                <div className="flex items-baseline justify-between border-b border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-950">
                  <div className="flex items-baseline gap-2">
                    <span className="text-base">📅</span>
                    <span className="font-semibold">配送日 {g.date}</span>
                    <span className="text-xs text-zinc-500">
                      {g.waves.length} 張撿貨單
                    </span>
                  </div>
                  <Link
                    href={`/picking/print-sign?date=${g.date}`}
                    target="_blank"
                    className="rounded-md border border-blue-300 bg-blue-50 px-2 py-1 text-xs text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                  >
                    📄 列印分店簽收單
                  </Link>
                </div>
                <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {g.waves.map((w) => {
                    const diff = w.actual_total - w.expected_total;
                    const completionPct = w.expected_total > 0
                      ? Math.round((w.actual_total / w.expected_total) * 100)
                      : 0;
                    return (
                      <li
                        key={w.id}
                        className="flex flex-wrap items-start justify-between gap-3 px-3 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-950"
                      >
                        <div className="flex-1 min-w-0">
                          <div className="flex flex-wrap items-baseline gap-2">
                            <span className="font-mono text-sm font-semibold">
                              {w.wave_code}
                            </span>
                            <span
                              className={`inline-flex rounded px-2 py-0.5 text-[11px] font-medium ${WAVE_STATUS_COLOR[w.status] ?? ""}`}
                            >
                              {WAVE_STATUS_LABEL[w.status] ?? w.status}
                            </span>
                            {w.source_po_no && (
                              <span className="font-mono text-[11px] text-zinc-500">
                                ← {w.source_po_no}
                              </span>
                            )}
                          </div>
                          <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-600 dark:text-zinc-300">
                            <span>
                              {w.item_count} 品項 / {w.store_count} 店
                            </span>
                            <span>
                              應發 <span className="font-mono font-semibold">{w.expected_total}</span>
                            </span>
                            <span>
                              實分 <span className="font-mono font-semibold">{w.actual_total}</span>
                            </span>
                            <span
                              className={`font-medium ${
                                diff === 0
                                  ? "text-emerald-600 dark:text-emerald-400"
                                  : diff > 0
                                    ? "text-purple-600 dark:text-purple-400"
                                    : "text-rose-600 dark:text-rose-400"
                              }`}
                            >
                              {diff === 0 ? "✓ 數量正確" : diff > 0 ? `+${diff}` : `${diff}`}
                            </span>
                            {w.expected_total > 0 && (
                              <span className="text-zinc-500">完成 {completionPct}%</span>
                            )}
                            <span className="text-zinc-400">
                              建單{" "}
                              {new Date(w.created_at).toLocaleString("zh-TW", {
                                dateStyle: "short",
                                timeStyle: "short",
                              })}
                            </span>
                          </div>
                          {w.note && (
                            <div className="mt-1 text-[11px] text-zinc-500">📝 {w.note}</div>
                          )}
                        </div>
                        <div className="flex items-center gap-2">
                          <SpinButton
                            onClick={() => directDispatchWave(w)}
                            disabled={dispatchingWaveId === w.id || hqLoc === null}
                            className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                            title={
                              w.status === "picked"
                                ? "建立 transfer 並從總倉出庫"
                                : "自動 確認撿貨完成 + 派貨出倉"
                            }
                          >
                            {dispatchingWaveId === w.id ? "派貨中…" : "🚚 派貨出倉"}
                          </SpinButton>
                          <SpinButton
                            onClick={() => setEditingWave(w)}
                            className="rounded-md border border-zinc-300 px-3 py-1 text-xs text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                            title="開啟明細修正撿貨數量"
                          >
                            ✎ 修正數量
                          </SpinButton>
                          <SpinButton
                            onClick={() => cancelWave(w)}
                            title="軟取消(留 audit log)"
                            className="rounded-md border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-700 dark:text-red-400 dark:hover:bg-red-950"
                          >
                            取消
                          </SpinButton>
                        </div>
                      </li>
                    );
                  })}
                </ul>
              </section>
            ))
          )}
        </div>
      )}

      {/* === Transfer tabs (其他 tab) === */}
      {tab !== "picking" && (
      <>
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
          <SpinButton
            disabled={busy || selected.size === 0 || tab !== "distributed"}
            onClick={callBatchArrive}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
            title={tab !== "distributed" ? "切到「已配送」tab 才能批次到倉" : ""}
          >
            批次到倉
          </SpinButton>
          <SpinButton
            disabled={busy || selected.size === 0 || tab !== "pending"}
            onClick={callBatchDistribute}
            className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
            title={tab !== "pending" ? "切到「待審核」tab 才能批次配送" : ""}
          >
            批次配送
          </SpinButton>
          <SpinButton
            disabled={busy || selected.size === 0 || tab !== "pending"}
            onClick={callBatchDelete}
            className="rounded-md bg-red-600 px-3 py-1.5 text-xs font-semibold text-white disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
            title={tab !== "pending" ? "只能刪 draft (待審核) 的單" : ""}
          >
            批次刪除
          </SpinButton>
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
                      <SpinButton
                        onClick={() => setDamageOpen(t)}
                        className="rounded-md border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
                      >
                        登記損壞
                      </SpinButton>
                    )}
                    <SpinButton
                      onClick={() => setDetailOpen(t)}
                      className="ml-2 text-xs text-blue-600 hover:underline dark:text-blue-400"
                    >
                      看明細
                    </SpinButton>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      </>
      )}

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

      {detailOpen && (
        <TransferReceiveModal
          transfer={detailOpen}
          srcName={locs.get(detailOpen.source_location) ?? `#${detailOpen.source_location}`}
          dstName={locs.get(detailOpen.dest_location) ?? `#${detailOpen.dest_location}`}
          wave={(() => {
            const wid = parseWaveId(detailOpen.transfer_no);
            return wid !== null ? waves.get(wid) ?? null : null;
          })()}
          onClose={() => setDetailOpen(null)}
          onSubmitted={() => {
            setDetailOpen(null);
            setReloadTick((n) => n + 1);
          }}
        />
      )}

      {editingWave && (
        <PickModal
          wave={editingWave}
          onClose={() => {
            setEditingWave(null);
            setReloadTick((t) => t + 1);
          }}
          onSubmitted={() => {
            setEditingWave(null);
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
      if (e) throw new Error(translateRpcError(e));
      onSubmitted();
    } catch (e) {
      setErr(translateRpcError(e));
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
            min="1"
            step="1"
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
          <SpinButton
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={submit}
            disabled={busy}
            className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-semibold text-white disabled:bg-zinc-300"
          >
            登記
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

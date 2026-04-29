"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

type DemandRow = {
  close_date: string;
  sku_id: number;
  sku_label: string;
  sku_code: string | null;
  store_id: number;
  store_name: string;
  demand_qty: number;
  campaign_ids: number[];
  received_qty: number; // 已進庫量
  picked_qty: number; // 已建在非 cancelled wave 的 qty（同 close_date 的 campaigns 範圍）
  po_numbers: string[] | null;
  order_numbers: string[] | null;
};

type SkuCard = {
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  total_demand: number;
  total_picked: number; // 已撿過總量（跨分店加總）
  by_store: Map<number, number>;
  short_stores: { id: number; name: string; qty: number }[]; // 欠品店家
  close_date: string; // 結單日
  received_qty: number; // 已進庫量
  is_short: boolean; // 是否缺貨（進庫量 < 訂單需求）
  po_numbers: string[]; // PO 單號集合
  order_numbers: string[]; // 訂單號集合
  is_picked: boolean; // total_picked >= total_demand → 已全部撿過、不可再加入
};

type SelectedItem = {
  key: string; // "${close_date}|${sku_id}"
  close_date: string;
  sku_id: number;
};

export default function PickingWorkstationPage() {
  const router = useRouter();
  const [closeDate, setCloseDate] = useState("");
  const [waveDate, setWaveDate] = useState("");
  const [allCloseDates, setAllCloseDates] = useState<string[]>([]);
  const [demand, setDemand] = useState<DemandRow[] | null>(null);
  const [stores, setStores] = useState<{ id: number; name: string; code: string | null }[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [selectedItems, setSelectedItems] = useState<Set<string>>(new Set()); // "${close_date}|${sku_id}"
  const [demandHistory, setDemandHistory] = useState<Map<string, DemandRow[]>>(new Map()); // closeDate -> rows
  const [searchTerm, setSearchTerm] = useState("");
  const [showOnlyNonZero, setShowOnlyNonZero] = useState(false);
  const [expandedSkuIds, setExpandedSkuIds] = useState<Set<number>>(new Set());

  // 載入可用結單日
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data } = await sb
          .from("v_picking_demand_by_close_date")
          .select("close_date")
          .order("close_date", { ascending: false });
        if (cancelled) return;
        const set = new Set<string>();
        for (const r of (data as { close_date: string }[] | null) ?? []) {
          if (r.close_date) {
            const d = new Date(r.close_date).toLocaleDateString("sv-SE");
            set.add(d);
          }
        }
        const list = Array.from(set).sort().reverse();
        setAllCloseDates(list);
        if (!closeDate && list.length > 0) {
          setCloseDate(list[0]);
          const d = new Date(list[0]);
          d.setDate(d.getDate() + 2);
          setWaveDate(d.toLocaleDateString("sv-SE"));
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 載入需求
  useEffect(() => {
    if (!closeDate) return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("v_picking_demand_by_close_date")
          .select("close_date, sku_id, sku_label, sku_code, store_id, store_name, demand_qty, campaign_ids, received_qty, picked_qty, po_numbers, order_numbers")
          .eq("close_date", closeDate);
        if (e) throw new Error(e.message);
        if (cancelled) return;
        const rows = ((data as DemandRow[] | null) ?? []).map((r) => ({
          ...r,
          demand_qty: Number(r.demand_qty),
          picked_qty: Number(r.picked_qty),
        }));
        setDemand(rows);
        // 保存到歷史記錄
        setDemandHistory((prev) => new Map(prev).set(closeDate, rows));

        const storeIds = Array.from(new Set(rows.map((r) => r.store_id)));
        if (storeIds.length) {
          const { data: ss } = await sb
            .from("stores")
            .select("id, code, name")
            .in("id", storeIds)
            .order("id");
          if (!cancelled)
            setStores((ss as { id: number; code: string | null; name: string }[] | null) ?? []);
        } else {
          setStores([]);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [closeDate]);

  const allSkuCards: SkuCard[] = useMemo(() => {
    if (!demand || !closeDate) return [];
    const m = new Map<number, SkuCard>();
    const poSet = new Map<number, Set<string>>();
    const orderSet = new Map<number, Set<string>>();
    for (const r of demand) {
      if (!m.has(r.sku_id)) {
        m.set(r.sku_id, {
          sku_id: r.sku_id,
          sku_code: r.sku_code,
          sku_label: r.sku_label,
          total_demand: 0,
          total_picked: 0,
          by_store: new Map(),
          short_stores: [],
          close_date: closeDate,
          received_qty: Number(r.received_qty) || 0,
          is_short: false,
          po_numbers: [],
          order_numbers: [],
          is_picked: false,
        });
        poSet.set(r.sku_id, new Set());
        orderSet.set(r.sku_id, new Set());
      }
      const e = m.get(r.sku_id)!;
      e.total_demand += r.demand_qty;
      e.total_picked += Number(r.picked_qty) || 0;
      e.by_store.set(r.store_id, (e.by_store.get(r.store_id) ?? 0) + r.demand_qty);
      // 聚合 PO 和訂單號
      if (r.po_numbers) {
        for (const po of r.po_numbers) {
          if (po) poSet.get(r.sku_id)!.add(po);
        }
      }
      if (r.order_numbers) {
        for (const ord of r.order_numbers) {
          if (ord) orderSet.get(r.sku_id)!.add(ord);
        }
      }
    }
    // 欠品店家 = 有需求量的分店
    for (const card of m.values()) {
      const arr: { id: number; name: string; qty: number }[] = [];
      for (const [sid, q] of card.by_store) {
        if (q > 0) {
          const st = stores.find((s) => s.id === sid);
          arr.push({ id: sid, name: st?.name ?? `#${sid}`, qty: q });
        }
      }
      card.short_stores = arr.sort((a, b) => b.qty - a.qty);
      // 檢查缺貨：進庫量 < 訂單需求
      card.is_short = card.received_qty < card.total_demand;
      // 設置 PO 和訂單號
      card.po_numbers = Array.from(poSet.get(card.sku_id) ?? new Set<string>()).sort();
      card.order_numbers = Array.from(orderSet.get(card.sku_id) ?? new Set<string>()).sort();
    }
    for (const card of m.values()) {
      card.is_picked = card.total_demand > 0 && card.total_picked >= card.total_demand;
    }
    return Array.from(m.values()).sort((a, b) => {
      // 已撿的排在後面
      if (a.is_picked !== b.is_picked) return a.is_picked ? 1 : -1;
      return (a.sku_code ?? "").localeCompare(b.sku_code ?? "");
    });
  }, [demand, stores, closeDate]);

  const filteredCards = useMemo(() => {
    const term = searchTerm.trim().toLowerCase();
    if (!term) return allSkuCards;
    return allSkuCards.filter(
      (c) =>
        (c.sku_code ?? "").toLowerCase().includes(term) ||
        c.sku_label.toLowerCase().includes(term),
    );
  }, [allSkuCards, searchTerm]);

  const selectedCards = useMemo(() => {
    const m = new Map<number, SkuCard>();
    const poSet = new Map<number, Set<string>>();
    const orderSet = new Map<number, Set<string>>();
    // 遍歷所有 selectedItems，聚合它們的數據
    for (const item of selectedItems) {
      const [cd, skuIdStr] = item.split("|");
      const skuId = Number(skuIdStr);
      const rows = demandHistory.get(cd) ?? [];
      const itemRows = rows.filter((r) => r.sku_id === skuId);
      if (itemRows.length === 0) continue;

      if (!m.has(skuId)) {
        const first = itemRows[0];
        m.set(skuId, {
          sku_id: skuId,
          sku_code: first.sku_code,
          sku_label: first.sku_label,
          total_demand: 0,
          total_picked: 0,
          by_store: new Map(),
          short_stores: [],
          close_date: cd,
          received_qty: 0,
          is_short: false,
          po_numbers: [],
          order_numbers: [],
          is_picked: false,
        });
        poSet.set(skuId, new Set());
        orderSet.set(skuId, new Set());
      }
      const card = m.get(skuId)!;
      for (const r of itemRows) {
        card.total_demand += r.demand_qty;
        card.total_picked += Number(r.picked_qty) || 0;
        card.received_qty += Number(r.received_qty) || 0;
        card.by_store.set(r.store_id, (card.by_store.get(r.store_id) ?? 0) + r.demand_qty);
        // 聚合 PO 和訂單號
        if (r.po_numbers) {
          for (const po of r.po_numbers) {
            if (po) poSet.get(skuId)!.add(po);
          }
        }
        if (r.order_numbers) {
          for (const ord of r.order_numbers) {
            if (ord) orderSet.get(skuId)!.add(ord);
          }
        }
      }
    }
    // 重新計算欠品店家和缺貨狀態
    for (const card of m.values()) {
      const arr: { id: number; name: string; qty: number }[] = [];
      for (const [sid, q] of card.by_store) {
        if (q > 0) {
          const st = stores.find((s) => s.id === sid);
          arr.push({ id: sid, name: st?.name ?? `#${sid}`, qty: q });
        }
      }
      card.short_stores = arr.sort((a, b) => b.qty - a.qty);
      card.is_short = card.received_qty < card.total_demand;
      card.po_numbers = Array.from(poSet.get(card.sku_id) ?? new Set<string>()).sort();
      card.order_numbers = Array.from(orderSet.get(card.sku_id) ?? new Set<string>()).sort();
    }
    return Array.from(m.values()).sort((a, b) =>
      (a.sku_code ?? "").localeCompare(b.sku_code ?? ""),
    );
  }, [selectedItems, demandHistory, stores]);

  // 右側矩陣：篩有量欄位
  const visibleStores = useMemo(() => {
    if (!showOnlyNonZero) return stores;
    const has = new Set<number>();
    for (const c of selectedCards) for (const [sid, q] of c.by_store) if (q > 0) has.add(sid);
    return stores.filter((s) => has.has(s.id));
  }, [stores, selectedCards, showOnlyNonZero]);

  const allCampaignIds = useMemo(() => {
    const set = new Set<number>();
    for (const item of selectedItems) {
      const [cd, skuIdStr] = item.split("|");
      const skuId = Number(skuIdStr);
      const rows = demandHistory.get(cd) ?? [];
      for (const r of rows) {
        if (r.sku_id === skuId) {
          for (const id of r.campaign_ids ?? []) set.add(id);
        }
      }
    }
    return Array.from(set);
  }, [selectedItems, demandHistory]);

  function toggleSku(skuId: number) {
    if (!closeDate) return;
    const key = `${closeDate}|${skuId}`;
    setSelectedItems((cur) => {
      const next = new Set(cur);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  function toggleExpanded(skuId: number) {
    setExpandedSkuIds((cur) => {
      const next = new Set(cur);
      if (next.has(skuId)) next.delete(skuId);
      else next.add(skuId);
      return next;
    });
  }

  function selectAll() {
    if (!closeDate) return;
    setSelectedItems((cur) => {
      const next = new Set(cur);
      for (const c of allSkuCards) {
        next.add(`${closeDate}|${c.sku_id}`);
      }
      return next;
    });
  }

  function clearAll() {
    setSelectedItems(new Set());
  }

  async function createWave() {
    setSubmitting(true);
    setError(null);
    try {
      if (selectedCards.length === 0) throw new Error("請先從左側加入商品到大表");
      if (allCampaignIds.length === 0) throw new Error("選中的商品沒有對應 campaign");
      if (!waveDate) throw new Error("請選配送日");

      const { data: userRes } = await getSupabase().auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const { data: camp } = await getSupabase()
        .from("group_buy_campaigns")
        .select("tenant_id")
        .eq("id", allCampaignIds[0])
        .single();
      const tenantId = (camp as { tenant_id: string } | null)?.tenant_id;
      if (!tenantId) throw new Error("無法取得 tenant_id");

      const code = "WV" + new Date().toISOString().replace(/[-:T.]/g, "").slice(2, 14);

      const { error: rpcErr } = await getSupabase().rpc("rpc_create_picking_wave", {
        p_tenant_id: tenantId,
        p_campaign_ids: allCampaignIds,
        p_wave_date: waveDate,
        p_wave_code: code,
        p_operator: operator,
      });
      if (rpcErr) throw new Error(rpcErr.message);

      alert(
        `撿貨單建立完成：${code}\n含 ${selectedCards.length} 個 SKU、${visibleStores.length} 間分店`,
      );
      router.push(`/picking/history`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-3 p-4">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">批次撿貨工作站</h1>
          <p className="text-sm text-zinc-500">
            選結單日 → 從左側商品卡加入到右側大表 → 建立撿貨單
          </p>
        </div>
        <Link
          href="/picking/history"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          撿貨歷史 →
        </Link>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="grid grid-cols-12 gap-3" style={{ minHeight: "70vh" }}>
        {/* 左側：1. 搜尋商品並加入大表 */}
        <section className="col-span-4 flex flex-col gap-2 rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold">1. 搜尋商品並加入大表</h2>
            <div className="flex gap-1 text-xs">
              <button
                onClick={selectAll}
                className="rounded-md border border-zinc-300 px-2 py-0.5 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                全選
              </button>
              <button
                onClick={clearAll}
                className="rounded-md border border-zinc-300 px-2 py-0.5 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                清空
              </button>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <label className="flex flex-col gap-1">
              <span className="text-[11px] text-zinc-500">結單日</span>
              <select
                value={closeDate}
                onChange={(e) => setCloseDate(e.target.value)}
                className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              >
                <option value="">— 選 —</option>
                {allCloseDates.map((d) => (
                  <option key={d} value={d}>
                    {d}
                  </option>
                ))}
              </select>
            </label>
            <label className="flex flex-col gap-1">
              <span className="text-[11px] text-zinc-500">配送日</span>
              <input
                type="date"
                value={waveDate}
                onChange={(e) => setWaveDate(e.target.value)}
                className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              />
            </label>
          </div>

          <input
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            placeholder="商編或品項"
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />

          <div className="flex-1 overflow-y-auto">
            {filteredCards.length === 0 ? (
              <div className="p-6 text-center text-xs text-zinc-500">
                {closeDate ? "無對應商品" : "請先選結單日"}
              </div>
            ) : (
              <ul className="space-y-2">
                {filteredCards.map((c) => {
                  const key = `${closeDate}|${c.sku_id}`;
                  const selected = selectedItems.has(key);
                  const isExpanded = expandedSkuIds.has(c.sku_id);
                  const isPicked = c.is_picked;
                  return (
                    <li
                      key={c.sku_id}
                      className={`rounded-md border p-2 text-xs ${
                        isPicked
                          ? "border-zinc-200 bg-zinc-50 opacity-60 dark:border-zinc-800 dark:bg-zinc-900/50"
                          : selected
                          ? "border-blue-300 bg-blue-50 dark:border-blue-800 dark:bg-blue-950/30"
                          : "border-zinc-200 dark:border-zinc-800"
                      }`}
                    >
                      <div className="mb-1 flex items-start justify-between gap-2">
                        <div>
                          <div className="font-mono text-zinc-500">{c.sku_code ?? "—"}</div>
                          <div className={`font-semibold ${isPicked ? "text-zinc-500 dark:text-zinc-500" : ""}`}>
                            {c.sku_label}
                          </div>
                        </div>
                        {isPicked ? (
                          <span className="shrink-0 rounded-md bg-zinc-200 px-2 py-1 text-xs font-semibold text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300">
                            ✓ 已撿過
                          </span>
                        ) : (
                          <button
                            onClick={() => toggleSku(c.sku_id)}
                            className={`shrink-0 rounded-md px-2 py-1 text-xs font-semibold ${
                              selected
                                ? "bg-zinc-200 text-zinc-700 hover:bg-zinc-300 dark:bg-zinc-700 dark:text-zinc-200"
                                : "bg-blue-600 text-white hover:bg-blue-700"
                            }`}
                          >
                            {selected ? "✓ 已加入" : "+ 加入"}
                          </button>
                        )}
                      </div>
                      <div className="text-[11px] text-zinc-600 dark:text-zinc-400">
                        叫貨：<span className="font-mono">{c.total_demand}</span>
                        {" · "}已進庫：<span className="font-mono">{c.received_qty}</span>
                        {" · "}店家：{c.short_stores.length}
                      </div>
                      {c.is_short && (
                        <div className="mt-1 rounded bg-red-50 px-1.5 py-0.5 text-[11px] font-semibold text-red-700 dark:bg-red-950 dark:text-red-300">
                          ⚠️ 缺貨 {c.total_demand - c.received_qty} 件
                        </div>
                      )}
                      {c.short_stores.length > 0 && (
                        <div className="mt-1 text-[11px] text-rose-600 dark:text-rose-400">
                          {c.short_stores
                            .slice(0, 8)
                            .map((s) => `${s.name} ${s.qty}`)
                            .join("、")}
                          {c.short_stores.length > 8 && "…"}
                        </div>
                      )}
                      {(c.po_numbers.length > 0 || c.order_numbers.length > 0) && (
                        <div className="mt-2 border-t border-zinc-200 pt-2 dark:border-zinc-700">
                          <button
                            onClick={() => toggleExpanded(c.sku_id)}
                            className="text-[11px] text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300"
                          >
                            {isExpanded ? "▼ 隱藏" : "▶ 採購單據"}
                          </button>
                          {isExpanded && (
                            <div className="mt-1 space-y-1 text-[10px]">
                              {c.po_numbers.length > 0 && (
                                <div>
                                  <div className="font-semibold text-zinc-700 dark:text-zinc-300">
                                    PO 單號：
                                  </div>
                                  <div className="text-zinc-600 dark:text-zinc-400">
                                    {c.po_numbers.join("、")}
                                  </div>
                                </div>
                              )}
                              {c.order_numbers.length > 0 && (
                                <div>
                                  <div className="font-semibold text-zinc-700 dark:text-zinc-300">
                                    訂單號：
                                  </div>
                                  <div className="text-zinc-600 dark:text-zinc-400">
                                    {c.order_numbers.join("、")}（共 {c.order_numbers.length} 筆）
                                  </div>
                                </div>
                              )}
                            </div>
                          )}
                        </div>
                      )}
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </section>

        {/* 右側：2. 分發作業大表 */}
        <section className="col-span-8 flex flex-col gap-2 rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div>
              <h2 className="text-sm font-semibold">
                2. 分發作業大表（{selectedCards.length} 個 SKU、
                {visibleStores.length}/{stores.length} 間分店）
              </h2>
              {selectedCards.some((c) => c.is_short) && (
                <p className="mt-1 text-xs text-red-600 dark:text-red-400">
                  ⚠️ 部分商品缺貨，請確認進庫後再建立撿貨單
                </p>
              )}
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <label className="flex items-center gap-1 text-xs">
                <input
                  type="checkbox"
                  checked={showOnlyNonZero}
                  onChange={(e) => setShowOnlyNonZero(e.target.checked)}
                />
                只顯示有量欄位
              </label>
              <button
                onClick={createWave}
                disabled={submitting || selectedCards.length === 0 || !waveDate}
                className="rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
              >
                {submitting ? "建立中…" : "🧾 建立撿貨單"}
              </button>
            </div>
          </div>

          <div className="flex-1 overflow-auto rounded-md border border-zinc-200 dark:border-zinc-800">
            <table className="min-w-full text-sm">
              <thead className="sticky top-0 bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="sticky left-0 z-10 bg-zinc-50 px-3 py-2 text-left text-xs uppercase text-zinc-500 dark:bg-zinc-900">
                    商品名稱
                  </th>
                  {visibleStores.map((s) => (
                    <th
                      key={s.id}
                      className="px-2 py-2 text-right text-xs uppercase text-zinc-500"
                    >
                      {s.name}
                    </th>
                  ))}
                  <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">合計</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {selectedCards.length === 0 ? (
                  <tr>
                    <td
                      colSpan={visibleStores.length + 2}
                      className="p-6 text-center text-sm text-zinc-500"
                    >
                      尚未加入商品。從左側點「+ 加入」把要撿的商品加進來。
                    </td>
                  </tr>
                ) : (
                  selectedCards.map((c) => (
                    <tr key={c.sku_id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                      <td className="sticky left-0 bg-white px-3 py-2 dark:bg-zinc-900">
                        <div className="flex items-start gap-2">
                          <button
                            onClick={() => {
                              // 移除該 SKU 的所有 selectedItems
                              setSelectedItems((cur) => {
                                const next = new Set(cur);
                                for (const item of next) {
                                  const [, skuIdStr] = item.split("|");
                                  if (Number(skuIdStr) === c.sku_id) {
                                    next.delete(item);
                                  }
                                }
                                return next;
                              });
                            }}
                            title="從大表移除"
                            className="text-rose-500 hover:text-rose-600"
                          >
                            ✕
                          </button>
                          <div>
                            <div className="font-medium">{c.sku_label}</div>
                            <div className="font-mono text-xs text-zinc-500">{c.sku_code}</div>
                          </div>
                        </div>
                      </td>
                      {visibleStores.map((s) => {
                        const q = c.by_store.get(s.id) ?? 0;
                        return (
                          <td
                            key={s.id}
                            className={`px-3 py-2 text-right font-mono ${q === 0 ? "text-zinc-300" : ""}`}
                          >
                            {q || "0"}
                          </td>
                        );
                      })}
                      <td className="px-3 py-2 text-right font-mono font-semibold">
                        {c.total_demand}
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </div>
  );
}

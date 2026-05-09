"use client";

// 📥 進貨確認 (Goods Receipt) — v2
// 重新設計重點:
//   1. PO 完成度 header (訂/累積已收/本次/剩餘)
//   2. 每行三欄清楚:實到 / 瑕疵 / 可入庫(自動計算)
//   3. 過量警示 + 強制填 variance_reason
//   4. 歷史 GR timeline (可折疊)
//   5. 分店分配預設折疊(可選擇先收貨,稍後到派貨工作台處理)
//   6. Sticky 底部 summary footer

import { Suspense, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";

type POItem = {
  id: number;
  sku_id: number;
  qty_ordered: number;
  qty_received: number;
  unit_cost: number;
  sku_code: string | null;
  sku_name: string | null;
  product_name: string | null;
};

type DemandRow = {
  po_item_id: number;
  sku_id: number;
  store_id: number;
  store_name: string;
  demand_qty: number;
};

type AllocationInput = {
  store_id: number;
  store_name: string;
  demand: number;
  qty: string;
};

type ArrivalForm = {
  po_item_id: number;
  sku_id: number;
  sku_label: string;
  qty_ordered: number;
  qty_already_received: number;
  qty_received: string;
  qty_damaged: string;
  unit_cost: string;
  batch_no: string;
  expiry_date: string;
  variance_reason: string;
  allocations: AllocationInput[];
  showAlloc: boolean;
};

type PriorGR = {
  id: number;
  gr_no: string;
  status: string;
  invoice_no: string | null;
  notes: string | null;
  created_at: string;
  total_qty: number;
  total_damaged: number;
  operator_name: string | null;
};

export default function ReceivePOPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PageContent />
    </Suspense>
  );
}

function PageContent() {
  const router = useRouter();
  const search = useSearchParams();
  const poId = Number(search.get("po") ?? "0");

  const [poInfo, setPOInfo] = useState<{
    po_no: string;
    supplier_name: string | null;
    status: string;
    close_date: string | null;
    sent_at: string | null;
  } | null>(null);
  const [forms, setForms] = useState<ArrivalForm[] | null>(null);
  const [priorGRs, setPriorGRs] = useState<PriorGR[]>([]);
  const [showHistory, setShowHistory] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [invoiceNo, setInvoiceNo] = useState("");
  const [notes, setNotes] = useState("");

  useEffect(() => {
    if (!poId) {
      setError("缺少 po 參數");
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();

        const [{ data: po, error: poErr }, { data: items, error: itemsErr }, { data: priors, error: priorErr }] = await Promise.all([
          sb.from("purchase_orders").select("id, po_no, status, sent_at, suppliers(name)").eq("id", poId).single(),
          sb.from("purchase_order_items").select("id, sku_id, qty_ordered, qty_received, unit_cost").eq("po_id", poId).order("id"),
          sb.from("goods_receipts").select("id, gr_no, status, supplier_invoice_no, notes, created_at").eq("po_id", poId).order("created_at", { ascending: false }),
        ]);
        if (poErr) throw new Error(poErr.message);
        if (itemsErr) throw new Error(itemsErr.message);
        if (priorErr) throw new Error(priorErr.message);

        type RawItem = { id: number; sku_id: number; qty_ordered: number; qty_received: number; unit_cost: number };
        const skuIds = Array.from(new Set(((items as RawItem[]) ?? []).map((r) => r.sku_id)));
        const skuMap = new Map<number, { code: string | null; name: string | null; product_name: string | null }>();
        if (skuIds.length) {
          const { data: skuData, error: skuErr } = await sb.from("skus").select("id, sku_code, variant_name, product_name").in("id", skuIds);
          if (skuErr) throw new Error(skuErr.message);
          for (const r of (skuData as Array<{ id: number; sku_code: string | null; variant_name: string | null; product_name: string | null }> | null) ?? []) {
            skuMap.set(r.id, { code: r.sku_code, name: r.variant_name, product_name: r.product_name });
          }
        }
        const poiArr: POItem[] = ((items as RawItem[]) ?? []).map((r) => {
          const sku = skuMap.get(r.sku_id);
          return {
            id: r.id,
            sku_id: r.sku_id,
            qty_ordered: Number(r.qty_ordered),
            qty_received: Number(r.qty_received ?? 0),
            unit_cost: Number(r.unit_cost),
            sku_code: sku?.code ?? null,
            sku_name: sku?.name ?? null,
            product_name: sku?.product_name ?? null,
          };
        });

        // GR items + 統計
        const priorRows: PriorGR[] = [];
        const priorList = (priors as Array<{ id: number; gr_no: string; status: string; supplier_invoice_no: string | null; notes: string | null; created_at: string }> | null) ?? [];
        if (priorList.length > 0) {
          const grIds = priorList.map((p) => p.id);
          const { data: griRows } = await sb.from("goods_receipt_items").select("gr_id, qty_received, qty_damaged").in("gr_id", grIds);
          const sumByGr = new Map<number, { qty: number; dmg: number }>();
          for (const it of (griRows as Array<{ gr_id: number; qty_received: number; qty_damaged: number | null }> | null) ?? []) {
            const slot = sumByGr.get(it.gr_id) ?? { qty: 0, dmg: 0 };
            slot.qty += Number(it.qty_received);
            slot.dmg += Number(it.qty_damaged ?? 0);
            sumByGr.set(it.gr_id, slot);
          }
          for (const p of priorList) {
            const s = sumByGr.get(p.id) ?? { qty: 0, dmg: 0 };
            priorRows.push({
              id: p.id,
              gr_no: p.gr_no,
              status: p.status,
              invoice_no: p.supplier_invoice_no,
              notes: p.notes,
              created_at: p.created_at,
              total_qty: s.qty,
              total_damaged: s.dmg,
              operator_name: null,
            });
          }
        }

        // 對應分店需求
        const { data: demand } = await sb.from("v_po_demand_by_store").select("po_item_id, sku_id, store_id, store_name, demand_qty, close_date").eq("po_id", poId);
        type RawDemand = { po_item_id: number; sku_id: number; store_id: number; store_name: string; demand_qty: number; close_date: string | null };
        const demandArr = ((demand as RawDemand[]) ?? []).map((r) => ({
          po_item_id: r.po_item_id,
          sku_id: r.sku_id,
          store_id: r.store_id,
          store_name: r.store_name,
          demand_qty: Number(r.demand_qty),
        })) as DemandRow[];
        const closeDate = ((demand as RawDemand[]) ?? []).find((r) => r.close_date)?.close_date ?? null;

        const supplierName = (() => {
          const s = (po as unknown as { suppliers: { name: string } | { name: string }[] | null }).suppliers;
          return Array.isArray(s) ? s[0]?.name ?? null : s?.name ?? null;
        })();

        const formArr: ArrivalForm[] = poiArr.map((it) => {
          const allocs = demandArr
            .filter((d) => d.po_item_id === it.id)
            .map((d) => ({
              store_id: d.store_id,
              store_name: d.store_name,
              demand: d.demand_qty,
              qty: "0", // 預設先不分配,可選擇後續到派貨工作台處理
            }));
          const remaining = Math.max(0, it.qty_ordered - it.qty_received);
          return {
            po_item_id: it.id,
            sku_id: it.sku_id,
            sku_label: `${it.sku_code ?? ""} ${it.product_name ?? ""}${it.sku_name ? ` / ${it.sku_name}` : ""}`.trim(),
            qty_ordered: it.qty_ordered,
            qty_already_received: it.qty_received,
            qty_received: String(remaining),
            qty_damaged: "0",
            unit_cost: String(it.unit_cost),
            batch_no: "",
            expiry_date: "",
            variance_reason: "",
            allocations: allocs,
            showAlloc: false,
          };
        });

        if (!cancelled) {
          setPOInfo({
            po_no: (po as { po_no: string }).po_no,
            supplier_name: supplierName,
            status: (po as { status: string }).status,
            close_date: closeDate,
            sent_at: (po as { sent_at?: string | null }).sent_at ?? null,
          });
          setForms(formArr);
          setPriorGRs(priorRows);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [poId]);

  function updateForm(idx: number, patch: Partial<ArrivalForm>) {
    setForms((cur) => {
      if (!cur) return cur;
      const next = [...cur];
      next[idx] = { ...next[idx], ...patch };
      return next;
    });
  }

  function updateAllocation(idx: number, allocIdx: number, qty: string) {
    setForms((cur) => {
      if (!cur) return cur;
      const next = [...cur];
      const allocs = [...next[idx].allocations];
      allocs[allocIdx] = { ...allocs[allocIdx], qty };
      next[idx] = { ...next[idx], allocations: allocs };
      return next;
    });
  }

  function autoBalance(idx: number) {
    setForms((cur) => {
      if (!cur) return cur;
      const f = cur[idx];
      const usable = (Number(f.qty_received) || 0) - (Number(f.qty_damaged) || 0);
      const totalDemand = f.allocations.reduce((s, a) => s + a.demand, 0);
      if (totalDemand === 0 || usable <= 0) return cur;
      const next = [...cur];
      const allocs = f.allocations.map((a, i, arr) => {
        if (i === arr.length - 1) {
          const allocated = arr.slice(0, i).reduce((s, x) => s + Math.floor((usable * x.demand) / totalDemand), 0);
          return { ...a, qty: String(Math.max(0, usable - allocated)) };
        }
        return { ...a, qty: String(Math.floor((usable * a.demand) / totalDemand)) };
      });
      next[idx] = { ...f, allocations: allocs };
      return next;
    });
  }

  function fillAllArrived() {
    setForms((cur) => {
      if (!cur) return cur;
      return cur.map((f) => ({
        ...f,
        qty_received: String(Math.max(0, f.qty_ordered - f.qty_already_received)),
      }));
    });
  }

  function clearAllArrived() {
    setForms((cur) => {
      if (!cur) return cur;
      return cur.map((f) => ({ ...f, qty_received: "0" }));
    });
  }

  const totals = useMemo(() => {
    if (!forms) return null;
    return forms.map((f) => {
      const allocSum = f.allocations.reduce((s, a) => s + (Number(a.qty) || 0), 0);
      const received = Number(f.qty_received) || 0;
      const damaged = Number(f.qty_damaged) || 0;
      const usable = received - damaged;
      const remaining = Math.max(0, f.qty_ordered - f.qty_already_received);
      const isOver = received > remaining;
      const isShort = received > 0 && received < remaining;
      const requiresReason = isOver || isShort;
      return {
        allocSum, received, damaged, usable, remaining,
        isOver, isShort, requiresReason,
        diff: usable - allocSum,
        ok: received > 0 && usable >= 0 && (allocSum === 0 || allocSum <= usable),
      };
    });
  }, [forms]);

  const headerSummary = useMemo(() => {
    if (!forms) return null;
    let totalOrdered = 0, totalAlready = 0, totalNow = 0;
    for (const f of forms) {
      totalOrdered += f.qty_ordered;
      totalAlready += f.qty_already_received;
      totalNow += Number(f.qty_received) || 0;
    }
    return { totalOrdered, totalAlready, totalNow, totalRemaining: Math.max(0, totalOrdered - totalAlready - totalNow) };
  }, [forms]);

  const submitSummary = useMemo(() => {
    if (!forms || !totals) return null;
    let totalReceived = 0, totalDamaged = 0, totalUsable = 0, totalAllocated = 0, lineCount = 0;
    let needsReason = 0, hasReason = 0;
    forms.forEach((f, i) => {
      const t = totals[i];
      if (t.received > 0) {
        lineCount += 1;
        totalReceived += t.received;
        totalDamaged += t.damaged;
        totalUsable += t.usable;
        totalAllocated += t.allocSum;
        if (t.requiresReason) {
          needsReason += 1;
          if (f.variance_reason.trim()) hasReason += 1;
        }
      }
    });
    return { totalReceived, totalDamaged, totalUsable, totalAllocated, lineCount, needsReason, hasReason };
  }, [forms, totals]);

  async function submit() {
    if (!forms) return;
    setError(null);
    setSubmitting(true);
    try {
      const arrivals = forms
        .filter((f) => Number(f.qty_received) > 0)
        .map((f) => ({
          po_item_id: f.po_item_id,
          sku_id: f.sku_id,
          qty_received: Number(f.qty_received),
          qty_damaged: Number(f.qty_damaged) || 0,
          unit_cost: Number(f.unit_cost),
          batch_no: f.batch_no || null,
          expiry_date: f.expiry_date || null,
          variance_reason: f.variance_reason || null,
          allocations: f.allocations.filter((a) => Number(a.qty) > 0).map((a) => ({ store_id: a.store_id, qty: Number(a.qty) })),
        }));

      if (arrivals.length === 0) throw new Error("請至少輸入一個品項的到貨數量");

      // 校驗:有差異(短少 / 過量)的必須填 variance_reason
      const missingReason = forms.filter((f, i) => {
        const t = totals?.[i];
        return t && t.received > 0 && t.requiresReason && !f.variance_reason.trim();
      });
      if (missingReason.length > 0) {
        throw new Error(`有 ${missingReason.length} 個品項實到 ≠ 訂購量,必須填差異原因。`);
      }

      const { data: userRes } = await getSupabase().auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const { data, error: rpcErr } = await getSupabase().rpc("rpc_arrive_and_distribute", {
        p_po_id: poId,
        p_arrivals: arrivals,
        p_operator: operator,
        p_invoice_no: invoiceNo || null,
        p_notes: notes || null,
      });
      if (rpcErr) throw new Error(translateRpcError(rpcErr));

      const result = data as { gr_no: string; wave_code: string | null };
      alert(
        `✅ 進貨完成!\n進貨單:${result.gr_no}` +
          (result.wave_code ? `\n撿貨波次:${result.wave_code}` : "")
      );
      router.push("/wms/receiving");
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSubmitting(false);
    }
  }

  if (!poId) return <div className="p-6 text-red-600">{error ?? "缺少參數"}</div>;
  if (error && !poInfo) return <div className="p-6 text-red-600">{error}</div>;
  if (!poInfo || !forms || !totals || !headerSummary) return <div className="p-6 text-zinc-500">載入中…</div>;

  const canSubmit =
    forms.some((f) => Number(f.qty_received) > 0) &&
    totals.every((t, i) => Number(forms[i].qty_received) === 0 || t.ok) &&
    (submitSummary?.needsReason === submitSummary?.hasReason);

  const completionPct = headerSummary.totalOrdered > 0
    ? Math.round(((headerSummary.totalAlready + headerSummary.totalNow) / headerSummary.totalOrdered) * 100)
    : 0;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6 pb-32">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex-1">
          <h1 className="text-xl font-semibold">📥 進貨確認</h1>
          <p className="text-sm text-zinc-500">
            <span className="font-mono">{poInfo.po_no}</span>
            {" · "}
            {poInfo.supplier_name ?? "—"}
            {poInfo.close_date && <> · 結單日 {poInfo.close_date}</>}
            {poInfo.sent_at && <> · 送單 {new Date(poInfo.sent_at).toLocaleDateString("zh-TW")}</>}
          </p>
        </div>
        <Link
          href="/wms/receiving"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          ← 返回進貨待辦
        </Link>
      </header>

      {/* PO 進度 KPI */}
      <div className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mb-2 flex items-baseline justify-between">
          <h2 className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">📊 PO 進度</h2>
          <span className="text-xs text-zinc-500">完成度 {completionPct}%</span>
        </div>
        <div className="mb-3 h-2 overflow-hidden rounded-full bg-zinc-100 dark:bg-zinc-800">
          <div
            className="h-full bg-emerald-500 transition-all"
            style={{ width: `${Math.min(100, completionPct)}%` }}
          />
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
          <Stat label="原訂購" value={headerSummary.totalOrdered} />
          <Stat label="累計已收" value={headerSummary.totalAlready} accent="text-emerald-700 dark:text-emerald-400" />
          <Stat label="本次到貨" value={headerSummary.totalNow} accent="text-blue-700 dark:text-blue-400" />
          <Stat label="尚未到" value={headerSummary.totalRemaining} accent="text-amber-700 dark:text-amber-400" />
        </div>
      </div>

      {/* GR 歷史 timeline */}
      {priorGRs.length > 0 && (
        <div className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <SpinButton
            type="button"
            onClick={() => setShowHistory((v) => !v)}
            className="flex w-full items-center justify-between p-3 text-sm font-semibold text-zinc-700 hover:bg-zinc-50 dark:text-zinc-300 dark:hover:bg-zinc-800"
          >
            <span>📜 過往進貨記錄 ({priorGRs.length} 筆)</span>
            <span className="text-xs text-zinc-400">{showHistory ? "▲ 收起" : "▼ 展開"}</span>
          </SpinButton>
          {showHistory && (
            <div className="border-t border-zinc-200 p-3 dark:border-zinc-800">
              <ol className="space-y-2 text-xs">
                {priorGRs.map((g) => (
                  <li key={g.id} className="flex items-center gap-3 rounded border border-zinc-100 bg-zinc-50 p-2 dark:border-zinc-800 dark:bg-zinc-950">
                    <span className="text-zinc-500">{new Date(g.created_at).toLocaleString("zh-TW")}</span>
                    <span className="font-mono text-zinc-700 dark:text-zinc-300">{g.gr_no}</span>
                    <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                      {g.status}
                    </span>
                    <span>實到 <span className="font-semibold">{g.total_qty}</span></span>
                    {g.total_damaged > 0 && <span className="text-rose-600">瑕疵 {g.total_damaged}</span>}
                    {g.invoice_no && <span className="text-zinc-500">發票 {g.invoice_no}</span>}
                    {g.notes && <span className="text-zinc-400">· {g.notes}</span>}
                  </li>
                ))}
              </ol>
            </div>
          )}
        </div>
      )}

      {/* 本次進貨 — 發票 / 備註 */}
      <div className="grid grid-cols-2 gap-3 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-500">供應商發票號</span>
          <input
            value={invoiceNo}
            onChange={(e) => setInvoiceNo(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            placeholder="可選"
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-500">備註</span>
          <input
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            placeholder="可選"
          />
        </label>
      </div>

      {/* Quick actions */}
      <div className="flex flex-wrap items-center gap-2 text-xs">
        <span className="text-zinc-500">快捷:</span>
        <SpinButton
          type="button"
          onClick={fillAllArrived}
          className="rounded border border-zinc-300 px-2 py-1 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          全部填剩餘量
        </SpinButton>
        <SpinButton
          type="button"
          onClick={clearAllArrived}
          className="rounded border border-zinc-300 px-2 py-1 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          全部清空
        </SpinButton>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* 各品項到貨 */}
      <div className="flex flex-col gap-3">
        {forms.map((f, idx) => {
          const t = totals[idx];
          const cardCls = t.isOver
            ? "border-amber-300 bg-amber-50 dark:border-amber-800 dark:bg-amber-950/30"
            : t.isShort && t.received > 0
              ? "border-rose-300 bg-rose-50 dark:border-rose-800 dark:bg-rose-950/30"
              : "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900";

          return (
            <div key={f.po_item_id} className={`rounded-md border p-4 ${cardCls}`}>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="flex-1">
                  <div className="font-semibold">{f.sku_label}</div>
                  <div className="text-xs text-zinc-500">
                    訂 {f.qty_ordered}
                    {f.qty_already_received > 0 && <> · 累計已收 {f.qty_already_received}</>}
                    {" · "}剩餘 {t.remaining}
                  </div>
                </div>
                <div className="text-right text-xs">
                  {t.received > 0 && (
                    <>
                      <div>
                        本次可入庫:<span className="font-mono font-semibold text-emerald-700 dark:text-emerald-400">{t.usable}</span>
                      </div>
                      {t.allocSum > 0 && (
                        <div className={t.diff === 0 ? "text-emerald-600" : "text-amber-600"}>
                          已分配 {t.allocSum} (差 {t.diff})
                        </div>
                      )}
                      {t.isOver && (
                        <div className="font-semibold text-amber-700 dark:text-amber-400">
                          ⚠ 過量 +{t.received - t.remaining}
                        </div>
                      )}
                      {t.isShort && t.received > 0 && (
                        <div className="font-semibold text-rose-700 dark:text-rose-400">
                          ⚠ 短少 -{t.remaining - t.received}
                        </div>
                      )}
                    </>
                  )}
                </div>
              </div>

              {/* 三欄:實到 / 瑕疵 / 可入庫 */}
              <div className="mt-3 grid grid-cols-3 gap-2">
                <NumField
                  label="實到數量"
                  value={f.qty_received}
                  onChange={(v) => updateForm(idx, { qty_received: v })}
                  highlight
                />
                <NumField
                  label="瑕疵 / 不入庫"
                  value={f.qty_damaged}
                  onChange={(v) => updateForm(idx, { qty_damaged: v })}
                />
                <ReadOnlyField
                  label="可入庫 = 實到 - 瑕疵"
                  value={String(t.usable)}
                  accent={t.usable < 0 ? "danger" : "success"}
                />
              </div>

              <div className="mt-2 grid grid-cols-2 gap-2 md:grid-cols-3">
                <NumField
                  label="單價"
                  value={f.unit_cost}
                  onChange={(v) => updateForm(idx, { unit_cost: v })}
                />
                <TextField
                  label="批號"
                  value={f.batch_no}
                  onChange={(v) => updateForm(idx, { batch_no: v })}
                />
                <TextField
                  label="效期"
                  value={f.expiry_date}
                  onChange={(v) => updateForm(idx, { expiry_date: v })}
                  placeholder="YYYY-MM-DD"
                />
              </div>

              {/* 差異原因 — 條件顯示 */}
              {t.requiresReason && (
                <div className="mt-3 rounded-md border border-amber-200 bg-amber-100/40 p-3 dark:border-amber-800 dark:bg-amber-950/40">
                  <label className="flex flex-col gap-1 text-xs">
                    <span className="font-semibold text-amber-800 dark:text-amber-300">
                      ⚠ 差異原因 {t.isOver ? "(過量)" : "(短少)"} <span className="text-rose-600">*</span>
                    </span>
                    <input
                      value={f.variance_reason}
                      onChange={(e) => updateForm(idx, { variance_reason: e.target.value })}
                      placeholder={t.isOver ? "例如:供應商多送贈品 / 箱數算錯" : "例如:供應商缺貨 / 運輸破損 / 短裝"}
                      className="rounded-md border border-amber-300 bg-white px-2 py-1 text-sm dark:border-amber-700 dark:bg-zinc-900"
                    />
                  </label>
                </div>
              )}

              {/* 分店分配 — 折疊 */}
              {f.allocations.length > 0 && (
                <div className="mt-3">
                  <SpinButton
                    type="button"
                    onClick={() => updateForm(idx, { showAlloc: !f.showAlloc })}
                    className="flex items-center gap-2 text-xs font-semibold text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
                  >
                    {f.showAlloc ? "▲" : "▼"} 分店分配 (共 {f.allocations.length} 店、需求合計 {f.allocations.reduce((s, a) => s + a.demand, 0)})
                    {!f.showAlloc && <span className="text-zinc-400">— 預設不分配,可在派貨工作台統一處理</span>}
                  </SpinButton>
                  {f.showAlloc && (
                    <div className="mt-2 rounded-md border border-dashed border-zinc-300 p-2 dark:border-zinc-700">
                      <div className="mb-2 flex items-center justify-between text-xs text-zinc-500">
                        <span>選填:本次直接分到指定店,提交時建撿貨單</span>
                        <SpinButton
                          type="button"
                          onClick={() => autoBalance(idx)}
                          className="rounded-md border border-zinc-300 px-2 py-0.5 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                        >
                          按需求比例自動分
                        </SpinButton>
                      </div>
                      <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
                        {f.allocations.map((a, ai) => (
                          <label key={a.store_id} className="flex flex-col gap-1 text-xs">
                            <span className="text-zinc-500">{a.store_name}<span className="ml-1 text-zinc-400">(需 {a.demand})</span></span>
                            <input
                              inputMode="decimal"
                              value={a.qty}
                              onChange={(e) => updateAllocation(idx, ai, e.target.value)}
                              className="rounded-md border border-zinc-300 bg-white px-2 py-1 font-mono text-sm dark:border-zinc-700 dark:bg-zinc-800"
                            />
                          </label>
                        ))}
                      </div>
                    </div>
                  )}
                </div>
              )}

              {f.allocations.length === 0 && Number(f.qty_received) > 0 && (
                <div className="mt-3 rounded-md bg-amber-50 p-2 text-xs text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                  該品項沒有對應分店訂單,將只入總倉庫存(可在派貨工作台分配出去)。
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Sticky submit footer */}
      {submitSummary && (
        <div className="fixed bottom-0 left-0 right-0 border-t border-zinc-200 bg-white shadow-lg dark:border-zinc-800 dark:bg-zinc-900 md:left-52">
          <div className="flex flex-wrap items-center justify-between gap-3 p-3">
            <div className="flex flex-wrap items-baseline gap-3 text-sm">
              <span className="text-zinc-500">本次:</span>
              <span>{submitSummary.lineCount} 行</span>
              <span>實到 <span className="font-mono font-semibold">{submitSummary.totalReceived}</span></span>
              {submitSummary.totalDamaged > 0 && (
                <span className="text-rose-600">瑕疵 {submitSummary.totalDamaged}</span>
              )}
              <span className="text-emerald-600">可入庫 <span className="font-mono font-semibold">{submitSummary.totalUsable}</span></span>
              {submitSummary.totalAllocated > 0 && (
                <span className="text-blue-600">分配 {submitSummary.totalAllocated}</span>
              )}
              {submitSummary.needsReason > 0 && (
                <span className={submitSummary.hasReason === submitSummary.needsReason ? "text-emerald-600" : "text-rose-600"}>
                  ⚠ 差異需填原因 ({submitSummary.hasReason}/{submitSummary.needsReason})
                </span>
              )}
            </div>
            <div className="flex gap-2">
              <SpinButton
                type="button"
                onClick={() => router.push("/wms/receiving")}
                className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                取消
              </SpinButton>
              <SpinButton
                type="button"
                onClick={submit}
                disabled={!canSubmit || submitting}
                className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
              >
                {submitting ? "處理中…" : "確認進貨"}
              </SpinButton>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value, accent = "text-zinc-900 dark:text-zinc-100" }: { label: string; value: number; accent?: string }) {
  return (
    <div className="rounded border border-zinc-200 bg-zinc-50 p-2 dark:border-zinc-800 dark:bg-zinc-950">
      <div className="text-[10px] text-zinc-500">{label}</div>
      <div className={`font-mono text-lg font-semibold tabular-nums ${accent}`}>{value}</div>
    </div>
  );
}

function NumField({
  label,
  value,
  onChange,
  highlight,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  highlight?: boolean;
}) {
  return (
    <label className="flex flex-col gap-1 text-xs">
      <span className="text-zinc-500">{label}</span>
      <input
        inputMode="decimal"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className={`rounded-md border bg-white px-2 py-1 font-mono text-sm dark:bg-zinc-800 ${
          highlight
            ? "border-blue-300 dark:border-blue-700"
            : "border-zinc-300 dark:border-zinc-700"
        }`}
      />
    </label>
  );
}

function ReadOnlyField({ label, value, accent }: { label: string; value: string; accent?: "success" | "danger" }) {
  const cls =
    accent === "danger"
      ? "border-rose-300 bg-rose-50 text-rose-700 dark:border-rose-800 dark:bg-rose-950 dark:text-rose-400"
      : accent === "success"
        ? "border-emerald-300 bg-emerald-50 text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-400"
        : "border-zinc-300 bg-zinc-50 text-zinc-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-300";
  return (
    <label className="flex flex-col gap-1 text-xs">
      <span className="text-zinc-500">{label}</span>
      <div className={`rounded-md border px-2 py-1 font-mono text-sm font-semibold ${cls}`}>
        {value}
      </div>
    </label>
  );
}

function TextField({
  label,
  value,
  onChange,
  placeholder,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
}) {
  return (
    <label className="flex flex-col gap-1 text-xs">
      <span className="text-zinc-500">{label}</span>
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
      />
    </label>
  );
}

"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

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
};

export default function ReceivePOPage() {
  const router = useRouter();
  const search = useSearchParams();
  const poId = Number(search.get("po") ?? "0");

  const [poInfo, setPOInfo] = useState<{
    po_no: string;
    supplier_name: string | null;
    status: string;
    close_date: string | null;
  } | null>(null);
  const [forms, setForms] = useState<ArrivalForm[] | null>(null);
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

        // 1) PO header + items + sku 資訊
        const { data: po, error: poErr } = await sb
          .from("purchase_orders")
          .select("id, po_no, status, suppliers(name)")
          .eq("id", poId)
          .single();
        if (poErr) throw new Error(poErr.message);

        const { data: items, error: itemsErr } = await sb
          .from("purchase_order_items")
          .select("id, sku_id, qty_ordered, qty_received, unit_cost")
          .eq("po_id", poId)
          .order("id");
        if (itemsErr) throw new Error(itemsErr.message);

        type RawItem = {
          id: number;
          sku_id: number;
          qty_ordered: number;
          qty_received: number;
          unit_cost: number;
        };
        const skuIds = Array.from(new Set(((items as RawItem[]) ?? []).map((r) => r.sku_id)));
        const skuMap = new Map<number, { code: string | null; name: string | null; product_name: string | null }>();
        if (skuIds.length) {
          const { data: skuData, error: skuErr } = await sb
            .from("skus")
            .select("id, sku_code, variant_name, product_name")
            .in("id", skuIds);
          if (skuErr) throw new Error(skuErr.message);
          type RawSku = {
            id: number;
            sku_code: string | null;
            variant_name: string | null;
            product_name: string | null;
          };
          for (const r of (skuData as RawSku[] | null) ?? []) {
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

        // 2) 對應分店需求（v_po_demand_by_store）
        const { data: demand, error: demErr } = await sb
          .from("v_po_demand_by_store")
          .select("po_item_id, sku_id, store_id, store_name, demand_qty, close_date")
          .eq("po_id", poId);
        if (demErr) throw new Error(demErr.message);

        type RawDemand = {
          po_item_id: number;
          sku_id: number;
          store_id: number;
          store_name: string;
          demand_qty: number;
          close_date: string | null;
        };
        const demandArr = ((demand as RawDemand[]) ?? []).map((r) => ({
          po_item_id: r.po_item_id,
          sku_id: r.sku_id,
          store_id: r.store_id,
          store_name: r.store_name,
          demand_qty: Number(r.demand_qty),
        })) as DemandRow[];

        const closeDate =
          ((demand as RawDemand[]) ?? []).find((r) => r.close_date)?.close_date ?? null;

        // 3) 組裝 form
        const supplierName = (() => {
          const s = (po as unknown as { suppliers: { name: string } | { name: string }[] | null })
            .suppliers;
          return Array.isArray(s) ? s[0]?.name ?? null : s?.name ?? null;
        })();

        const formArr: ArrivalForm[] = poiArr.map((it) => {
          const allocs = demandArr
            .filter((d) => d.po_item_id === it.id)
            .map((d) => ({
              store_id: d.store_id,
              store_name: d.store_name,
              demand: d.demand_qty,
              qty: String(d.demand_qty), // 預設 = 需求量
            }));
          return {
            po_item_id: it.id,
            sku_id: it.sku_id,
            sku_label: `${it.sku_code ?? ""} ${it.product_name ?? ""}${it.sku_name ? ` / ${it.sku_name}` : ""}`.trim(),
            qty_ordered: it.qty_ordered,
            qty_already_received: it.qty_received,
            qty_received: String(Math.max(0, it.qty_ordered - it.qty_received)), // 預設 = 還沒到貨的部分
            qty_damaged: "0",
            unit_cost: String(it.unit_cost),
            batch_no: "",
            expiry_date: "",
            variance_reason: "",
            allocations: allocs,
          };
        });

        if (!cancelled) {
          setPOInfo({
            po_no: (po as { po_no: string }).po_no,
            supplier_name: supplierName,
            status: (po as { status: string }).status,
            close_date: closeDate,
          });
          setForms(formArr);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
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
      const received = Number(f.qty_received) || 0;
      const totalDemand = f.allocations.reduce((s, a) => s + a.demand, 0);
      if (totalDemand === 0) return cur;
      const next = [...cur];
      const allocs = f.allocations.map((a, i, arr) => {
        if (i === arr.length - 1) {
          // 最後一個吃尾差
          const allocated = arr.slice(0, i).reduce((s, x) => s + Math.floor((received * x.demand) / totalDemand), 0);
          return { ...a, qty: String(received - allocated) };
        }
        return { ...a, qty: String(Math.floor((received * a.demand) / totalDemand)) };
      });
      next[idx] = { ...f, allocations: allocs };
      return next;
    });
  }

  const totals = useMemo(() => {
    if (!forms) return null;
    return forms.map((f) => {
      const allocSum = f.allocations.reduce((s, a) => s + (Number(a.qty) || 0), 0);
      const received = Number(f.qty_received) || 0;
      const damaged = Number(f.qty_damaged) || 0;
      const usable = received - damaged;
      return {
        allocSum,
        received,
        damaged,
        usable,
        diff: usable - allocSum,
        ok: allocSum === usable && received > 0,
      };
    });
  }, [forms]);

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
          allocations: f.allocations
            .filter((a) => Number(a.qty) > 0)
            .map((a) => ({ store_id: a.store_id, qty: Number(a.qty) })),
        }));

      if (arrivals.length === 0) {
        throw new Error("請至少輸入一個品項的到貨數量");
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
      if (rpcErr) throw new Error(rpcErr.message);

      const result = data as { gr_no: string; wave_code: string | null };
      alert(
        `進貨完成！\n進貨單：${result.gr_no}` +
          (result.wave_code ? `\n撿貨波次：${result.wave_code}` : ""),
      );
      router.push("/purchase/orders");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  if (!poId) return <div className="p-6 text-red-600">{error ?? "缺少參數"}</div>;
  if (error && !poInfo) return <div className="p-6 text-red-600">{error}</div>;
  if (!poInfo || !forms) return <div className="p-6 text-zinc-500">載入中…</div>;

  const canSubmit =
    forms.some((f) => Number(f.qty_received) > 0) &&
    totals?.every(
      (t, i) =>
        Number(forms[i].qty_received) === 0 ||
        (t.received > 0 &&
          t.usable >= 0 &&
          (forms[i].allocations.length === 0 || t.allocSum <= t.usable)),
    );

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">進貨／撿貨</h1>
          <p className="text-sm text-zinc-500">
            <span className="font-mono">{poInfo.po_no}</span>
            {" · "}
            {poInfo.supplier_name ?? "—"}
            {poInfo.close_date && (
              <>
                {" · "}結單日 {poInfo.close_date}
              </>
            )}
            {" · 狀態 "}
            {poInfo.status}
          </p>
        </div>
        <a
          href="/purchase/orders"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          ← 返回 PO 列表
        </a>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="grid grid-cols-2 gap-3 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-500">供應商發票號</span>
          <input
            value={invoiceNo}
            onChange={(e) => setInvoiceNo(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            placeholder="optional"
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-500">備註</span>
          <input
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            placeholder="optional"
          />
        </label>
      </div>

      <div className="flex flex-col gap-3">
        {forms.map((f, idx) => {
          const t = totals?.[idx];
          return (
            <div
              key={f.po_item_id}
              className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900"
            >
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="font-semibold">{f.sku_label}</div>
                  <div className="text-xs text-zinc-500">
                    PO 訂量 {f.qty_ordered} 件
                    {f.qty_already_received > 0 && (
                      <> · 累計已收 {f.qty_already_received}</>
                    )}
                  </div>
                </div>
                {t && (
                  <div className="text-right text-xs">
                    <div>到貨可用：<span className="font-mono font-semibold">{t.usable}</span></div>
                    <div className={t.diff === 0 ? "text-emerald-600" : "text-amber-600"}>
                      已分配：<span className="font-mono">{t.allocSum}</span>
                      （差 {t.diff}）
                    </div>
                  </div>
                )}
              </div>

              <div className="mt-3 grid grid-cols-2 gap-2 md:grid-cols-5">
                <NumField
                  label="實到數量"
                  value={f.qty_received}
                  onChange={(v) => updateForm(idx, { qty_received: v })}
                />
                <NumField
                  label="瑕疵 / 不入庫"
                  value={f.qty_damaged}
                  onChange={(v) => updateForm(idx, { qty_damaged: v })}
                />
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

              {f.allocations.length > 0 && (
                <div className="mt-3">
                  <div className="mb-2 flex items-center justify-between">
                    <div className="text-xs font-semibold text-zinc-600 dark:text-zinc-400">
                      分店分配（共 {f.allocations.length} 店、需求合計{" "}
                      {f.allocations.reduce((s, a) => s + a.demand, 0)}）
                    </div>
                    <button
                      type="button"
                      onClick={() => autoBalance(idx)}
                      className="rounded-md border border-zinc-300 px-2 py-0.5 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      按需求比例自動分配
                    </button>
                  </div>
                  <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
                    {f.allocations.map((a, ai) => (
                      <label key={a.store_id} className="flex flex-col gap-1 text-xs">
                        <span className="text-zinc-500">
                          {a.store_name}（需 {a.demand}）
                        </span>
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

              {f.allocations.length === 0 && (
                <div className="mt-3 rounded-md bg-amber-50 p-2 text-xs text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                  該 SKU 沒有對應分店訂單，將只入總倉庫存（不產生撿貨單）。
                </div>
              )}
            </div>
          );
        })}
      </div>

      <div className="flex justify-end gap-2">
        <button
          type="button"
          onClick={() => router.push("/purchase/orders")}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          取消
        </button>
        <button
          type="button"
          onClick={submit}
          disabled={!canSubmit || submitting}
          className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
        >
          {submitting ? "處理中…" : "確認進貨／撿貨"}
        </button>
      </div>
    </div>
  );
}

function NumField({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <label className="flex flex-col gap-1 text-xs">
      <span className="text-zinc-500">{label}</span>
      <input
        inputMode="decimal"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="rounded-md border border-zinc-300 bg-white px-2 py-1 font-mono text-sm dark:border-zinc-700 dark:bg-zinc-800"
      />
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

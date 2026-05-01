"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { useRole, canSeeBranch } from "@/lib/role";

type Store = { id: number; code: string; name: string };

type SkuOption = {
  id: number;
  sku_code: string;
  variant_name: string | null;
  product_id: number;
  product_name: string;
  retail_price: number | null;
  branch_price: number | null;
};

type Line = {
  sku_id: number | null;
  sku_label: string;
  qty: string;
  unit_price: string;
  notes: string;
};

const emptyLine = (): Line => ({ sku_id: null, sku_label: "", qty: "1", unit_price: "0", notes: "" });

export default function RestockNewPage() {
  const router = useRouter();
  const role = useRole();
  const showBranch = canSeeBranch(role);

  const [stores, setStores] = useState<Store[]>([]);
  const [storeId, setStoreId] = useState<number | null>(null);
  const [lines, setLines] = useState<Line[]>([emptyLine()]);
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [{ data: storeData }, { data: sess }] = await Promise.all([
        sb.from("stores").select("id, code, name").eq("is_active", true).order("code"),
        sb.auth.getSession(),
      ]);
      setStores((storeData ?? []) as Store[]);
      // 分店 role 自動帶 store_id
      const meta = sess.session?.user?.app_metadata as Record<string, unknown> | undefined;
      const sId = meta?.store_id ? Number(meta.store_id) : null;
      if (sId) setStoreId(sId);
    })();
  }, []);

  const setLine = <K extends keyof Line>(idx: number, key: K, value: Line[K]) => {
    setLines((arr) => arr.map((l, i) => (i === idx ? { ...l, [key]: value } : l)));
  };
  const addLine = () => setLines((arr) => [...arr, emptyLine()]);
  const removeLine = (idx: number) => setLines((arr) => arr.filter((_, i) => i !== idx));

  const valid =
    storeId !== null &&
    lines.length > 0 &&
    lines.every((l) => l.sku_id !== null && Number(l.qty) > 0 && Number(l.unit_price) >= 0);

  async function handleSubmit() {
    setError(null);
    if (!valid || storeId === null) {
      setError("請選分店、每行需挑商品 + 填數量");
      return;
    }
    setBusy(true);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_create_restock_request", {
        p_store_id: storeId,
        p_lines: lines.map((l) => ({
          sku_id: l.sku_id,
          qty: Number(l.qty),
          unit_price: Number(l.unit_price),
          notes: l.notes.trim() || null,
        })),
        p_notes: notes.trim() || null,
      });
      if (err) throw err;
      router.push(`/restock?id=${Number(data)}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const inputCls =
    "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">補貨申請</h1>
        <p className="text-sm text-zinc-500">針對既有上架商品向 HQ 叫貨；HQ 會選擇派庫存或進貨</p>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <label className="flex flex-col gap-1 text-sm sm:max-w-md">
        <span className="text-zinc-600 dark:text-zinc-400">收貨分店 *</span>
        <select value={storeId ?? ""} onChange={(e) => setStoreId(Number(e.target.value) || null)} className={inputCls}>
          <option value="">— 請選 —</option>
          {stores.map((s) => (
            <option key={s.id} value={s.id}>{s.code} {s.name}</option>
          ))}
        </select>
      </label>

      <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="w-full text-sm">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">商品 / 規格 *</th>
              <th className="px-3 py-2 text-right">數量 *</th>
              <th className="px-3 py-2 text-right">單價 *</th>
              <th className="px-3 py-2">備註</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
            {lines.map((l, i) => (
              <LineRow
                key={i}
                line={l}
                showBranch={showBranch}
                onChange={(patch) => setLines((arr) => arr.map((x, j) => (j === i ? { ...x, ...patch } : x)))}
                onRemove={lines.length > 1 ? () => removeLine(i) : null}
              />
            ))}
          </tbody>
        </table>
        <div className="border-t border-zinc-200 p-2 dark:border-zinc-800">
          <button onClick={addLine} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
            + 新增一行
          </button>
        </div>
      </div>

      <label className="flex flex-col gap-1 text-sm">
        <span className="text-zinc-600 dark:text-zinc-400">整單備註 / 用途說明</span>
        <textarea value={notes} onChange={(e) => setNotes(e.target.value)} className={`${inputCls} min-h-16`} placeholder="（選填，例如：週末活動需求 / 庫存不足等）" />
      </label>

      <div className="flex gap-2">
        <button onClick={handleSubmit} disabled={busy || !valid} className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900">
          {busy ? "送出中…" : "送出申請"}
        </button>
        <button onClick={() => router.back()} disabled={busy} className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700">取消</button>
      </div>
    </div>
  );
}

function LineRow({
  line,
  showBranch,
  onChange,
  onRemove,
}: {
  line: Line;
  showBranch: boolean;
  onChange: (patch: Partial<Line>) => void;
  onRemove: (() => void) | null;
}) {
  const [open, setOpen] = useState(false);
  const [term, setTerm] = useState("");
  const [opts, setOpts] = useState<SkuOption[]>([]);

  useEffect(() => {
    if (!open) return;
    const t = setTimeout(async () => {
      const sb = getSupabase();
      let q = sb
        .from("skus")
        .select("id, sku_code, variant_name, product_id, products!inner(id, name, is_virtual)")
        .eq("status", "active")
        .eq("products.is_virtual", false)
        .limit(15);
      const safe = term.replace(/[%,()]/g, " ").trim();
      if (safe) q = q.or(`sku_code.ilike.%${safe}%,variant_name.ilike.%${safe}%`);
      const { data } = await q;
      const ids = (data ?? []).map((r) => r.id);
      let priceMap = new Map<number, { retail?: number; branch?: number }>();
      if (ids.length > 0) {
        const { data: priceRows } = await sb
          .from("prices")
          .select("sku_id, scope, price")
          .in("sku_id", ids)
          .in("scope", ["retail", "branch"])
          .is("effective_to", null);
        for (const p of (priceRows ?? []) as { sku_id: number; scope: string; price: number }[]) {
          const slot = priceMap.get(p.sku_id) ?? {};
          if (p.scope === "retail" && slot.retail === undefined) slot.retail = Number(p.price);
          if (p.scope === "branch" && slot.branch === undefined) slot.branch = Number(p.price);
          priceMap.set(p.sku_id, slot);
        }
      }
      setOpts(
        ((data ?? []) as unknown as Array<{
          id: number; sku_code: string; variant_name: string | null; product_id: number;
          products: { id: number; name: string; is_virtual: boolean };
        }>).map((s) => ({
          id: s.id, sku_code: s.sku_code, variant_name: s.variant_name,
          product_id: s.product_id, product_name: s.products.name,
          retail_price: priceMap.get(s.id)?.retail ?? null,
          branch_price: priceMap.get(s.id)?.branch ?? null,
        }))
      );
    }, 200);
    return () => clearTimeout(t);
  }, [term, open]);

  return (
    <tr>
      <td className="relative px-3 py-2">
        <input
          value={line.sku_id ? line.sku_label : term}
          onFocus={() => setOpen(true)}
          onChange={(e) => {
            if (line.sku_id) onChange({ sku_id: null, sku_label: "", unit_price: "0" });
            setTerm(e.target.value);
            setOpen(true);
          }}
          placeholder="搜尋商品 / SKU"
          className="w-full rounded border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
        {open && opts.length > 0 && (
          <div className="absolute left-0 top-full z-10 mt-1 max-h-60 w-96 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800" onMouseLeave={() => setOpen(false)}>
            {opts.map((o) => {
              const price = showBranch && o.branch_price !== null ? o.branch_price : o.retail_price ?? 0;
              return (
                <button
                  key={o.id}
                  type="button"
                  onClick={() => {
                    onChange({
                      sku_id: o.id,
                      sku_label: `${o.product_name}${o.variant_name ? ` / ${o.variant_name}` : ""} (${o.sku_code})`,
                      unit_price: String(price),
                    });
                    setOpen(false); setTerm("");
                  }}
                  className="block w-full px-2 py-1 text-left text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
                >
                  <span className="font-medium">{o.product_name}</span>
                  {o.variant_name && <span className="ml-1 text-zinc-500">/ {o.variant_name}</span>}
                  <span className="ml-2 font-mono text-zinc-400">{o.sku_code}</span>
                  <span className="ml-2 text-zinc-600 dark:text-zinc-300">${price}</span>
                </button>
              );
            })}
          </div>
        )}
      </td>
      <td className="px-3 py-2"><input type="number" min="0" step="0.001" value={line.qty} onChange={(e) => onChange({ qty: e.target.value })} className="w-24 rounded border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800" /></td>
      <td className="px-3 py-2"><input type="number" min="0" step="0.01" value={line.unit_price} onChange={(e) => onChange({ unit_price: e.target.value })} className="w-24 rounded border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800" /></td>
      <td className="px-3 py-2"><input value={line.notes} onChange={(e) => onChange({ notes: e.target.value })} placeholder="（選填）" className="w-full rounded border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800" /></td>
      <td className="px-3 py-2">
        {onRemove && (
          <button onClick={onRemove} className="rounded border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-400">移除</button>
        )}
      </td>
    </tr>
  );
}

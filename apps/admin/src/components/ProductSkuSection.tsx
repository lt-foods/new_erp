"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type SkuStatus = "draft" | "active" | "inactive" | "discontinued";

type Sku = {
  id: number;
  sku_code: string;
  variant_name: string | null;
  base_unit: string;
  weight_g: number | null;
  tax_rate: number;
  status: SkuStatus;
};

type PriceRow = { sku_id: number; price: number; effective_from: string };

type Draft = {
  id: number | null;
  sku_code: string;
  variant_name: string;
  base_unit: string;
  weight_g: string;
  tax_rate: string;
  status: SkuStatus;
  retail_price: string;
};

const EMPTY_DRAFT: Draft = {
  id: null,
  sku_code: "",
  variant_name: "",
  base_unit: "個",
  weight_g: "",
  tax_rate: "0.05",
  status: "active",
  retail_price: "",
};

const STATUS_LABEL: Record<SkuStatus, string> = {
  draft: "草稿",
  active: "上架",
  inactive: "下架",
  discontinued: "停產",
};

export function ProductSkuSection({ productId }: { productId: number }) {
  const [skus, setSkus] = useState<Sku[] | null>(null);
  const [prices, setPrices] = useState<Record<number, number>>({});
  const [draft, setDraft] = useState<Draft | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    setError(null);
    const sb = getSupabase();
    const { data: skuRows, error: skuErr } = await sb
      .from("skus")
      .select("id, sku_code, variant_name, base_unit, weight_g, tax_rate, status")
      .eq("product_id", productId)
      .order("id");
    if (skuErr) {
      setError(skuErr.message);
      return;
    }
    const list = (skuRows ?? []) as Sku[];
    setSkus(list);

    if (list.length > 0) {
      const ids = list.map((s) => s.id);
      const { data: priceRows } = await sb
        .from("prices")
        .select("sku_id, price, effective_from")
        .eq("scope", "retail")
        .is("effective_to", null)
        .in("sku_id", ids)
        .order("effective_from", { ascending: false });
      const map: Record<number, number> = {};
      for (const row of (priceRows ?? []) as PriceRow[]) {
        if (!(row.sku_id in map)) map[row.sku_id] = Number(row.price);
      }
      setPrices(map);
    } else {
      setPrices({});
    }
  }, [productId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  function startNew() {
    setDraft({ ...EMPTY_DRAFT });
  }

  function startEdit(sku: Sku) {
    setDraft({
      id: sku.id,
      sku_code: sku.sku_code,
      variant_name: sku.variant_name ?? "",
      base_unit: sku.base_unit,
      weight_g: sku.weight_g == null ? "" : String(sku.weight_g),
      tax_rate: String(sku.tax_rate),
      status: sku.status,
      retail_price: sku.id in prices ? String(prices[sku.id]) : "",
    });
  }

  async function save() {
    if (!draft) return;
    setError(null);
    setSaving(true);
    try {
      const sb = getSupabase();
      const { data: skuId, error: rpcErr } = await sb.rpc("rpc_upsert_sku", {
        p_id: draft.id,
        p_product_id: productId,
        p_sku_code: draft.sku_code,
        p_variant_name: draft.variant_name || null,
        p_spec: {},
        p_base_unit: draft.base_unit || "個",
        p_weight_g: draft.weight_g ? Number(draft.weight_g) : null,
        p_tax_rate: draft.tax_rate ? Number(draft.tax_rate) : 0.05,
        p_status: draft.status,
        p_reason: null,
      });
      if (rpcErr) throw rpcErr;

      const priceStr = draft.retail_price.trim();
      if (priceStr !== "") {
        const priceNum = Number(priceStr);
        const existing = skuId in prices ? prices[skuId as number] : null;
        if (existing !== priceNum) {
          const { error: priceErr } = await sb.rpc("rpc_set_retail_price", {
            p_sku_id: skuId,
            p_price: priceNum,
            p_effective_from: new Date().toISOString(),
            p_reason: null,
          });
          if (priceErr) throw priceErr;
        }
      }

      setDraft(null);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="space-y-3 rounded-lg border border-zinc-200 p-5 dark:border-zinc-800">
      <header className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold">SKU 變體</h2>
          <p className="text-xs text-zinc-500">
            每個 SKU 是獨立可賣 / 計庫存單位。零售價版本化、成本從採購入庫後自動算（avg_cost）。
          </p>
        </div>
        {!draft && (
          <button
            type="button"
            onClick={startNew}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            + 新增 SKU
          </button>
        )}
      </header>

      {error && (
        <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </p>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>SKU 編號</Th>
              <Th>變體名</Th>
              <Th>單位</Th>
              <Th className="text-right">重量 (g)</Th>
              <Th className="text-right">稅率</Th>
              <Th>狀態</Th>
              <Th className="text-right">零售價</Th>
              <Th className="text-right">動作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {skus === null ? (
              <tr>
                <td colSpan={8} className="p-3">
                  <div className="h-4 animate-pulse rounded bg-zinc-100 dark:bg-zinc-800" />
                </td>
              </tr>
            ) : (
              <>
                {skus.map((s) =>
                  draft?.id === s.id ? (
                    <DraftRow
                      key={s.id}
                      draft={draft}
                      setDraft={setDraft}
                      onSave={save}
                      onCancel={() => setDraft(null)}
                      saving={saving}
                    />
                  ) : (
                    <tr key={s.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                      <Td className="font-mono">{s.sku_code}</Td>
                      <Td>{s.variant_name ?? "—"}</Td>
                      <Td>{s.base_unit}</Td>
                      <Td className="text-right">{s.weight_g ?? "—"}</Td>
                      <Td className="text-right">{s.tax_rate}</Td>
                      <Td>
                        <StatusBadge status={s.status} />
                      </Td>
                      <Td className="text-right">
                        {s.id in prices ? `$${prices[s.id]}` : "—"}
                      </Td>
                      <Td className="text-right">
                        <button
                          type="button"
                          onClick={() => startEdit(s)}
                          className="text-xs text-zinc-600 hover:underline dark:text-zinc-400"
                        >
                          編輯
                        </button>
                      </Td>
                    </tr>
                  )
                )}
                {draft && draft.id === null && (
                  <DraftRow
                    draft={draft}
                    setDraft={setDraft}
                    onSave={save}
                    onCancel={() => setDraft(null)}
                    saving={saving}
                  />
                )}
                {skus.length === 0 && !draft && (
                  <tr>
                    <td colSpan={8} className="p-4 text-center text-sm text-zinc-500">
                      還沒有 SKU。按「新增 SKU」開始。
                    </td>
                  </tr>
                )}
              </>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function DraftRow({
  draft,
  setDraft,
  onSave,
  onCancel,
  saving,
}: {
  draft: Draft;
  setDraft: (d: Draft) => void;
  onSave: () => void;
  onCancel: () => void;
  saving: boolean;
}) {
  function set<K extends keyof Draft>(key: K, value: Draft[K]) {
    setDraft({ ...draft, [key]: value });
  }

  return (
    <tr className="bg-amber-50/40 dark:bg-amber-950/20">
      <Td>
        <input
          value={draft.sku_code}
          onChange={(e) => set("sku_code", e.target.value)}
          placeholder="SKU 編號"
          className={inputClass}
        />
      </Td>
      <Td>
        <input
          value={draft.variant_name}
          onChange={(e) => set("variant_name", e.target.value)}
          placeholder="例：100 入"
          className={inputClass}
        />
      </Td>
      <Td>
        <input
          value={draft.base_unit}
          onChange={(e) => set("base_unit", e.target.value)}
          className={`${inputClass} w-14`}
        />
      </Td>
      <Td>
        <input
          type="number"
          value={draft.weight_g}
          onChange={(e) => set("weight_g", e.target.value)}
          className={`${inputClass} w-20 text-right`}
        />
      </Td>
      <Td>
        <input
          type="number"
          step="0.0001"
          value={draft.tax_rate}
          onChange={(e) => set("tax_rate", e.target.value)}
          className={`${inputClass} w-20 text-right`}
        />
      </Td>
      <Td>
        <select
          value={draft.status}
          onChange={(e) => set("status", e.target.value as SkuStatus)}
          className={inputClass}
        >
          <option value="draft">草稿</option>
          <option value="active">上架</option>
          <option value="inactive">下架</option>
          <option value="discontinued">停產</option>
        </select>
      </Td>
      <Td>
        <input
          type="number"
          step="0.01"
          value={draft.retail_price}
          onChange={(e) => set("retail_price", e.target.value)}
          placeholder="$"
          className={`${inputClass} w-24 text-right`}
        />
      </Td>
      <Td className="text-right">
        <div className="flex justify-end gap-1">
          <button
            type="button"
            onClick={onSave}
            disabled={saving}
            className="rounded bg-zinc-900 px-2 py-1 text-xs font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
          >
            {saving ? "…" : "儲存"}
          </button>
          <button
            type="button"
            onClick={onCancel}
            disabled={saving}
            className="rounded border border-zinc-300 px-2 py-1 text-xs dark:border-zinc-700"
          >
            取消
          </button>
        </div>
      </Td>
    </tr>
  );
}

const inputClass =
  "rounded border border-zinc-300 bg-white px-2 py-1 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return (
    <th className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>
      {children}
    </th>
  );
}

function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-3 py-2 ${className}`}>{children}</td>;
}

function StatusBadge({ status }: { status: SkuStatus }) {
  const styles: Record<SkuStatus, string> = {
    draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    active: "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
    inactive: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    discontinued: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  };
  return (
    <span className={`inline-block rounded px-2 py-0.5 text-xs ${styles[status]}`}>
      {STATUS_LABEL[status]}
    </span>
  );
}

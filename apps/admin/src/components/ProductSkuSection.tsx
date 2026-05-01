"use client";

import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useState,
  type Ref,
} from "react";
import { getSupabase } from "@/lib/supabase";
import { useRole, canSeeCost, canSeeBranch, type Role } from "@/lib/role";

type Sku = {
  id: number;
  sku_code: string;
  variant_name: string | null;
  base_unit: string;
};

type PriceScope = "retail" | "cost" | "branch";
type PriceRow = { sku_id: number; price: number; scope: PriceScope; effective_from: string };
type PriceMap = { retail?: number; cost?: number; branch?: number };

type Draft = {
  id: number | null;
  sku_code: string;
  variant_name: string;
  base_unit: string;
  retail_price: string;
  cost_price: string;
  branch_price: string;
};

type PendingSku = Draft & { tempId: number };

const EMPTY_DRAFT: Draft = {
  id: null,
  sku_code: "",
  variant_name: "",
  base_unit: "個",
  retail_price: "",
  cost_price: "",
  branch_price: "",
};

// 寫 retail / cost / branch 三種價格。空字串跳過、與 existing 同值跳過、
// 角色不允許的 scope 也跳過（若角色看不到，DraftCard 該欄位本來就不渲染、永遠空字串）。
async function writePrices(
  skuId: number,
  draft: { retail_price: string; cost_price: string; branch_price: string },
  role: Role | null,
  existing?: PriceMap
) {
  const sb = getSupabase();
  const now = new Date().toISOString();
  type PriceJob = { rpc: string; field: keyof PriceMap; value: string };
  const jobs: PriceJob[] = [
    { rpc: "rpc_set_retail_price", field: "retail", value: draft.retail_price },
    { rpc: "rpc_set_cost_price", field: "cost", value: draft.cost_price },
    { rpc: "rpc_set_branch_price", field: "branch", value: draft.branch_price },
  ];
  for (const job of jobs) {
    const trimmed = job.value.trim();
    if (trimmed === "") continue;
    if (job.field === "cost" && !canSeeCost(role)) continue;
    if (job.field === "branch" && !canSeeBranch(role)) continue;
    const num = Number(trimmed);
    if (!Number.isFinite(num) || num < 0) {
      throw new Error(`${job.field} 價格必須為 ≥ 0 的數字`);
    }
    if (existing && existing[job.field] === num) continue;
    const { error } = await sb.rpc(job.rpc, {
      p_sku_id: skuId,
      p_price: num,
      p_effective_from: now,
      p_reason: null,
    });
    if (error) throw error;
  }
}

export type ProductSkuSectionHandle = {
  flush: (productId: number) => Promise<void>;
  hasPending: () => boolean;
};

export function ProductSkuSection({
  productId,
  ref,
}: {
  productId: number | null;
  ref?: Ref<ProductSkuSectionHandle>;
}) {
  const isPending = productId === null;
  const role = useRole();
  const showCost = canSeeCost(role);
  const showBranch = canSeeBranch(role);

  const [skus, setSkus] = useState<Sku[] | null>(isPending ? [] : null);
  const [prices, setPrices] = useState<Record<number, PriceMap>>({});
  const [pending, setPending] = useState<PendingSku[]>([]);
  const [editingTempId, setEditingTempId] = useState<number | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    if (productId === null) return;
    setError(null);
    const sb = getSupabase();
    const { data: skuRows, error: skuErr } = await sb
      .from("skus")
      .select("id, sku_code, variant_name, base_unit")
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
      // RLS 自動依 role × scope 過濾 — store_staff 拿不到 cost/branch、store_manager 拿不到 cost
      const { data: priceRows } = await sb
        .from("prices")
        .select("sku_id, price, scope, effective_from")
        .in("scope", ["retail", "cost", "branch"])
        .is("effective_to", null)
        .in("sku_id", ids)
        .order("effective_from", { ascending: false });
      const map: Record<number, PriceMap> = {};
      for (const row of (priceRows ?? []) as PriceRow[]) {
        const slot = (map[row.sku_id] ??= {});
        if (slot[row.scope] === undefined) slot[row.scope] = Number(row.price);
      }
      setPrices(map);
    } else {
      setPrices({});
    }
  }, [productId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useImperativeHandle(
    ref,
    () => ({
      hasPending: () => pending.length > 0,
      flush: async (newId: number) => {
        if (pending.length === 0) return;
        const sb = getSupabase();
        for (const p of pending) {
          const { data: skuId, error: rpcErr } = await sb.rpc("rpc_upsert_sku", {
            p_id: null,
            p_product_id: newId,
            p_sku_code: p.sku_code,
            p_variant_name: p.variant_name || null,
            p_spec: {},
            p_base_unit: p.base_unit || "個",
            p_weight_g: null,
            p_tax_rate: 0,
            p_status: "active",
            p_reason: null,
          });
          if (rpcErr) throw rpcErr;
          await writePrices(skuId as number, p, role);
        }
        setPending([]);
      },
    }),
    [pending, role]
  );

  async function startNew() {
    let code = "";
    if (productId !== null) {
      const { data } = await getSupabase().rpc("rpc_next_sku_code", {
        p_product_id: productId,
      });
      if (typeof data === "string") code = data;
    }
    // 帶入第一筆規格的價格 / base_unit（已存的優先、否則用 pending 第一筆）
    const firstSaved = skus && skus.length > 0 ? skus[0] : null;
    const firstPending = pending.length > 0 ? pending[0] : null;
    let prefilledRetail = "";
    let prefilledCost = "";
    let prefilledBranch = "";
    let prefilledUnit = EMPTY_DRAFT.base_unit;
    if (firstSaved) {
      const p = prices[firstSaved.id] ?? {};
      prefilledRetail = p.retail !== undefined ? String(p.retail) : "";
      prefilledCost = p.cost !== undefined ? String(p.cost) : "";
      prefilledBranch = p.branch !== undefined ? String(p.branch) : "";
      prefilledUnit = firstSaved.base_unit || prefilledUnit;
    } else if (firstPending) {
      prefilledRetail = firstPending.retail_price;
      prefilledCost = firstPending.cost_price;
      prefilledBranch = firstPending.branch_price;
      prefilledUnit = firstPending.base_unit || prefilledUnit;
    }
    setDraft({
      ...EMPTY_DRAFT,
      sku_code: code,
      base_unit: prefilledUnit,
      retail_price: prefilledRetail,
      cost_price: prefilledCost,
      branch_price: prefilledBranch,
    });
    setEditingTempId(null);
  }

  function startEditExisting(sku: Sku) {
    const p = prices[sku.id] ?? {};
    setDraft({
      id: sku.id,
      sku_code: sku.sku_code,
      variant_name: sku.variant_name ?? "",
      base_unit: sku.base_unit,
      retail_price: p.retail !== undefined ? String(p.retail) : "",
      cost_price: p.cost !== undefined ? String(p.cost) : "",
      branch_price: p.branch !== undefined ? String(p.branch) : "",
    });
    setEditingTempId(null);
  }

  function startEditPending(p: PendingSku) {
    setDraft({
      id: null,
      sku_code: p.sku_code,
      variant_name: p.variant_name,
      base_unit: p.base_unit,
      retail_price: p.retail_price,
      cost_price: p.cost_price,
      branch_price: p.branch_price,
    });
    setEditingTempId(p.tempId);
  }

  function deletePending(tempId: number) {
    setPending((arr) => arr.filter((x) => x.tempId !== tempId));
    if (editingTempId === tempId) {
      setDraft(null);
      setEditingTempId(null);
    }
  }

  function cancelEdit() {
    setDraft(null);
    setEditingTempId(null);
  }

  async function save() {
    if (!draft) return;
    setError(null);

    if (!draft.sku_code.trim()) {
      setError("規格編號必填");
      return;
    }

    if (isPending) {
      if (editingTempId !== null) {
        const tid = editingTempId;
        setPending((arr) =>
          arr.map((x) => (x.tempId === tid ? { ...draft, tempId: tid } : x))
        );
      } else {
        const tid = -Date.now();
        setPending((arr) => [...arr, { ...draft, tempId: tid }]);
      }
      cancelEdit();
      return;
    }

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
        p_weight_g: null,
        p_tax_rate: 0,
        p_status: "active",
        p_reason: null,
      });
      if (rpcErr) throw rpcErr;

      const existing = (skuId as number) in prices ? prices[skuId as number] : {};
      await writePrices(skuId as number, draft, role, existing);

      cancelEdit();
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  async function deleteSku(sku: Sku) {
    if (
      !confirm(
        `確定刪除規格「${sku.sku_code}${sku.variant_name ? ` / ${sku.variant_name}` : ""}」？\n（軟刪除：狀態改為「停產」、保留歷史紀錄）`
      )
    )
      return;
    setError(null);
    const { error: err } = await getSupabase().rpc("rpc_delete_sku", {
      p_id: sku.id,
    });
    if (err) {
      setError(err.message);
      return;
    }
    await refresh();
  }

  const isEditingExisting = draft?.id != null;
  const isEditingPending = editingTempId !== null;
  const isAddingNew = draft != null && !isEditingExisting && !isEditingPending;

  return (
    <section className="space-y-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold">規格 / 品項</h2>
          <p className="text-xs text-zinc-500">
            一個商品可有多個規格（口味 / 容量 / 入數），各自獨立計庫存。
          </p>
        </div>
        {!draft && (
          <button
            type="button"
            onClick={startNew}
            className="shrink-0 rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            + 新增規格
          </button>
        )}
      </header>

      {error && (
        <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </p>
      )}

      <div className="space-y-2">
        {skus === null && (
          <div className="h-12 animate-pulse rounded-md bg-zinc-100 dark:bg-zinc-800" />
        )}

        {skus?.map((s) =>
          draft?.id === s.id ? (
            <DraftCard
              key={s.id}
              draft={draft}
              setDraft={setDraft}
              onSave={save}
              onCancel={cancelEdit}
              saving={saving}
              showCost={showCost}
              showBranch={showBranch}
            />
          ) : (
            <SkuCard
              key={s.id}
              sku={s}
              priceMap={prices[s.id] ?? {}}
              showCost={showCost}
              showBranch={showBranch}
              onEdit={() => startEditExisting(s)}
              onDelete={() => deleteSku(s)}
            />
          )
        )}

        {pending.map((p) =>
          editingTempId === p.tempId && draft ? (
            <DraftCard
              key={p.tempId}
              draft={draft}
              setDraft={setDraft}
              onSave={save}
              onCancel={cancelEdit}
              saving={saving}
              showCost={showCost}
              showBranch={showBranch}
            />
          ) : (
            <PendingCard
              key={p.tempId}
              p={p}
              showCost={showCost}
              showBranch={showBranch}
              onEdit={() => startEditPending(p)}
              onDelete={() => deletePending(p.tempId)}
            />
          )
        )}

        {isAddingNew && draft && (
          <DraftCard
            draft={draft}
            setDraft={setDraft}
            onSave={save}
            onCancel={cancelEdit}
            saving={saving}
            showCost={showCost}
            showBranch={showBranch}
          />
        )}

        {skus !== null && skus.length === 0 && pending.length === 0 && !draft && (
          <p className="rounded-md border border-dashed border-zinc-300 px-3 py-6 text-center text-sm text-zinc-500 dark:border-zinc-700">
            還沒有規格。按「新增規格」開始。
          </p>
        )}
      </div>

      {isPending && pending.length > 0 && (
        <p className="text-xs text-amber-700 dark:text-amber-400">
          已暫存 {pending.length} 筆規格，將在「建立」商品時一併寫入。
        </p>
      )}
    </section>
  );
}

function SkuCard({
  sku,
  priceMap,
  showCost,
  showBranch,
  onEdit,
  onDelete,
}: {
  sku: Sku;
  priceMap: PriceMap;
  showCost: boolean;
  showBranch: boolean;
  onEdit: () => void;
  onDelete: () => void;
}) {
  return (
    <div className="flex items-center gap-3 rounded-md border border-zinc-200 px-3 py-2 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-900">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="font-mono text-sm">{sku.sku_code}</span>
          {sku.variant_name && (
            <span className="text-sm text-zinc-700 dark:text-zinc-300">
              {sku.variant_name}
            </span>
          )}
        </div>
        <div className="mt-0.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-zinc-500">
          <span>{sku.base_unit}</span>
          {priceMap.retail !== undefined && (
            <span className="rounded bg-emerald-100 px-1.5 py-0.5 font-bold text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
              零售 ${priceMap.retail}
            </span>
          )}
          {showBranch && priceMap.branch !== undefined && (
            <span className="rounded bg-amber-100 px-1.5 py-0.5 font-bold text-amber-800 dark:bg-amber-950 dark:text-amber-300">
              分店 ${priceMap.branch}
            </span>
          )}
          {showCost && priceMap.cost !== undefined && (
            <span className="rounded bg-rose-100 px-1.5 py-0.5 font-bold text-rose-800 dark:bg-rose-950 dark:text-rose-300">
              成本 ${priceMap.cost}
            </span>
          )}
        </div>
      </div>
      <button
        type="button"
        onClick={onEdit}
        className="shrink-0 rounded border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
      >
        編輯
      </button>
      <button
        type="button"
        onClick={onDelete}
        className="shrink-0 rounded border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-400 dark:hover:bg-red-950"
      >
        刪除
      </button>
    </div>
  );
}

function PendingCard({
  p,
  showCost,
  showBranch,
  onEdit,
  onDelete,
}: {
  p: PendingSku;
  showCost: boolean;
  showBranch: boolean;
  onEdit: () => void;
  onDelete: () => void;
}) {
  return (
    <div className="flex items-center gap-3 rounded-md border border-amber-300 bg-amber-50/40 px-3 py-2 dark:border-amber-800 dark:bg-amber-950/20">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="font-mono text-sm">{p.sku_code}</span>
          {p.variant_name && (
            <span className="text-sm text-zinc-700 dark:text-zinc-300">
              {p.variant_name}
            </span>
          )}
          <span className="rounded bg-amber-200 px-1.5 py-0.5 text-[10px] font-medium text-amber-900 dark:bg-amber-900 dark:text-amber-100">
            待寫入
          </span>
        </div>
        <div className="mt-0.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-zinc-500">
          <span>{p.base_unit}</span>
          {p.retail_price && (
            <span className="rounded bg-emerald-100 px-1.5 py-0.5 font-bold text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
              零售 ${p.retail_price}
            </span>
          )}
          {showBranch && p.branch_price && (
            <span className="rounded bg-amber-100 px-1.5 py-0.5 font-bold text-amber-800 dark:bg-amber-950 dark:text-amber-300">
              分店 ${p.branch_price}
            </span>
          )}
          {showCost && p.cost_price && (
            <span className="rounded bg-rose-100 px-1.5 py-0.5 font-bold text-rose-800 dark:bg-rose-950 dark:text-rose-300">
              成本 ${p.cost_price}
            </span>
          )}
        </div>
      </div>
      <button
        type="button"
        onClick={onEdit}
        className="shrink-0 rounded border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
      >
        編輯
      </button>
      <button
        type="button"
        onClick={onDelete}
        className="shrink-0 rounded border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-400 dark:hover:bg-red-950"
      >
        移除
      </button>
    </div>
  );
}

function DraftCard({
  draft,
  setDraft,
  onSave,
  onCancel,
  saving,
  showCost,
  showBranch,
}: {
  draft: Draft;
  setDraft: (d: Draft) => void;
  onSave: () => void;
  onCancel: () => void;
  saving: boolean;
  showCost: boolean;
  showBranch: boolean;
}) {
  function set<K extends keyof Draft>(key: K, value: Draft[K]) {
    setDraft({ ...draft, [key]: value });
  }

  return (
    <div className="space-y-3 rounded-md border-2 border-amber-300 bg-amber-50/40 p-3 dark:border-amber-800 dark:bg-amber-950/20">
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="規格編號" required>
          <input
            value={draft.sku_code}
            onChange={(e) => set("sku_code", e.target.value)}
            placeholder="例：A001-100"
            className={inputClass}
          />
        </Field>
        <Field label="變體名">
          <input
            value={draft.variant_name}
            onChange={(e) => set("variant_name", e.target.value)}
            placeholder="例：100 入"
            className={inputClass}
          />
        </Field>
        <Field label="單位">
          <input
            value={draft.base_unit}
            onChange={(e) => set("base_unit", e.target.value)}
            className={inputClass}
          />
        </Field>
        <Field label="零售價">
          <input
            type="number"
            step="0.01"
            value={draft.retail_price}
            onChange={(e) => set("retail_price", e.target.value)}
            placeholder="$"
            className={inputClass}
          />
        </Field>
        {showBranch && (
          <Field label="分店價">
            <input
              type="number"
              step="0.01"
              value={draft.branch_price}
              onChange={(e) => set("branch_price", e.target.value)}
              placeholder="$（全分店共用）"
              className={inputClass}
            />
          </Field>
        )}
        {showCost && (
          <Field label="成本價">
            <input
              type="number"
              step="0.01"
              value={draft.cost_price}
              onChange={(e) => set("cost_price", e.target.value)}
              placeholder="$（進貨成本）"
              className={inputClass}
            />
          </Field>
        )}
      </div>
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={onSave}
          disabled={saving}
          className="rounded bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
        >
          {saving ? "儲存中…" : "儲存"}
        </button>
        <button
          type="button"
          onClick={onCancel}
          disabled={saving}
          className="rounded border border-zinc-300 px-3 py-1.5 text-xs dark:border-zinc-700"
        >
          取消
        </button>
      </div>
    </div>
  );
}

function Field({
  label,
  required,
  children,
}: {
  label: string;
  required?: boolean;
  children: React.ReactNode;
}) {
  return (
    <label className="block space-y-1">
      <span className="text-xs font-medium text-zinc-700 dark:text-zinc-300">
        {label}
        {required && <span className="text-red-500"> *</span>}
      </span>
      {children}
    </label>
  );
}

const inputClass =
  "w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

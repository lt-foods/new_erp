"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";

/**
 * 店家自開團的建立視窗。
 *
 * 跟總倉的「從商品開團」是兩條不同的路：那條走 /products?mode=campaign，
 * 而 /products 在 BRANCH_HIDDEN_HREFS 裡、分店根本進不去。所以這支自己帶
 * 商品搜尋，讓店長在開團列表就能開完。
 *
 * 送出走 rpc_store_create_campaign —— 它強制寫上 owner_store_id 並過
 * _assert_own_store（分店只能開自己店的），也會在沒填團購價時退回零售價、
 * 兩者都沒有就擋下來（避免 0 元團）。
 */

type StoreOpt = { id: number; name: string };

type SkuRow = {
  id: number;
  sku_code: string;
  product_name: string | null;
  variant_name: string | null;
  status: string | null;
  product_id: number | null;
};

type PickedSku = {
  sku: SkuRow;
  /** 團購價；空字串 = 沿用零售價（後端補） */
  price: string;
};

const CLOSE_TYPES: { value: "regular" | "fast" | "limited"; label: string; hint: string }[] = [
  { value: "regular", label: "一般", hint: "到結單時間就收單" },
  { value: "fast", label: "快團", hint: "強制要有結單時間" },
  { value: "limited", label: "限量", hint: "可設總量上限" },
];

function toDatetimeLocal(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function StoreCampaignCreateModal({
  stores,
  defaultStoreId,
  lockStore,
  onClose,
  onCreated,
}: {
  stores: StoreOpt[];
  /** 分店帳號預選自己的店 */
  defaultStoreId: number | null;
  /** 分店帳號不給改店（後端也會擋，這裡只是不要給錯的選項） */
  lockStore: boolean;
  onClose: () => void;
  onCreated: (campaignId: number) => void;
}) {
  const today = new Date();
  const defaultEnd = new Date(today);
  defaultEnd.setDate(today.getDate() + 3);
  defaultEnd.setHours(23, 59, 0, 0);

  const [storeId, setStoreId] = useState<number | null>(defaultStoreId ?? stores[0]?.id ?? null);
  const [name, setName] = useState("");
  const [closeType, setCloseType] = useState<"regular" | "fast" | "limited">("regular");
  const [endAt, setEndAt] = useState(toDatetimeLocal(defaultEnd));
  const [pickupDeadline, setPickupDeadline] = useState(() => {
    const d = new Date(defaultEnd);
    d.setDate(d.getDate() + 14);
    return d.toISOString().split("T")[0];
  });
  const [totalCap, setTotalCap] = useState("");
  const [description, setDescription] = useState("");

  const [search, setSearch] = useState("");
  const [results, setResults] = useState<SkuRow[]>([]);
  const [searching, setSearching] = useState(false);
  const [picked, setPicked] = useState<PickedSku[]>([]);
  const [retail, setRetail] = useState<Record<number, number>>({});

  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // 商品搜尋（debounce 300ms）。只找 active SKU —— 停用的規格開了團也賣不出去。
  useEffect(() => {
    const q = search.trim();
    if (q.length < 1) {
      setResults([]);
      return;
    }
    let cancelled = false;
    const t = setTimeout(async () => {
      setSearching(true);
      try {
        const safe = q.replace(/[%,()]/g, " ").trim();
        const { data, error } = await getSupabase()
          .from("skus")
          .select("id, sku_code, product_name, variant_name, status, product_id")
          .eq("status", "active")
          .or(`product_name.ilike.%${safe}%,variant_name.ilike.%${safe}%,sku_code.ilike.%${safe}%`)
          .order("product_name", { ascending: true })
          .limit(30);
        if (cancelled) return;
        if (error) { setErr(error.message); return; }
        setResults((data ?? []) as SkuRow[]);
      } finally {
        if (!cancelled) setSearching(false);
      }
    }, 300);
    return () => { cancelled = true; clearTimeout(t); };
  }, [search]);

  // 帶出現行零售價當預設團購價（沒有就留空，後端會擋並說明要補價）
  useEffect(() => {
    const missing = picked.map((p) => p.sku.id).filter((id) => !(id in retail));
    if (missing.length === 0) return;
    let cancelled = false;
    (async () => {
      const { data } = await getSupabase()
        .from("prices")
        .select("sku_id, price")
        .eq("scope", "retail")
        .is("effective_to", null)
        .in("sku_id", missing);
      if (cancelled) return;
      const next: Record<number, number> = {};
      for (const r of data ?? []) next[Number(r.sku_id)] = Number(r.price);
      setRetail((prev) => ({ ...prev, ...next }));
      setPicked((prev) =>
        prev.map((p) =>
          p.price === "" && next[p.sku.id] != null
            ? { ...p, price: String(next[p.sku.id]) }
            : p,
        ),
      );
    })();
    return () => { cancelled = true; };
  }, [picked, retail]);

  const pickedIds = useMemo(() => new Set(picked.map((p) => p.sku.id)), [picked]);

  function addSku(s: SkuRow) {
    if (pickedIds.has(s.id)) return;
    setPicked((prev) => [...prev, { sku: s, price: retail[s.id] != null ? String(retail[s.id]) : "" }]);
    if (!name.trim() && s.product_name) setName(s.product_name);
  }

  function removeSku(id: number) {
    setPicked((prev) => prev.filter((p) => p.sku.id !== id));
  }

  function setPrice(id: number, v: string) {
    setPicked((prev) => prev.map((p) => (p.sku.id === id ? { ...p, price: v } : p)));
  }

  async function submit(status: "draft" | "open") {
    setErr(null);
    if (!storeId) { setErr("請選擇門市"); return; }
    if (!name.trim()) { setErr("請填團名"); return; }
    if (picked.length === 0) { setErr("至少要選一個商品"); return; }
    if (closeType === "fast" && !endAt) { setErr("快團一定要設結單時間"); return; }

    setSaving(true);
    try {
      const { data, error } = await getSupabase().rpc("rpc_store_create_campaign", {
        p_store_id: storeId,
        p_name: name.trim(),
        p_items: picked.map((p, i) => ({
          sku_id: p.sku.id,
          unit_price: p.price.trim() === "" ? null : Number(p.price),
          sort_order: i,
        })),
        p_end_at: endAt ? new Date(endAt).toISOString() : null,
        p_pickup_deadline: pickupDeadline || null,
        p_description: description.trim() || null,
        p_cover_image_url: null,
        p_close_type: closeType,
        p_total_cap_qty: totalCap.trim() === "" ? null : Number(totalCap),
        p_status: status,
      });
      if (error) { setErr(error.message); return; }
      onCreated(Number(data));
    } finally {
      setSaving(false);
    }
  }

  const storeName = stores.find((s) => s.id === storeId)?.name ?? "";

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="my-8 w-full max-w-2xl rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <div className="mb-1 flex items-start justify-between gap-3">
          <h2 className="text-lg font-semibold">🏪 開自己店的團</h2>
          <button onClick={onClose} className="text-zinc-400 hover:text-zinc-600" aria-label="關閉">✕</button>
        </div>
        <p className="mb-4 text-sm text-zinc-500 dark:text-zinc-400">
          只有 {storeName || "該門市"} 的客人跟員工看得到。結單後不經總倉、不請購也不出貨，
          直接到「收貨」對這個團收貨就會配單給客人。
        </p>

        {err && (
          <div className="mb-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        <div className="space-y-4">
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block">
              <span className="mb-1 block text-sm font-medium">門市</span>
              <select
                value={storeId ?? ""}
                onChange={(e) => setStoreId(Number(e.target.value) || null)}
                disabled={lockStore}
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-800"
              >
                {stores.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
              </select>
            </label>

            <label className="block">
              <span className="mb-1 block text-sm font-medium">收單類型</span>
              <select
                value={closeType}
                onChange={(e) => setCloseType(e.target.value as typeof closeType)}
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              >
                {CLOSE_TYPES.map((t) => (
                  <option key={t.value} value={t.value}>{t.label}（{t.hint}）</option>
                ))}
              </select>
            </label>
          </div>

          <label className="block">
            <span className="mb-1 block text-sm font-medium">團名</span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="例：本店限定・週末水果團"
              className="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>

          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block">
              <span className="mb-1 block text-sm font-medium">
                結單時間{closeType === "fast" && <span className="text-red-600"> *</span>}
              </span>
              <input
                type="datetime-local"
                value={endAt}
                onChange={(e) => setEndAt(e.target.value)}
                className="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              />
            </label>
            <div>
              <span className="mb-1 block text-sm font-medium">取貨期限</span>
              <DatePicker value={pickupDeadline} onChange={setPickupDeadline} />
            </div>
          </div>

          {closeType === "limited" && (
            <label className="block">
              <span className="mb-1 block text-sm font-medium">總量上限</span>
              <input
                type="number"
                min={1}
                value={totalCap}
                onChange={(e) => setTotalCap(e.target.value)}
                placeholder="不填 = 不限"
                className="w-40 rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              />
            </label>
          )}

          {/* 商品 */}
          <div>
            <span className="mb-1 block text-sm font-medium">商品</span>
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="搜尋商品名稱 / 規格 / 貨號"
              className="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
            {searching && <p className="mt-1 text-xs text-zinc-400">搜尋中…</p>}
            {results.length > 0 && (
              <ul className="mt-2 max-h-48 divide-y divide-zinc-100 overflow-y-auto rounded-md border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-700">
                {results.map((s) => (
                  <li key={s.id}>
                    <button
                      type="button"
                      onClick={() => addSku(s)}
                      disabled={pickedIds.has(s.id)}
                      className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left text-sm hover:bg-zinc-50 disabled:opacity-40 dark:hover:bg-zinc-800"
                    >
                      <span className="min-w-0 truncate">
                        {s.product_name}
                        {s.variant_name ? <span className="text-zinc-500"> / {s.variant_name}</span> : null}
                        <span className="ml-2 text-xs text-zinc-400">{s.sku_code}</span>
                      </span>
                      <span className="shrink-0 text-xs text-zinc-400">
                        {pickedIds.has(s.id) ? "已加入" : "+ 加入"}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            )}

            {picked.length > 0 && (
              <table className="mt-3 w-full text-sm">
                <thead className="text-xs text-zinc-500">
                  <tr>
                    <th className="py-1 text-left font-medium">商品</th>
                    <th className="py-1 text-right font-medium">團購價</th>
                    <th className="w-8" />
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {picked.map((p) => (
                    <tr key={p.sku.id}>
                      <td className="py-1.5 pr-2">
                        <span className="block truncate">
                          {p.sku.product_name}
                          {p.sku.variant_name ? <span className="text-zinc-500"> / {p.sku.variant_name}</span> : null}
                        </span>
                        <span className="text-xs text-zinc-400">{p.sku.sku_code}</span>
                      </td>
                      <td className="py-1.5 text-right">
                        <input
                          type="number"
                          min={0}
                          value={p.price}
                          onChange={(e) => setPrice(p.sku.id, e.target.value)}
                          placeholder="零售價"
                          className="w-24 rounded-md border border-zinc-300 px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                        />
                      </td>
                      <td className="py-1.5 text-right">
                        <button
                          type="button"
                          onClick={() => removeSku(p.sku.id)}
                          className="text-zinc-400 hover:text-red-600"
                          aria-label="移除"
                        >
                          ✕
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>

          <label className="block">
            <span className="mb-1 block text-sm font-medium">說明（選填）</span>
            <textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              rows={2}
              className="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
        </div>

        <div className="mt-5 flex justify-end gap-2">
          <button
            onClick={onClose}
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700"
          >
            取消
          </button>
          <SpinButton
            onClick={() => submit("draft")}
            disabled={saving}
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm font-medium disabled:opacity-50 dark:border-zinc-700"
          >
            存成草稿
          </SpinButton>
          <SpinButton
            onClick={() => submit("open")}
            disabled={saving}
            className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
          >
            開團
          </SpinButton>
        </div>
      </div>
    </div>
  );
}

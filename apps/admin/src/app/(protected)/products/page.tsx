"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { ProductForm, type ProductFormValues } from "@/components/ProductForm";
import { ProductSkuSection, type ProductSkuSectionHandle } from "@/components/ProductSkuSection";

type Status = "draft" | "active" | "inactive" | "discontinued";
type SortKey = "updated_at" | "product_code" | "name" | "status";
type SortDir = "asc" | "desc";

type ProductRow = {
  id: number;
  product_code: string;
  name: string;
  short_name: string | null;
  status: Status;
  brand_id: number | null;
  category_id: number | null;
  updated_at: string;
};

type LookupRow = { id: number; name: string; code: string };

type StorageType = "room_temp" | "refrigerated" | "frozen" | "meal_train" | null;

const STATUS_LABEL: Record<Status, string> = {
  draft: "草稿",
  active: "上架",
  inactive: "下架",
  discontinued: "停產",
};

const PAGE_SIZE = 50;

// 取貨天數 by 溫層（收單時間 + N 天 = 取貨截止）
const PICKUP_DAYS_BY_STORAGE: Record<string, number> = {
  frozen: 14,
  refrigerated: 14,
  room_temp: 30,
  meal_train: 7,
};
const DEFAULT_PICKUP_DAYS = 21;

function pickupDaysForStorageTypes(types: (StorageType | null)[]): number {
  const all = types.filter(Boolean) as string[];
  if (all.includes("frozen") || all.includes("refrigerated")) {
    return Math.min(...all.map((t) => PICKUP_DAYS_BY_STORAGE[t] ?? DEFAULT_PICKUP_DAYS));
  }
  if (all.length === 0) return DEFAULT_PICKUP_DAYS;
  return Math.max(...all.map((t) => PICKUP_DAYS_BY_STORAGE[t] ?? DEFAULT_PICKUP_DAYS));
}

function addDays(date: Date, n: number): string {
  const d = new Date(date);
  d.setDate(d.getDate() + n);
  return d.toISOString().split("T")[0];
}

function toDatetimeLocal(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// ============================================================
// CreateCampaignModal
// ============================================================
type SelectedProduct = {
  id: number;
  name: string;
  storage_type: StorageType;
};

function CreateCampaignModal({
  products,
  onClose,
  onCreated,
}: {
  products: SelectedProduct[];
  onClose: () => void;
  onCreated: (campaignId: number) => void;
}) {
  const today = new Date();
  const defaultEndAt = new Date(today);
  defaultEndAt.setDate(today.getDate() + 3);
  defaultEndAt.setHours(23, 59, 0, 0);

  const storageTypes = products.map((p) => p.storage_type);
  const pickupDays = pickupDaysForStorageTypes(storageTypes);

  const defaultName = products.length <= 3
    ? products.map((p) => p.name).join(" / ")
    : `${products[0].name} 等 ${products.length} 項商品`;

  const [name, setName] = useState(defaultName);
  const [endAt, setEndAt] = useState(toDatetimeLocal(defaultEndAt.toISOString()));
  const [pickupDeadline, setPickupDeadline] = useState(() => {
    const d = new Date(defaultEndAt);
    d.setDate(d.getDate() + pickupDays);
    return d.toISOString().split("T")[0];
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [campaignNo, setCampaignNo] = useState<string>("（產生中…）");

  // fetch preview campaign_no
  useEffect(() => {
    getSupabase().rpc("rpc_next_campaign_no").then(({ data }) => {
      if (data) setCampaignNo(data as string);
    });
  }, []);

  // auto-update pickup_deadline when end_at changes
  function handleEndAtChange(val: string) {
    setEndAt(val);
    if (!val) return;
    const d = new Date(val);
    if (Number.isNaN(d.getTime())) return;
    d.setDate(d.getDate() + pickupDays);
    setPickupDeadline(d.toISOString().split("T")[0]);
  }

  async function handleSave() {
    if (!name.trim()) { setError("請輸入團名稱"); return; }
    if (!endAt) { setError("請設定收單時間"); return; }
    setSaving(true); setError(null);
    try {
      // 1 campaign : 1 product invariant — UI 端已限制 products.length=1
      if (products.length !== 1) {
        throw new Error("一個開團只能對應一個商品");
      }
      const { data, error: err } = await getSupabase().rpc("rpc_create_campaign_from_product", {
        p_name: name.trim(),
        p_end_at: new Date(endAt).toISOString(),
        p_pickup_deadline: pickupDeadline || null,
        p_product_id: products[0].id,
      });
      if (err) throw err;
      onCreated(Number(data));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  const inputCls = "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <div className="space-y-4">
      <div className="rounded-md border border-blue-100 bg-blue-50 px-3 py-2 text-xs text-blue-800 dark:border-blue-900 dark:bg-blue-950 dark:text-blue-200">
        已選 {products.length} 項商品 · {products.map((p) => p.name).join("、")}
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">團號</span>
          <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-sm text-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 select-all">
            {campaignNo}
          </div>
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">收單時間 <span className="text-red-500">*</span></span>
          <input
            type="datetime-local"
            value={endAt}
            onChange={(e) => handleEndAtChange(e.target.value)}
            className={inputCls}
          />
        </label>

        <label className="flex flex-col gap-1 text-sm sm:col-span-2">
          <span className="text-zinc-600 dark:text-zinc-400">團名稱 <span className="text-red-500">*</span></span>
          <input value={name} onChange={(e) => setName(e.target.value)} className={inputCls} />
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">
            取貨截止日
            <span className="ml-1 text-xs text-zinc-400">（依溫層自動計算，可調整）</span>
          </span>
          <input
            type="date"
            value={pickupDeadline}
            onChange={(e) => setPickupDeadline(e.target.value)}
            className={inputCls}
          />
        </label>

        <div className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-500">溫層 → 取貨天數</span>
          <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs text-zinc-500 dark:border-zinc-700 dark:bg-zinc-900">
            {products.map((p) => (
              <div key={p.id}>{p.name}：{p.storage_type ?? "未設定"} (+{PICKUP_DAYS_BY_STORAGE[p.storage_type ?? ""] ?? DEFAULT_PICKUP_DAYS}天)</div>
            ))}
          </div>
        </div>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={handleSave}
          disabled={saving}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          {saving ? "建立中…" : "建立開團"}
        </button>
        <button
          type="button"
          onClick={onClose}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          取消
        </button>
      </div>
    </div>
  );
}

// ============================================================
// Main page (wrapped in Suspense for useSearchParams)
// ============================================================
export default function ProductListPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PageContent />
    </Suspense>
  );
}

function PageContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const campaignMode = searchParams.get("mode") === "campaign";
  const urlEditId = searchParams.get("id");

  const [rows, setRows] = useState<ProductRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  // filters
  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [categoryId, setCategoryId] = useState<string>("");
  const [brandId, setBrandId] = useState<string>("");
  const [status, setStatus] = useState<string>("");

  // sort + page
  const [sortBy, setSortBy] = useState<SortKey>("updated_at");
  const [sortDir, setSortDir] = useState<SortDir>("desc");
  const [page, setPage] = useState(1);

  // lookups
  const [brands, setBrands] = useState<LookupRow[]>([]);
  const [categories, setCategories] = useState<LookupRow[]>([]);

  // multi-select for 開團
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set());
  const [campaignModal, setCampaignModal] = useState<SelectedProduct[] | null>(null);

  // product edit modal
  const [modal, setModal] = useState<
    | { mode: "new" }
    | { mode: "edit"; values: ProductFormValues }
    | null
  >(null);
  const [reloadTick, setReloadTick] = useState(0);
  const newSkuRef = useRef<ProductSkuSectionHandle | null>(null);
  const lastUrlEditId = useRef<string | null>(null);

  async function openEdit(id: number) {
    const { data, error: err } = await getSupabase()
      .from("products")
      .select(
        "id, product_code, name, short_name, brand_id, category_id, description, status, images, " +
          "storage_type, default_supplier_id, " +
          "stop_shipping, is_for_shop, customized_id, customized_text, storage_location, " +
          "user_note, user_note_public, vip_level_min"
      )
      .eq("id", id)
      .maybeSingle();
    if (err || !data) {
      setError(err?.message ?? "找不到此商品");
      return;
    }
    const d = data as unknown as {
      id: number; product_code: string; name: string; short_name: string | null;
      brand_id: number | null; category_id: number | null; description: string | null;
      status: ProductFormValues["status"]; images: string[] | null;
      storage_type: ProductFormValues["storage_type"];
      default_supplier_id: number | null;
      stop_shipping: boolean | null; is_for_shop: boolean | null;
      customized_id: string | null; customized_text: string | null;
      storage_location: string | null; user_note: string | null;
      user_note_public: string | null; vip_level_min: number | null;
    };
    setModal({
      mode: "edit",
      values: {
        id: d.id,
        product_code: d.product_code,
        name: d.name,
        short_name: d.short_name ?? "",
        brand_id: d.brand_id,
        category_id: d.category_id,
        description: d.description ?? "",
        status: d.status,
        images: Array.isArray(d.images) ? d.images : [],
        storage_type: d.storage_type ?? null,
        default_supplier_id: d.default_supplier_id,
        stop_shipping: d.stop_shipping ?? false,
        is_for_shop: d.is_for_shop ?? true,
        customized_id: d.customized_id ?? "",
        customized_text: d.customized_text ?? "",
        storage_location: d.storage_location ?? "",
        user_note: d.user_note ?? "",
        user_note_public: d.user_note_public ?? "",
        vip_level_min: d.vip_level_min ?? 0,
      },
    });
  }

  // open 開團 modal: fetch storage_type for selected product ids
  async function openCampaignModal() {
    const ids = Array.from(selectedIds);
    if (ids.length === 0) return;
    const { data, error: err } = await getSupabase()
      .from("products")
      .select("id, name, storage_type")
      .in("id", ids);
    if (err || !data) { setError(err?.message ?? "載入商品失敗"); return; }
    setCampaignModal(
      (data as { id: number; name: string; storage_type: StorageType }[]).map((p) => ({
        id: p.id,
        name: p.name,
        storage_type: p.storage_type,
      }))
    );
  }

  // 從 URL ?id=X 自動開啟商品編輯 modal（給 CampaignItemsTable 跳轉用）
  useEffect(() => {
    if (!urlEditId) return;
    if (lastUrlEditId.current === urlEditId) return;
    const idNum = Number(urlEditId);
    if (!Number.isFinite(idNum) || idNum <= 0) return;
    lastUrlEditId.current = urlEditId;
    openEdit(idNum);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [urlEditId]);

  // debounce search
  useEffect(() => {
    const t = setTimeout(() => { setQuery(queryDraft); setPage(1); }, 250);
    return () => clearTimeout(t);
  }, [queryDraft]);

  // reset page when filter changes
  useEffect(() => { setPage(1); }, [categoryId, brandId, status, sortBy, sortDir]);

  // fetch lookups once
  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [b, c] = await Promise.all([
        sb.from("brands").select("id, name, code").order("name"),
        sb.from("categories").select("id, name, code").order("level").order("sort_order"),
      ]);
      if (b.data) setBrands(b.data as LookupRow[]);
      if (c.data) setCategories(c.data as LookupRow[]);
    })();
  }, []);

  // fetch rows
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        let q = getSupabase()
          .from("products")
          .select("id, product_code, name, short_name, status, brand_id, category_id, updated_at", {
            count: "exact",
          })
          .order(sortBy, { ascending: sortDir === "asc" })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        if (query.trim()) {
          const safe = query.replace(/[%,()]/g, " ").trim();
          q = q.or(`name.ilike.%${safe}%,product_code.ilike.%${safe}%,short_name.ilike.%${safe}%`);
        }
        if (categoryId) q = q.eq("category_id", Number(categoryId));
        if (brandId) q = q.eq("brand_id", Number(brandId));
        if (status) q = q.eq("status", status);

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) { setError(error.message); return; }
        setError(null);
        setRows((data ?? []) as ProductRow[]);
        setTotal(count ?? 0);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [query, categoryId, brandId, status, sortBy, sortDir, page, reloadTick]);

  const brandMap = useMemo(() => new Map(brands.map((b) => [b.id, b])), [brands]);
  const categoryMap = useMemo(() => new Map(categories.map((c) => [c.id, c])), [categories]);

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  function toggleSort(key: SortKey) {
    if (sortBy === key) {
      setSortDir((d) => (d === "asc" ? "desc" : "asc"));
    } else {
      setSortBy(key);
      setSortDir(key === "updated_at" ? "desc" : "asc");
    }
  }

  function toggleSelect(id: number) {
    setSelectedIds((prev) => {
      // 1 campaign : 1 product invariant — campaign mode 改成單選
      if (campaignMode) {
        return prev.has(id) ? new Set() : new Set([id]);
      }
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  function toggleAll() {
    if (!rows) return;
    const allOnPage = rows.map((r) => r.id);
    const allSelected = allOnPage.every((id) => selectedIds.has(id));
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (allSelected) { allOnPage.forEach((id) => next.delete(id)); }
      else { allOnPage.forEach((id) => next.add(id)); }
      return next;
    });
  }

  const allOnPageSelected = !!rows && rows.length > 0 && rows.every((r) => selectedIds.has(r.id));
  const someOnPageSelected = !!rows && rows.some((r) => selectedIds.has(r.id));

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">商品</h1>
          <p className="text-sm text-zinc-500">
            {loading
              ? "載入中…"
              : total === 0
                ? "共 0 筆"
                : `共 ${total} 筆（顯示 ${fromIdx}-${toIdx}）`}
          </p>
        </div>
        <button
          onClick={() => setModal({ mode: "new" })}
          className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          新增商品
        </button>
      </header>

      {/* 開團模式提示 */}
      {campaignMode && (
        <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">
          勾選商品後按「開團」即可建立團購活動
        </div>
      )}

      {/* 多選工具列 */}
      {selectedIds.size > 0 && (
        <div className="flex items-center gap-3 rounded-md border border-zinc-300 bg-white px-4 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900">
          <span className="text-zinc-600 dark:text-zinc-400">已選 <span className="font-semibold">{selectedIds.size}</span> 項商品</span>
          <button
            onClick={openCampaignModal}
            className="rounded-md bg-green-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-green-600"
          >
            開團
          </button>
          <button
            onClick={() => setSelectedIds(new Set())}
            className="ml-auto text-xs text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
          >
            清除選取
          </button>
        </div>
      )}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <input
          type="search"
          placeholder="搜尋 編號 / 名稱 / 簡稱"
          value={queryDraft}
          onChange={(e) => setQueryDraft(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
        <select
          value={categoryId}
          onChange={(e) => setCategoryId(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部分類</option>
          {categories.map((c) => (
            <option key={c.id} value={c.id}>{c.name} ({c.code})</option>
          ))}
        </select>
        <select
          value={brandId}
          onChange={(e) => setBrandId(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部品牌</option>
          {brands.map((b) => (
            <option key={b.id} value={b.id}>{b.name} ({b.code})</option>
          ))}
        </select>
        <select
          value={status}
          onChange={(e) => setStatus(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部狀態</option>
          <option value="draft">草稿</option>
          <option value="active">上架</option>
          <option value="inactive">下架</option>
          <option value="discontinued">停產</option>
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <th className="w-10 px-3 py-2">
                <input
                  type="checkbox"
                  checked={allOnPageSelected}
                  ref={(el) => { if (el) el.indeterminate = !allOnPageSelected && someOnPageSelected; }}
                  onChange={toggleAll}
                  className="cursor-pointer"
                />
              </th>
              <ThSort label="商品編號" col="product_code" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} />
              <ThSort label="名稱" col="name" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} />
              <Th>品牌 / 分類</Th>
              <ThSort label="狀態" col="status" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} />
              <ThSort label="更新時間" col="updated_at" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} align="right" />
              <Th>{""}</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <SkeletonRows />
            ) : rows.length === 0 ? (
              <tr>
                <td colSpan={7} className="p-6 text-center text-sm text-zinc-500">
                  {total === 0 && !query && !categoryId && !brandId && !status
                    ? "還沒有商品，按「新增商品」開始建立。"
                    : "沒有符合條件的商品。"}
                </td>
              </tr>
            ) : (
              rows.map((r) => (
                <tr
                  key={r.id}
                  className={`hover:bg-zinc-50 dark:hover:bg-zinc-900 ${selectedIds.has(r.id) ? "bg-blue-50 dark:bg-blue-950/30" : ""}`}
                >
                  <td className="w-10 px-3 py-3">
                    <input
                      type="checkbox"
                      checked={selectedIds.has(r.id)}
                      onChange={() => toggleSelect(r.id)}
                      className="cursor-pointer"
                    />
                  </td>
                  <Td className="font-mono">
                    <button onClick={() => openEdit(r.id)} className="hover:underline">
                      {r.product_code}
                    </button>
                  </Td>
                  <Td>
                    <div>{r.name}</div>
                    {r.short_name && <div className="text-xs text-zinc-500">{r.short_name}</div>}
                  </Td>
                  <Td className="text-xs text-zinc-600 dark:text-zinc-400">
                    {r.brand_id ? brandMap.get(r.brand_id)?.name ?? "—" : "—"}
                    {r.category_id ? ` / ${categoryMap.get(r.category_id)?.name ?? "—"}` : ""}
                  </Td>
                  <Td>
                    <StatusBadge status={r.status} />
                  </Td>
                  <Td className="text-right text-zinc-500">
                    {new Date(r.updated_at).toLocaleString("zh-TW")}
                  </Td>
                  <Td>
                    <button
                      onClick={() => openEdit(r.id)}
                      className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                    >
                      編輯
                    </button>
                  </Td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn onClick={() => setPage(1)} disabled={page === 1}>« 第一頁</PagerBtn>
          <PagerBtn onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={page === 1}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn onClick={() => setPage((p) => Math.min(totalPages, p + 1))} disabled={page === totalPages}>下頁 ›</PagerBtn>
          <PagerBtn onClick={() => setPage(totalPages)} disabled={page === totalPages}>最末頁 »</PagerBtn>
        </div>
      )}

      {/* Product Edit Modal */}
      <Modal
        open={!!modal}
        onClose={() => setModal(null)}
        title={modal?.mode === "edit" ? `編輯商品 ${modal.values.product_code}` : "新增商品"}
        maxWidth="max-w-4xl"
      >
        {modal?.mode === "new" && (
          <ProductForm
            onSaved={async (id) => {
              try {
                await newSkuRef.current?.flush(id);
              } catch (e) {
                setError(e instanceof Error ? e.message : String(e));
              }
              setReloadTick((t) => t + 1);
              await openEdit(id);
            }}
            onCancel={() => setModal(null)}
            midSlot={<ProductSkuSection ref={newSkuRef} productId={null} />}
          />
        )}
        {modal?.mode === "edit" && (
          <ProductForm
            initial={modal.values}
            onSaved={() => { setModal(null); setReloadTick((t) => t + 1); }}
            onCancel={() => setModal(null)}
            midSlot={
              modal.values.id !== null ? (
                <ProductSkuSection productId={modal.values.id} />
              ) : null
            }
          />
        )}
      </Modal>

      {/* 開團 Modal */}
      <Modal
        open={!!campaignModal}
        onClose={() => setCampaignModal(null)}
        title="建立開團"
        maxWidth="max-w-2xl"
      >
        {campaignModal && (
          <CreateCampaignModal
            products={campaignModal}
            onClose={() => setCampaignModal(null)}
            onCreated={(campaignId) => {
              setCampaignModal(null);
              setSelectedIds(new Set());
              router.push(`/campaigns`);
            }}
          />
        )}
      </Modal>
    </div>
  );
}

function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className="rounded-md border border-zinc-300 px-2 py-1 hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800 dark:disabled:hover:bg-transparent"
    >
      {children}
    </button>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return (
    <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>
      {children}
    </th>
  );
}

function ThSort({
  label, col, sortBy, sortDir, onToggle, align = "left",
}: {
  label: string; col: SortKey; sortBy: SortKey; sortDir: SortDir;
  onToggle: (c: SortKey) => void; align?: "left" | "right";
}) {
  const active = sortBy === col;
  const arrow = active ? (sortDir === "asc" ? "↑" : "↓") : "";
  return (
    <th
      onClick={() => onToggle(col)}
      className={`cursor-pointer px-4 py-2 text-xs font-medium uppercase tracking-wide text-zinc-500 select-none hover:text-zinc-900 dark:hover:text-zinc-100 ${align === "right" ? "text-right" : "text-left"}`}
    >
      {label} <span className="text-zinc-400">{arrow}</span>
    </th>
  );
}

function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}

function StatusBadge({ status }: { status: Status }) {
  const styles: Record<Status, string> = {
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

function SkeletonRows() {
  return (
    <>
      {Array.from({ length: 5 }).map((_, i) => (
        <tr key={i}>
          <td colSpan={7} className="p-3">
            <div className="h-4 animate-pulse rounded bg-zinc-100 dark:bg-zinc-800" />
          </td>
        </tr>
      ))}
    </>
  );
}

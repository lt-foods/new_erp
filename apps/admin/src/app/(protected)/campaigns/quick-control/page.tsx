"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { CampaignThumb } from "@/components/CampaignThumb";
import {
  campaignCoverUrl,
  publicProductUrl,
  type CampaignCoverItem,
} from "@/lib/campaignCover";
import { useRole, isAdmin, type Role } from "@/lib/role";

type QuickStatus = "draft" | "open" | "closed" | "locked";
type CloseType = "regular" | "fast" | "limited" | "food_train";
type CreateCloseType = "fast" | "limited" | "food_train";
type StorageType = "room_temp" | "refrigerated" | "frozen" | "meal_train" | null;

type CampaignRow = {
  id: number;
  campaign_no: string;
  name: string;
  status: QuickStatus;
  close_type: CloseType;
  end_at: string | null;
  total_cap_qty: number | null;
  updated_at: string;
  cover_image_url: string | null;
  campaign_items: (CampaignCoverItem & { cap_qty?: number | string | null })[] | null;
};

type OrderRow = {
  campaign_id: number;
  status: string;
  order_kind: string | null;
  customer_order_items?: { qty: number | string; status: string }[];
};

type ProductRow = {
  id: number;
  product_code: string;
  name: string;
  short_name: string | null;
  description: string | null;
  storage_type: StorageType;
  images: unknown;
};

type SkuRow = {
  id: number;
  sku_code: string;
  product_name: string | null;
  variant_name: string | null;
  status: string;
};

type PriceRow = {
  sku_id: number;
  price: number | string;
  effective_from: string;
};

const MEMBER_APP_URL = (process.env.NEXT_PUBLIC_MEMBER_APP_URL ?? "https://new-erp-admin.vercel.app").replace(/\/$/, "");
const QUICK_CREATE_ENABLED = false;

const STATUS_LABEL: Record<QuickStatus, string> = {
  draft: "草稿",
  open: "開團中",
  closed: "已關團",
  locked: "已鎖定",
};

const TYPE_LABEL: Record<CloseType, string> = {
  regular: "一般",
  fast: "限時",
  limited: "限量",
  food_train: "美食列車",
};

const CREATE_TYPES: { value: CreateCloseType; label: string; hint: string }[] = [
  { value: "fast", label: "限時", hint: "到時間收單" },
  { value: "limited", label: "限量", hint: "賣完就停" },
  { value: "food_train", label: "美食列車", hint: "美食列車專區" },
];

const PICKUP_DAYS_BY_STORAGE: Record<string, number> = {
  frozen: 14,
  refrigerated: 14,
  room_temp: 30,
  meal_train: 7,
};
const DEFAULT_PICKUP_DAYS = 21;

function canQuickControl(role: Role | null) {
  return isAdmin(role) || role === "hq_manager" || role === "assistant";
}

function toLocalInput(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function fromLocalInput(v: string): string | null {
  return v ? new Date(v).toISOString() : null;
}

function futureIsoFromLocalInput(v: string): string | null {
  const iso = fromLocalInput(v);
  if (!iso) return null;
  const time = new Date(iso).getTime();
  return Number.isFinite(time) && time > Date.now() ? iso : null;
}

function defaultEndAt(): string {
  const d = new Date();
  d.setHours(d.getHours() + 24, 0, 0, 0);
  return toLocalInput(d.toISOString());
}

function defaultCreateEndAt(): string {
  const d = new Date();
  d.setDate(d.getDate() + 3);
  d.setHours(23, 59, 0, 0);
  return toLocalInput(d.toISOString());
}

function pickupDaysForStorage(storageType: StorageType): number {
  return PICKUP_DAYS_BY_STORAGE[storageType ?? ""] ?? DEFAULT_PICKUP_DAYS;
}

function pickupDeadlineFrom(endAt: string, storageType: StorageType): string {
  const d = endAt ? new Date(endAt) : new Date();
  if (Number.isNaN(d.getTime())) return "";
  d.setDate(d.getDate() + pickupDaysForStorage(storageType));
  return d.toISOString().split("T")[0] ?? "";
}

function editableEndAt(iso: string | null): string {
  if (iso && new Date(iso).getTime() > Date.now()) return toLocalInput(iso);
  return defaultEndAt();
}

function formatDateTime(iso: string | null): string {
  if (!iso) return "未設定";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "未設定";
  return new Intl.DateTimeFormat("zh-TW", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(d);
}

function statusClass(status: QuickStatus): string {
  if (status === "open") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (status === "closed") return "bg-amber-50 text-amber-700 ring-amber-200";
  if (status === "locked") return "bg-rose-50 text-rose-700 ring-rose-200";
  return "bg-zinc-100 text-zinc-700 ring-zinc-200";
}

function itemCapSummary(items: CampaignRow["campaign_items"]) {
  const caps = (items ?? [])
    .map((item) => Number(item.cap_qty ?? 0))
    .filter((cap) => Number.isFinite(cap) && cap > 0);
  if (caps.length === 0) return null;
  return {
    count: caps.length,
    total: caps.reduce((sum, cap) => sum + cap, 0),
    min: Math.min(...caps),
    max: Math.max(...caps),
  };
}

function productImageUrl(images: unknown): string | null {
  if (!Array.isArray(images) || images.length === 0) return null;
  const first = images[0] as unknown;
  const path = typeof first === "string" ? first : (first as { url?: string | null })?.url ?? null;
  return publicProductUrl(path);
}

function skuLabel(sku: SkuRow): string {
  return sku.variant_name?.trim() || sku.product_name?.trim() || sku.sku_code;
}

export default function QuickCampaignControlPage() {
  const role = useRole();
  const allowed = canQuickControl(role);
  const [rows, setRows] = useState<CampaignRow[]>([]);
  const [soldMap, setSoldMap] = useState<Map<number, number>>(new Map());
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [endAtDraft, setEndAtDraft] = useState<Record<number, string>>({});
  const [deltaDraft, setDeltaDraft] = useState<Record<number, string>>({});

  const [createOpen, setCreateOpen] = useState(false);
  const [productQuery, setProductQuery] = useState("");
  const [productRows, setProductRows] = useState<ProductRow[]>([]);
  const [productSearching, setProductSearching] = useState(false);
  const [selectedProduct, setSelectedProduct] = useState<ProductRow | null>(null);
  const [skus, setSkus] = useState<SkuRow[]>([]);
  const [skuLoading, setSkuLoading] = useState(false);
  const [priceMap, setPriceMap] = useState<Record<number, number>>({});
  const [createType, setCreateType] = useState<CreateCloseType>("fast");
  const [createName, setCreateName] = useState("");
  const [createEndAt, setCreateEndAt] = useState(defaultCreateEndAt);
  const [pickupDeadline, setPickupDeadline] = useState(() => pickupDeadlineFrom(defaultCreateEndAt(), null));
  const [totalCapDraft, setTotalCapDraft] = useState("");
  const [itemCapDraft, setItemCapDraft] = useState<Record<number, string>>({});
  const [createBusy, setCreateBusy] = useState(false);
  const [createdUrl, setCreatedUrl] = useState<string | null>(null);
  const [createdCampaignId, setCreatedCampaignId] = useState<number | null>(null);

  const visibleRows = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) =>
      `${r.campaign_no} ${r.name} ${TYPE_LABEL[r.close_type]}`.toLowerCase().includes(q),
    );
  }, [query, rows]);

  const missingPrice = skus.some((sku) => priceMap[sku.id] == null);
  const totalCap = Number(totalCapDraft);
  const itemCaps = useMemo(
    () =>
      Object.entries(itemCapDraft)
        .map(([skuId, cap]) => ({ sku_id: Number(skuId), cap_qty: Number(cap) }))
        .filter((item) => Number.isFinite(item.sku_id) && Number.isFinite(item.cap_qty) && item.cap_qty > 0),
    [itemCapDraft],
  );
  const createNeedsCap =
    createType === "limited" && !(Number.isFinite(totalCap) && totalCap > 0) && itemCaps.length === 0;

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data, error: campaignErr } = await sb
        .from("group_buy_campaigns")
        .select("id, campaign_no, name, status, close_type, end_at, total_cap_qty, updated_at, cover_image_url, campaign_items(cap_qty, sort_order, sku:skus(product:products(images)))")
        .in("status", ["draft", "open", "closed", "locked"])
        .order("updated_at", { ascending: false })
        .limit(160);

      if (campaignErr) throw campaignErr;
      const campaigns = ((data ?? []) as unknown as CampaignRow[])
        .filter((r) =>
          r.close_type === "food_train"
          || r.close_type === "fast"
          || r.close_type === "limited"
          || Number(r.total_cap_qty ?? 0) > 0
          || (r.campaign_items ?? []).some((item) => Number(item.cap_qty ?? 0) > 0)
        )
        .slice(0, 80);
      const ids = campaigns.map((r) => r.id);
      const nextSold = new Map<number, number>();

      if (ids.length > 0) {
        const { data: orderRows, error: orderErr } = await sb
          .from("customer_orders")
          .select("campaign_id, status, order_kind, customer_order_items(qty, status)")
          .in("campaign_id", ids);
        if (orderErr) throw orderErr;

        for (const order of ((orderRows ?? []) as OrderRow[])) {
          if (["cancelled", "expired", "transferred_out"].includes(order.status)) continue;
          if ((order.order_kind ?? "normal") !== "normal") continue;
          const qty = (order.customer_order_items ?? [])
            .filter((item) => !["cancelled", "expired"].includes(item.status))
            .reduce((sum, item) => sum + Number(item.qty ?? 0), 0);
          nextSold.set(order.campaign_id, (nextSold.get(order.campaign_id) ?? 0) + qty);
        }
      }

      setRows(campaigns);
      setSoldMap(nextSold);
      setEndAtDraft(Object.fromEntries(campaigns.map((r) => [r.id, editableEndAt(r.end_at)])));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => { void load(); }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  useEffect(() => {
    if (!createOpen) return;
    const q = productQuery.trim();
    if (!q || selectedProduct?.name === q || selectedProduct?.product_code === q) {
      return;
    }

    let alive = true;
    const timer = window.setTimeout(async () => {
      setProductSearching(true);
      try {
        const term = q.replace(/[^\p{L}\p{N}\s_-]/gu, " ").trim();
        if (!term) {
          setProductRows([]);
          return;
        }
        const { data, error: productErr } = await getSupabase()
          .from("products")
          .select("id, product_code, name, short_name, description, storage_type, images")
          .eq("status", "active")
          .eq("is_for_shop", true)
          .or(`product_code.ilike.%${term}%,name.ilike.%${term}%,short_name.ilike.%${term}%`)
          .order("updated_at", { ascending: false })
          .limit(20);
        if (productErr) throw productErr;
        if (alive) setProductRows((data ?? []) as unknown as ProductRow[]);
      } catch (e) {
        if (alive) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (alive) setProductSearching(false);
      }
    }, 250);

    return () => {
      alive = false;
      window.clearTimeout(timer);
    };
  }, [createOpen, productQuery, selectedProduct]);

  async function quickUpdate(
    row: CampaignRow,
    patch: { status?: "open"; endAt?: string | null; delta?: number | null },
    successText: string,
  ) {
    if (!allowed || busyId) return;
    setBusyId(row.id);
    setError(null);
    setNotice(null);
    try {
      const { data, error: rpcErr } = await getSupabase().rpc("rpc_quick_update_campaign_control", {
        p_campaign_id: row.id,
        p_status: patch.status ?? null,
        p_end_at: patch.endAt ?? null,
        p_total_cap_qty_delta: patch.delta ?? null,
      });
      if (rpcErr) throw rpcErr;
      const updated = Array.isArray(data) ? data[0] : data;
      setRows((cur) =>
        cur.map((r) =>
          r.id === row.id
            ? {
                ...r,
                status: (updated?.status ?? r.status) as QuickStatus,
                end_at: updated?.end_at ?? r.end_at,
                total_cap_qty:
                  updated?.total_cap_qty != null ? Number(updated.total_cap_qty) : r.total_cap_qty,
              }
            : r,
        ),
      );
      if (updated?.sold_qty != null) {
        setSoldMap((cur) => new Map(cur).set(row.id, Number(updated.sold_qty)));
      }
      setDeltaDraft((cur) => ({ ...cur, [row.id]: "" }));
      setNotice(successText);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyId(null);
    }
  }

  async function closeCampaign(row: CampaignRow) {
    if (!allowed || busyId) return;
    if (!confirm(`確定立即關團「${row.name}」？\n關團後客人將不能再下單。`)) return;
    setBusyId(row.id);
    setError(null);
    setNotice(null);
    try {
      const sb = getSupabase();
      const { data: userData } = await sb.auth.getUser();
      const { error: rpcErr } = await sb.rpc("rpc_close_campaign", {
        p_campaign_id: row.id,
        p_operator: userData.user?.id ?? null,
      });
      if (rpcErr) throw rpcErr;
      setRows((cur) => cur.map((r) => (r.id === row.id ? { ...r, status: "closed" } : r)));
      setNotice(`${row.name} 已關團`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyId(null);
    }
  }

  function setEndAt(row: CampaignRow, hours: number) {
    const base = row.end_at && new Date(row.end_at).getTime() > new Date().getTime()
      ? new Date(row.end_at)
      : new Date();
    base.setHours(base.getHours() + hours, 0, 0, 0);
    const local = toLocalInput(base.toISOString());
    setEndAtDraft((cur) => ({ ...cur, [row.id]: local }));
    return fromLocalInput(local);
  }

  async function selectProduct(product: ProductRow) {
    setSelectedProduct(product);
    setProductQuery(product.name);
    setProductRows([]);
    setCreateName(product.name);
    const endAt = defaultCreateEndAt();
    setCreateEndAt(endAt);
    setPickupDeadline(pickupDeadlineFrom(endAt, product.storage_type));
    setTotalCapDraft("");
    setItemCapDraft({});
    setCreatedUrl(null);
    setCreatedCampaignId(null);
    setSkuLoading(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: skuData, error: skuErr } = await sb
        .from("skus")
        .select("id, sku_code, product_name, variant_name, status")
        .eq("product_id", product.id)
        .eq("status", "active")
        .order("sku_code", { ascending: true });
      if (skuErr) throw skuErr;
      const nextSkus = (skuData ?? []) as unknown as SkuRow[];
      setSkus(nextSkus);

      if (nextSkus.length === 0) {
        setPriceMap({});
        return;
      }

      const { data: priceData, error: priceErr } = await sb
        .from("prices")
        .select("sku_id, price, effective_from")
        .in("sku_id", nextSkus.map((sku) => sku.id))
        .eq("scope", "retail")
        .lte("effective_from", new Date().toISOString())
        .or(`effective_to.is.null,effective_to.gt.${new Date().toISOString()}`)
        .order("effective_from", { ascending: false });
      if (priceErr) throw priceErr;

      const nextPrices: Record<number, number> = {};
      for (const price of (priceData ?? []) as unknown as PriceRow[]) {
        const value = Number(price.price);
        if (nextPrices[price.sku_id] == null && Number.isFinite(value) && value > 0) {
          nextPrices[price.sku_id] = value;
        }
      }
      setPriceMap(nextPrices);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSkuLoading(false);
    }
  }

  function updateCreateEndAt(value: string) {
    setCreateEndAt(value);
    setPickupDeadline(pickupDeadlineFrom(value, selectedProduct?.storage_type ?? null));
  }

  async function copyCreatedUrl(url: string) {
    try {
      await navigator.clipboard.writeText(url);
      setNotice("已複製客人網址");
    } catch {
      setNotice("網址已產生，請長按網址複製");
    }
  }

  async function createCampaign() {
    if (!allowed || createBusy) return;
    if (!selectedProduct) { setError("請先選商品"); return; }
    if (!createName.trim()) { setError("請輸入團名稱"); return; }
    const endIso = fromLocalInput(createEndAt);
    if (!endIso || new Date(endIso).getTime() <= Date.now()) {
      setError("收單時間必須在未來");
      return;
    }
    if (skus.length === 0) { setError("這個商品沒有 active 規格"); return; }
    if (missingPrice) { setError("有規格缺少現行零售價，請先補售價"); return; }
    if (createNeedsCap) { setError("限量團請填總限量，或至少填一個規格限量"); return; }

    setCreateBusy(true);
    setError(null);
    setNotice(null);
    try {
      const { data, error: rpcErr } = await getSupabase().rpc("rpc_quick_create_campaign_from_product", {
        p_product_id: selectedProduct.id,
        p_name: createName.trim(),
        p_close_type: createType,
        p_end_at: endIso,
        p_description: selectedProduct.description ?? null,
        p_pickup_deadline: pickupDeadline || null,
        p_total_cap_qty: Number.isFinite(totalCap) && totalCap > 0 ? totalCap : null,
        p_item_caps: itemCaps,
      });
      if (rpcErr) throw rpcErr;

      const created = Array.isArray(data) ? data[0] : data;
      const campaignId = Number(created?.campaign_id);
      if (!Number.isFinite(campaignId)) throw new Error("建立成功但沒有拿到團 ID");

      const url = `${MEMBER_APP_URL}/shop/c/${campaignId}`;
      setCreatedCampaignId(campaignId);
      setCreatedUrl(url);
      setNotice(`已建立「${createName.trim()}」，客人網址已產生`);
      try {
        await navigator.clipboard.writeText(url);
        setNotice(`已建立「${createName.trim()}」，客人網址已複製`);
      } catch {
        setNotice(`已建立「${createName.trim()}」，請長按網址複製`);
      }

      setSelectedProduct(null);
      setProductQuery("");
      setProductRows([]);
      setSkus([]);
      setPriceMap({});
      setCreateName("");
      setTotalCapDraft("");
      setItemCapDraft({});
      void load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCreateBusy(false);
    }
  }

  return (
    <div className="min-h-full bg-zinc-50 px-3 py-4 dark:bg-zinc-950 sm:px-6">
      <div className="mx-auto flex max-w-3xl flex-col gap-4">
        <header className="flex flex-col gap-3 rounded-md border border-zinc-200 bg-white p-4 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex items-start justify-between gap-3">
            <div>
              <p className="text-xs font-medium text-zinc-500">手機快速開團 / 團控</p>
              <h1 className="text-xl font-semibold text-zinc-950 dark:text-zinc-50">
                美食列車 / 限時 / 限量
              </h1>
            </div>
            <Link
              href="/campaigns"
              className="shrink-0 rounded-md border border-zinc-300 px-3 py-2 text-sm text-zinc-700 dark:border-zinc-700 dark:text-zinc-200"
            >
              回後台
            </Link>
          </div>
          <div className="grid gap-2 sm:grid-cols-[auto_1fr_auto]">
            <SpinButton
              type="button"
              disabled={!allowed || !QUICK_CREATE_ENABLED}
              onClick={() => {
                setCreateOpen((v) => !v);
                setError(null);
                setNotice(null);
              }}
              title={QUICK_CREATE_ENABLED ? undefined : "正取/候補流程對齊中，暫停手機開新團"}
              className="min-h-11 rounded-md bg-pink-600 px-4 text-sm font-semibold text-white disabled:opacity-50"
            >
              {QUICK_CREATE_ENABLED ? (createOpen ? "收起開新團" : "+ 開新團") : "開新團開發中"}
            </SpinButton>
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="搜尋既有團"
              className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-zinc-900 dark:border-zinc-700 dark:bg-zinc-950"
            />
            <SpinButton
              type="button"
              onClick={load}
              loading={loading}
              className="min-h-11 rounded-md bg-zinc-900 px-4 text-sm font-medium text-white dark:bg-zinc-100 dark:text-zinc-950"
            >
              重新整理
            </SpinButton>
          </div>
        </header>

        {QUICK_CREATE_ENABLED && createOpen && (
          <section className="rounded-md border border-pink-200 bg-white p-4 shadow-sm dark:border-pink-900 dark:bg-zinc-900">
            <div className="mb-4 flex items-center justify-between gap-3">
              <div>
                <h2 className="text-lg font-semibold text-zinc-950 dark:text-zinc-50">開新團</h2>
                <p className="text-sm text-zinc-500">選一個商品，系統會帶入所有 active 規格。</p>
              </div>
              <span className="rounded-full bg-pink-50 px-3 py-1 text-xs font-medium text-pink-700 ring-1 ring-pink-200 dark:bg-pink-950 dark:text-pink-200 dark:ring-pink-900">
                手機用
              </span>
            </div>

            {createdUrl && (
              <div className="mb-4 grid gap-2 rounded-md border border-emerald-200 bg-emerald-50 p-3 dark:border-emerald-900 dark:bg-emerald-950">
                <div className="text-sm font-semibold text-emerald-800 dark:text-emerald-200">客人網址</div>
                <input
                  readOnly
                  value={createdUrl}
                  className="min-h-11 rounded-md border border-emerald-200 bg-white px-3 text-sm text-emerald-900 dark:border-emerald-900 dark:bg-zinc-950 dark:text-emerald-100"
                />
                <div className="grid grid-cols-2 gap-2">
                  <SpinButton
                    type="button"
                    onClick={() => copyCreatedUrl(createdUrl)}
                    className="min-h-11 rounded-md bg-emerald-600 text-sm font-semibold text-white"
                  >
                    複製網址
                  </SpinButton>
                  {createdCampaignId ? (
                    <Link
                      href={`/campaigns/order-entry?id=${createdCampaignId}`}
                      className="flex min-h-11 items-center justify-center rounded-md border border-emerald-300 text-sm font-semibold text-emerald-800 dark:border-emerald-800 dark:text-emerald-100"
                    >
                      查看此團
                    </Link>
                  ) : null}
                </div>
              </div>
            )}

            <div className="grid gap-3">
              <label className="grid gap-1 text-sm">
                <span className="font-medium text-zinc-700 dark:text-zinc-200">搜尋商品</span>
                <input
                  value={productQuery}
                  onChange={(e) => {
                    setProductQuery(e.target.value);
                    setSelectedProduct(null);
                    setSkus([]);
                    setPriceMap({});
                    setProductRows([]);
                    setProductSearching(false);
                  }}
                  placeholder="輸入商品名稱或商品代碼"
                  disabled={!allowed || createBusy}
                  className="min-h-12 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-pink-600 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                />
              </label>

              {productSearching && (
                <div className="rounded-md border border-zinc-200 p-3 text-sm text-zinc-500 dark:border-zinc-800">
                  搜尋商品中...
                </div>
              )}

              {productRows.length > 0 && (
                <div className="divide-y divide-zinc-200 overflow-hidden rounded-md border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
                  {productRows.map((product) => (
                    <button
                      key={product.id}
                      type="button"
                      onClick={() => selectProduct(product)}
                      className="flex w-full items-center gap-3 bg-white p-3 text-left hover:bg-pink-50 focus:bg-pink-50 focus:outline-none dark:bg-zinc-900 dark:hover:bg-zinc-800 dark:focus:bg-zinc-800"
                    >
                      {productImageUrl(product.images) ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img
                          src={productImageUrl(product.images) ?? ""}
                          alt={product.name}
                          className="h-14 w-14 rounded-md border border-zinc-200 object-cover dark:border-zinc-800"
                        />
                      ) : (
                        <div className="h-14 w-14 rounded-md border border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-950" />
                      )}
                      <div className="min-w-0">
                        <div className="break-words text-sm font-semibold text-zinc-950 dark:text-zinc-50">
                          {product.name}
                        </div>
                        <div className="mt-1 text-xs text-zinc-500">{product.product_code}</div>
                      </div>
                    </button>
                  ))}
                </div>
              )}

              {selectedProduct && (
                <div className="grid gap-3 border-y border-zinc-200 py-3 dark:border-zinc-800">
                  <div className="flex items-center gap-3">
                    {productImageUrl(selectedProduct.images) ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img
                        src={productImageUrl(selectedProduct.images) ?? ""}
                        alt={selectedProduct.name}
                        className="h-16 w-16 rounded-md border border-zinc-200 object-cover dark:border-zinc-800"
                      />
                    ) : (
                      <div className="h-16 w-16 rounded-md border border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-950" />
                    )}
                    <div className="min-w-0">
                      <div className="break-words font-semibold text-zinc-950 dark:text-zinc-50">
                        {selectedProduct.name}
                      </div>
                      <div className="mt-1 text-sm text-zinc-500">
                        {skuLoading ? "讀取規格中..." : `${skus.length} 個規格`} / 取貨期限 +{pickupDaysForStorage(selectedProduct.storage_type)} 天
                      </div>
                    </div>
                  </div>

                  <label className="grid gap-1 text-sm">
                    <span className="font-medium text-zinc-700 dark:text-zinc-200">團名稱</span>
                    <input
                      value={createName}
                      onChange={(e) => setCreateName(e.target.value)}
                      disabled={!allowed || createBusy}
                      className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-pink-600 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                    />
                  </label>

                  <div className="grid grid-cols-3 gap-2">
                    {CREATE_TYPES.map((type) => (
                      <button
                        key={type.value}
                        type="button"
                        aria-pressed={createType === type.value}
                        onClick={() => setCreateType(type.value)}
                        disabled={!allowed || createBusy}
                        className={`min-h-14 rounded-md border px-2 text-center disabled:opacity-50 ${
                          createType === type.value
                            ? "border-pink-600 bg-pink-600 text-white"
                            : "border-zinc-300 text-zinc-700 dark:border-zinc-700 dark:text-zinc-200"
                        }`}
                      >
                        <span className="block text-sm font-semibold">{type.label}</span>
                        <span className="block text-xs opacity-80">{type.hint}</span>
                      </button>
                    ))}
                  </div>

                  <div className="grid gap-3 sm:grid-cols-2">
                    <label className="grid gap-1 text-sm">
                      <span className="font-medium text-zinc-700 dark:text-zinc-200">收單時間</span>
                      <input
                        type="datetime-local"
                        value={createEndAt}
                        onChange={(e) => updateCreateEndAt(e.target.value)}
                        disabled={!allowed || createBusy}
                        className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-pink-600 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                      />
                    </label>
                    <label className="grid gap-1 text-sm">
                      <span className="font-medium text-zinc-700 dark:text-zinc-200">取貨期限</span>
                      <input
                        type="date"
                        value={pickupDeadline}
                        onChange={(e) => setPickupDeadline(e.target.value)}
                        disabled={!allowed || createBusy}
                        className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-pink-600 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                      />
                    </label>
                  </div>

                  <label className="grid gap-1 text-sm">
                    <span className="font-medium text-zinc-700 dark:text-zinc-200">總限量</span>
                    <input
                      type="number"
                      min="1"
                      step="1"
                      value={totalCapDraft}
                      onChange={(e) => setTotalCapDraft(e.target.value)}
                      placeholder={createType === "limited" ? "限量團建議填寫" : "可不填"}
                      disabled={!allowed || createBusy}
                      className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-pink-600 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                    />
                  </label>

                  <div className="grid gap-2">
                    <div className="text-sm font-medium text-zinc-700 dark:text-zinc-200">規格限量</div>
                    {skuLoading ? (
                      <div className="rounded-md border border-zinc-200 p-3 text-sm text-zinc-500 dark:border-zinc-800">
                        讀取規格中...
                      </div>
                    ) : skus.length === 0 ? (
                      <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
                        找不到 active 規格，不能開團。
                      </div>
                    ) : (
                      <div className="divide-y divide-zinc-200 overflow-hidden rounded-md border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
                        {skus.map((sku) => (
                          <div key={sku.id} className="grid grid-cols-[1fr_6rem] items-center gap-2 p-3">
                            <div className="min-w-0">
                              <div className="break-words text-sm font-medium text-zinc-950 dark:text-zinc-50">
                                {skuLabel(sku)}
                              </div>
                              <div className={`mt-1 text-xs ${priceMap[sku.id] == null ? "text-red-600" : "text-zinc-500"}`}>
                                {priceMap[sku.id] == null ? "缺現行售價" : `售價 ${priceMap[sku.id]}`}
                              </div>
                            </div>
                            <input
                              type="number"
                              min="1"
                              step="1"
                              value={itemCapDraft[sku.id] ?? ""}
                              onChange={(e) => setItemCapDraft((cur) => ({ ...cur, [sku.id]: e.target.value }))}
                              placeholder="不填"
                              disabled={!allowed || createBusy}
                              className="min-h-10 rounded-md border border-zinc-300 bg-white px-2 text-base outline-none focus:border-pink-600 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                            />
                          </div>
                        ))}
                      </div>
                    )}
                  </div>

                  {missingPrice && (
                    <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
                      有規格缺現行零售價，先到商品售價補好再開團。
                    </div>
                  )}
                  {createNeedsCap && (
                    <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
                      限量團請填總限量，或至少填一個規格限量。
                    </div>
                  )}

                  <SpinButton
                    type="button"
                    onClick={createCampaign}
                    loading={createBusy}
                    disabled={!allowed || skuLoading || missingPrice || createNeedsCap || !selectedProduct}
                    className="min-h-12 rounded-md bg-pink-600 text-base font-semibold text-white disabled:opacity-50"
                  >
                    建立開團並產生網址
                  </SpinButton>
                </div>
              )}
            </div>
          </section>
        )}

        {!allowed && role !== null && (
          <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
            你目前沒有手機團控權限，請用總部或助理帳號操作。
          </div>
        )}

        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
            {error}
          </div>
        )}

        {notice && (
          <div className="rounded-md border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-700 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200">
            {notice}
          </div>
        )}

        {loading && rows.length === 0 ? (
          <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            載入既有團...
          </div>
        ) : visibleRows.length === 0 ? (
          <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            找不到符合的團。
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            {visibleRows.map((row) => {
              const sold = soldMap.get(row.id) ?? 0;
              const cap = row.total_cap_qty;
              const remain = cap == null ? null : Math.max(0, cap - sold);
              const locked = row.status === "locked";
              const endInput = endAtDraft[row.id] ?? toLocalInput(row.end_at) ?? defaultEndAt();
              const delta = Number(deltaDraft[row.id] ?? 0);
              const previewCap = Number.isFinite(delta) && delta > 0 ? (cap ?? sold) + delta : null;
              const itemCap = itemCapSummary(row.campaign_items);

              return (
                <section
                  key={row.id}
                  className="rounded-md border border-zinc-200 bg-white p-4 shadow-sm dark:border-zinc-800 dark:bg-zinc-900"
                >
                  <div className="flex gap-3">
                    <CampaignThumb
                      url={campaignCoverUrl(row.cover_image_url, row.campaign_items)}
                      name={row.name}
                    />
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className={`rounded-full px-2 py-1 text-xs ring-1 ${statusClass(row.status)}`}>
                          {STATUS_LABEL[row.status]}
                        </span>
                        <span className="rounded-full bg-zinc-100 px-2 py-1 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                          {TYPE_LABEL[row.close_type]}
                        </span>
                      </div>
                      <h2 className="mt-2 break-words text-lg font-semibold leading-snug text-zinc-950 dark:text-zinc-50">
                        {row.name}
                      </h2>
                      <p className="mt-1 text-sm text-zinc-500">
                        收單 {formatDateTime(row.end_at)} / 已售 {sold}
                        {cap != null ? ` / 上限 ${cap} / 剩 ${remain}` : " / 無總上限"}
                      </p>
                    </div>
                  </div>

                  <div className="mt-4 grid gap-3">
                    {itemCap && (
                      <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
                        <div className="font-medium">品項上限摘要</div>
                        <div className="mt-1 text-xs sm:text-sm">
                          {itemCap.count} 項有單品上限 / 合計 {itemCap.total} / 最小 {itemCap.min} / 最大 {itemCap.max}
                        </div>
                        <div className="mt-1 text-xs">
                          整團加名額不會改品項上限，單品已滿仍可能無法下單。
                        </div>
                      </div>
                    )}

                    <label className="grid gap-1 text-sm">
                      <span className="font-medium text-zinc-700 dark:text-zinc-200">收單時間</span>
                      <input
                        type="datetime-local"
                        value={endInput}
                        onChange={(e) => setEndAtDraft((cur) => ({ ...cur, [row.id]: e.target.value }))}
                        disabled={locked || !allowed}
                        className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-zinc-900 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                      />
                    </label>

                    <div className="grid grid-cols-3 gap-2">
                      {[
                        ["+1小時", 1],
                        ["+3小時", 3],
                        ["+1天", 24],
                      ].map(([label, hours]) => (
                        <SpinButton
                          key={String(label)}
                          type="button"
                          disabled={locked || !allowed || busyId === row.id}
                          onClick={async () => {
                            const iso = setEndAt(row, Number(hours));
                            if (row.status === "closed") {
                              setNotice(`${row.name} 已改時間，若要重開請按「重開」`);
                              return;
                            }
                            await quickUpdate(row, { endAt: iso }, `${row.name} 已延長`);
                          }}
                          className="min-h-11 rounded-md border border-zinc-300 text-sm font-medium disabled:opacity-50 dark:border-zinc-700"
                        >
                          {label}
                        </SpinButton>
                      ))}
                    </div>

                    {row.status === "closed" && (
                      <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
                        已關團的團若只延長時間，不會自動恢復下單；確認時間後請按「重開」。
                      </div>
                    )}

                    <div className="grid grid-cols-[1fr_auto] gap-2">
                      <input
                        type="number"
                        min="1"
                        step="1"
                        value={deltaDraft[row.id] ?? ""}
                        onChange={(e) => setDeltaDraft((cur) => ({ ...cur, [row.id]: e.target.value }))}
                        placeholder="再增加整團正取名額"
                        disabled={locked || !allowed}
                        className="min-h-11 rounded-md border border-zinc-300 bg-white px-3 text-base outline-none focus:border-zinc-900 disabled:bg-zinc-100 disabled:text-zinc-400 dark:border-zinc-700 dark:bg-zinc-950 dark:disabled:bg-zinc-800"
                      />
                      <SpinButton
                        type="button"
                        disabled={locked || !allowed || busyId === row.id || !Number.isFinite(delta) || delta <= 0}
                        onClick={() => quickUpdate(row, { delta }, `${row.name} 已加量 ${delta}`)}
                        className="min-h-11 rounded-md bg-zinc-900 px-4 text-sm font-medium text-white disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-950"
                      >
                        加整團正取
                      </SpinButton>
                    </div>
                    <div className="text-xs text-zinc-500 dark:text-zinc-400">
                      只增加整團正取上限，不會改候補名額；若有單品上限，單品已滿仍需到開團管理調整。
                    </div>
                    {previewCap != null && (
                      <div className="grid gap-1 text-sm text-zinc-500 dark:text-zinc-400">
                        <div>
                          {cap == null ? "目前無整團總上限" : `目前整團總上限 ${cap}`} / 已售 {sold} / 加 {delta} 後整團總上限 {previewCap}
                        </div>
                        {itemCap && (
                          <div className="text-amber-700 dark:text-amber-300">
                            本頁只加整團名額；若單一品項已滿，仍需調整品項上限。
                          </div>
                        )}
                      </div>
                    )}

                    <div className="grid grid-cols-2 gap-2">
                      {row.status === "open" ? (
                        <SpinButton
                          type="button"
                          disabled={!allowed || busyId === row.id}
                          onClick={() => closeCampaign(row)}
                          className="min-h-12 rounded-md border border-amber-300 bg-amber-50 text-base font-semibold text-amber-800 disabled:opacity-50 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200"
                        >
                          關團
                        </SpinButton>
                      ) : (
                        <SpinButton
                          type="button"
                          disabled={locked || !allowed || busyId === row.id}
                          onClick={() => {
                            const nextEndAt = futureIsoFromLocalInput(endInput);
                            if (!nextEndAt) {
                              setError("請先設定未來的收單時間，再開團或重開。");
                              setNotice(null);
                              return;
                            }
                            quickUpdate(
                              row,
                              { status: "open", endAt: nextEndAt },
                              row.status === "closed" ? `${row.name} 已重開收單` : `${row.name} 已開團`,
                            );
                          }}
                          className="min-h-12 rounded-md bg-emerald-600 text-base font-semibold text-white disabled:opacity-50"
                        >
                          {row.status === "closed" ? "重開收單" : "開團"}
                        </SpinButton>
                      )}
                      <Link
                        href={`/campaigns/order-entry?id=${row.id}`}
                        aria-disabled={locked}
                        className={`flex min-h-12 items-center justify-center rounded-md border border-zinc-300 text-base font-semibold dark:border-zinc-700 ${
                          locked
                            ? "pointer-events-none text-zinc-400 opacity-50 dark:text-zinc-600"
                            : "text-zinc-700 dark:text-zinc-200"
                        }`}
                      >
                        補單
                      </Link>
                    </div>
                  </div>
                </section>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

"use client";

import { Suspense, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

type Campaign = {
  id: number;
  campaign_no: string;
  name: string;
  status: string;
  pickup_deadline: string | null;
};

type Channel = { id: number; name: string; home_store_id: number };

type Store = { id: number; code: string; name: string };

type Mode = "customer" | "internal";

type MemberRow = {
  id: number;
  member_no: string;
  name: string;
  phone: string | null;
  avatar_url: string | null;
  home_store_id: number | null;
  home_store_name: string | null;
};

type AliasRow = {
  alias_id: number;
  nickname: string;
  member_id: number;
  member_no: string;
  member_name: string;
  phone: string | null;
  avatar_url: string | null;
  home_store_id: number | null;
  home_store_name: string | null;
};

type SkuOption = {
  campaign_item_id: number;
  sku_id: number;
  sku_code: string;
  product_name: string;
  variant_name: string | null;
  unit_price: number;
  cap_qty: number | null;
};

type ItemRow = {
  campaign_item_id: number | null;
  sku_label: string;
  qty: string;
  unit_price: number;
};

type CustomerEntry = {
  key: string;
  member_id: number | null;
  member_no: string;
  display_name: string;
  nickname: string;
  pickup_store_id: number | null;
  pickup_store_name: string | null;
  items: ItemRow[];
};

const DRAFT_PREFIX = "draft:order-entry:";
const AUTOSAVE_MS = 30_000;

function newEntry(): CustomerEntry {
  return {
    key: crypto.randomUUID(),
    member_id: null,
    member_no: "",
    display_name: "",
    nickname: "",
    pickup_store_id: null,
    pickup_store_name: null,
    items: [emptyItem()],
  };
}

function emptyItem(): ItemRow {
  return { campaign_item_id: null, sku_label: "", qty: "", unit_price: 0 };
}

export default function OrderEntryPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PageContent />
    </Suspense>
  );
}

function PageContent() {
  const searchParams = useSearchParams();
  const campaignId = Number(searchParams.get("id"));

  const [campaign, setCampaign] = useState<Campaign | null>(null);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [channelId, setChannelId] = useState<number | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [campaignSkus, setCampaignSkus] = useState<SkuOption[]>([]);
  const [entries, setEntries] = useState<CustomerEntry[]>([newEntry()]);
  const [mode, setMode] = useState<Mode>("customer");
  const [internalStoreId, setInternalStoreId] = useState<number | null>(null);
  const [internalNotes, setInternalNotes] = useState("");
  const [internalItems, setInternalItems] = useState<ItemRow[]>([emptyItem()]);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [draftLoaded, setDraftLoaded] = useState(false);

  const draftKey = useMemo(() => `${DRAFT_PREFIX}${campaignId}`, [campaignId]);

  // 載入活動 / channels
  useEffect(() => {
    if (!Number.isFinite(campaignId)) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [cRes, chRes, stRes] = await Promise.all([
        sb.from("group_buy_campaigns")
          .select("id, campaign_no, name, status, pickup_deadline")
          .eq("id", campaignId).maybeSingle(),
        sb.from("line_channels")
          .select("id, name, home_store_id").eq("is_active", true).order("name"),
        sb.from("stores")
          .select("id, code, name").eq("is_active", true).order("name"),
      ]);
      if (cancelled) return;
      if (cRes.error) { setError(cRes.error.message); return; }
      setCampaign(cRes.data as Campaign);
      setChannels((chRes.data ?? []) as Channel[]);
      if (chRes.data && chRes.data.length > 0) {
        setChannelId((chRes.data[0] as Channel).id);
      }
      setStores((stRes.data ?? []) as Store[]);
      // 一次抓活動內全部 SKU 給 dropdown 用
      const { data: skuData } = await getSupabase().rpc("rpc_search_skus_for_campaign", {
        p_campaign_id: campaignId, p_term: "", p_limit: 50,
      });
      if (!cancelled) setCampaignSkus((skuData as SkuOption[]) ?? []);
    })();
    return () => { cancelled = true; };
  }, [campaignId]);

  // 載入 draft（一次性）
  useEffect(() => {
    if (draftLoaded || !campaign) return;
    setDraftLoaded(true);
    try {
      const raw = localStorage.getItem(draftKey);
      if (!raw) return;
      const parsed = JSON.parse(raw) as { entries?: CustomerEntry[]; channelId?: number };
      if (!parsed.entries?.length) return;
      if (confirm("發現未送出的草稿，要載回嗎？")) {
        setEntries(parsed.entries);
        if (parsed.channelId) setChannelId(parsed.channelId);
      } else {
        localStorage.removeItem(draftKey);
      }
    } catch { /* ignore */ }
  }, [campaign, draftKey, draftLoaded]);

  // Autosave 30s
  useEffect(() => {
    if (!draftLoaded) return;
    const t = setInterval(() => {
      const hasContent = entries.some(
        (e) => e.member_id || e.items.some((i) => i.campaign_item_id || i.qty)
      );
      if (hasContent) {
        localStorage.setItem(draftKey, JSON.stringify({ entries, channelId }));
      }
    }, AUTOSAVE_MS);
    return () => clearInterval(t);
  }, [entries, channelId, draftKey, draftLoaded]);


  function updateEntry(key: string, patch: Partial<CustomerEntry>) {
    setEntries((es) => es.map((e) => (e.key === key ? { ...e, ...patch } : e)));
  }

  function updateItem(key: string, idx: number, patch: Partial<ItemRow>) {
    setEntries((es) =>
      es.map((e) => {
        if (e.key !== key) return e;
        const items = e.items.map((it, i) => (i === idx ? { ...it, ...patch } : it));
        return { ...e, items };
      })
    );
  }

  function addItem(key: string) {
    setEntries((es) =>
      es.map((e) => (e.key === key ? { ...e, items: [...e.items, emptyItem()] } : e))
    );
  }

  function removeItem(key: string, idx: number) {
    setEntries((es) =>
      es.map((e) => {
        if (e.key !== key) return e;
        const items = e.items.filter((_, i) => i !== idx);
        return { ...e, items: items.length ? items : [emptyItem()] };
      })
    );
  }

  function addSku(key: string, opt: SkuOption) {
    setEntries((es) =>
      es.map((e) => {
        if (e.key !== key) return e;
        if (e.items.some((it) => it.campaign_item_id === opt.campaign_item_id)) return e;
        const newRow: ItemRow = {
          campaign_item_id: opt.campaign_item_id,
          sku_label: `${opt.product_name}${opt.variant_name ? ` / ${opt.variant_name}` : ""} (${opt.sku_code})`,
          qty: "1",
          unit_price: Number(opt.unit_price),
        };
        const cleaned = e.items.filter((it) => it.campaign_item_id || it.qty);
        return { ...e, items: [...cleaned, newRow] };
      })
    );
  }

  // ---- internal mode helpers ----
  function updateInternalItem(idx: number, patch: Partial<ItemRow>) {
    setInternalItems((items) => items.map((it, i) => (i === idx ? { ...it, ...patch } : it)));
  }
  function addInternalItemRow() {
    setInternalItems((items) => [...items, emptyItem()]);
  }
  function removeInternalItem(idx: number) {
    setInternalItems((items) => {
      const next = items.filter((_, i) => i !== idx);
      return next.length ? next : [emptyItem()];
    });
  }
  function addInternalSku(opt: SkuOption) {
    setInternalItems((items) => {
      if (items.some((it) => it.campaign_item_id === opt.campaign_item_id)) return items;
      const newRow: ItemRow = {
        campaign_item_id: opt.campaign_item_id,
        sku_label: `${opt.product_name}${opt.variant_name ? ` / ${opt.variant_name}` : ""} (${opt.sku_code})`,
        qty: "1",
        unit_price: Number(opt.unit_price),
      };
      const cleaned = items.filter((it) => it.campaign_item_id || it.qty);
      return [...cleaned, newRow];
    });
  }

  // 全域快速鍵：Alt+N 加新顧客 / 加新項目、Ctrl+S 送出
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.altKey && !e.ctrlKey && !e.metaKey && e.key.toLowerCase() === "n") {
        e.preventDefault();
        if (mode === "internal") {
          setInternalItems((items) => [...items, emptyItem()]);
        } else {
          setEntries((es) => [...es, newEntry()]);
        }
      }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        handleSubmit();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entries, channelId, mode, internalStoreId, internalItems, internalNotes]);

  async function handleSubmit() {
    if (submitting) return;
    setError(null);
    if (mode === "internal") {
      await submitInternal();
      return;
    }
    if (!channelId) { setError("請選 LINE 頻道"); return; }
    const noStore = entries.filter((e) => e.member_id && !e.pickup_store_id).map((e) => e.display_name);
    if (noStore.length > 0) { setError(`下列顧客未設預設取貨店：${noStore.join("、")}（請先在會員資料設 home_store_id）`); return; }
    const rows = entries
      .filter((e) => e.member_id && e.pickup_store_id)
      .map((e) => ({
        member_id: e.member_id,
        nickname: e.nickname || e.display_name || null,
        pickup_store_id: e.pickup_store_id,
        items: e.items
          .filter((i) => i.campaign_item_id && Number(i.qty) > 0)
          .map((i) => ({ campaign_item_id: i.campaign_item_id, qty: Number(i.qty) })),
      }))
      .filter((r) => r.items.length > 0);

    if (rows.length === 0) { setError("沒有可送出的訂單列"); return; }

    setSubmitting(true);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_create_customer_orders", {
        p_campaign_id: campaignId,
        p_channel_id: channelId,
        p_rows: rows,
      });
      if (err) { setError(err.message); return; }
      const created = (data as { out_order_id: number; out_order_no: string; out_item_count: number }[]) ?? [];
      setToast(`已建立/更新 ${created.length} 筆訂單`);
      setEntries([newEntry()]);
      localStorage.removeItem(draftKey);
      setTimeout(() => setToast(null), 3000);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  async function submitInternal() {
    if (!internalStoreId) { setError("請選取貨店"); return; }
    const items = internalItems
      .filter((i) => i.campaign_item_id && Number(i.qty) > 0)
      .map((i) => ({
        campaign_item_id: i.campaign_item_id,
        qty: Number(i.qty),
        unit_price: i.unit_price,
      }));
    if (items.length === 0) { setError("請至少加一項商品"); return; }
    if (items.some((i) => i.unit_price < 0)) { setError("單價不能為負"); return; }

    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setError("未登入或 session 過期"); return; }
      const { data, error: err } = await sb.rpc("rpc_create_store_internal_order", {
        p_campaign_id: campaignId,
        p_store_id: internalStoreId,
        p_items: items,
        p_operator: operator,
        p_notes: internalNotes.trim() || null,
      });
      if (err) { setError(err.message); return; }
      setToast(`已建立內部訂單 #${data}`);
      setInternalItems([emptyItem()]);
      setInternalNotes("");
      setTimeout(() => setToast(null), 3000);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  if (!Number.isFinite(campaignId)) {
    return <div className="p-6 text-sm text-red-600">無效的活動 ID</div>;
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">小幫手加單</h1>
          {campaign ? (
            <p className="text-sm text-zinc-500">
              <span className="font-mono">{campaign.campaign_no}</span> · {campaign.name} ·
              <StatusBadge s={campaign.status} />
              {campaign.pickup_deadline && <> · 取貨截止 {campaign.pickup_deadline}</>}
            </p>
          ) : (
            <p className="text-sm text-zinc-500">載入中…</p>
          )}
        </div>
        <div className="flex items-center gap-2 text-xs text-zinc-500">
          <kbd className="rounded border px-1">Alt+N</kbd> {mode === "internal" ? "新項目" : "新顧客"}
          <kbd className="rounded border px-1">Ctrl+S</kbd> 送出
        </div>
      </header>

      <div className="inline-flex w-fit overflow-hidden rounded-md border border-zinc-300 text-xs dark:border-zinc-700">
        <button
          type="button"
          onClick={() => setMode("customer")}
          className={`px-3 py-1.5 ${
            mode === "customer"
              ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
              : "bg-white text-zinc-600 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
          }`}
        >
          客戶下單
        </button>
        <button
          type="button"
          onClick={() => setMode("internal")}
          className={`px-3 py-1.5 ${
            mode === "internal"
              ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
              : "bg-white text-zinc-600 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
          }`}
          title="店長為自己店內部叫貨（會自動掛內部會員、可改價）"
        >
          為分店叫貨
        </button>
      </div>

      {mode === "customer" ? (
        <p className="text-xs text-zinc-500">
          LINE 頻道：<span className="font-medium text-zinc-700 dark:text-zinc-300">
            {channels.find((c) => c.id === channelId)?.name ?? "—"}
          </span>
          　·　取貨店：依顧客的「預設取貨店」自動帶出（會員資料設定）
        </p>
      ) : (
        <p className="text-xs text-zinc-500">
          內部叫貨：客戶自動掛 <span className="font-medium text-zinc-700 dark:text-zinc-300">store_internal</span> 內部會員、訂單編號 <span className="font-mono">XXX-INT0001</span>。可改 unit_price（88 折出清）。
        </p>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}
      {toast && (
        <div className="rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-800 dark:border-green-900 dark:bg-green-950 dark:text-green-300">
          {toast}
        </div>
      )}

      {mode === "customer" ? (
        <div className="grid gap-4 lg:grid-cols-[1fr_280px]">
          <div className="flex flex-col gap-3">
            {entries.map((e) => (
              <CustomerCard
                key={e.key}
                entry={e}
                campaignId={campaignId}
                channelId={channelId}
                campaignSkus={campaignSkus}
                pickedMemberIds={
                  new Set(
                    entries
                      .filter((x) => x.key !== e.key && x.member_id != null)
                      .map((x) => x.member_id as number)
                  )
                }
                onChange={(patch) => updateEntry(e.key, patch)}
                onItemChange={(idx, patch) => updateItem(e.key, idx, patch)}
                onAddItem={() => addItem(e.key)}
                onRemoveItem={(idx) => removeItem(e.key, idx)}
                onAddSku={(opt) => addSku(e.key, opt)}
                onRemove={() =>
                  setEntries((es) => (es.length > 1 ? es.filter((x) => x.key !== e.key) : es))
                }
              />
            ))}
            <button
              type="button"
              onClick={() => setEntries((es) => [...es, newEntry()])}
              className="rounded-md border border-dashed border-zinc-300 px-3 py-2 text-sm text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
            >
              + 新增顧客（Alt+N）
            </button>
            <div className="flex justify-end">
              <button
                type="button"
                onClick={handleSubmit}
                disabled={submitting}
                className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
              >
                {submitting ? "送出中…" : "送出訂單（Ctrl+S）"}
              </button>
            </div>
          </div>

          <SummaryPanel entries={entries} />
        </div>
      ) : (
        <InternalOrderPanel
          campaignId={campaignId}
          campaignSkus={campaignSkus}
          stores={stores}
          storeId={internalStoreId}
          onStoreChange={setInternalStoreId}
          notes={internalNotes}
          onNotesChange={setInternalNotes}
          items={internalItems}
          onItemChange={updateInternalItem}
          onAddItem={addInternalItemRow}
          onRemoveItem={removeInternalItem}
          onAddSku={addInternalSku}
          onSubmit={handleSubmit}
          submitting={submitting}
        />
      )}
    </div>
  );
}

// ============================================================
// Internal Order Panel — 店長為自己店叫貨
// ============================================================
function InternalOrderPanel({
  campaignId, campaignSkus, stores, storeId, onStoreChange,
  notes, onNotesChange, items, onItemChange, onAddItem, onRemoveItem, onAddSku,
  onSubmit, submitting,
}: {
  campaignId: number;
  campaignSkus: SkuOption[];
  stores: Store[];
  storeId: number | null;
  onStoreChange: (id: number | null) => void;
  notes: string;
  onNotesChange: (s: string) => void;
  items: ItemRow[];
  onItemChange: (idx: number, patch: Partial<ItemRow>) => void;
  onAddItem: () => void;
  onRemoveItem: (idx: number) => void;
  onAddSku: (opt: SkuOption) => void;
  onSubmit: () => void;
  submitting: boolean;
}) {
  const pickedIds = new Set(items.map((it) => it.campaign_item_id).filter((x): x is number => x != null));
  const availableSkus = campaignSkus.filter((s) => !pickedIds.has(s.campaign_item_id));
  const totalQty = items.reduce((s, it) => s + (Number(it.qty) || 0), 0);
  const totalAmount = items.reduce((s, it) => {
    const q = Number(it.qty);
    return s + (Number.isFinite(q) && q > 0 ? q * it.unit_price : 0);
  }, 0);
  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_280px]">
      <div className="flex flex-col gap-3">
        <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
          <div className="mb-3 grid gap-3 sm:grid-cols-[200px_1fr]">
            <label className="text-xs">
              <span className="mb-1 block text-zinc-500">取貨店 <span className="text-red-500">*</span></span>
              <select
                value={storeId ?? ""}
                onChange={(e) => onStoreChange(e.target.value ? Number(e.target.value) : null)}
                className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              >
                <option value="">— 選店 —</option>
                {stores.map((s) => (
                  <option key={s.id} value={s.id}>{s.name} ({s.code})</option>
                ))}
              </select>
            </label>
            <label className="text-xs">
              <span className="mb-1 block text-zinc-500">備註（選填）</span>
              <input
                value={notes}
                onChange={(e) => onNotesChange(e.target.value)}
                placeholder="預設【店長內部叫貨】"
                className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
              />
            </label>
          </div>

          <table className="w-full text-xs">
            <thead className="text-zinc-500">
              <tr>
                <th className="text-left">商品</th>
                <th className="w-20 text-right">數量</th>
                <th className="w-24 text-right">單價（可改）</th>
                <th className="w-24 text-right">小計</th>
                <th className="w-8"></th>
              </tr>
            </thead>
            <tbody>
              {items.map((it, idx) => (
                <ItemEditorRow
                  key={idx}
                  campaignId={campaignId}
                  item={it}
                  isLast={idx === items.length - 1}
                  editablePrice
                  onChange={(patch) => onItemChange(idx, patch)}
                  onAddNext={onAddItem}
                  onRemove={() => onRemoveItem(idx)}
                />
              ))}
            </tbody>
          </table>

          <div className="mt-2 flex justify-end">
            <select
              value=""
              onChange={(e) => {
                const id = Number(e.target.value);
                const opt = availableSkus.find((s) => s.campaign_item_id === id);
                if (opt) onAddSku(opt);
                e.target.value = "";
              }}
              disabled={availableSkus.length === 0}
              className="rounded border border-zinc-300 bg-white px-2 py-1 text-xs disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800"
            >
              <option value="">+ 加商品{availableSkus.length === 0 ? "（已全選）" : ""}</option>
              {availableSkus.map((s) => (
                <option key={s.campaign_item_id} value={s.campaign_item_id}>
                  {s.product_name}{s.variant_name ? ` / ${s.variant_name}` : ""} (${Number(s.unit_price)})
                </option>
              ))}
            </select>
          </div>
        </div>

        <button
          type="button"
          onClick={onAddItem}
          className="rounded-md border border-dashed border-zinc-300 px-3 py-2 text-sm text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        >
          + 新增空白項目（Alt+N）
        </button>

        <div className="flex justify-end">
          <button
            type="button"
            onClick={onSubmit}
            disabled={submitting}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            {submitting ? "送出中…" : "送出內部訂單（Ctrl+S）"}
          </button>
        </div>
      </div>

      <aside className="sticky top-4 h-fit rounded-md border border-zinc-200 bg-white p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-2 text-sm font-semibold">本次統計（內部）</h2>
        <div className="grid grid-cols-2 gap-2 text-xs">
          <Stat label="件數" value={totalQty} />
          <Stat label="總金額" value={`$${totalAmount}`} />
        </div>
      </aside>
    </div>
  );
}

// ============================================================
// Customer Card
// ============================================================
function CustomerCard({
  entry, campaignId, channelId, campaignSkus, pickedMemberIds,
  onChange, onItemChange, onAddItem, onRemoveItem, onAddSku, onRemove,
}: {
  entry: CustomerEntry;
  campaignId: number;
  channelId: number | null;
  campaignSkus: SkuOption[];
  pickedMemberIds: Set<number>;
  onChange: (patch: Partial<CustomerEntry>) => void;
  onItemChange: (idx: number, patch: Partial<ItemRow>) => void;
  onAddItem: () => void;
  onRemoveItem: (idx: number) => void;
  onAddSku: (opt: SkuOption) => void;
  onRemove: () => void;
}) {
  const pickedIds = new Set(entry.items.map((it) => it.campaign_item_id).filter((x): x is number => x != null));
  const availableSkus = campaignSkus.filter((s) => !pickedIds.has(s.campaign_item_id));
  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="mb-2 flex items-start gap-2">
        <div className="flex-1">
          <CustomerSearch
            channelId={channelId}
            value={entry}
            pickedMemberIds={pickedMemberIds}
            onPick={(picked) => onChange(picked)}
          />
        </div>
        <div className="w-40 shrink-0 pt-1.5 text-xs">
          <span className="text-zinc-500">取貨店：</span>
          {entry.member_id ? (
            entry.pickup_store_name ? (
              <span className="font-medium">{entry.pickup_store_name}</span>
            ) : (
              <span className="text-red-500">⚠ 未設</span>
            )
          ) : (
            <span className="text-zinc-400">—</span>
          )}
        </div>
        <button
          type="button"
          onClick={onRemove}
          className="text-xs text-zinc-400 hover:text-red-500"
          title="移除此顧客"
        >
          ✕
        </button>
      </div>

      <table className="w-full text-xs">
        <thead className="text-zinc-500">
          <tr>
            <th className="text-left">商品</th>
            <th className="w-20 text-right">數量</th>
            <th className="w-24 text-right">單價</th>
            <th className="w-24 text-right">小計</th>
            <th className="w-8"></th>
          </tr>
        </thead>
        <tbody>
          {entry.items.map((it, idx) => (
            <ItemEditorRow
              key={idx}
              campaignId={campaignId}
              item={it}
              isLast={idx === entry.items.length - 1}
              onChange={(patch) => onItemChange(idx, patch)}
              onAddNext={onAddItem}
              onRemove={() => onRemoveItem(idx)}
            />
          ))}
        </tbody>
      </table>

      <div className="mt-2 flex justify-end">
        <select
          value=""
          onChange={(e) => {
            const id = Number(e.target.value);
            const opt = availableSkus.find((s) => s.campaign_item_id === id);
            if (opt) onAddSku(opt);
            e.target.value = "";
          }}
          disabled={availableSkus.length === 0}
          className="rounded border border-zinc-300 bg-white px-2 py-1 text-xs disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">+ 加商品{availableSkus.length === 0 ? "（已全選）" : ""}</option>
          {availableSkus.map((s) => (
            <option key={s.campaign_item_id} value={s.campaign_item_id}>
              {s.product_name}{s.variant_name ? ` / ${s.variant_name}` : ""} (${Number(s.unit_price)})
            </option>
          ))}
        </select>
      </div>
    </div>
  );
}


// ============================================================
// Customer Search (combo: alias + member)
// ============================================================
function CustomerSearch({
  channelId, value, pickedMemberIds, onPick,
}: {
  channelId: number | null;
  value: CustomerEntry;
  pickedMemberIds: Set<number>;
  onPick: (patch: Partial<CustomerEntry>) => void;
}) {
  const [term, setTerm] = useState("");
  const [open, setOpen] = useState(false);
  const [members, setMembers] = useState<MemberRow[]>([]);
  const [aliases, setAliases] = useState<AliasRow[]>([]);
  const debounceRef = useRef<NodeJS.Timeout | null>(null);

  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (term.length < 1 && !open) return;
    debounceRef.current = setTimeout(async () => {
      const sb = getSupabase();
      const [mRes, aRes] = await Promise.all([
        sb.rpc("rpc_search_members", { p_term: term, p_limit: 8 }),
        channelId
          ? sb.rpc("rpc_search_aliases", { p_channel_id: channelId, p_term: term, p_limit: 8 })
          : Promise.resolve({ data: [], error: null }),
      ]);
      setMembers((mRes.data as MemberRow[]) ?? []);
      setAliases((aRes.data as AliasRow[]) ?? []);
    }, 200);
    return () => { if (debounceRef.current) clearTimeout(debounceRef.current); };
  }, [term, channelId, open]);

  async function handleBindAlias(memberId: number, memberName: string) {
    if (!channelId) return;
    const nickname = prompt("輸入此頻道內顧客的暱稱：", memberName);
    if (!nickname) return;
    const { error: err } = await getSupabase().rpc("rpc_bind_line_alias", {
      p_channel_id: channelId, p_nickname: nickname, p_member_id: memberId,
    });
    if (err) { alert(err.message); return; }
    onPick({ member_id: memberId, display_name: memberName, nickname });
    setOpen(false);
  }

  return (
    <div className="relative flex-1">
      <input
        value={value.member_id ? `${value.display_name} (${value.member_no})` : term}
        onFocus={() => setOpen(true)}
        onChange={(e) => {
          if (value.member_id) {
            onPick({ member_id: null, member_no: "", display_name: "", nickname: "" });
          }
          setTerm(e.target.value);
          setOpen(true);
        }}
        placeholder="搜尋會員 / 暱稱 / 手機"
        className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
      />
      {open && (members.length > 0 || aliases.length > 0) && (
        <div
          className="absolute left-0 right-0 top-full z-20 mt-1 max-h-72 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800"
          onMouseLeave={() => setOpen(false)}
        >
          {aliases.length > 0 && (
            <div>
              <div className="px-2 py-1 text-xs font-medium text-zinc-400">綁過的暱稱</div>
              {aliases.map((a) => {
                const dup = pickedMemberIds.has(a.member_id);
                const noStore = a.home_store_id == null;
                const blocked = dup || noStore;
                return (
                  <button
                    key={`a-${a.alias_id}`}
                    type="button"
                    disabled={blocked}
                    onClick={() => {
                      onPick({
                        member_id: a.member_id,
                        member_no: a.member_no,
                        display_name: a.member_name,
                        nickname: a.nickname,
                        pickup_store_id: a.home_store_id,
                        pickup_store_name: a.home_store_name,
                      });
                      setOpen(false);
                    }}
                    className="block w-full px-2 py-1.5 text-left text-xs hover:bg-zinc-100 disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-transparent dark:hover:bg-zinc-700"
                  >
                    <span className="font-medium">{a.nickname}</span>
                    <span className="ml-2 text-zinc-500">→ {a.member_name} ({a.member_no})</span>
                    {dup && <span className="ml-2 text-amber-600">已選</span>}
                    {!dup && noStore && <span className="ml-2 text-red-500">未設取貨店</span>}
                  </button>
                );
              })}
            </div>
          )}
          {members.length > 0 && (
            <div>
              <div className="px-2 py-1 text-xs font-medium text-zinc-400">會員</div>
              {members.map((m) => {
                const aliased = aliases.some((a) => a.member_id === m.id);
                const dup = pickedMemberIds.has(m.id);
                const noStore = m.home_store_id == null;
                const blocked = dup || noStore;
                return (
                  <div
                    key={`m-${m.id}`}
                    className="flex items-center justify-between px-2 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
                  >
                    <button
                      type="button"
                      disabled={blocked}
                      onClick={() => {
                        onPick({
                          member_id: m.id,
                          member_no: m.member_no,
                          display_name: m.name,
                          pickup_store_id: m.home_store_id,
                          pickup_store_name: m.home_store_name,
                        });
                        setOpen(false);
                      }}
                      className="flex-1 text-left disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      <span className="font-medium">{m.name}</span>
                      <span className="ml-2 text-zinc-500">{m.member_no} · {m.phone ?? "—"}</span>
                      {dup && <span className="ml-2 text-amber-600">已選</span>}
                      {!dup && noStore && <span className="ml-2 text-red-500">未設取貨店</span>}
                    </button>
                    {!aliased && channelId && !blocked && (
                      <button
                        type="button"
                        onClick={() => handleBindAlias(m.id, m.name)}
                        className="ml-2 rounded border border-zinc-300 px-1.5 text-[10px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-600 dark:text-zinc-300"
                        title="綁定此頻道暱稱"
                      >
                        + 綁
                      </button>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ============================================================
// Item Editor Row
// ============================================================
function ItemEditorRow({
  campaignId, item, isLast, editablePrice, onChange, onAddNext, onRemove,
}: {
  campaignId: number;
  item: ItemRow;
  isLast: boolean;
  editablePrice?: boolean;
  onChange: (patch: Partial<ItemRow>) => void;
  onAddNext: () => void;
  onRemove: () => void;
}) {
  const [term, setTerm] = useState("");
  const [open, setOpen] = useState(false);
  const [opts, setOpts] = useState<SkuOption[]>([]);
  const debounceRef = useRef<NodeJS.Timeout | null>(null);

  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (!open) return;
    debounceRef.current = setTimeout(async () => {
      const { data } = await getSupabase().rpc("rpc_search_skus_for_campaign", {
        p_campaign_id: campaignId, p_term: term, p_limit: 12,
      });
      setOpts((data as SkuOption[]) ?? []);
    }, 200);
    return () => { if (debounceRef.current) clearTimeout(debounceRef.current); };
  }, [term, campaignId, open]);

  const qtyN = Number(item.qty);
  const subtotal = Number.isFinite(qtyN) && qtyN > 0 ? qtyN * item.unit_price : 0;
  const qtyInvalid = item.qty !== "" && (!Number.isFinite(qtyN) || qtyN <= 0);

  return (
    <tr className="border-t border-zinc-100 dark:border-zinc-800">
      <td className="relative py-1">
        <input
          value={item.campaign_item_id ? item.sku_label : term}
          onFocus={() => setOpen(true)}
          onChange={(e) => {
            if (item.campaign_item_id) {
              onChange({ campaign_item_id: null, sku_label: "", unit_price: 0 });
            }
            setTerm(e.target.value);
            setOpen(true);
          }}
          placeholder="搜尋商品 / SKU"
          className="w-full rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-800"
        />
        {open && opts.length > 0 && (
          <div
            className="absolute left-0 top-full z-10 mt-1 max-h-60 w-80 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800"
            onMouseLeave={() => setOpen(false)}
          >
            {opts.map((o) => (
              <button
                key={o.campaign_item_id ?? `s-${o.sku_id}`}
                type="button"
                onClick={async () => {
                  // 兄弟 SKU（campaign_item_id=NULL）→ lazy 建 campaign_item
                  let ciId = o.campaign_item_id;
                  if (ciId == null) {
                    const { data: newId, error } = await getSupabase().rpc("rpc_upsert_campaign_item", {
                      p_id: null,
                      p_campaign_id: campaignId,
                      p_sku_id: o.sku_id,
                      p_unit_price: Number(o.unit_price) || 0,
                      p_cap_qty: null,
                      p_sort_order: 0,
                      p_notes: null,
                    });
                    if (error) {
                      alert("加入此規格失敗：" + error.message);
                      return;
                    }
                    ciId = Number(newId);
                  }
                  onChange({
                    campaign_item_id: ciId,
                    sku_label: `${o.product_name}${o.variant_name ? ` / ${o.variant_name}` : ""} (${o.sku_code})`,
                    unit_price: Number(o.unit_price),
                    qty: item.qty === "" ? "1" : item.qty,
                  });
                  setOpen(false);
                  setTerm("");
                }}
                className="block w-full px-2 py-1 text-left text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
              >
                <span className="font-medium">{o.product_name}</span>
                {o.variant_name && <span className="ml-1 text-zinc-500">/ {o.variant_name}</span>}
                <span className="ml-2 font-mono text-zinc-400">{o.sku_code}</span>
                <span className="ml-2 text-zinc-600 dark:text-zinc-300">${Number(o.unit_price)}</span>
                {o.campaign_item_id == null && (
                  <span className="ml-2 rounded bg-blue-100 px-1 py-0.5 text-[10px] text-blue-700 dark:bg-blue-950 dark:text-blue-300">
                    + 加入此團
                  </span>
                )}
              </button>
            ))}
          </div>
        )}
      </td>
      <td className="text-right">
        <input
          value={item.qty}
          onChange={(e) => onChange({ qty: e.target.value })}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              if (isLast) onAddNext();
            }
          }}
          inputMode="decimal"
          className={`w-16 rounded border px-2 py-1 text-right text-xs ${
            qtyInvalid
              ? "border-red-400 bg-red-50 dark:bg-red-950"
              : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800"
          }`}
        />
      </td>
      <td className="text-right">
        {editablePrice ? (
          <input
            value={item.unit_price}
            onChange={(e) => {
              const n = Number(e.target.value);
              onChange({ unit_price: Number.isFinite(n) ? n : 0 });
            }}
            inputMode="decimal"
            className={`w-20 rounded border px-2 py-1 text-right text-xs ${
              item.unit_price < 0
                ? "border-red-400 bg-red-50 dark:bg-red-950"
                : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800"
            }`}
            title="可改價（88 折出清）"
          />
        ) : (
          <span className="font-mono text-xs text-zinc-500">${item.unit_price}</span>
        )}
      </td>
      <td className="text-right font-mono text-xs">${subtotal}</td>
      <td className="text-right">
        <button type="button" onClick={onRemove} className="text-zinc-400 hover:text-red-500">×</button>
      </td>
    </tr>
  );
}

// ============================================================
// Summary Panel
// ============================================================
function SummaryPanel({ entries }: { entries: CustomerEntry[] }) {
  const stats = useMemo(() => {
    let totalCustomers = 0;
    let totalAmount = 0;
    const skuTotals = new Map<string, { label: string; qty: number }>();
    for (const e of entries) {
      let entryHasItem = false;
      for (const i of e.items) {
        const q = Number(i.qty);
        if (!i.campaign_item_id || !Number.isFinite(q) || q <= 0) continue;
        entryHasItem = true;
        totalAmount += q * i.unit_price;
        const key = String(i.campaign_item_id);
        const cur = skuTotals.get(key);
        if (cur) cur.qty += q;
        else skuTotals.set(key, { label: i.sku_label, qty: q });
      }
      if (entryHasItem && e.member_id) totalCustomers += 1;
    }
    return { totalCustomers, totalAmount, skuTotals: Array.from(skuTotals.values()) };
  }, [entries]);

  return (
    <aside className="sticky top-4 h-fit rounded-md border border-zinc-200 bg-white p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
      <h2 className="mb-2 text-sm font-semibold">本次統計</h2>
      <div className="mb-3 grid grid-cols-2 gap-2 text-xs">
        <Stat label="顧客" value={stats.totalCustomers} />
        <Stat label="總金額" value={`$${stats.totalAmount}`} />
      </div>
      <div className="text-xs">
        <div className="mb-1 font-medium text-zinc-500">SKU 累計</div>
        {stats.skuTotals.length === 0 ? (
          <div className="text-zinc-400">尚無資料</div>
        ) : (
          <ul className="space-y-1">
            {stats.skuTotals.map((s, i) => (
              <li key={i} className="flex justify-between gap-2">
                <span className="truncate">{s.label}</span>
                <span className="font-mono">{s.qty}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </aside>
  );
}

function Stat({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded border border-zinc-200 p-2 dark:border-zinc-800">
      <div className="text-zinc-500">{label}</div>
      <div className="font-mono text-base">{value}</div>
    </div>
  );
}

function StatusBadge({ s }: { s: string }) {
  const map: Record<string, string> = {
    open: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
    closed: "bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200",
    draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  };
  return (
    <span className={`ml-1 inline-block rounded px-1.5 py-0.5 text-[10px] ${map[s] ?? map.draft}`}>
      {s}
    </span>
  );
}

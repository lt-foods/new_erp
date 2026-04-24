"use client";

import { useEffect, useMemo, useRef, useState } from "react";
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

type Store = { id: number; name: string };

type MemberRow = {
  id: number;
  member_no: string;
  name: string;
  phone: string | null;
  avatar_url: string | null;
};

type AliasRow = {
  alias_id: number;
  nickname: string;
  member_id: number;
  member_no: string;
  member_name: string;
  phone: string | null;
  avatar_url: string | null;
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
    items: [emptyItem()],
  };
}

function emptyItem(): ItemRow {
  return { campaign_item_id: null, sku_label: "", qty: "", unit_price: 0 };
}

export default function OrderEntryPage() {
  const searchParams = useSearchParams();
  const campaignId = Number(searchParams.get("id"));

  const [campaign, setCampaign] = useState<Campaign | null>(null);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  const [channelId, setChannelId] = useState<number | null>(null);
  const [defaultStoreId, setDefaultStoreId] = useState<number | null>(null);
  const [entries, setEntries] = useState<CustomerEntry[]>([newEntry()]);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [draftLoaded, setDraftLoaded] = useState(false);

  const draftKey = useMemo(() => `${DRAFT_PREFIX}${campaignId}`, [campaignId]);

  // 載入活動 / channels / stores
  useEffect(() => {
    if (!Number.isFinite(campaignId)) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [cRes, chRes, sRes] = await Promise.all([
        sb.from("group_buy_campaigns")
          .select("id, campaign_no, name, status, pickup_deadline")
          .eq("id", campaignId).maybeSingle(),
        sb.from("line_channels")
          .select("id, name, home_store_id").eq("is_active", true).order("name"),
        sb.from("stores").select("id, name").eq("is_active", true).order("name"),
      ]);
      if (cancelled) return;
      if (cRes.error) { setError(cRes.error.message); return; }
      setCampaign(cRes.data as Campaign);
      setChannels((chRes.data ?? []) as Channel[]);
      setStores((sRes.data ?? []) as Store[]);
      if (chRes.data && chRes.data.length > 0) {
        const first = chRes.data[0] as Channel;
        setChannelId(first.id);
        setDefaultStoreId(first.home_store_id);
      }
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

  // 套用 channel 的 home_store_id 為新 entry 預設 + 補上既有空白
  useEffect(() => {
    const ch = channels.find((c) => c.id === channelId);
    if (!ch) return;
    setDefaultStoreId(ch.home_store_id);
    setEntries((es) =>
      es.map((e) => (e.pickup_store_id == null ? { ...e, pickup_store_id: ch.home_store_id } : e))
    );
  }, [channelId, channels]);

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

  // 全域快速鍵：Ctrl+N 加新顧客、Ctrl+S 送出
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "n") {
        e.preventDefault();
        setEntries((es) => [...es, { ...newEntry(), pickup_store_id: defaultStoreId }]);
      }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        handleSubmit();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entries, channelId, defaultStoreId]);

  async function handleSubmit() {
    if (submitting) return;
    setError(null);
    if (!channelId) { setError("請選 LINE 頻道"); return; }
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
      setEntries([{ ...newEntry(), pickup_store_id: defaultStoreId }]);
      localStorage.removeItem(draftKey);
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
          <h1 className="text-xl font-semibold">小幫手 key 單</h1>
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
          <kbd className="rounded border px-1">Ctrl+N</kbd> 新顧客
          <kbd className="rounded border px-1">Ctrl+S</kbd> 送出
        </div>
      </header>

      <div className="grid gap-3 sm:grid-cols-2">
        <label className="flex items-center gap-2 text-sm">
          <span className="w-20 text-zinc-500">LINE 頻道</span>
          <select
            value={channelId ?? ""}
            onChange={(e) => setChannelId(Number(e.target.value) || null)}
            className="flex-1 rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選頻道 —</option>
            {channels.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
      </div>

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

      <div className="grid gap-4 lg:grid-cols-[1fr_280px]">
        <div className="flex flex-col gap-3">
          {entries.map((e) => (
            <CustomerCard
              key={e.key}
              entry={e}
              campaignId={campaignId}
              channelId={channelId}
              stores={stores}
              onChange={(patch) => updateEntry(e.key, patch)}
              onItemChange={(idx, patch) => updateItem(e.key, idx, patch)}
              onAddItem={() => addItem(e.key)}
              onRemoveItem={(idx) => removeItem(e.key, idx)}
              onRemove={() =>
                setEntries((es) => (es.length > 1 ? es.filter((x) => x.key !== e.key) : es))
              }
            />
          ))}
          <button
            type="button"
            onClick={() => setEntries((es) => [...es, { ...newEntry(), pickup_store_id: defaultStoreId }])}
            className="rounded-md border border-dashed border-zinc-300 px-3 py-2 text-sm text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
          >
            + 新增顧客（Ctrl+N）
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
    </div>
  );
}

// ============================================================
// Customer Card
// ============================================================
function CustomerCard({
  entry, campaignId, channelId, stores,
  onChange, onItemChange, onAddItem, onRemoveItem, onRemove,
}: {
  entry: CustomerEntry;
  campaignId: number;
  channelId: number | null;
  stores: Store[];
  onChange: (patch: Partial<CustomerEntry>) => void;
  onItemChange: (idx: number, patch: Partial<ItemRow>) => void;
  onAddItem: () => void;
  onRemoveItem: (idx: number) => void;
  onRemove: () => void;
}) {
  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="mb-2 flex items-start justify-between gap-2">
        <CustomerSearch
          channelId={channelId}
          value={entry}
          onPick={(picked) => onChange(picked)}
        />
        <button
          type="button"
          onClick={onRemove}
          className="text-xs text-zinc-400 hover:text-red-500"
          title="移除此顧客"
        >
          ✕
        </button>
      </div>

      <div className="mb-2 grid gap-2 sm:grid-cols-2">
        <label className="flex items-center gap-2 text-xs">
          <span className="w-16 text-zinc-500">取貨店</span>
          <select
            value={entry.pickup_store_id ?? ""}
            onChange={(e) => onChange({ pickup_store_id: Number(e.target.value) || null })}
            className="flex-1 rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選店 —</option>
            {stores.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="flex items-center gap-2 text-xs">
          <span className="w-16 text-zinc-500">暱稱</span>
          <input
            value={entry.nickname}
            onChange={(e) => onChange({ nickname: e.target.value })}
            placeholder="LINE 顯示名稱"
            className="flex-1 rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
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
    </div>
  );
}

// ============================================================
// Customer Search (combo: alias + member)
// ============================================================
function CustomerSearch({
  channelId, value, onPick,
}: {
  channelId: number | null;
  value: CustomerEntry;
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
              {aliases.map((a) => (
                <button
                  key={`a-${a.alias_id}`}
                  type="button"
                  onClick={() => {
                    onPick({
                      member_id: a.member_id,
                      member_no: a.member_no,
                      display_name: a.member_name,
                      nickname: a.nickname,
                    });
                    setOpen(false);
                  }}
                  className="block w-full px-2 py-1.5 text-left text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
                >
                  <span className="font-medium">{a.nickname}</span>
                  <span className="ml-2 text-zinc-500">→ {a.member_name} ({a.member_no})</span>
                </button>
              ))}
            </div>
          )}
          {members.length > 0 && (
            <div>
              <div className="px-2 py-1 text-xs font-medium text-zinc-400">會員</div>
              {members.map((m) => {
                const aliased = aliases.some((a) => a.member_id === m.id);
                return (
                  <div
                    key={`m-${m.id}`}
                    className="flex items-center justify-between px-2 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
                  >
                    <button
                      type="button"
                      onClick={() => {
                        onPick({ member_id: m.id, member_no: m.member_no, display_name: m.name });
                        setOpen(false);
                      }}
                      className="flex-1 text-left"
                    >
                      <span className="font-medium">{m.name}</span>
                      <span className="ml-2 text-zinc-500">{m.member_no} · {m.phone ?? "—"}</span>
                    </button>
                    {!aliased && channelId && (
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
  campaignId, item, isLast, onChange, onAddNext, onRemove,
}: {
  campaignId: number;
  item: ItemRow;
  isLast: boolean;
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
                key={o.campaign_item_id}
                type="button"
                onClick={() => {
                  onChange({
                    campaign_item_id: o.campaign_item_id,
                    sku_label: `${o.product_name}${o.variant_name ? ` / ${o.variant_name}` : ""} (${o.sku_code})`,
                    unit_price: Number(o.unit_price),
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
      <td className="text-right font-mono text-xs text-zinc-500">${item.unit_price}</td>
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

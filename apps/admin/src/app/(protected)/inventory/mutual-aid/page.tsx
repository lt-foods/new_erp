"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";

type Store = { id: number; code: string; name: string };
type SkuOption = { id: number; sku_code: string; product_name: string; variant_name: string | null };

type PostType = "offer" | "request";

type Post = {
  id: number;
  post_type: PostType;
  offering_store_id: number;
  sku_id: number;
  qty_available: number;
  qty_remaining: number;
  expires_at: string;
  note: string | null;
  status: "active" | "exhausted" | "expired" | "cancelled";
  source_customer_order_id: number | null;
  created_at: string;
  created_by: string | null;
  store_name?: string;
  sku_label?: string;
  source_order_no?: string | null;
  replies_count?: number;
};

type PendingOrder = {
  id: number;
  order_no: string;
  pickup_store_id: number;
  status: string;
  member_name: string | null;
  items: { campaign_item_id: number | null; sku_id: number | null; qty: number; sku_label: string }[];
};

type Reply = {
  id: number;
  board_id: number;
  author_id: string | null;
  author_label: string | null;
  body: string;
  created_at: string;
};

const STATUS_LABEL: Record<Post["status"], string> = {
  active: "進行中",
  exhausted: "已認領",
  expired: "已過期",
  cancelled: "已取消",
};

const STATUS_COLOR: Record<Post["status"], string> = {
  active: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  exhausted: "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-400",
  expired: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

const TYPE_LABEL: Record<PostType, string> = {
  offer: "釋出",
  request: "需求",
};

const TYPE_COLOR: Record<PostType, string> = {
  offer: "bg-pink-100 text-pink-800 dark:bg-pink-950 dark:text-pink-300",
  request: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
};

export default function MutualAidPage() {
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [filter, setFilter] = useState<"all" | "request" | "offer">("all");
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [requestModalOpen, setRequestModalOpen] = useState(false);
  const [offerModalOpen, setOfferModalOpen] = useState(false);
  const [threadPost, setThreadPost] = useState<Post | null>(null);

  // 載入 stores 一次
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data } = await sb.from("stores").select("id, code, name").eq("is_active", true).order("name");
      if (!cancelled) setStores((data ?? []) as Store[]);
    })();
    return () => { cancelled = true; };
  }, []);

  // 載入 posts
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        let q = sb
          .from("mutual_aid_board")
          .select("id, post_type, offering_store_id, sku_id, qty_available, qty_remaining, expires_at, note, status, source_customer_order_id, created_at, created_by")
          .eq("status", "active")
          .order("created_at", { ascending: false })
          .limit(200);
        if (filter !== "all") q = q.eq("post_type", filter);
        const { data, error: e } = await q;
        if (e) throw new Error(e.message);
        const rows = ((data as Post[] | null) ?? []);
        if (rows.length === 0) {
          if (!cancelled) setPosts([]);
          return;
        }
        const skuIds = Array.from(new Set(rows.map((r) => r.sku_id)));
        const storeIds = Array.from(new Set(rows.map((r) => r.offering_store_id)));
        const boardIds = rows.map((r) => r.id);
        const orderIds = Array.from(new Set(rows.map((r) => r.source_customer_order_id).filter((x): x is number => x != null)));

        const [skuRes, storeRes, replyRes, orderRes] = await Promise.all([
          sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds),
          sb.from("stores").select("id, name").in("id", storeIds),
          sb.from("mutual_aid_replies").select("board_id").in("board_id", boardIds),
          orderIds.length > 0
            ? sb.from("customer_orders").select("id, order_no").in("id", orderIds)
            : Promise.resolve({ data: [], error: null }),
        ]);
        const skuMap = new Map<number, SkuOption>(((skuRes.data ?? []) as SkuOption[]).map((s) => [s.id, s]));
        const storeMap = new Map<number, string>(((storeRes.data ?? []) as { id: number; name: string }[]).map((s) => [s.id, s.name]));
        const orderMap = new Map<number, string>(((orderRes.data ?? []) as { id: number; order_no: string }[]).map((o) => [o.id, o.order_no]));
        const replyCount = new Map<number, number>();
        for (const r of (replyRes.data ?? []) as { board_id: number }[]) {
          replyCount.set(r.board_id, (replyCount.get(r.board_id) ?? 0) + 1);
        }
        const enriched = rows.map((r) => {
          const sku = skuMap.get(r.sku_id);
          return {
            ...r,
            store_name: storeMap.get(r.offering_store_id) ?? `#${r.offering_store_id}`,
            sku_label: sku ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} (${sku.sku_code})` : `SKU#${r.sku_id}`,
            source_order_no: r.source_customer_order_id ? orderMap.get(r.source_customer_order_id) ?? null : null,
            replies_count: replyCount.get(r.id) ?? 0,
          };
        });
        if (!cancelled) setPosts(enriched);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [filter, reloadTick]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">互助交流板</h1>
          <p className="text-sm text-zinc-500">
            純通訊板：店家貼出需求或可釋出的訂單、其他店認領 → 走 5b-1 訂單轉移把訂單變成接收店的。
          </p>
        </div>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => setRequestModalOpen(true)}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700"
          >
            📢 我要求助
          </button>
          <button
            type="button"
            onClick={() => setOfferModalOpen(true)}
            className="rounded-md bg-pink-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-pink-700"
          >
            📦 我有庫存可提供
          </button>
        </div>
      </header>

      <div className="inline-flex w-fit overflow-hidden rounded-md border border-zinc-300 text-xs dark:border-zinc-700">
        {(["all", "request", "offer"] as const).map((opt) => (
          <button
            key={opt}
            type="button"
            onClick={() => setFilter(opt)}
            className={`px-3 py-1.5 ${
              filter === opt
                ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                : "bg-white text-zinc-600 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
            }`}
          >
            {opt === "all" ? "全部" : opt === "request" ? "需求中" : "釋出中"}
          </button>
        ))}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {posts === null ? (
        <div className="text-sm text-zinc-500">載入中…</div>
      ) : posts.length === 0 ? (
        <div className="rounded-md border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500 dark:border-zinc-700">
          目前沒有進行中的{filter === "request" ? "需求" : filter === "offer" ? "釋出" : ""}貼文
        </div>
      ) : (
        <ul className="space-y-2">
          {posts.map((p) => (
            <li key={p.id}>
              <button
                type="button"
                onClick={() => setThreadPost(p)}
                className="block w-full rounded-md border border-zinc-200 bg-white p-3 text-left transition hover:border-zinc-400 hover:shadow-sm dark:border-zinc-800 dark:bg-zinc-900 dark:hover:border-zinc-600"
              >
                <div className="mb-1 flex flex-wrap items-center gap-2">
                  <span className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${TYPE_COLOR[p.post_type]}`}>
                    {TYPE_LABEL[p.post_type]}
                  </span>
                  <span className={`rounded px-1.5 py-0.5 text-[10px] ${STATUS_COLOR[p.status]}`}>
                    {STATUS_LABEL[p.status]}
                  </span>
                  <span className="text-sm font-medium">{p.store_name}</span>
                  <span className="text-sm">{p.sku_label}</span>
                  <span className="ml-auto text-xs text-zinc-500">💬 {p.replies_count} 留言</span>
                </div>
                <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-500">
                  <span>
                    {p.post_type === "request" ? "需要" : "釋出"}{" "}
                    <span className="font-mono text-zinc-700 dark:text-zinc-300">{p.qty_remaining}</span>
                    {p.qty_remaining !== p.qty_available && (
                      <span className="ml-1 text-[10px] text-zinc-400">/ 原 {p.qty_available}</span>
                    )}
                  </span>
                  <span>到期 <span className="text-zinc-700 dark:text-zinc-300">{fmtDt(p.expires_at)}</span></span>
                  {p.source_order_no && (
                    <span>源訂單 <span className="font-mono text-zinc-700 dark:text-zinc-300">{p.source_order_no}</span></span>
                  )}
                  {p.note && <span className="text-zinc-700 dark:text-zinc-300">「{p.note}」</span>}
                </div>
              </button>
            </li>
          ))}
        </ul>
      )}

      <RequestModal
        open={requestModalOpen}
        onClose={() => setRequestModalOpen(false)}
        stores={stores}
        onPosted={() => {
          setRequestModalOpen(false);
          setReloadTick((n) => n + 1);
        }}
      />

      <OfferModal
        open={offerModalOpen}
        onClose={() => setOfferModalOpen(false)}
        stores={stores}
        onPosted={() => {
          setOfferModalOpen(false);
          setReloadTick((n) => n + 1);
        }}
      />

      {threadPost && (
        <ThreadModal
          post={threadPost}
          stores={stores}
          onClose={() => setThreadPost(null)}
          onClosed={() => {
            setThreadPost(null);
            setReloadTick((n) => n + 1);
          }}
        />
      )}
    </div>
  );
}

// ============================================================
// Common: SKU search input
// ============================================================
function SkuSearchInput({
  value, onChange,
}: {
  value: SkuOption | null;
  onChange: (s: SkuOption | null) => void;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SkuOption[]>([]);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const t = setTimeout(async () => {
      let q = getSupabase()
        .from("skus").select("id, sku_code, product_name, variant_name")
        .eq("status", "active")
        .order("updated_at", { ascending: false })
        .limit(20);
      const s = query.trim();
      if (s) {
        const safe = s.replace(/[%,()]/g, " ").trim();
        q = q.or(`sku_code.ilike.%${safe}%,product_name.ilike.%${safe}%,variant_name.ilike.%${safe}%`);
      }
      const { data } = await q;
      setResults((data as SkuOption[]) ?? []);
    }, query ? 250 : 0);
    return () => clearTimeout(t);
  }, [query]);

  return (
    <div className="relative">
      <input
        value={value ? `${value.product_name}${value.variant_name ? ` / ${value.variant_name}` : ""} (${value.sku_code})` : query}
        onFocus={() => setOpen(true)}
        onChange={(e) => {
          if (value) onChange(null);
          setQuery(e.target.value);
          setOpen(true);
        }}
        placeholder="搜尋商品 / SKU"
        className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
      />
      {open && results.length > 0 && !value && (
        <div
          className="absolute left-0 right-0 top-full z-20 mt-1 max-h-60 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800"
          onMouseLeave={() => setOpen(false)}
        >
          {results.map((s) => (
            <button
              key={s.id}
              type="button"
              onClick={() => { onChange(s); setOpen(false); }}
              className="block w-full px-2 py-1.5 text-left text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
            >
              <span className="font-medium">{s.product_name}</span>
              {s.variant_name && <span className="ml-1 text-zinc-500">/ {s.variant_name}</span>}
              <span className="ml-2 font-mono text-zinc-400">{s.sku_code}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function defaultExpiresAt() {
  const d = new Date(Date.now() + 7 * 86400_000);
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}

// ============================================================
// Request Modal — 我要求助
// ============================================================
function RequestModal({
  open, onClose, stores, onPosted,
}: {
  open: boolean;
  onClose: () => void;
  stores: Store[];
  onPosted: () => void;
}) {
  const [storeId, setStoreId] = useState<number | "">("");
  const [picked, setPicked] = useState<SkuOption | null>(null);
  const [qty, setQty] = useState("");
  const [expiresAt, setExpiresAt] = useState(defaultExpiresAt);
  const [note, setNote] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setStoreId(""); setPicked(null); setQty(""); setNote(""); setErr(null);
      setExpiresAt(defaultExpiresAt());
    }
  }, [open]);

  async function submit() {
    if (submitting) return;
    setErr(null);
    if (!storeId) { setErr("請選求助店"); return; }
    if (!picked) { setErr("請選 SKU"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("數量需 > 0"); return; }
    const expDate = new Date(expiresAt);
    if (expDate <= new Date()) { setErr("到期時間需在未來"); return; }

    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_post_aid_board", {
        p_offering_store_id: storeId,
        p_sku_id: picked.id,
        p_qty_available: qtyN,
        p_expires_at: expDate.toISOString(),
        p_note: note.trim() || null,
        p_operator: operator,
        p_post_type: "request",
        p_source_customer_order_id: null,
      });
      if (e) { setErr(e.message); return; }
      onPosted();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="📢 我要求助" maxWidth="max-w-lg">
      <div className="flex flex-col gap-3 text-sm">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}
        <label>
          <span className="mb-1 block text-xs text-zinc-500">求助店 <span className="text-red-500">*</span></span>
          <select
            value={storeId}
            onChange={(e) => setStoreId(e.target.value ? Number(e.target.value) : "")}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選店 —</option>
            {stores.map((s) => (<option key={s.id} value={s.id}>{s.name} ({s.code})</option>))}
          </select>
        </label>
        <div>
          <span className="mb-1 block text-xs text-zinc-500">需要的 SKU <span className="text-red-500">*</span></span>
          <SkuSearchInput value={picked} onChange={setPicked} />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <label>
            <span className="mb-1 block text-xs text-zinc-500">需要數量 <span className="text-red-500">*</span></span>
            <input
              value={qty}
              onChange={(e) => setQty(e.target.value)}
              inputMode="decimal"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">到期時間 <span className="text-red-500">*</span></span>
            <input
              type="datetime-local"
              value={expiresAt}
              onChange={(e) => setExpiresAt(e.target.value)}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
        </div>
        <label>
          <span className="mb-1 block text-xs text-zinc-500">備註（選填）</span>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="例：客人要、想多進"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="mt-2 flex justify-end gap-2">
          <button type="button" onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</button>
          <button
            type="button"
            onClick={submit}
            disabled={submitting}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {submitting ? "送出中…" : "發佈求助"}
          </button>
        </div>
      </div>
    </Modal>
  );
}

// ============================================================
// Offer Modal — 我有庫存可提供（從既有訂單釋出）
// ============================================================
function OfferModal({
  open, onClose, stores, onPosted,
}: {
  open: boolean;
  onClose: () => void;
  stores: Store[];
  onPosted: () => void;
}) {
  const [storeId, setStoreId] = useState<number | "">("");
  const [orders, setOrders] = useState<PendingOrder[] | null>(null);
  const [pickedOrder, setPickedOrder] = useState<PendingOrder | null>(null);
  const [pickedItemIdx, setPickedItemIdx] = useState(0);
  const [qty, setQty] = useState("");
  const [expiresAt, setExpiresAt] = useState(defaultExpiresAt);
  const [note, setNote] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setStoreId(""); setOrders(null); setPickedOrder(null); setPickedItemIdx(0);
      setQty(""); setNote(""); setErr(null);
      setExpiresAt(defaultExpiresAt());
    }
  }, [open]);

  // 載入該店 pending orders
  useEffect(() => {
    if (!open || !storeId) { setOrders(null); return; }
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error: e } = await sb
        .from("customer_orders")
        .select(`
          id, order_no, pickup_store_id, status,
          member:members(name),
          items:customer_order_items(campaign_item_id, sku_id, qty, sku:skus(sku_code, product_name, variant_name))
        `)
        .eq("pickup_store_id", storeId)
        .in("status", ["pending", "confirmed", "reserved"])
        .order("id", { ascending: false })
        .limit(50);
      if (cancelled) return;
      if (e) { setErr(e.message); return; }
      type RawSku = { sku_code: string; product_name: string; variant_name: string | null };
      type RawItem = { campaign_item_id: number | null; sku_id: number | null; qty: number; sku: RawSku | RawSku[] | null };
      type RawOrder = {
        id: number; order_no: string; pickup_store_id: number; status: string;
        member: { name: string | null } | { name: string | null }[] | null;
        items: RawItem[];
      };
      const enriched: PendingOrder[] = ((data as unknown as RawOrder[] | null) ?? []).map((o) => {
        const memberObj = Array.isArray(o.member) ? o.member[0] : o.member;
        return {
          id: o.id,
          order_no: o.order_no,
          pickup_store_id: o.pickup_store_id,
          status: o.status,
          member_name: memberObj?.name ?? null,
          items: (o.items ?? []).map((it) => {
            const sku = Array.isArray(it.sku) ? it.sku[0] : it.sku;
            return {
              campaign_item_id: it.campaign_item_id,
              sku_id: it.sku_id,
              qty: Number(it.qty),
              sku_label: sku
                ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} (${sku.sku_code})`
                : `SKU#${it.sku_id}`,
            };
          }),
        };
      }).filter((o) => o.items.length > 0);
      setOrders(enriched);
    })();
    return () => { cancelled = true; };
  }, [open, storeId]);

  // 選了訂單 → 自動帶第一個 item 的 qty
  useEffect(() => {
    if (pickedOrder && pickedOrder.items[pickedItemIdx]) {
      setQty(String(pickedOrder.items[pickedItemIdx].qty));
    }
  }, [pickedOrder, pickedItemIdx]);

  async function submit() {
    if (submitting) return;
    setErr(null);
    if (!storeId) { setErr("請選釋出店"); return; }
    if (!pickedOrder) { setErr("請選要釋出的訂單"); return; }
    const item = pickedOrder.items[pickedItemIdx];
    if (!item || !item.sku_id) { setErr("選定 item 沒 sku_id"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("數量需 > 0"); return; }
    const expDate = new Date(expiresAt);
    if (expDate <= new Date()) { setErr("到期時間需在未來"); return; }

    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_post_aid_board", {
        p_offering_store_id: storeId,
        p_sku_id: item.sku_id,
        p_qty_available: qtyN,
        p_expires_at: expDate.toISOString(),
        p_note: note.trim() || null,
        p_operator: operator,
        p_post_type: "offer",
        p_source_customer_order_id: pickedOrder.id,
      });
      if (e) { setErr(e.message); return; }
      onPosted();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="📦 我有庫存可提供（從既有訂單釋出）" maxWidth="max-w-2xl">
      <div className="flex flex-col gap-3 text-sm">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}
        <label>
          <span className="mb-1 block text-xs text-zinc-500">釋出店 <span className="text-red-500">*</span></span>
          <select
            value={storeId}
            onChange={(e) => {
              setStoreId(e.target.value ? Number(e.target.value) : "");
              setPickedOrder(null); setPickedItemIdx(0); setQty("");
            }}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選店 —</option>
            {stores.map((s) => (<option key={s.id} value={s.id}>{s.name} ({s.code})</option>))}
          </select>
        </label>

        {storeId !== "" && (
          <div>
            <span className="mb-1 block text-xs text-zinc-500">選擇要釋出的訂單 <span className="text-red-500">*</span></span>
            {orders === null ? (
              <div className="text-xs text-zinc-500">載入訂單中…</div>
            ) : orders.length === 0 ? (
              <div className="rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500 dark:border-zinc-700">該店目前沒有可釋出的 pending / confirmed / reserved 訂單</div>
            ) : (
              <div className="max-h-60 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-800">
                {orders.map((o) => (
                  <button
                    key={o.id}
                    type="button"
                    onClick={() => { setPickedOrder(o); setPickedItemIdx(0); }}
                    className={`block w-full border-b border-zinc-100 px-2 py-1.5 text-left text-xs last:border-b-0 dark:border-zinc-800 ${
                      pickedOrder?.id === o.id ? "bg-pink-50 dark:bg-pink-950" : "hover:bg-zinc-50 dark:hover:bg-zinc-800"
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <span><span className="font-mono">{o.order_no}</span> · {o.member_name ?? "—"} · <span className="text-zinc-500">{o.status}</span></span>
                      <span className="text-zinc-500">{o.items.length} 項</span>
                    </div>
                    {pickedOrder?.id === o.id && o.items.length > 1 && (
                      <div className="mt-1 flex flex-wrap gap-1">
                        {o.items.map((it, idx) => (
                          <button
                            key={idx}
                            type="button"
                            onClick={(e) => { e.stopPropagation(); setPickedItemIdx(idx); }}
                            className={`rounded border px-1.5 py-0.5 text-[10px] ${
                              pickedItemIdx === idx
                                ? "border-pink-500 bg-pink-100 text-pink-800 dark:bg-pink-950 dark:text-pink-300"
                                : "border-zinc-300 text-zinc-600 dark:border-zinc-700 dark:text-zinc-400"
                            }`}
                          >
                            {it.sku_label} × {it.qty}
                          </button>
                        ))}
                      </div>
                    )}
                    {pickedOrder?.id === o.id && o.items.length === 1 && (
                      <div className="mt-1 text-[10px] text-zinc-500">{o.items[0].sku_label} × {o.items[0].qty}</div>
                    )}
                  </button>
                ))}
              </div>
            )}
          </div>
        )}

        <div className="grid grid-cols-2 gap-3">
          <label>
            <span className="mb-1 block text-xs text-zinc-500">釋出數量 <span className="text-red-500">*</span></span>
            <input
              value={qty}
              onChange={(e) => setQty(e.target.value)}
              inputMode="decimal"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">到期時間 <span className="text-red-500">*</span></span>
            <input
              type="datetime-local"
              value={expiresAt}
              onChange={(e) => setExpiresAt(e.target.value)}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
        </div>
        <label>
          <span className="mb-1 block text-xs text-zinc-500">備註（選填）</span>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="例：客人棄單、效期將至"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="mt-2 flex justify-end gap-2">
          <button type="button" onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</button>
          <button
            type="button"
            onClick={submit}
            disabled={submitting}
            className="rounded-md bg-pink-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-pink-700 disabled:opacity-50"
          >
            {submitting ? "送出中…" : "發佈釋出"}
          </button>
        </div>
      </div>
    </Modal>
  );
}

// ============================================================
// Thread Modal
// ============================================================
function ThreadModal({
  post, stores, onClose, onClosed,
}: {
  post: Post;
  stores: Store[];
  onClose: () => void;
  onClosed: () => void;
}) {
  const [replies, setReplies] = useState<Reply[] | null>(null);
  const [body, setBody] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [closing, setClosing] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [currentUserId, setCurrentUserId] = useState<string | null>(null);
  const [claimOpen, setClaimOpen] = useState(false);
  const [fulfillOpen, setFulfillOpen] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [{ data: rRes }, { data: uRes }] = await Promise.all([
        sb.from("mutual_aid_replies")
          .select("id, board_id, author_id, author_label, body, created_at")
          .eq("board_id", post.id)
          .order("created_at", { ascending: true }),
        sb.auth.getUser(),
      ]);
      if (cancelled) return;
      setReplies((rRes as Reply[] | null) ?? []);
      setCurrentUserId(uRes.user?.id ?? null);
    })();
    return () => { cancelled = true; };
  }, [post.id, tick]);

  const canClose = post.status === "active" && (currentUserId === post.created_by || true);

  async function postReply() {
    if (submitting) return;
    setErr(null);
    if (!body.trim()) { setErr("請輸入留言"); return; }
    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_post_aid_reply", {
        p_board_id: post.id,
        p_body: body,
        p_operator: operator,
      });
      if (e) { setErr(e.message); return; }
      setBody("");
      setTick((n) => n + 1);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  async function closePost() {
    if (closing) return;
    if (!confirm("確定要結束這則互助貼文？")) return;
    setClosing(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes.user?.id;
      if (!operator) { setErr("未登入或 session 過期"); return; }
      const { error: e } = await sb.rpc("rpc_close_aid_board", {
        p_board_id: post.id,
        p_status: "cancelled",
        p_operator: operator,
      });
      if (e) { setErr(e.message); return; }
      onClosed();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setClosing(false);
    }
  }

  return (
    <Modal open={true} onClose={onClose} title="互助貼文 #" maxWidth="max-w-2xl">
      <div className="flex flex-col gap-3 text-sm">
        {/* Post header */}
        <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs dark:border-zinc-800 dark:bg-zinc-950">
          <div className="mb-1 flex flex-wrap items-center gap-2">
            <span className={`rounded px-1.5 py-0.5 text-[10px] ${STATUS_COLOR[post.status]}`}>
              {STATUS_LABEL[post.status]}
            </span>
            <span className="font-medium text-zinc-700 dark:text-zinc-300">{post.store_name}</span>
            <span className="text-zinc-500">釋出</span>
            <span>{post.sku_label}</span>
          </div>
          <div className="flex flex-wrap gap-x-4 gap-y-1 text-zinc-500">
            <span>
              {post.post_type === "request" ? "尚需" : "可釋"}{" "}
              <span className="font-mono text-zinc-700 dark:text-zinc-300">{post.qty_remaining}</span>
              {post.qty_remaining !== post.qty_available && (
                <span className="ml-1 text-[10px] text-zinc-400">/ 原 {post.qty_available}</span>
              )}
            </span>
            <span>到期 <span className="text-zinc-700 dark:text-zinc-300">{fmtDt(post.expires_at)}</span></span>
            <span>發佈 {fmtDt(post.created_at)}</span>
            {post.note && <div className="basis-full pt-1 text-zinc-700 dark:text-zinc-300">「{post.note}」</div>}
          </div>
        </div>

        {/* Replies thread */}
        <div className="flex flex-col gap-2 max-h-80 overflow-y-auto pr-1">
          {replies === null ? (
            <div className="text-xs text-zinc-500">載入留言…</div>
          ) : replies.length === 0 ? (
            <div className="text-xs text-zinc-500">尚無留言。第一個留言開始討論吧！</div>
          ) : (
            replies.map((r) => (
              <div
                key={r.id}
                className="rounded-md border border-zinc-200 bg-white p-2 text-xs dark:border-zinc-800 dark:bg-zinc-900"
              >
                <div className="mb-1 flex items-center justify-between text-[10px] text-zinc-500">
                  <span className="font-medium text-zinc-700 dark:text-zinc-300">{r.author_label ?? "匿名"}</span>
                  <span>{fmtDt(r.created_at)}</span>
                </div>
                <div className="whitespace-pre-wrap text-zinc-700 dark:text-zinc-300">{r.body}</div>
              </div>
            ))
          )}
        </div>

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        {/* Reply form */}
        {post.status === "active" ? (
          <div>
            <textarea
              value={body}
              onChange={(e) => setBody(e.target.value)}
              onKeyDown={(e) => {
                if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
                  e.preventDefault();
                  postReply();
                }
              }}
              placeholder="留言（Ctrl+Enter 送出）"
              rows={2}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-xs dark:border-zinc-700 dark:bg-zinc-800"
            />
            <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
              <div className="flex flex-wrap gap-2">
                {post.post_type === "offer" && (
                  <button
                    type="button"
                    onClick={() => setClaimOpen(true)}
                    className="rounded-md border border-pink-400 bg-pink-50 px-3 py-1.5 text-xs font-medium text-pink-700 hover:bg-pink-100 dark:border-pink-700 dark:bg-pink-950 dark:text-pink-300 dark:hover:bg-pink-900"
                    title="把釋出店的訂單轉成接收店的（走 5b-1 棄單轉出）"
                  >
                    ✋ 我要認領
                  </button>
                )}
                {post.post_type === "request" && (
                  <button
                    type="button"
                    onClick={() => setFulfillOpen(true)}
                    className="rounded-md border border-blue-400 bg-blue-50 px-3 py-1.5 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                    title="從我的 pending 訂單挑一張轉給求助店"
                  >
                    🤝 我可以提供
                  </button>
                )}
                {canClose && (
                  <button
                    type="button"
                    onClick={closePost}
                    disabled={closing}
                    className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs text-zinc-600 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                  >
                    {closing ? "處理中…" : "結束此貼"}
                  </button>
                )}
              </div>
              <button
                type="button"
                onClick={postReply}
                disabled={submitting || !body.trim()}
                className="rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
              >
                {submitting ? "送出中…" : "送出留言"}
              </button>
            </div>
          </div>
        ) : (
          <div className="rounded-md border border-zinc-200 bg-zinc-50 p-2 text-xs text-zinc-500 dark:border-zinc-800 dark:bg-zinc-950">
            此貼已關閉（{STATUS_LABEL[post.status]}），無法再留言。
          </div>
        )}
      </div>

      {claimOpen && (
        <ClaimOfferDialog
          post={post}
          stores={stores}
          onCancel={() => setClaimOpen(false)}
          onDone={() => {
            setClaimOpen(false);
            onClosed();
          }}
        />
      )}
      {fulfillOpen && (
        <FulfillRequestDialog
          post={post}
          stores={stores}
          onCancel={() => setFulfillOpen(false)}
          onDone={() => {
            setFulfillOpen(false);
            onClosed();
          }}
        />
      )}
    </Modal>
  );
}

// ============================================================
// Claim Offer Dialog — 認領釋出（receiving store 從釋出方拿訂單）
// ============================================================
function ClaimOfferDialog({
  post, stores, onCancel, onDone,
}: {
  post: Post;
  stores: Store[];
  onCancel: () => void;
  onDone: () => void;
}) {
  const [toStore, setToStore] = useState<number | "">("");
  const [qty, setQty] = useState(String(post.qty_remaining));
  const [isAir, setIsAir] = useState(false);
  const [reason, setReason] = useState(`互助板認領 #${post.id}`);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function submit() {
    if (busy) return;
    setErr(null);
    if (!toStore) { setErr("請選接收店"); return; }
    if (!post.source_customer_order_id) { setErr("此 offer 缺 source_customer_order_id（資料異常）"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("認領數量需 > 0"); return; }
    if (qtyN > post.qty_remaining) { setErr(`認領數量超過剩餘量 ${post.qty_remaining}`); return; }
    setBusy(true);
    try {
      const sb = getSupabase();
      const { data: { user } } = await sb.auth.getUser();
      if (!user?.id) { setErr("未登入"); return; }
      const { error: e1 } = await sb.rpc("rpc_transfer_order_partial", {
        p_order_id: post.source_customer_order_id,
        p_to_pickup_store_id: toStore,
        p_to_member_id: null,
        p_to_channel_id: null,
        p_operator: user.id,
        p_reason: reason || null,
        p_items: [{ sku_id: post.sku_id, qty: qtyN }],
        p_is_air_transfer: isAir,
      });
      if (e1) { setErr(e1.message); return; }
      // 統一走 consume RPC：reach 0 自動 exhausted、>0 保持 active 可分批
      const { error: e2 } = await sb.rpc("rpc_consume_aid_board", {
        p_board_id: post.id,
        p_qty: qtyN,
        p_operator: user.id,
      });
      if (e2) { setErr(`轉移成功但扣量失敗：${e2.message}`); return; }
      onDone();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-zinc-900/60 p-4" onClick={onCancel}>
      <div className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900" onClick={(e) => e.stopPropagation()}>
        <h3 className="mb-3 text-base font-semibold">認領釋出</h3>
        {err && (
          <div className="mb-2 rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{err}</div>
        )}
        <div className="mb-3 rounded bg-zinc-50 p-2 text-xs dark:bg-zinc-950">
          從「{post.store_name}」的訂單 <span className="font-mono">{post.source_order_no ?? `#${post.source_customer_order_id}`}</span> 取出指定數量、開新單給接收店（走 5b-1 partial transfer）。
        </div>
        <div className="mb-3 grid grid-cols-2 gap-3 text-sm">
          <label>
            <span className="mb-1 block text-xs text-zinc-500">接收店 <span className="text-red-500">*</span></span>
            <select
              value={toStore}
              onChange={(e) => setToStore(e.target.value ? Number(e.target.value) : "")}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
            >
              <option value="">— 選店 —</option>
              {stores.filter((s) => s.id !== post.offering_store_id).map((s) => (
                <option key={s.id} value={s.id}>{s.name} ({s.code})</option>
              ))}
            </select>
          </label>
          <label>
            <span className="mb-1 block text-xs text-zinc-500">認領數量 <span className="text-red-500">*</span></span>
            <input
              value={qty}
              onChange={(e) => setQty(e.target.value)}
              inputMode="decimal"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
            />
            <div className="mt-1 text-[10px] text-zinc-500">剩餘可認 {post.qty_remaining}{post.qty_remaining !== post.qty_available && `（原 ${post.qty_available}）`}</div>
          </label>
        </div>
        <label className="mb-3 flex items-center gap-2 text-sm">
          <input type="checkbox" checked={isAir} onChange={(e) => setIsAir(e.target.checked)} className="h-4 w-4" />
          <span>空中轉（店對店直送、不經總倉）</span>
        </label>
        <label className="mb-3 block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">原因（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="flex justify-end gap-2">
          <button type="button" onClick={onCancel} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</button>
          <button
            type="button"
            onClick={submit}
            disabled={busy}
            className="rounded-md bg-pink-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-pink-700 disabled:opacity-50"
          >
            {busy ? "處理中…" : "確認認領"}
          </button>
        </div>
      </div>
    </div>
  );
}

// ============================================================
// Fulfill Request Dialog — 提供需求（從我的訂單挑一張轉給求助店）
// ============================================================
function FulfillRequestDialog({
  post, stores, onCancel, onDone,
}: {
  post: Post;
  stores: Store[];
  onCancel: () => void;
  onDone: () => void;
}) {
  const [myStore, setMyStore] = useState<number | "">("");
  const [orders, setOrders] = useState<PendingOrder[] | null>(null);
  const [pickedOrderId, setPickedOrderId] = useState<number | null>(null);
  const [qty, setQty] = useState(String(post.qty_remaining));
  const [isAir, setIsAir] = useState(false);
  const [reason, setReason] = useState(`互助板提供 #${post.id}`);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // 載入我店符合 sku 的 pending orders
  useEffect(() => {
    if (!myStore) { setOrders(null); return; }
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error: e } = await sb
        .from("customer_orders")
        .select(`
          id, order_no, pickup_store_id, status,
          member:members(name),
          items:customer_order_items!inner(sku_id, qty, sku:skus(sku_code, product_name, variant_name))
        `)
        .eq("pickup_store_id", myStore)
        .in("status", ["pending", "confirmed", "reserved"])
        .eq("items.sku_id", post.sku_id)
        .order("id", { ascending: false })
        .limit(50);
      if (cancelled) return;
      if (e) { setErr(e.message); return; }
      type RawSku = { sku_code: string; product_name: string; variant_name: string | null };
      type RawItem = { sku_id: number | null; qty: number; sku: RawSku | RawSku[] | null };
      type RawOrder = {
        id: number; order_no: string; pickup_store_id: number; status: string;
        member: { name: string | null } | { name: string | null }[] | null;
        items: RawItem[];
      };
      const enriched: PendingOrder[] = ((data as unknown as RawOrder[] | null) ?? []).map((o) => {
        const memberObj = Array.isArray(o.member) ? o.member[0] : o.member;
        return {
          id: o.id, order_no: o.order_no, pickup_store_id: o.pickup_store_id, status: o.status,
          member_name: memberObj?.name ?? null,
          items: (o.items ?? []).map((it) => {
            const sku = Array.isArray(it.sku) ? it.sku[0] : it.sku;
            return {
              campaign_item_id: null, sku_id: it.sku_id, qty: Number(it.qty),
              sku_label: sku ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} (${sku.sku_code})` : `SKU#${it.sku_id}`,
            };
          }),
        };
      });
      setOrders(enriched);
    })();
    return () => { cancelled = true; };
  }, [myStore, post.sku_id]);

  async function submit() {
    if (busy) return;
    setErr(null);
    if (!myStore) { setErr("請選提供店"); return; }
    if (!pickedOrderId) { setErr("請選要轉移的訂單"); return; }
    const qtyN = Number(qty);
    if (!Number.isFinite(qtyN) || qtyN <= 0) { setErr("提供數量需 > 0"); return; }
    if (qtyN > post.qty_remaining) { setErr(`提供數量超過剩餘需求 ${post.qty_remaining}`); return; }
    setBusy(true);
    try {
      const sb = getSupabase();
      const { data: { user } } = await sb.auth.getUser();
      if (!user?.id) { setErr("未登入"); return; }
      const { error: e1 } = await sb.rpc("rpc_transfer_order_partial", {
        p_order_id: pickedOrderId,
        p_to_pickup_store_id: post.offering_store_id,
        p_to_member_id: null,
        p_to_channel_id: null,
        p_operator: user.id,
        p_reason: reason || null,
        p_items: [{ sku_id: post.sku_id, qty: qtyN }],
        p_is_air_transfer: isAir,
      });
      if (e1) { setErr(e1.message); return; }
      const { error: e2 } = await sb.rpc("rpc_consume_aid_board", {
        p_board_id: post.id,
        p_qty: qtyN,
        p_operator: user.id,
      });
      if (e2) { setErr(`轉移成功但扣量失敗：${e2.message}`); return; }
      onDone();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-zinc-900/60 p-4" onClick={onCancel}>
      <div className="w-full max-w-lg rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900" onClick={(e) => e.stopPropagation()}>
        <h3 className="mb-3 text-base font-semibold">提供需求</h3>
        {err && (
          <div className="mb-2 rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{err}</div>
        )}
        <div className="mb-3 rounded bg-zinc-50 p-2 text-xs dark:bg-zinc-950">
          求助店「{post.store_name}」尚需 {post.sku_label}（剩餘 {post.qty_remaining}{post.qty_remaining !== post.qty_available && `／原 ${post.qty_available}`}）。
          選一張你店的 pending 訂單轉給他（走 5b-1 棄單轉出）。
        </div>
        <label className="mb-3 block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">提供店（你的店） <span className="text-red-500">*</span></span>
          <select
            value={myStore}
            onChange={(e) => { setMyStore(e.target.value ? Number(e.target.value) : ""); setPickedOrderId(null); }}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選店 —</option>
            {stores.filter((s) => s.id !== post.offering_store_id).map((s) => (
              <option key={s.id} value={s.id}>{s.name} ({s.code})</option>
            ))}
          </select>
        </label>
        {myStore !== "" && (
          <div className="mb-3">
            <span className="mb-1 block text-xs text-zinc-500">挑一張含此 SKU 的 pending 訂單 <span className="text-red-500">*</span></span>
            {orders === null ? (
              <div className="text-xs text-zinc-500">載入訂單中…</div>
            ) : orders.length === 0 ? (
              <div className="rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500 dark:border-zinc-700">該店沒有含此 SKU 的可轉移訂單</div>
            ) : (
              <div className="max-h-48 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-800">
                {orders.map((o) => (
                  <button
                    key={o.id}
                    type="button"
                    onClick={() => setPickedOrderId(o.id)}
                    className={`block w-full border-b border-zinc-100 px-2 py-1.5 text-left text-xs last:border-b-0 dark:border-zinc-800 ${
                      pickedOrderId === o.id ? "bg-blue-50 dark:bg-blue-950" : "hover:bg-zinc-50 dark:hover:bg-zinc-800"
                    }`}
                  >
                    <span className="font-mono">{o.order_no}</span> · {o.member_name ?? "—"} · 數量 {o.items.find((it) => it.sku_id === post.sku_id)?.qty ?? "—"} · <span className="text-zinc-500">{o.status}</span>
                  </button>
                ))}
              </div>
            )}
          </div>
        )}
        <label className="mb-3 block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">提供數量 <span className="text-red-500">*</span></span>
          <input
            value={qty}
            onChange={(e) => setQty(e.target.value)}
            inputMode="decimal"
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-800"
          />
          <div className="mt-1 text-[10px] text-zinc-500">剩餘需求 {post.qty_remaining}（≤ 此值；不足部分維持需求中）</div>
        </label>
        <label className="mb-3 flex items-center gap-2 text-sm">
          <input type="checkbox" checked={isAir} onChange={(e) => setIsAir(e.target.checked)} className="h-4 w-4" />
          <span>空中轉（店對店直送、不經總倉）</span>
        </label>
        <label className="mb-3 block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">原因（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <div className="flex justify-end gap-2">
          <button type="button" onClick={onCancel} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</button>
          <button
            type="button"
            onClick={submit}
            disabled={busy}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {busy ? "處理中…" : "確認提供"}
          </button>
        </div>
      </div>
    </div>
  );
}

function fmtDt(s: string) {
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return s;
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  return `${y}/${m}/${day} ${hh}:${mm}`;
}

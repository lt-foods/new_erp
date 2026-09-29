"use client";

// 限量 / 美食列車的「品項統計」：每個規格 已下單 / 正取上限 的進度條，點 ✏️ 改正取上限。
// 老闆 9/30 要的「手機快速看」頁，從開團列表的「進度」連結進來（/campaigns/stats?id=）。
// 已下單的算法同 /campaigns/quick-control：排除取消 / 過期 / 轉出的單、非 normal 單、
// 取消 / 過期的品項。

import { Suspense, useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

type Item = {
  id: number;
  sku_id: number;
  unit_price: number;
  cap_qty: number | null;
  sort_order: number;
  notes: string | null;
  label: string;
};

type Campaign = {
  id: number;
  campaign_no: string;
  name: string;
  close_type: string;
  total_cap_qty: number | null;
};

const PAGE = 1000;

export default function CampaignStatsPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PageContent />
    </Suspense>
  );
}

function PageContent() {
  const searchParams = useSearchParams();
  return <CampaignStats campaignId={Number(searchParams.get("id"))} />;
}

function letter(i: number): string {
  return i < 26 ? String.fromCharCode(65 + i) : String(i + 1);
}

function CampaignStats({ campaignId }: { campaignId: number }) {
  const [campaign, setCampaign] = useState<Campaign | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [sold, setSold] = useState<Map<number, number>>(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<number | null>(null);
  const [draft, setDraft] = useState("");

  const load = useCallback(async () => {
    if (!campaignId) { setError("缺少團 id"); setLoading(false); return; }
    setLoading(true); setError(null);
    try {
      const sb = getSupabase();
      const { data: c, error: cErr } = await sb
        .from("group_buy_campaigns")
        .select("id, campaign_no, name, close_type, total_cap_qty, campaign_items(id, sku_id, unit_price, cap_qty, sort_order, notes, sku:skus(variant_name, sku_code, product:products(name)))")
        .eq("id", campaignId)
        .maybeSingle();
      if (cErr) throw cErr;
      if (!c) throw new Error("找不到這個團");
      type RawItem = Omit<Item, "label"> & {
        sku: { variant_name: string | null; sku_code: string; product: { name: string } | null } | null;
      };
      const raw = ((c as unknown as { campaign_items: RawItem[] }).campaign_items ?? [])
        .slice()
        .sort((a, b) => (a.sort_order - b.sort_order) || (a.id - b.id));
      setCampaign({
        id: c.id, campaign_no: c.campaign_no, name: c.name, close_type: c.close_type,
        total_cap_qty: c.total_cap_qty != null ? Number(c.total_cap_qty) : null,
      });
      setItems(raw.map((it) => ({
        id: it.id, sku_id: it.sku_id, unit_price: Number(it.unit_price), sort_order: it.sort_order, notes: it.notes,
        cap_qty: it.cap_qty != null ? Number(it.cap_qty) : null,
        // 單規格的團，規格名常常只是「1」之類的佔位字，改印商品名
        label: (raw.length > 1 ? it.sku?.variant_name?.trim() : null)
          || it.sku?.product?.name || it.sku?.variant_name?.trim() || it.sku?.sku_code || `#${it.sku_id}`,
      })));

      const next = new Map<number, number>();
      for (let from = 0; ; from += PAGE) {
        const { data: rows, error: oErr } = await sb
          .from("customer_order_items")
          .select("sku_id, qty, status, customer_orders!inner(campaign_id, status, order_kind)")
          .eq("customer_orders.campaign_id", campaignId)
          .range(from, from + PAGE - 1);
        if (oErr) throw oErr;
        type Row = { sku_id: number; qty: number; status: string; customer_orders: { status: string; order_kind: string | null } };
        for (const r of (rows ?? []) as unknown as Row[]) {
          if (["cancelled", "expired"].includes(r.status)) continue;
          if (["cancelled", "expired", "transferred_out"].includes(r.customer_orders.status)) continue;
          if ((r.customer_orders.order_kind ?? "normal") !== "normal") continue;
          next.set(r.sku_id, (next.get(r.sku_id) ?? 0) + Number(r.qty ?? 0));
        }
        if (!rows || rows.length < PAGE) break;
      }
      setSold(next);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [campaignId]);

  useEffect(() => {
    const t = window.setTimeout(() => { void load(); }, 0);
    return () => window.clearTimeout(t);
  }, [load]);

  async function saveCap(it: Item) {
    const v = draft.trim();
    const cap = v ? Number(v) : null;
    if (cap != null && !(Number.isInteger(cap) && cap > 0)) { alert("正取上限要填大於 0 的整數，或留空＝不限"); return; }
    const { error: err } = await getSupabase().rpc("rpc_upsert_campaign_item", {
      p_id: it.id,
      p_campaign_id: campaignId,
      p_sku_id: it.sku_id,
      p_unit_price: it.unit_price,
      p_cap_qty: cap,
      p_sort_order: it.sort_order,
      p_notes: it.notes,
    });
    if (err) { alert("修改失敗：" + err.message); return; }
    setItems((cur) => cur.map((x) => (x.id === it.id ? { ...x, cap_qty: cap } : x)));
    setEditing(null);
  }

  const totalSold = items.reduce((s, it) => s + (sold.get(it.sku_id) ?? 0), 0);

  return (
    <div className="mx-auto max-w-xl space-y-4 p-4">
      <div className="flex items-center justify-between gap-2">
        <Link href="/campaigns" className="text-sm text-blue-600 hover:underline dark:text-blue-400">← 開團列表</Link>
        <SpinButton onClick={() => load()} className="rounded-md border border-zinc-300 px-3 py-1 text-sm dark:border-zinc-700">
          重新整理
        </SpinButton>
      </div>

      {error && <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</div>}

      {campaign && (
        <div className="rounded-xl border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
          <div className="text-xs text-zinc-500">{campaign.campaign_no}</div>
          <h1 className="text-lg font-bold">{campaign.name}</h1>
          <div className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
            共 {totalSold} 件{campaign.total_cap_qty != null ? ` / 整團上限 ${campaign.total_cap_qty}` : ""}
          </div>
        </div>
      )}

      <div className="rounded-xl border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-2 font-semibold">品項統計 <span className="text-xs font-normal text-zinc-500">（點 ✏️ 可修改正取數量）</span></h2>
        {loading && items.length === 0 && <div className="py-6 text-center text-sm text-zinc-500">載入中…</div>}
        {!loading && items.length === 0 && !error && <div className="py-6 text-center text-sm text-zinc-500">這個團沒有品項</div>}
        <ul className="divide-y divide-dashed divide-zinc-200 dark:divide-zinc-800">
          {items.map((it, i) => {
            const n = sold.get(it.sku_id) ?? 0;
            const cap = it.cap_qty;
            const pct = cap ? Math.min(100, (n / cap) * 100) : 0;
            const full = cap != null && n >= cap;
            return (
              <li key={it.id} className="py-4">
                <div className="flex items-center justify-between gap-3">
                  <div className="min-w-0 truncate text-lg font-semibold">({letter(i)}){it.label}</div>
                  {editing !== it.id && (
                    <button
                      type="button"
                      onClick={() => { setEditing(it.id); setDraft(cap != null ? String(cap) : ""); }}
                      className="shrink-0 rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
                    >
                      ✏️ 修改
                    </button>
                  )}
                </div>
                {editing === it.id && (
                  <div className="mt-2 flex items-center gap-2">
                    <input
                      type="number"
                      inputMode="numeric"
                      min="1"
                      step="1"
                      autoFocus
                      value={draft}
                      onChange={(e) => setDraft(e.target.value)}
                      placeholder="正取上限（留空＝不限）"
                      className="min-w-0 flex-1 rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                    />
                    <SpinButton onClick={() => saveCap(it)} className="rounded-md bg-zinc-900 px-3 py-2 text-sm text-white dark:bg-zinc-100 dark:text-zinc-900">
                      儲存
                    </SpinButton>
                    <button type="button" onClick={() => setEditing(null)} className="px-2 py-2 text-sm text-zinc-500">取消</button>
                  </div>
                )}
                <div className="mt-2 flex items-center justify-between text-sm">
                  <span className="text-zinc-500">進度：</span>
                  <span className={`text-base font-bold ${full ? "text-red-600 dark:text-red-400" : "text-green-600 dark:text-green-400"}`}>
                    {n} / {cap ?? "不限"}{cap != null ? (full ? "（已滿）" : "（正取）") : ""}
                  </span>
                </div>
                {cap != null && (
                  <div className="mt-1.5 h-2.5 w-full overflow-hidden rounded-full bg-zinc-100 dark:bg-zinc-800">
                    <div
                      className={`h-full rounded-full ${full ? "bg-red-500" : "bg-green-500"}`}
                      style={{ width: `${pct}%` }}
                    />
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      </div>
    </div>
  );
}

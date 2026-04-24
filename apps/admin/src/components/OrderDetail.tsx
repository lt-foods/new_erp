"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type OrderHead = {
  id: number;
  order_no: string;
  status: string;
  pickup_deadline: string | null;
  nickname_snapshot: string | null;
  created_at: string;
  updated_at: string;
  member: { id: number; name: string | null; phone: string | null; member_no: string } | null;
  campaign: { id: number; campaign_no: string; name: string } | null;
  store: { id: number; name: string } | null;
};

type ItemRow = {
  id: number;
  qty: number;
  unit_price: number;
  status: string;
  source: string;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
  sku: { id: number; sku_code: string; product_name: string | null; variant_name: string | null } | null;
};

function uidShort(uid: string | null): string {
  if (!uid) return "—";
  return uid.slice(0, 8);
}

function fmtDt(iso: string): string {
  return new Date(iso).toLocaleString("zh-TW", { hour12: false });
}

export function OrderDetail({ orderId }: { orderId: number }) {
  const [head, setHead] = useState<OrderHead | null>(null);
  const [items, setItems] = useState<ItemRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [hRes, iRes] = await Promise.all([
        sb.from("customer_orders")
          .select("id, order_no, status, pickup_deadline, nickname_snapshot, created_at, updated_at, member:members(id, name, phone, member_no), campaign:group_buy_campaigns(id, campaign_no, name), store:stores!customer_orders_pickup_store_id_fkey(id, name)")
          .eq("id", orderId).maybeSingle(),
        sb.from("customer_order_items")
          .select("id, qty, unit_price, status, source, created_at, updated_at, created_by, updated_by, sku:skus(id, sku_code, product_name, variant_name)")
          .eq("order_id", orderId)
          .order("created_at", { ascending: true }),
      ]);
      if (cancelled) return;
      if (hRes.error) { setError(hRes.error.message); return; }
      setHead(hRes.data as unknown as OrderHead);
      if (iRes.error) { setError(iRes.error.message); return; }
      setItems((iRes.data ?? []) as unknown as ItemRow[]);
    })();
    return () => { cancelled = true; };
  }, [orderId]);

  if (error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {error}
      </div>
    );
  }
  if (!head || !items) return <div className="text-sm text-zinc-500">載入中…</div>;

  const totalQty = items.reduce((s, i) => s + Number(i.qty), 0);
  const totalAmount = items.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0);

  return (
    <div className="space-y-4 text-sm">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Field label="訂單號" value={<span className="font-mono">{head.order_no}</span>} />
        <Field label="狀態" value={head.status} />
        <Field label="取貨截止" value={head.pickup_deadline ?? "—"} />
        <Field
          label="會員"
          value={
            head.member ? (
              <span>
                {head.member.name ?? "—"}{" "}
                <span className="font-mono text-xs text-zinc-500">{head.member.member_no}</span>
                <br />
                <span className="font-mono text-xs text-zinc-500">{head.member.phone ?? "—"}</span>
              </span>
            ) : (
              <span className="text-zinc-500">({head.nickname_snapshot ?? "—"})</span>
            )
          }
        />
        <Field label="開團" value={head.campaign ? `${head.campaign.campaign_no} ${head.campaign.name}` : "—"} />
        <Field label="取貨店" value={head.store?.name ?? "—"} />
        <Field label="建立" value={fmtDt(head.created_at)} />
        <Field label="最後更新" value={fmtDt(head.updated_at)} />
      </div>

      <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
        <div className="flex items-center justify-between border-b border-zinc-200 bg-zinc-50 px-3 py-2 text-xs font-medium dark:border-zinc-800 dark:bg-zinc-900">
          <span>明細（{items.length} 項 · {totalQty} 件 · ${totalAmount}）</span>
        </div>
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">商品</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">數量</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">單價</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">小計</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">第一次加</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">最後更新</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {items.length === 0 ? (
                <tr><td colSpan={6} className="p-4 text-center text-zinc-500">尚無明細</td></tr>
              ) : items.map((it) => {
                const sub = Number(it.qty) * Number(it.unit_price);
                return (
                  <tr key={it.id}>
                    <td className="px-3 py-2">
                      {it.sku ? (
                        <span>
                          {it.sku.product_name ?? "—"}
                          {it.sku.variant_name && <span className="text-zinc-500"> / {it.sku.variant_name}</span>}
                          <span className="ml-1 font-mono text-zinc-400">{it.sku.sku_code}</span>
                        </span>
                      ) : "—"}
                    </td>
                    <td className="px-3 py-2 text-right font-mono">{Number(it.qty)}</td>
                    <td className="px-3 py-2 text-right font-mono text-zinc-500">${Number(it.unit_price)}</td>
                    <td className="px-3 py-2 text-right font-mono">${sub}</td>
                    <td className="px-3 py-2 text-zinc-500">
                      {fmtDt(it.created_at)}<br />
                      <span className="font-mono text-[10px]">by {uidShort(it.created_by)}</span>
                    </td>
                    <td className="px-3 py-2 text-zinc-500">
                      {fmtDt(it.updated_at)}<br />
                      <span className="font-mono text-[10px]">by {uidShort(it.updated_by)}</span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <p className="border-t border-zinc-200 bg-zinc-50 px-3 py-1.5 text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          ※ 同顧客在同活動連 key 多次會合併到同一筆，舊 qty 被新值覆寫。如需「每次 +N 紀錄」請告知改完整版（加 append-only audit table）。
        </p>
      </div>
    </div>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <div className="text-xs text-zinc-500">{label}</div>
      <div>{value}</div>
    </div>
  );
}

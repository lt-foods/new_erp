"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";

type Row = {
  id: number;
  sku_id: number;
  sku_code: string;
  product_id: number;
  product_name: string | null;
  variant_name: string | null;
  unit_price: number;
  cap_qty: number | null;
  sort_order: number;
  notes: string | null;
  locked_at: string | null;
};

export function CampaignItemsTable({ campaignId }: { campaignId: number }) {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = async () => {
    // products.name 是 source of truth；skus.product_name 是 denorm 可能過期、不用它
    const { data, error: err } = await getSupabase()
      .from("campaign_items")
      .select("id, sku_id, unit_price, cap_qty, sort_order, notes, locked_at, skus!inner(id, sku_code, product_id, variant_name, products!inner(id, name))")
      .eq("campaign_id", campaignId)
      .order("sort_order");
    if (err) { setError(err.message); return; }
    setRows(
      (data as unknown as Array<{
        id: number; sku_id: number; unit_price: number; cap_qty: number | null;
        sort_order: number; notes: string | null; locked_at: string | null;
        skus: { id: number; sku_code: string; product_id: number; variant_name: string | null;
          products: { id: number; name: string };
        };
      }>).map((r) => ({
        id: r.id, sku_id: r.sku_id, sku_code: r.skus.sku_code,
        product_id: r.skus.product_id,
        product_name: r.skus.products?.name ?? null,
        variant_name: r.skus.variant_name,
        unit_price: Number(r.unit_price), cap_qty: r.cap_qty != null ? Number(r.cap_qty) : null,
        sort_order: r.sort_order, notes: r.notes, locked_at: r.locked_at,
      }))
    );
  };

  useEffect(() => { reload(); }, [campaignId]);

  const anyLocked = (rows ?? []).some((r) => !!r.locked_at);
  const earliestLock = (rows ?? [])
    .map((r) => r.locked_at)
    .filter((t): t is string => !!t)
    .sort()[0];

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-baseline gap-2">
          <h2 className="text-base font-semibold">商品明細</h2>
          {anyLocked && earliestLock && (
            <span
              title="開團（status=open）後活動單價已 snapshot 鎖定，零售價變動不再影響此團"
              className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-900 dark:text-amber-200"
            >
              🔒 已鎖定 {new Date(earliestLock).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
            </span>
          )}
        </div>
        <span className="text-xs text-zinc-500">{rows?.length ?? 0} 項</span>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>規格</Th><Th>名稱</Th><Th className="text-right">單價</Th><Th className="text-right">量上限</Th><Th>鎖定時間</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={5} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">尚無商品</td></tr>
            ) : rows.map((r) => (
              <tr key={r.id}>
                <Td className="font-mono">
                  <Link
                    href={`/products?id=${r.product_id}`}
                    className="text-blue-600 hover:underline dark:text-blue-400"
                    title="點此跳轉到商品編輯頁"
                  >
                    {r.sku_code}
                  </Link>
                </Td>
                <Td>
                  <div className="text-xs text-zinc-500">{r.product_name ?? "—"}</div>
                  {r.variant_name && (
                    <div className="text-base font-bold text-zinc-900 dark:text-zinc-100">
                      {r.variant_name}
                    </div>
                  )}
                </Td>
                <Td className="text-right font-mono">${r.unit_price}</Td>
                <Td className="text-right text-xs text-zinc-500">{r.cap_qty ?? "—"}</Td>
                <Td className="text-xs text-zinc-500">
                  {r.locked_at ? new Date(r.locked_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" }) : "—"}
                </Td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-2 ${className}`}>{children}</td>;
}

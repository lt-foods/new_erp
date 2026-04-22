"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type ProductRow = {
  id: number;
  product_code: string;
  name: string;
  short_name: string | null;
  status: "draft" | "active" | "inactive" | "discontinued";
  brand_id: number | null;
  category_id: number | null;
  updated_at: string;
};

const STATUS_LABEL: Record<ProductRow["status"], string> = {
  draft: "草稿",
  active: "上架",
  inactive: "下架",
  discontinued: "停產",
};

export default function ProductListPage() {
  const [rows, setRows] = useState<ProductRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error } = await getSupabase()
          .from("products")
          .select("id, product_code, name, short_name, status, brand_id, category_id, updated_at")
          .order("updated_at", { ascending: false })
          .limit(200);
        if (cancelled) return;
        if (error) {
          setError(error.message);
          return;
        }
        setRows((data ?? []) as ProductRow[]);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const filtered = rows?.filter((r) => {
    if (!query) return true;
    const q = query.toLowerCase();
    return (
      r.product_code.toLowerCase().includes(q) ||
      r.name.toLowerCase().includes(q) ||
      (r.short_name ?? "").toLowerCase().includes(q)
    );
  });

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">商品</h1>
          <p className="text-sm text-zinc-500">
            {rows === null ? "載入中…" : `共 ${rows.length} 筆（最新 200）`}
          </p>
        </div>
        <span
          title="需先建立 rpc_upsert_product RPC（schema 規定寫入走 RPC）"
          className="cursor-not-allowed rounded-md border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-400 dark:border-zinc-700 dark:text-zinc-600"
        >
          新增商品（待 RPC）
        </span>
      </header>

      <div>
        <input
          type="search"
          placeholder="搜尋 商品編號 / 名稱"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          className="w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
          <p className="mt-2 text-xs text-red-700 dark:text-red-400">
            可能是 RLS 沒 policy、或 tenant_id 不相符；請到 Supabase dashboard → Authentication / Policies 檢查。
          </p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>商品編號</Th>
              <Th>名稱</Th>
              <Th>狀態</Th>
              <Th className="text-right">更新時間</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {filtered === undefined ? (
              <SkeletonRows />
            ) : filtered.length === 0 ? (
              <tr>
                <td colSpan={4} className="p-6 text-center text-sm text-zinc-500">
                  {rows?.length === 0 ? "還沒有商品，按「新增商品」開始建立。" : "沒有符合條件的商品。"}
                </td>
              </tr>
            ) : (
              filtered.map((r) => (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="font-mono">{r.product_code}</Td>
                  <Td>
                    <div>{r.name}</div>
                    {r.short_name && <div className="text-xs text-zinc-500">{r.short_name}</div>}
                  </Td>
                  <Td>
                    <StatusBadge status={r.status} />
                  </Td>
                  <Td className="text-right text-zinc-500">
                    {new Date(r.updated_at).toLocaleString("zh-TW")}
                  </Td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return (
    <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>
      {children}
    </th>
  );
}

function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}

function StatusBadge({ status }: { status: ProductRow["status"] }) {
  const styles: Record<ProductRow["status"], string> = {
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
          <td colSpan={4} className="p-3">
            <div className="h-4 animate-pulse rounded bg-zinc-100 dark:bg-zinc-800" />
          </td>
        </tr>
      ))}
    </>
  );
}

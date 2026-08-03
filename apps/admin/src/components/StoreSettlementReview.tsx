"use client";

// 分店端「月結對帳」列表：總部送單後這裡會出現待核對的對帳單，
// 點進去是整頁核對介面（/transfers/settlement/review?id=）。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { useAuth } from "@/components/AuthProvider";

type StoreRow = { id: number; code: string; name: string };

type Settlement = {
  id: number;
  settlement_month: string;
  store_id: number;
  payable_amount: number;
  item_count: number;
  status: "sent" | "disputed" | "confirmed" | "remitted" | "settled" | "draft" | "cancelled";
  sent_at: string | null;
  remitted_at: string | null;
};

const STATUS_LABEL: Record<string, string> = {
  sent: "待核對",
  disputed: "爭議處理中",
  confirmed: "已同意待匯款",
  remitted: "已匯款待總部確認",
  settled: "已結案",
};
const STATUS_COLOR: Record<string, string> = {
  sent: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  disputed: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  remitted: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  settled: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
};

export default function StoreSettlementReview() {
  const { user } = useAuth();
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [pickedStoreId, setPickedStoreId] = useState<number | null>(null);
  const [rows, setRows] = useState<Settlement[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await getSupabase().from("stores").select("id, code, name").order("name");
      if (cancelled) return;
      setStores((data ?? []) as StoreRow[]);
    })();
    return () => { cancelled = true; };
  }, []);

  // 帳號綁定的店（app_metadata.stores 店名 → stores 列）
  const myStores = useMemo(() => {
    const userStores = user?.app_metadata?.stores as unknown;
    if (!Array.isArray(userStores)) return [];
    return stores.filter((s) => userStores.includes(s.name));
  }, [user, stores]);
  const storeId = pickedStoreId ?? myStores[0]?.id ?? null;

  useEffect(() => {
    if (storeId === null) return;
    let cancelled = false;
    (async () => {
      const { data, error: e } = await getSupabase()
        .from("store_monthly_settlements")
        .select("id, settlement_month, store_id, payable_amount, item_count, status, sent_at, remitted_at")
        .eq("store_id", storeId)
        .in("status", ["sent", "disputed", "confirmed", "remitted", "settled"])
        .order("settlement_month", { ascending: false })
        .limit(24);
      if (cancelled) return;
      if (e) { setError(e.message); setRows([]); return; }
      setError(null);
      setRows((data ?? []) as Settlement[]);
    })();
    return () => { cancelled = true; };
  }, [storeId]);

  if (user && myStores.length === 0 && stores.length > 0) {
    return (
      <p className="rounded-md border border-amber-300 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
        此帳號未綁定分店，請聯絡總部設定。
      </p>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {myStores.length > 1 && (
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">分店</span>
          <select
            value={storeId ?? ""}
            onChange={(e) => setPickedStoreId(Number(e.target.value) || null)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            {myStores.map((s) => (
              <option key={s.id} value={s.id}>{s.name}</option>
            ))}
          </select>
        </label>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">月份</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">應付金額</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">明細行數</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">狀態</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">動作</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={5} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">目前沒有待處理的對帳單。</td></tr>
            ) : rows.map((r) => (
              <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                <td className="px-3 py-2 font-mono text-xs">{r.settlement_month?.slice(0, 7)}</td>
                <td className="px-3 py-2 text-right font-mono">
                  {/* 有明細卻 0 元 = 該月進退相抵；負數 = 退貨多於進貨，總倉要退款給店家。
                      兩種情況都用紅字寫「$0 / $-x」店家會看不懂，分開標示。 */}
                  {Number(r.payable_amount) < 0 ? (
                    <span className="text-emerald-600">
                      總倉應退 ${Math.abs(Number(r.payable_amount)).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                    </span>
                  ) : (
                    <>
                      <span className={Number(r.payable_amount) > 0 ? "text-rose-600" : "text-zinc-500"}>
                        ${Number(r.payable_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                      </span>
                      {Number(r.payable_amount) === 0 && r.item_count > 0 && (
                        <span className="block text-[10px] text-zinc-500">進貨與退貨相抵</span>
                      )}
                    </>
                  )}
                </td>
                <td className="px-3 py-2 text-right font-mono">{r.item_count}</td>
                <td className="px-3 py-2">
                  <span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[r.status] ?? ""}`}>
                    {STATUS_LABEL[r.status] ?? r.status}
                  </span>
                </td>
                <td className="px-3 py-2 text-right">
                  <Link
                    href={`/transfers/settlement/review?id=${r.id}`}
                    className={`inline-block rounded-md px-3 py-1 text-xs ${
                      r.status === "sent" || r.status === "confirmed"
                        ? "bg-blue-600 font-medium text-white hover:bg-blue-700"
                        : "border border-zinc-300 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    }`}
                  >
                    {r.status === "sent" ? "核對" : r.status === "confirmed" ? "回報匯款" : "查看"}
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

"use client";

// 召回單列表。總倉看全部、分店只看到有自己店的那幾張（RPC 內按角色過濾）。
// 開單入口不在這裡 —— 在「總倉收件匣 → 撿貨單 → 已完成」那一列的 🚨 召回。

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import Spinner from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";

type RecallRow = {
  recall_id: number;
  recall_no: string;
  source_wave_id: number | null;
  wave_code: string | null;
  wave_date: string | null;
  reason_code: string;
  reason: string | null;
  status: "draft" | "issued" | "completed" | "cancelled";
  issued_at: string | null;
  completed_at: string | null;
  created_at: string;
  line_count: number;
  store_count: number;
  sku_count: number;
  total_target: number;
  total_intercepted: number;
  total_returned: number;
  total_in_return: number;
  total_written_off: number;
  total_recovered: number;
  total_outstanding: number;
  total_customer_held: number;
  open_line_count: number;
  open_store_count: number;
};

const STATUS_LABEL: Record<RecallRow["status"], string> = {
  draft: "草稿",
  issued: "回收中",
  completed: "已結案",
  cancelled: "已作廢",
};

const STATUS_CLS: Record<RecallRow["status"], string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  issued: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  completed: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-zinc-100 text-zinc-500 line-through dark:bg-zinc-800 dark:text-zinc-500",
};

export const REASON_LABEL: Record<string, string> = {
  wrong_sku: "派錯商品",
  wrong_qty: "派錯數量",
  wrong_store: "派錯分店",
  quality: "品質異常",
  expiry: "效期問題",
  supplier_recall: "供應商召回",
  other: "其他",
};

const TABS: { key: string; label: string }[] = [
  { key: "issued", label: "回收中" },
  { key: "draft", label: "草稿" },
  { key: "completed", label: "已結案" },
  { key: "", label: "全部" },
];

const num = (v: unknown) => Number(v ?? 0);

export default function RecallsPage() {
  const [tab, setTab] = useState("issued");
  const [rows, setRows] = useState<RecallRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data, error } = await sb.rpc("rpc_recall_list", {
        p_status: tab || null,
        p_limit: 200,
      });
      if (error) throw error;
      setRows((data ?? []) as RecallRow[]);
    } catch (e) {
      setErr(translateRpcError(e));
    } finally {
      setLoading(false);
    }
  }, [tab]);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="p-4 sm:p-6">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold">🚨 召回單</h1>
          <p className="mt-0.5 text-xs text-zinc-500">
            總倉派貨錯誤後的回收追蹤。開單入口在{" "}
            <Link href="/hq/inbox?source=picking" className="text-blue-600 underline dark:text-blue-400">
              總倉收件匣 → 撿貨單 → 已完成
            </Link>
          </p>
        </div>
        <SpinButton
          onClick={load}
          className="rounded border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          重新整理
        </SpinButton>
      </div>

      <div className="mb-3 flex flex-wrap gap-1">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`rounded px-3 py-1 text-sm ${
              tab === t.key
                ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                : "border border-zinc-300 text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-400 dark:hover:bg-zinc-800"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {err && (
        <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-300">
          {err}
        </div>
      )}

      {loading ? (
        <div className="flex justify-center py-12">
          <Spinner />
        </div>
      ) : rows.length === 0 ? (
        <div className="rounded border border-dashed border-zinc-300 py-12 text-center text-sm text-zinc-500 dark:border-zinc-700">
          沒有召回單
        </div>
      ) : (
        <div className="overflow-x-auto rounded border border-zinc-200 dark:border-zinc-800">
          <table className="w-full min-w-[900px] text-sm">
            <thead className="bg-zinc-50 text-xs text-zinc-600 dark:bg-zinc-900 dark:text-zinc-400">
              <tr>
                <th className="px-3 py-2 text-left">召回單號</th>
                <th className="px-3 py-2 text-left">來源撿貨單</th>
                <th className="px-3 py-2 text-left">原因</th>
                <th className="px-2 py-2 text-right">範圍</th>
                <th className="px-2 py-2 text-right">目標</th>
                <th className="px-2 py-2 text-right">已回收</th>
                <th className="px-2 py-2 text-right">在途</th>
                <th className="px-2 py-2 text-right">未回收</th>
                <th className="px-3 py-2 text-left">狀態</th>
                <th className="px-3 py-2 text-left">建立</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const outstanding = num(r.total_outstanding);
                return (
                  <tr
                    key={r.recall_id}
                    className="border-t border-zinc-200 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-950"
                  >
                    <td className="px-3 py-2">
                      <Link
                        href={`/recalls/detail?id=${r.recall_id}`}
                        className="font-mono text-blue-600 underline dark:text-blue-400"
                      >
                        {r.recall_no}
                      </Link>
                    </td>
                    <td className="px-3 py-2 text-zinc-600 dark:text-zinc-400">
                      {r.wave_code ?? "—"}
                      {r.wave_date && <span className="ml-1 text-xs text-zinc-400">{r.wave_date}</span>}
                    </td>
                    <td className="px-3 py-2">
                      <span className="text-zinc-700 dark:text-zinc-300">
                        {REASON_LABEL[r.reason_code] ?? r.reason_code}
                      </span>
                      {r.reason && <span className="ml-1 text-xs text-zinc-500">{r.reason}</span>}
                    </td>
                    <td className="px-2 py-2 text-right text-xs text-zinc-500">
                      {num(r.store_count)} 店 / {num(r.sku_count)} 品
                    </td>
                    <td className="px-2 py-2 text-right font-semibold tabular-nums">{num(r.total_target)}</td>
                    <td className="px-2 py-2 text-right tabular-nums text-emerald-700 dark:text-emerald-400">
                      {num(r.total_recovered)}
                    </td>
                    <td className="px-2 py-2 text-right tabular-nums text-sky-700 dark:text-sky-400">
                      {num(r.total_in_return) || <span className="text-zinc-300">0</span>}
                    </td>
                    <td className="px-2 py-2 text-right tabular-nums">
                      {outstanding > 0 ? (
                        <span className="font-semibold text-red-700 dark:text-red-400">{outstanding}</span>
                      ) : (
                        <span className="text-emerald-600 dark:text-emerald-400">0</span>
                      )}
                    </td>
                    <td className="px-3 py-2">
                      <span className={`rounded px-1.5 py-0.5 text-xs font-medium ${STATUS_CLS[r.status]}`}>
                        {STATUS_LABEL[r.status]}
                      </span>
                      {r.status === "issued" && num(r.open_store_count) > 0 && (
                        <span className="ml-1 text-[11px] text-zinc-500">
                          {num(r.open_store_count)} 店未回完
                        </span>
                      )}
                    </td>
                    <td className="px-3 py-2 text-xs text-zinc-500">
                      {new Date(r.created_at).toLocaleString("zh-TW", {
                        dateStyle: "short",
                        timeStyle: "short",
                      })}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

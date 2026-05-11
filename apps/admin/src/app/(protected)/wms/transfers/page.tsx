"use client";

// 內部調撥 (Internal Transfers) — 匯總頁
// 涵蓋:
//   C. 自由轉貨 (store ↔ store)
//   E. 退貨回總倉 (store → HQ)
// 不含:
//   A. 客戶訂單派貨 (走 wave) — 在 /wms/picking + /hq/inbox 撿貨單 tab
//   B. 補貨派貨 — 在 /hq/inbox(補貨申請 → 派貨 → 派貨工作台)
//   D. 互助訂單 — 走 customer_orders,在 /transfers/aid

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import FreeTransferCreateModal from "@/components/FreeTransferCreateModal";
import OrderReturnCreateModal from "@/components/OrderReturnCreateModal";

type Loc = { id: number; name: string; type: string };

type TransferRow = {
  id: number;
  transfer_no: string;
  source_location: number;
  dest_location: number;
  status: string;
  transfer_type: string;
  notes: string | null;
  created_at: string;
  shipped_at: string | null;
  received_at: string | null;
};

const STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  confirmed: "已確認",
  shipped: "已出貨",
  received: "已收貨",
  cancelled: "已取消",
  closed: "已結案",
};
const STATUS_COLOR: Record<string, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  shipped: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  received: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  closed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-400",
};

export default function InternalTransfersPage() {
  const [transfers, setTransfers] = useState<TransferRow[] | null>(null);
  const [locs, setLocs] = useState<Map<number, Loc>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<"store_to_store" | "store_to_hq" | "all">("store_to_store");
  const [showCreate, setShowCreate] = useState(false);
  const [showReturn, setShowReturn] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("transfers")
          .select("id, transfer_no, source_location, dest_location, status, transfer_type, notes, created_at, shipped_at, received_at")
          .in("transfer_type", ["store_to_store", "return_to_hq"])
          .order("id", { ascending: false })
          .limit(200);
        if (e) throw new Error(e.message);
        const rows = (data ?? []) as TransferRow[];

        const locIds = Array.from(new Set(rows.flatMap((r) => [r.source_location, r.dest_location])));
        const locMap = new Map<number, Loc>();
        if (locIds.length > 0) {
          const { data: lr } = await sb.from("locations").select("id, name, type").in("id", locIds);
          for (const l of (lr ?? []) as Loc[]) locMap.set(l.id, l);
        }

        if (!cancelled) {
          setTransfers(rows);
          setLocs(locMap);
          setError(null);
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    })();
    return () => { cancelled = true; };
  }, [reloadKey]);

  function isStoreToHq(t: TransferRow): boolean {
    if (t.transfer_type === "return_to_hq") return true;
    const dest = locs.get(t.dest_location);
    return dest?.type === "central_warehouse";
  }

  // 退訂單(由 rpc_create_order_return 產生,note 以「[order return」開頭)
  function isOrderReturn(notes: string | null): boolean {
    return !!notes && notes.startsWith("[order return");
  }

  // 翻譯系統產生的 note tag,例如:
  //   [order return]        → 退訂單
  //   [order return: 客退]  → 退訂單:客退
  //   [rejected: aaaa]      → 已退單:aaaa
  function formatNote(notes: string | null): string {
    if (!notes) return "—";
    let s = notes;
    s = s.replace(/^\[order return: ([^\]]+)\]/, "退訂單:$1");
    s = s.replace(/^\[order return\]/, "退訂單");
    s = s.replace(/^\[rejected: ([^\]]+)\]/, "已退單:$1");
    s = s.replace(/^\[rejected\]/, "已退單");
    return s;
  }

  const filtered = useMemo(() => {
    if (!transfers) return [];
    return transfers.filter((t) => {
      if (tab === "all") return true;
      const isReturn = isStoreToHq(t);
      if (tab === "store_to_hq") return isReturn;
      return !isReturn;
    });
  }, [transfers, tab, locs]); // eslint-disable-line react-hooks/exhaustive-deps

  const counts = useMemo(() => {
    if (!transfers) return { s2s: 0, s2hq: 0 };
    return transfers.reduce(
      (acc, t) => {
        if (isStoreToHq(t)) acc.s2hq += 1;
        else acc.s2s += 1;
        return acc;
      },
      { s2s: 0, s2hq: 0 },
    );
  }, [transfers, locs]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">🔄 內部調撥</h1>
          <p className="text-sm text-zinc-500">
            店與店互轉、退貨回總倉。不含客戶訂單派貨(在派貨工作台)、互助訂單(在互助轉移單)。
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <SpinButton
            onClick={() => setShowReturn(true)}
            className="rounded-md bg-orange-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-orange-700"
          >
            ↩ 退訂單
          </SpinButton>
          <SpinButton
            onClick={() => setShowCreate(true)}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700"
          >
            + 建自由轉貨
          </SpinButton>
        </div>
      </header>

      <FreeTransferCreateModal
        open={showCreate}
        onClose={() => setShowCreate(false)}
        onCreated={() => {
          setShowCreate(false);
          setReloadKey((k) => k + 1);
        }}
      />
      <OrderReturnCreateModal
        open={showReturn}
        onClose={() => setShowReturn(false)}
        onCreated={() => {
          setShowReturn(false);
          setReloadKey((k) => k + 1);
        }}
      />

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["store_to_store", "store_to_hq", "all"] as const).map((k) => {
          const label = k === "store_to_store" ? `店 ↔ 店 (${counts.s2s})` : k === "store_to_hq" ? `退貨回總倉 (${counts.s2hq})` : `全部 (${transfers?.length ?? 0})`;
          return (
            <SpinButton
              key={k}
              onClick={() => setTab(k)}
              className={`-mb-px border-b-2 px-3 py-2 text-sm ${
                tab === k
                  ? "border-blue-600 font-semibold text-blue-700 dark:text-blue-300"
                  : "border-transparent text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
              }`}
            >
              {label}
            </SpinButton>
          );
        })}
      </div>

      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">轉貨單號</th>
              <th className="px-3 py-2">時間</th>
              <th className="px-3 py-2">來源 → 目的</th>
              <th className="px-3 py-2">狀態</th>
              <th className="px-3 py-2">備註</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {transfers === null ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">載入中…</td></tr>
            ) : filtered.length === 0 ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">目前沒有資料</td></tr>
            ) : filtered.map((t) => {
              const src = locs.get(t.source_location)?.name ?? `#${t.source_location}`;
              const dst = locs.get(t.dest_location)?.name ?? `#${t.dest_location}`;
              const isReturn = isStoreToHq(t);
              return (
                <tr key={t.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                  <td className="px-3 py-2 font-mono text-xs">
                    {t.transfer_no}
                    {isOrderReturn(t.notes) ? (
                      <span className="ml-2 inline-block rounded bg-rose-100 px-1 py-0.5 text-[10px] font-medium text-rose-700 dark:bg-rose-950 dark:text-rose-300" title="由客戶退訂單建立">🔁 退訂單</span>
                    ) : isReturn ? (
                      <span className="ml-2 inline-block rounded bg-orange-100 px-1 py-0.5 text-[10px] text-orange-700 dark:bg-orange-950 dark:text-orange-300">↩ 退貨</span>
                    ) : null}
                  </td>
                  <td className="px-3 py-2 text-xs text-zinc-500">{new Date(t.created_at).toLocaleString("zh-TW")}</td>
                  <td className="px-3 py-2 text-xs">{src} → {dst}</td>
                  <td className="px-3 py-2"><span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${STATUS_COLOR[t.status] ?? STATUS_COLOR.draft}`}>{STATUS_LABEL[t.status] ?? t.status}</span></td>
                  <td className="px-3 py-2 text-xs text-zinc-500" title={t.notes ?? undefined}>{formatNote(t.notes)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

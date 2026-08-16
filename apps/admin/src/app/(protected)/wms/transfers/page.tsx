"use client";

// 內部調撥 (Internal Transfers) — 匯總頁
// 涵蓋:
//   C. 自由轉貨 (store ↔ store)
//      (2026-08-14 曾停用建單,2026-08-16 重新開放 — 見 20260816000040_reenable_free_transfer)
//   E. 退貨回總倉 (store → HQ)
// 不含:
//   A. 客戶訂單派貨 (走 wave) — 在 /wms/picking + /hq/inbox 撿貨單 tab
//   B. 補貨派貨 — 在 /hq/inbox(補貨申請 → 派貨 → 派貨工作台)
//   D. 互助訂單 — 走 customer_orders,在 /transfers/aid

import { useEffect, useMemo, useState } from "react";
import { LoadingBlock } from "@/components/Spinner";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import FreeTransferCreateModal from "@/components/FreeTransferCreateModal";
import FreeTransferExplainerModal, { FT_EXPLAINER_HIDE_KEY } from "@/components/FreeTransferExplainerModal";
import OrderReturnCreateModal from "@/components/OrderReturnCreateModal";
import TransferDetailModal from "@/components/TransferDetailModal";
import { printViaIframe } from "@/lib/printIframe";
import { withBasePath } from "@/lib/basePath";
import { formatReturnNote } from "@/lib/returnNote";

type Loc = { id: number; name: string; type: string };

type TransferRow = {
  id: number;
  transfer_no: string;
  source_location: number;
  dest_location: number;
  status: string;
  transfer_type: string;
  customer_order_id: number | null;
  notes: string | null;
  created_at: string;
  shipped_at: string | null;
  received_at: string | null;
  items_summary: string;       // 「描述×qty、…」或「SKU×qty、…」
  total_estimated: number;     // 自由轉貨 estimated_amount 加總（0 表非自由轉貨或都未估）
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
  const [detailId, setDetailId] = useState<number | null>(null);
  // 進頁自動播放運作說明動畫（勾過「不再自動顯示」則否；header ❓ 可隨時重看）
  const [showExplainer, setShowExplainer] = useState(false);
  useEffect(() => {
    if (localStorage.getItem(FT_EXPLAINER_HIDE_KEY) !== "1") setShowExplainer(true);
  }, []);
  // 深連結：?open=<transferId> 直接開調撥單明細（月結對帳單的調撥單號連過來）
  useEffect(() => {
    const openId = new URLSearchParams(window.location.search).get("open");
    if (!openId || !(Number(openId) > 0)) return;
    const t = setTimeout(() => setDetailId(Number(openId)), 0);
    return () => clearTimeout(t);
  }, []);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("transfers")
          .select("id, transfer_no, source_location, dest_location, status, transfer_type, customer_order_id, notes, created_at, shipped_at, received_at")
          .in("transfer_type", ["store_to_store", "return_to_hq"])
          .order("id", { ascending: false })
          .limit(200);
        if (e) throw new Error(e.message);
        const baseRows = (data ?? []) as Omit<TransferRow, "items_summary" | "total_estimated">[];

        const locIds = Array.from(new Set(baseRows.flatMap((r) => [r.source_location, r.dest_location])));
        const locMap = new Map<number, Loc>();
        if (locIds.length > 0) {
          const { data: lr } = await sb.from("locations").select("id, name, type").in("id", locIds);
          for (const l of (lr ?? []) as Loc[]) locMap.set(l.id, l);
        }

        // 撈每張 transfer 的 items：自由轉貨用 description，退訂單用 sku
        const tIds = baseRows.map((r) => r.id);
        const itemsAgg = new Map<number, { parts: string[]; total: number }>();
        if (tIds.length > 0) {
          const { data: tis } = await sb
            .from("transfer_items")
            .select("transfer_id, sku_id, qty_shipped, description, estimated_amount")
            .in("transfer_id", tIds);
          const allTis = (tis ?? []) as {
            transfer_id: number; sku_id: number; qty_shipped: number;
            description: string | null; estimated_amount: number | null;
          }[];

          // 對沒 description 的 SKU 行（退訂單）需另外撈 sku_code + product name
          const realSkuIds = Array.from(new Set(
            allTis.filter((it) => !it.description).map((it) => it.sku_id).filter((x) => x != null)
          ));
          let skuLabelMap = new Map<number, string>();
          if (realSkuIds.length > 0) {
            const { data: skus } = await sb
              .from("skus")
              .select("id, sku_code, product_id")
              .in("id", realSkuIds);
            const arr = (skus ?? []) as { id: number; sku_code: string; product_id: number | null }[];
            const prodIds = Array.from(new Set(arr.map((s) => s.product_id).filter((x): x is number => x != null)));
            let prodMap = new Map<number, string>();
            if (prodIds.length > 0) {
              const { data: ps } = await sb.from("products").select("id, name").in("id", prodIds);
              prodMap = new Map(((ps ?? []) as { id: number; name: string }[]).map((p) => [p.id, p.name]));
            }
            skuLabelMap = new Map(
              arr.map((s) => [s.id, s.product_id != null ? (prodMap.get(s.product_id) ?? s.sku_code) : s.sku_code])
            );
          }

          for (const it of allTis) {
            const slot = itemsAgg.get(it.transfer_id) ?? { parts: [] as string[], total: 0 };
            const qty = Number(it.qty_shipped ?? 0);
            if (it.description) {
              slot.parts.push(`${it.description}×${qty}`);
              slot.total += Number(it.estimated_amount ?? 0);
            } else {
              const label = skuLabelMap.get(it.sku_id) ?? `#${it.sku_id}`;
              slot.parts.push(`${label}×${qty}`);
            }
            itemsAgg.set(it.transfer_id, slot);
          }
        }

        const MAX = 4;
        const rows: TransferRow[] = baseRows.map((r) => {
          const agg = itemsAgg.get(r.id) ?? { parts: [] as string[], total: 0 };
          const summary = agg.parts.length <= MAX
            ? agg.parts.join("、")
            : agg.parts.slice(0, MAX).join("、") + ` +${agg.parts.length - MAX}`;
          return { ...r, items_summary: summary, total_estimated: agg.total };
        });

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

  // 可刪除 = 自由轉貨(店↔店、無綁訂單)且還在草稿(總倉配送前);互助接力單/退訂單不可刪
  function canDelete(t: TransferRow): boolean {
    return t.status === "draft" && t.transfer_type === "store_to_store" && t.customer_order_id == null;
  }

  async function handleDelete(t: TransferRow) {
    const src = locs.get(t.source_location)?.name ?? `#${t.source_location}`;
    const dst = locs.get(t.dest_location)?.name ?? `#${t.dest_location}`;
    const ok = window.confirm(
      `確定刪除自由轉貨 ${t.transfer_no}(${src} → ${dst})?\n\n` +
      `${t.items_summary || "(無品項)"}\n` +
      `刪除後無法復原;只有「草稿」(總倉配送前)的自由轉貨可以刪除。`,
    );
    if (!ok) return;
    try {
      const { error: err } = await getSupabase().rpc("rpc_delete_free_transfer", { p_transfer_id: t.id });
      if (err) throw err;
      setError(null);
      setTransfers((prev) => (prev ?? []).filter((x) => x.id !== t.id));
    } catch (e) {
      setError(translateRpcError(e));
    }
  }

  // 翻譯系統產生的 note tag,例如:
  //   [order return]              → 退貨
  //   [order return|破損: 客退]   → 退貨・破損：客退
  //   [order return|取貨後退回]   → 退貨・客戶已取貨後退回
  //   [rejected: aaaa]            → 已退單:aaaa
  function formatNote(notes: string | null): string {
    if (!notes) return "—";
    // 退貨 note（含 |破損 / |取貨後退回 tag）交給共用 helper；非退貨 note 原樣回傳再處理其它 tag
    let s = formatReturnNote(notes);
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
          <p className="mt-0.5 text-xs text-zinc-400">
            自由轉貨用在「商品檔裡沒有的東西」（器具、樣品、零碼）；有掛顧客訂單的貨請在該店的訂單上
            「轉給別人」並勾「空中轉」—— 系統會自動出貨、接收店在「收貨」頁收掉即可。
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <SpinButton
            onClick={() => setShowExplainer(true)}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            ❓ 運作說明
          </SpinButton>
          <SpinButton
            onClick={() => setShowReturn(true)}
            className="rounded-md bg-orange-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-orange-700"
            title="把店端顧客訂單的貨從該店扣掉、送回總倉（必須關聯顧客訂單）"
          >
            ↩ 退貨回總倉
          </SpinButton>
          <SpinButton
            onClick={() => setShowCreate(true)}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700"
          >
            + 建自由轉貨
          </SpinButton>
        </div>
      </header>

      <FreeTransferExplainerModal open={showExplainer} onClose={() => setShowExplainer(false)} />

      <FreeTransferCreateModal
        open={showCreate}
        onClose={() => setShowCreate(false)}
        onCreated={(transferId) => {
          setShowCreate(false);
          setReloadKey((k) => k + 1);
          // 建完直接開明細,方便按「列印出貨單」交給司機
          setDetailId(transferId);
        }}
      />
      <OrderReturnCreateModal
        open={showReturn}
        onClose={() => setShowReturn(false)}
        onCreated={(transferId) => {
          setShowReturn(false);
          setReloadKey((k) => k + 1);
          setDetailId(transferId);
        }}
      />
      <TransferDetailModal
        open={detailId !== null}
        transferId={detailId}
        onClose={() => setDetailId(null)}
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
              <th className="px-3 py-2">品項 / 描述</th>
              <th className="px-3 py-2 text-right">估價</th>
              <th className="px-3 py-2">狀態</th>
              <th className="px-3 py-2">備註</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {transfers === null ? (
              <tr><td colSpan={8}><LoadingBlock /></td></tr>
            ) : filtered.length === 0 ? (
              <tr><td colSpan={8} className="p-6 text-center text-zinc-500">目前沒有資料</td></tr>
            ) : filtered.map((t) => {
              const src = locs.get(t.source_location)?.name ?? `#${t.source_location}`;
              const dst = locs.get(t.dest_location)?.name ?? `#${t.dest_location}`;
              const isReturn = isStoreToHq(t);
              return (
                <tr
                  key={t.id}
                  onClick={() => setDetailId(t.id)}
                  className="cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-950"
                >
                  <td className="px-3 py-2 font-mono text-xs">
                    {t.transfer_no}
                    {isOrderReturn(t.notes) ? (
                      <span className="ml-2 inline-block rounded bg-rose-100 px-1 py-0.5 text-[10px] font-medium text-rose-700 dark:bg-rose-950 dark:text-rose-300" title="由店端顧客訂單退貨回總倉建立">↩ 退貨回總倉</span>
                    ) : isReturn ? (
                      <span className="ml-2 inline-block rounded bg-orange-100 px-1 py-0.5 text-[10px] text-orange-700 dark:bg-orange-950 dark:text-orange-300" title="店端送回總倉，非由顧客訂單建立">↩ 退貨回總倉</span>
                    ) : null}
                  </td>
                  <td className="px-3 py-2 text-xs text-zinc-500">{new Date(t.created_at).toLocaleString("zh-TW")}</td>
                  <td className="px-3 py-2 text-xs">{src} → {dst}</td>
                  <td className="px-3 py-2 text-xs text-zinc-600 dark:text-zinc-300 max-w-md">
                    <span title={t.items_summary} className="line-clamp-2">{t.items_summary || "—"}</span>
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs">
                    {t.total_estimated > 0 ? `$${t.total_estimated.toFixed(0)}` : <span className="text-zinc-300">—</span>}
                  </td>
                  <td className="px-3 py-2"><span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${STATUS_COLOR[t.status] ?? STATUS_COLOR.draft}`}>{STATUS_LABEL[t.status] ?? t.status}</span></td>
                  <td className="px-3 py-2 text-xs text-zinc-500" title={t.notes ?? undefined}>{formatNote(t.notes)}</td>
                  <td className="px-3 py-2 text-right" onClick={(e) => e.stopPropagation()}>
                    <div className="flex justify-end gap-1.5">
                      <SpinButton
                        onClick={() =>
                          printViaIframe(withBasePath(`/transfers/print?transfer_id=${t.id}&copies=driver,stub`))
                        }
                        title="列印出貨單（司機聯 + 店家存根聯）"
                        className="rounded-md border border-zinc-300 px-2 py-1 text-[11px] font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                      >
                        列印出貨單
                      </SpinButton>
                      {canDelete(t) && (
                        <SpinButton
                          onClick={() => handleDelete(t)}
                          title="刪除自由轉貨（僅草稿可刪）"
                          className="rounded-md border border-red-300 px-2 py-1 text-[11px] font-medium text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950"
                        >
                          刪除
                        </SpinButton>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

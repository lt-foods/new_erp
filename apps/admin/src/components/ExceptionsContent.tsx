"use client";

// ⚠️ 異常處理 — 抽離自舊 /wms/exceptions 頁,目前由 /hq/inbox?source=exception 內嵌使用
// 集中顯示倉儲全鏈路異常:
//   1. 進貨短少 — PO fully_received 但 gr_qty < qty_ordered
//   2. 進貨破損 — GR qty_damaged > 0
//   3. 過量進貨 — GR cumulative qty_received > qty_ordered
//   4. 收貨短少 — Transfer received 但 qty_received < qty_shipped

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "./SpinButton";
import { TransferShortageResolveModal, type ShortageContext } from "./TransferShortageResolveModal";

type Tab = "all" | "po_shortage" | "po_damage" | "po_over" | "transfer_short" | "customer_shortage";

const TAB_LABEL: Record<Tab, string> = {
  all: "全部",
  po_shortage: "進貨短少",
  po_damage: "進貨破損",
  po_over: "過量進貨",
  transfer_short: "收貨短少",
  customer_shortage: "訂單短少",
};

const RESOLUTION_LABEL: Record<string, string> = {
  notified: "✓ 已通知客戶",
  cancelled: "✓ 已取消退款",
  reallocated: "✓ 已改派",
  waiting_next_po: "⏳ 等下批 PO",
};

type ExceptionRow = {
  key: string;
  type: "po_shortage" | "po_damage" | "po_over" | "transfer_short" | "customer_shortage";
  ts: string;
  doc_no: string;
  doc_link: string;
  sku_label: string;
  sku_code: string | null;
  expected: number;
  actual: number;
  diff: number;
  reason: string | null;
  extra: string;
  shortage_ctx?: ShortageContext;
  // customer_shortage 用
  customer_order_id?: number;
  shortage_resolution?: string | null;
};

export default function ExceptionsContent({
  showHeader = true,
  onCountChange,
}: {
  showHeader?: boolean;
  onCountChange?: (count: number) => void;
}) {
  const [rows, setRows] = useState<ExceptionRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("all");
  const [resolveCtx, setResolveCtx] = useState<ShortageContext | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [busy, setBusy] = useState<number | null>(null);

  async function handleCustomerShortageAction(
    orderId: number,
    action: "notified" | "cancelled" | "waiting_next_po" | "reallocated",
  ) {
    const labelMap: Record<typeof action, string> = {
      notified: "通知客戶(標記已通知)",
      cancelled: "取消(請去訂單頁正式取消退款)",
      waiting_next_po: "等下批 PO 補貨",
      reallocated: "改派(從其他店調貨)",
    };
    if (!confirm(`確定:${labelMap[action]}?`)) return;
    setBusy(orderId);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: err } = await sb.rpc("rpc_handle_shortage_order", {
        p_order_id: orderId,
        p_action: action,
        p_operator: operator,
      });
      if (err) throw err;
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();

        const { data: pickingDemand, error: e1 } = await sb
          .from("v_picking_demand_by_po")
          .select("po_id, po_no, po_status, sku_id, sku_code, sku_label, qty_ordered, gr_qty, qty_shortage")
          .gt("qty_shortage", 0);
        if (e1) throw new Error("po_shortage: " + e1.message);

        const { data: damageRows, error: e2 } = await sb
          .from("goods_receipt_items")
          .select("id, gr_id, sku_id, qty_received, qty_damaged, variance_reason, gr:goods_receipts!inner(id, gr_no, po_id, status, created_at)")
          .gt("qty_damaged", 0)
          .eq("gr.status", "confirmed");
        if (e2) throw new Error("po_damage: " + e2.message);

        const { data: overRows, error: e3 } = await sb
          .from("v_picking_demand_by_po")
          .select("po_id, po_no, po_status, sku_id, sku_code, sku_label, qty_ordered, gr_qty");
        if (e3) throw new Error("po_over: " + e3.message);

        const { data: tShortRows, error: e4 } = await sb
          .from("transfer_items")
          .select("id, transfer_id, sku_id, qty_shipped, qty_received, damage_qty, shortage_resolution, transfer:transfers!inner(id, transfer_no, status, dest_location)")
          .eq("transfer.status", "received")
          .is("shortage_resolution", null);
        if (e4) throw new Error("transfer_short: " + e4.message);

        // 5. 客戶訂單短少 — v_order_shortage,以 order_id 聚合
        const { data: custShortRows, error: e5 } = await sb
          .from("v_order_shortage")
          .select(
            "order_id, order_no, member_id, store_name, order_status, shortage_resolution, shortage_notified_at, sku_id, product_name, variant_name, sku_code, order_qty, demand_unfulfillable, order_updated_at",
          )
          .limit(20000);
        if (e5) throw new Error("customer_shortage: " + e5.message);

        const destLocs = Array.from(new Set(((tShortRows ?? []) as Array<{ transfer: { dest_location: number } | { dest_location: number }[] }>)
          .map((r) => Array.isArray(r.transfer) ? r.transfer[0]?.dest_location : r.transfer?.dest_location)
          .filter((x): x is number => typeof x === "number")));
        const destStoreMap = new Map<number, { id: number; name: string; loc_name: string }>();
        if (destLocs.length > 0) {
          const [{ data: lr }, { data: sr }] = await Promise.all([
            sb.from("locations").select("id, name").in("id", destLocs),
            sb.from("stores").select("id, name, location_id").in("location_id", destLocs),
          ]);
          const locNameMap = new Map<number, string>();
          for (const l of (lr ?? []) as Array<{ id: number; name: string }>) locNameMap.set(l.id, l.name);
          for (const s of (sr ?? []) as Array<{ id: number; name: string; location_id: number | null }>) {
            if (s.location_id !== null) {
              destStoreMap.set(s.location_id, { id: s.id, name: s.name, loc_name: locNameMap.get(s.location_id) ?? `#${s.location_id}` });
            }
          }
          for (const lid of destLocs) {
            if (!destStoreMap.has(lid)) {
              destStoreMap.set(lid, { id: 0, name: locNameMap.get(lid) ?? `#${lid}`, loc_name: locNameMap.get(lid) ?? `#${lid}` });
            }
          }
        }

        const skuIds = new Set<number>();
        for (const r of (damageRows ?? []) as Array<{ sku_id: number }>) skuIds.add(r.sku_id);
        for (const r of (tShortRows ?? []) as Array<{ sku_id: number }>) skuIds.add(r.sku_id);
        const skuMap = new Map<number, { sku_code: string | null; product_name: string | null; variant_name: string | null }>();
        if (skuIds.size > 0) {
          const { data: sk } = await sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", Array.from(skuIds));
          for (const r of (sk ?? []) as Array<{ id: number; sku_code: string | null; product_name: string | null; variant_name: string | null }>) {
            skuMap.set(r.id, { sku_code: r.sku_code, product_name: r.product_name, variant_name: r.variant_name });
          }
        }
        function skuLabel(id: number): { code: string | null; label: string } {
          const s = skuMap.get(id);
          if (!s) return { code: null, label: `品項#${id}` };
          const lbl = `${s.product_name ?? ""}${s.variant_name ? ` / ${s.variant_name}` : ""}`.trim() || `品項#${id}`;
          return { code: s.sku_code, label: lbl };
        }

        const all: ExceptionRow[] = [];

        const poShortageSeen = new Set<string>();
        for (const r of ((pickingDemand ?? []) as Array<{ po_id: number; po_no: string; po_status: string; sku_id: number; sku_code: string | null; sku_label: string; qty_ordered: number; gr_qty: number; qty_shortage: number }>)) {
          const k = `${r.po_id}:${r.sku_id}`;
          if (poShortageSeen.has(k)) continue;
          poShortageSeen.add(k);
          all.push({
            key: `po-short-${k}`,
            type: "po_shortage",
            ts: "—",
            doc_no: r.po_no,
            doc_link: `/wms/receiving`,
            sku_code: r.sku_code,
            sku_label: r.sku_label,
            expected: Number(r.qty_ordered),
            actual: Number(r.gr_qty),
            diff: Number(r.qty_shortage),
            reason: null,
            extra: "PO 已關單,差額不會到",
          });
        }

        for (const r of ((damageRows ?? []) as Array<{ id: number; gr_id: number; sku_id: number; qty_received: number; qty_damaged: number; variance_reason: string | null; gr: { id: number; gr_no: string; po_id: number; status: string; created_at: string } | { id: number; gr_no: string; po_id: number; status: string; created_at: string }[] }>)) {
          const gr = Array.isArray(r.gr) ? r.gr[0] : r.gr;
          const sl = skuLabel(r.sku_id);
          all.push({
            key: `po-dmg-${r.id}`,
            type: "po_damage",
            ts: gr?.created_at ?? "—",
            doc_no: gr?.gr_no ?? "—",
            doc_link: `/wms/receiving`,
            sku_code: sl.code,
            sku_label: sl.label,
            expected: Number(r.qty_received),
            actual: Number(r.qty_received) - Number(r.qty_damaged),
            diff: Number(r.qty_damaged),
            reason: r.variance_reason,
            extra: `已收 ${r.qty_received} 含瑕疵 ${r.qty_damaged}`,
          });
        }

        const overSeen = new Set<string>();
        for (const r of ((overRows ?? []) as Array<{ po_id: number; po_no: string; sku_id: number; sku_code: string | null; sku_label: string; qty_ordered: number; gr_qty: number }>)) {
          if (Number(r.gr_qty) <= Number(r.qty_ordered)) continue;
          const k = `${r.po_id}:${r.sku_id}`;
          if (overSeen.has(k)) continue;
          overSeen.add(k);
          all.push({
            key: `po-over-${k}`,
            type: "po_over",
            ts: "—",
            doc_no: r.po_no,
            doc_link: `/wms/receiving`,
            sku_code: r.sku_code,
            sku_label: r.sku_label,
            expected: Number(r.qty_ordered),
            actual: Number(r.gr_qty),
            diff: Number(r.gr_qty) - Number(r.qty_ordered),
            reason: null,
            extra: "供應商多送或重複入庫",
          });
        }

        for (const r of ((tShortRows ?? []) as Array<{ id: number; transfer_id: number; sku_id: number; qty_shipped: number; qty_received: number; damage_qty: number | null; transfer: { id: number; transfer_no: string; status: string; dest_location: number } | { id: number; transfer_no: string; status: string; dest_location: number }[] }>)) {
          if (Number(r.qty_received) >= Number(r.qty_shipped)) continue;
          const tr = Array.isArray(r.transfer) ? r.transfer[0] : r.transfer;
          const sl = skuLabel(r.sku_id);
          const diff = Number(r.qty_shipped) - Number(r.qty_received);
          const destInfo = tr?.dest_location ? destStoreMap.get(tr.dest_location) : undefined;
          all.push({
            key: `tshort-${r.id}`,
            type: "transfer_short",
            ts: "—",
            doc_no: tr?.transfer_no ?? "—",
            doc_link: `/wms/inbound`,
            sku_code: sl.code,
            sku_label: sl.label,
            expected: Number(r.qty_shipped),
            actual: Number(r.qty_received),
            diff,
            reason: null,
            extra: r.damage_qty && Number(r.damage_qty) > 0 ? `含破損 ${r.damage_qty}` : "分店少收或運送中遺失",
            shortage_ctx: {
              transfer_item_id: r.id,
              transfer_id: r.transfer_id,
              transfer_no: tr?.transfer_no ?? `#${r.transfer_id}`,
              sku_id: r.sku_id,
              sku_code: sl.code,
              sku_label: sl.label,
              qty_shipped: Number(r.qty_shipped),
              qty_received: Number(r.qty_received),
              shortage_qty: diff,
              dest_location: tr?.dest_location ?? 0,
              dest_store_id: destInfo && destInfo.id > 0 ? destInfo.id : null,
              dest_store_name: destInfo?.name ?? `位置 #${tr?.dest_location ?? "?"}`,
            },
          });
        }

        // 5. 客戶訂單短少 — aggregate by order_id
        type CustShortRaw = {
          order_id: number;
          order_no: string;
          member_id: number | null;
          store_name: string | null;
          order_status: string;
          shortage_resolution: string | null;
          shortage_notified_at: string | null;
          sku_id: number;
          product_name: string | null;
          variant_name: string | null;
          sku_code: string | null;
          order_qty: number;
          demand_unfulfillable: number;
          order_updated_at: string;
        };
        type CustShortAgg = {
          order_id: number;
          order_no: string;
          member_id: number | null;
          store_name: string | null;
          shortage_resolution: string | null;
          shortage_notified_at: string | null;
          short_items: { sku_label: string; demand_unfulfillable: number }[];
          total_unfulfillable: number;
          total_ordered: number;
          ts: string;
        };
        const custByOrder = new Map<number, CustShortAgg>();
        for (const r of (custShortRows ?? []) as CustShortRaw[]) {
          let s = custByOrder.get(r.order_id);
          if (!s) {
            s = {
              order_id: r.order_id,
              order_no: r.order_no,
              member_id: r.member_id,
              store_name: r.store_name,
              shortage_resolution: r.shortage_resolution,
              shortage_notified_at: r.shortage_notified_at,
              short_items: [],
              total_unfulfillable: 0,
              total_ordered: 0,
              ts: r.order_updated_at,
            };
            custByOrder.set(r.order_id, s);
          }
          const lbl = `${r.product_name ?? ""}${r.variant_name ? ` / ${r.variant_name}` : ""}`.trim() || `品項#${r.sku_id}`;
          s.short_items.push({
            sku_label: r.sku_code ? `${r.sku_code} ${lbl}` : lbl,
            demand_unfulfillable: Number(r.demand_unfulfillable),
          });
          s.total_unfulfillable += Number(r.demand_unfulfillable);
          s.total_ordered += Number(r.order_qty);
        }
        for (const s of custByOrder.values()) {
          all.push({
            key: `custshort-${s.order_id}`,
            type: "customer_shortage",
            ts: s.ts,
            doc_no: s.order_no,
            doc_link: `/orders?id=${s.order_id}`,
            sku_code: null,
            sku_label: s.short_items.map((it) => it.sku_label).join("、"),
            expected: s.total_ordered,
            actual: Math.max(0, s.total_ordered - s.total_unfulfillable),
            diff: s.total_unfulfillable,
            reason: s.shortage_resolution ? RESOLUTION_LABEL[s.shortage_resolution] ?? s.shortage_resolution : null,
            extra: `${s.store_name ?? "—"} · 會員 #${s.member_id ?? "—"} · ${s.short_items.length} 樣品項短少`,
            customer_order_id: s.order_id,
            shortage_resolution: s.shortage_resolution,
          });
        }

        if (!cancelled) {
          setRows(all);
          setError(null);
          if (onCountChange) onCountChange(all.length);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [reloadTick, onCountChange]);

  const counts = useMemo(() => {
    const c: Record<Tab, number> = { all: 0, po_shortage: 0, po_damage: 0, po_over: 0, transfer_short: 0, customer_shortage: 0 };
    for (const r of rows ?? []) {
      c.all += 1;
      c[r.type] += 1;
    }
    return c;
  }, [rows]);

  const filtered = useMemo(() => (rows ?? []).filter((r) => tab === "all" || r.type === tab), [rows, tab]);

  return (
    <div className="flex flex-1 flex-col gap-4">
      {showHeader && (
        <header>
          <h1 className="text-xl font-semibold">⚠️ 異常處理</h1>
          <p className="text-sm text-zinc-500">
            {rows === null ? "載入中…" : `共 ${rows.length} 筆異常 · 進貨短少 ${counts.po_shortage} / 進貨破損 ${counts.po_damage} / 過量 ${counts.po_over} / 收貨短少 ${counts.transfer_short} / 訂單短少 ${counts.customer_shortage}`}
          </p>
        </header>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["all", "po_shortage", "po_damage", "po_over", "transfer_short", "customer_shortage"] as const).map((t) => {
          const active = tab === t;
          return (
            <SpinButton
              key={t}
              onClick={() => setTab(t)}
              className={`-mb-px border-b-2 px-3 py-2 text-sm ${
                active
                  ? "border-rose-600 font-semibold text-rose-700 dark:text-rose-300"
                  : "border-transparent text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
              }`}
            >
              {TAB_LABEL[t]} <span className="ml-1 text-xs text-zinc-400">{counts[t]}</span>
            </SpinButton>
          );
        })}
      </div>

      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">類型</th>
              <th className="px-3 py-2">單號</th>
              <th className="px-3 py-2">品項</th>
              <th className="px-3 py-2 text-right">預期</th>
              <th className="px-3 py-2 text-right">實際</th>
              <th className="px-3 py-2 text-right">差額</th>
              <th className="px-3 py-2">原因 / 備註</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={8} className="p-6 text-center text-zinc-500">載入中…</td></tr>
            ) : filtered.length === 0 ? (
              <tr><td colSpan={8} className="p-6 text-center text-zinc-500">沒有異常,系統運作正常 ✓</td></tr>
            ) : filtered.map((r) => (
              <tr key={r.key} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                <td className="px-3 py-2">
                  <span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${
                    r.type === "po_shortage" ? "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300" :
                    r.type === "po_damage" ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300" :
                    r.type === "po_over" ? "bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300" :
                    r.type === "transfer_short" ? "bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300" :
                    "bg-fuchsia-100 text-fuchsia-800 dark:bg-fuchsia-950 dark:text-fuchsia-300"
                  }`}>{TAB_LABEL[r.type]}</span>
                </td>
                <td className="px-3 py-2 font-mono text-xs">{r.doc_no}</td>
                <td className="px-3 py-2 text-xs">
                  {r.sku_code && <div className="font-mono text-[10px] text-zinc-500">{r.sku_code}</div>}
                  <div>{r.sku_label}</div>
                </td>
                <td className="px-3 py-2 text-right font-mono text-xs">{r.expected}</td>
                <td className="px-3 py-2 text-right font-mono text-xs">{r.actual}</td>
                <td className="px-3 py-2 text-right font-mono text-xs font-bold text-rose-600">{r.diff > 0 ? `-${r.diff}` : `+${Math.abs(r.diff)}`}</td>
                <td className="px-3 py-2 text-xs text-zinc-500">
                  {r.reason && <div className="text-amber-700 dark:text-amber-400">⚠ {r.reason}</div>}
                  <div>{r.extra}</div>
                </td>
                <td className="px-3 py-2 text-xs">
                  {r.type === "transfer_short" && r.shortage_ctx ? (
                    <SpinButton
                      onClick={() => setResolveCtx(r.shortage_ctx ?? null)}
                      className="rounded-md bg-blue-600 px-3 py-1 text-xs font-semibold text-white hover:bg-blue-700"
                    >
                      處理
                    </SpinButton>
                  ) : r.type === "customer_shortage" && r.customer_order_id ? (
                    r.shortage_resolution ? (
                      <Link href={r.doc_link} className="text-blue-600 hover:underline dark:text-blue-400">看訂單 →</Link>
                    ) : (
                      <div className="flex flex-wrap justify-end gap-1">
                        <SpinButton
                          onClick={() => handleCustomerShortageAction(r.customer_order_id!, "notified")}
                          disabled={busy === r.customer_order_id}
                          className="rounded border border-blue-300 bg-blue-50 px-2 py-0.5 text-[11px] text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300"
                        >
                          通知客戶
                        </SpinButton>
                        <SpinButton
                          onClick={() => handleCustomerShortageAction(r.customer_order_id!, "waiting_next_po")}
                          disabled={busy === r.customer_order_id}
                          className="rounded border border-amber-300 bg-amber-50 px-2 py-0.5 text-[11px] text-amber-700 hover:bg-amber-100 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300"
                        >
                          等下批
                        </SpinButton>
                        <SpinButton
                          onClick={() => handleCustomerShortageAction(r.customer_order_id!, "reallocated")}
                          disabled={busy === r.customer_order_id}
                          className="rounded border border-emerald-300 bg-emerald-50 px-2 py-0.5 text-[11px] text-emerald-700 hover:bg-emerald-100 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
                        >
                          改派
                        </SpinButton>
                        <SpinButton
                          onClick={() => handleCustomerShortageAction(r.customer_order_id!, "cancelled")}
                          disabled={busy === r.customer_order_id}
                          className="rounded border border-rose-300 bg-rose-50 px-2 py-0.5 text-[11px] text-rose-700 hover:bg-rose-100 dark:border-rose-700 dark:bg-rose-950 dark:text-rose-300"
                        >
                          取消退款
                        </SpinButton>
                      </div>
                    )
                  ) : (
                    <Link href={r.doc_link} className="text-blue-600 hover:underline dark:text-blue-400">前往 →</Link>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {resolveCtx && (
        <TransferShortageResolveModal
          ctx={resolveCtx}
          onClose={() => setResolveCtx(null)}
          onSubmitted={() => {
            setResolveCtx(null);
            setReloadTick((t) => t + 1);
          }}
        />
      )}
    </div>
  );
}

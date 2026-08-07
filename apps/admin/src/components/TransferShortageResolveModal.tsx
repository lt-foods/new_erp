"use client";

// 收貨短少處理 Modal
// 顯示:
//   - transfer 短少詳情(品項、缺多少)
//   - 影響的客戶訂單(同店該品項尚未取走的行,含部分取貨單)
//   - 4 個處理選項 + 備註

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import { Modal } from "@/components/Modal";
import { ORDER_STATUS_LABEL, type OrderStatus } from "@/lib/orderStatus";

export type ShortageContext = {
  transfer_item_id: number;
  transfer_id: number;
  transfer_no: string;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  qty_shipped: number;
  qty_received: number;
  shortage_qty: number;
  dest_location: number;
  dest_store_id?: number | null;
  dest_store_name: string;
};

type Resolution = "replenish" | "cancel_orders" | "vendor_claim" | "accept";

const RESOLUTION_OPTIONS: Array<{
  value: Resolution;
  icon: string;
  title: string;
  desc: string;
  cta?: { label: string; href: string; hint: string };
}> = [
  {
    value: "replenish",
    icon: "📦",
    title: "補出貨",
    desc: "從 HQ 庫存或他店再派一筆貨給該店補上短少。",
    cta: {
      label: "前往自由轉貨建單",
      href: "/transfers/free",
      hint: "建單後回來標記為「已處理」",
    },
  },
  {
    value: "cancel_orders",
    icon: "❌",
    title: "取消客戶訂單",
    desc: "通知顧客貨拿不到,在客戶端取消訂單 / 退款。",
    cta: {
      label: "前往總倉收件匣 → 短少訂單",
      href: "/hq/inbox",
      hint: "在短少訂單來源中處理該店該品項顧客",
    },
  },
  {
    value: "vendor_claim",
    icon: "🚚",
    title: "供應商 / 物流求償",
    desc: "判定為運送途中遺失或上游短裝,跟物流/供應商求償。",
  },
  {
    value: "accept",
    icon: "✓",
    title: "接受短少 (認賠)",
    desc: "短少不追究,直接結案。庫存以實收為準。",
  },
];

type AffectedOrder = {
  id: number;
  order_no: string;
  member_id: number | null;
  pending_qty: number;
  status: string;
};

export function TransferShortageResolveModal({
  ctx,
  onClose,
  onSubmitted,
}: {
  ctx: ShortageContext;
  onClose: () => void;
  onSubmitted: () => void;
}) {
  const [resolution, setResolution] = useState<Resolution | null>(null);
  const [notes, setNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [affected, setAffected] = useState<AffectedOrder[] | null>(null);

  useEffect(() => {
    if (!ctx.dest_store_id) { setAffected([]); return; }
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("customer_orders")
          .select(`id, order_no, status, member_id,
                   items:customer_order_items!inner(qty, status, sku_id)`)
          .eq("pickup_store_id", ctx.dest_store_id)
          // partially_completed 也要看:到的品項客人先領走、沒到的那行還掛在這張單上,
          // 正是短少最直接的受害者(GRP-20260714-013-0003 (D)芋頭生乳捲就是這樣被漏掉)
          .in("status", ["pending", "confirmed", "shipping", "ready", "partially_completed"])
          .eq("items.sku_id", ctx.sku_id)
          .is("transferred_from_order_id", null)
          .limit(50);
        if (e) throw new Error(e.message);
        if (cancelled) return;
        const rows = ((data ?? []) as Array<{
          id: number;
          order_no: string;
          status: string;
          member_id: number | null;
          items: Array<{ qty: number; status: string; sku_id: number }>;
        }>).map((o) => {
          // 已取走的行不算待處理需求(部分取貨單會同時有已取 / 待取兩種行)
          const matchingItems = o.items.filter(
            (i) => i.sku_id === ctx.sku_id && !["cancelled", "expired", "picked_up"].includes(i.status),
          );
          const pending = matchingItems.reduce((s, i) => s + Number(i.qty), 0);
          return { id: o.id, order_no: o.order_no, member_id: o.member_id, pending_qty: pending, status: o.status };
        }).filter((x) => x.pending_qty > 0);
        setAffected(rows);
      } catch (e) {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : String(e));
          setAffected([]);
        }
      }
    })();
    return () => { cancelled = true; };
  }, [ctx.dest_store_id, ctx.sku_id]);

  async function submit() {
    if (!resolution) {
      setError("請選擇處理方式");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_resolve_transfer_item_shortage", {
        p_transfer_item_id: ctx.transfer_item_id,
        p_resolution: resolution,
        p_notes: notes || null,
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      onSubmitted();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  const totalAffectedQty = affected?.reduce((s, o) => s + o.pending_qty, 0) ?? 0;

  return (
    <Modal open onClose={onClose} title="處理收貨短少" maxWidth="max-w-3xl">
      {/* 短少詳情 */}
      <div className="rounded-md border border-rose-200 bg-rose-50 p-3 dark:border-rose-900 dark:bg-rose-950/40">
        <div className="flex flex-wrap items-baseline gap-2">
          <span className="font-mono text-sm">{ctx.transfer_no}</span>
          <span className="text-xs text-zinc-500">→ {ctx.dest_store_name}</span>
        </div>
        <div className="mt-1 text-sm">
          <span className="font-mono text-[11px] text-zinc-500">{ctx.sku_code}</span>
          <span className="ml-1 font-medium">{ctx.sku_label}</span>
        </div>
        <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
          <div className="rounded border border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="text-zinc-500">應收(派出)</div>
            <div className="font-mono text-base font-semibold">{ctx.qty_shipped}</div>
          </div>
          <div className="rounded border border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="text-zinc-500">實收</div>
            <div className="font-mono text-base font-semibold">{ctx.qty_received}</div>
          </div>
          <div className="rounded border border-rose-300 bg-rose-100 p-2 dark:border-rose-700 dark:bg-rose-900/40">
            <div className="text-rose-700 dark:text-rose-300">短少</div>
            <div className="font-mono text-base font-bold text-rose-700 dark:text-rose-300">{ctx.shortage_qty}</div>
          </div>
        </div>
      </div>

      {/* 影響的客戶訂單 */}
      <div className="mt-4 rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <div className="border-b border-zinc-200 px-3 py-2 text-xs font-semibold text-zinc-700 dark:border-zinc-800 dark:text-zinc-300">
          📊 該店該品項待處理客戶訂單分析
        </div>
        {affected === null ? (
          <div className="p-3 text-xs text-zinc-500">分析中…</div>
        ) : affected.length === 0 ? (
          <div className="p-3 text-xs text-zinc-500">沒有待處理客戶訂單(可能該品項顧客已取消或已取貨)。</div>
        ) : (
          <div className="px-3 py-2">
            <div className="mb-2 flex flex-wrap items-baseline gap-2 text-xs">
              <span className="text-zinc-500">{affected.length} 張訂單,合計需求</span>
              <span className="font-mono text-base font-semibold">{totalAffectedQty}</span>
              {totalAffectedQty <= ctx.shortage_qty ? (
                <span className="rounded bg-rose-100 px-1.5 py-0.5 text-[10px] font-medium text-rose-700 dark:bg-rose-950 dark:text-rose-300">
                  ⚠ 全部訂單可能受影響
                </span>
              ) : (
                <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-950 dark:text-amber-300">
                  部分訂單可能受影響(短少 {ctx.shortage_qty} / 需求 {totalAffectedQty})
                </span>
              )}
            </div>
            <ul className="max-h-32 space-y-0.5 overflow-y-auto text-xs">
              {affected.slice(0, 10).map((o) => (
                <li key={o.id} className="flex items-baseline gap-2">
                  <span className="font-mono text-zinc-700 dark:text-zinc-300">{o.order_no}</span>
                  <span className="text-zinc-500">會員 #{o.member_id ?? "—"}</span>
                  <span className="text-zinc-500">{o.pending_qty} 件</span>
                  <span className="rounded bg-zinc-100 px-1 py-0.5 text-[9px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                    {ORDER_STATUS_LABEL[o.status as OrderStatus] ?? o.status}
                  </span>
                </li>
              ))}
              {affected.length > 10 && (
                <li className="text-[11px] text-zinc-400">… 還有 {affected.length - 10} 張</li>
              )}
            </ul>
          </div>
        )}
      </div>

      {/* 處理選項 */}
      <div className="mt-4 space-y-2">
        <div className="text-xs font-semibold text-zinc-700 dark:text-zinc-300">選擇處理方式 *</div>
        {RESOLUTION_OPTIONS.map((opt) => {
          const active = resolution === opt.value;
          return (
            <label
              key={opt.value}
              className={`flex cursor-pointer items-start gap-3 rounded-md border p-3 transition ${
                active
                  ? "border-blue-400 bg-blue-50 dark:border-blue-700 dark:bg-blue-950/30"
                  : "border-zinc-200 bg-white hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:hover:bg-zinc-950"
              }`}
            >
              <input
                type="radio"
                name="resolution"
                value={opt.value}
                checked={active}
                onChange={() => setResolution(opt.value)}
                className="mt-1"
              />
              <div className="flex-1">
                <div className="flex items-baseline gap-2">
                  <span className="text-base">{opt.icon}</span>
                  <span className="font-medium">{opt.title}</span>
                </div>
                <div className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">{opt.desc}</div>
                {active && opt.cta && (
                  <div className="mt-2 rounded bg-amber-50 p-2 text-xs dark:bg-amber-950/30">
                    <Link
                      href={opt.cta.href}
                      target="_blank"
                      className="font-medium text-blue-600 hover:underline dark:text-blue-400"
                    >
                      → {opt.cta.label}(新分頁)
                    </Link>
                    <div className="mt-0.5 text-[11px] text-zinc-500">{opt.cta.hint}</div>
                  </div>
                )}
              </div>
            </label>
          );
        })}
      </div>

      {/* 備註 */}
      <label className="mt-4 block text-xs">
        <span className="block font-semibold text-zinc-700 dark:text-zinc-300">處理備註(選填)</span>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          placeholder="例如:已通知司機張先生補送 / 物流單號 XXX-XX / 顧客同意延期至下批貨..."
          rows={2}
          className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
      </label>

      {error && (
        <div className="mt-3 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="mt-4 flex justify-end gap-2">
        <SpinButton
          onClick={onClose}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          取消
        </SpinButton>
        <SpinButton
          onClick={submit}
          disabled={!resolution || submitting}
          className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
        >
          {submitting ? "處理中…" : "✓ 標記已處理"}
        </SpinButton>
      </div>
    </Modal>
  );
}

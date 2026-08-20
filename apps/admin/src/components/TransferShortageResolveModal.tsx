"use client";

// 收貨短少處理 Modal
// 顯示:
//   - transfer 短少詳情(品項、缺多少)
//   - 影響的客戶訂單(同店該品項 pending orders)
//   - 「該選哪一顆」的適用情境 + 單行道警語
//   - 6 個處理選項 + 備註
//
// ⚠️⚠️ 按下去幾乎都回不來(2026-08-21 查證,只改文案沒改行為):
//   異常清單的 transfer_short 分支條件是
//     ti.shortage_resolution IS NULL
//     OR (shortage_resolution = 'replenish' AND 該店該品項還沒收到補的貨)
//   (最新版 20260811020010_hq_exceptions_drop_customer_shortage.sql:145-160)
//   而 rpc_resolve_transfer_item_shortage 對「六個 resolution 一律」寫入
//   shortage_resolution(20260811020000:262-270,沒有任何例外)
//   ⇒ 除了 replenish,其餘 5 顆按完這一筆就從清單消失、之後無法改選別的。
//   其中 cancel_orders / vendor_claim / accept 是「僅打標記」(RPC 的 COMMENT 原話),
//   短少的貨不會回到總倉庫存。
//   實際案例:古華有一筆按了 restock_hq,貨帳回到總倉,但「已派量」只看
//   picking_wave_items(20260818000030:174-194)、不看沖回 → 沒有人能再派它,
//   8 位客人 pending 兩個月。⇒ 還有客人在等就要選 redispatch。

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

type Resolution = "redispatch" | "restock_hq" | "replenish" | "cancel_orders" | "vendor_claim" | "accept";

const RESOLUTION_OPTIONS: Array<{
  value: Resolution;
  icon: string;
  title: string;
  desc: string;
  // 按下去會發生什麼「回不去」的事 / 這顆的關鍵限制(顯示在說明下面一行,紅字)
  warn?: string;
  cta?: { label: string; href: string; hint: string };
}> = [
  {
    value: "redispatch",
    icon: "🔁",
    title: "拒絕短收 — 沖回總倉並自動重派",
    desc: "貨仍在總倉(漏裝/揀貨少拿):短少數量沖回總倉庫存,並自動開一張撿貨單重派回原店、接回原訂單(出貨/收貨後訂單自動推進)。重派撿貨單會出現在總倉收件匣的撿貨單匣。真的遺失請勿選(帳會多)。",
    warn: "還有客人在等這批貨 → 選這顆。按完這一筆會從「收貨短少」清單消失,但貨已沖回總倉、撿貨單也開好了,樓下撿完就會再送一次。",
  },
  {
    value: "restock_hq",
    icon: "🏭",
    title: "貨仍在總倉（只沖回庫存,不重派）",
    desc: "把短少數量以原出庫成本記回總倉庫存,之後再自行決定怎麼派。要自動重派回原店請選上面的「拒絕短收」。真的遺失請勿選(帳會多)。",
    warn: "⚠️ 單行道,按下去回不來:這一筆會從「收貨短少」清單消失,之後不能再改選上面的「🔁 拒絕短收(自動重派)」。而且系統仍算這批貨已經派掉了 → 沒有人能再派它。還有客人在等,請改選「🔁 拒絕短收」。",
  },
  {
    value: "replenish",
    icon: "📦",
    title: "補出貨",
    desc: "從 HQ 庫存或他店再派一筆貨給該店補上短少。",
    warn: "✓ 只有這一顆會留在清單上:標了之後這筆會繼續顯示「已標補出貨,尚未補到」,直到該店真的收到補的貨才自動消失。不確定要選哪顆時,這顆最安全。",
    cta: {
      // CTA 指補貨申請（總倉派貨）：自由轉貨的表單只給店↔店、選不到總倉，
      // 而短少多半是總倉再補一次。要從別店調貨走 /wms/transfers 的「+ 建自由轉貨」
      // （2026-08-16 重新開放，20260816000040），有掛顧客訂單的貨走「轉給別人 + 空中轉」。
      label: "前往補貨申請建單",
      href: "/restock/new",
      hint: "建單後回來標記為「已處理」；要從別店調貨改用內部調撥的「+ 建自由轉貨」",
    },
  },
  {
    value: "cancel_orders",
    icon: "❌",
    title: "取消客戶訂單",
    desc: "通知顧客貨拿不到,在客戶端取消訂單 / 退款。",
    warn: "⚠️ 單行道:這一筆會從清單消失、不能再改選別的。而且這顆只打標記 —— 短少的貨不會回到總倉庫存,帳上就是少了這些。貨其實還在總倉的話請改選上面兩顆。",
    cta: {
      // 收件匣「異常 → 訂單短少」分頁已於 2026-08-11 移除,改導去訂單管理頁處理
      label: "前往訂單管理",
      href: "/orders",
      hint: "取消該店該品項的顧客訂單後,回來標記為「已處理」",
    },
  },
  {
    value: "vendor_claim",
    icon: "🚚",
    title: "供應商 / 物流求償",
    desc: "判定為運送途中遺失或上游短裝,跟物流/供應商求償。",
    warn: "⚠️ 單行道:這一筆會從清單消失、不能再改選別的。這顆只打標記 —— 短少的貨不會回到總倉庫存(貨真的不見了才選這顆)。",
  },
  {
    value: "accept",
    icon: "✓",
    title: "接受短少 (認賠)",
    desc: "短少不追究,直接結案。庫存以實收為準。",
    warn: "⚠️ 單行道:這一筆會從清單消失、不能再改選別的。這顆只打標記 —— 短少的貨不會回到總倉庫存,等於認賠這些貨。貨其實還在總倉的話⛔不要選這顆。",
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
          .in("status", ["pending", "confirmed", "shipping", "ready"])
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
          const matchingItems = o.items.filter((i) => i.sku_id === ctx.sku_id && !["cancelled", "expired"].includes(i.status));
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

        {/* 先講「該選哪一顆」,不要讓人自己從六段說明去推理 —— 按錯不可逆(見檔頭註解) */}
        <div className="rounded-md border border-blue-200 bg-blue-50 p-3 text-xs dark:border-blue-800 dark:bg-blue-950/40">
          <div className="font-semibold text-blue-900 dark:text-blue-200">先看這個:該選哪一顆?</div>
          <ul className="mt-1 space-y-1 text-blue-900 dark:text-blue-200">
            <li>
              <span className="font-semibold">還有客人在等這批貨</span>(上面那張表有列到訂單)
              → 選 <span className="font-semibold">🔁 拒絕短收</span>:貨沖回總倉,並自動開撿貨單重派回原店。
            </li>
            <li>
              <span className="font-semibold">沒有客人在等</span>,只是想先把貨收回總倉
              → 選 <span className="font-semibold">🏭 貨仍在總倉</span>。
            </li>
            <li>
              <span className="font-semibold">還不確定 / 要另外補一批給店家</span>
              → 選 <span className="font-semibold">📦 補出貨</span>(唯一會留在清單上的一顆)。
            </li>
            <li>
              <span className="font-semibold">貨真的遺失或破損了</span>
              → 選 <span className="font-semibold">🚚 求償</span> 或 <span className="font-semibold">✓ 接受短少</span>
              (這兩顆<span className="font-semibold">不會</span>把貨補回總倉庫存)。
            </li>
          </ul>
          <div className="mt-2 rounded bg-white/70 p-2 text-[11px] leading-relaxed text-rose-800 dark:bg-zinc-900/60 dark:text-rose-300">
            <span className="font-semibold">⚠️ 按下去就回不來:</span>
            除了「📦 補出貨」,其他五顆按完之後這一筆就會從「收貨短少」清單消失,
            <span className="font-semibold">之後不能再改選別的</span>。
            <br />
            實際發生過:古華有一筆按了「🏭 貨仍在總倉」,貨帳雖然回到總倉,但系統仍然算這批貨已經派掉了,
            <span className="font-semibold">結果沒有任何人能再派它</span> → 8 位客人等了兩個月。
            <span className="font-semibold">還有客人在等,就選「🔁 拒絕短收」。</span>
          </div>
        </div>

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
                {/* 「按下去會發生什麼回不去的事」一律顯示,不只在選中時才出現 ——
                    要在按之前就看到才有用。replenish 那條是好消息(綠字),其餘是警告(紅字)。 */}
                {opt.warn && (
                  <div
                    className={`mt-1 text-[11px] leading-relaxed ${
                      opt.value === "replenish"
                        ? "text-emerald-700 dark:text-emerald-400"
                        : "text-rose-700 dark:text-rose-400"
                    }`}
                  >
                    {opt.warn}
                  </div>
                )}
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

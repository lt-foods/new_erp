"use client";

import { useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import Spinner from "@/components/Spinner";
import { getSupabase } from "@/lib/supabase";
import { orderStatusLabel } from "@/lib/orderStatus";

// 這張派貨單（可再限定單一品項）背後的顧客訂單。
// 用途是回答店家的「這幾件是誰的？」以及「多出來的幾件為什麼沒人訂？」
// 資料來自 rpc_get_orders_for_transfer（見 20260805000030 migration）。

export type OrderLine = {
  sku_id: number;
  order_id: number;
  order_no: string;
  customer: string | null;
  order_status: string;
  order_qty: number;
  campaign_id: number | null;
  match_kind: "wave" | "aid" | "store_sku";
};

// 呼叫端已經有的品項資訊 — 免得彈窗再查一次 skus
export type ModalSkuLine = { skuId: number | null; name: string; skuCode: string | null; qty: number };

export function TransferOrdersModal({
  transferId,
  transferNo,
  skuLines,
  onClose,
}: {
  transferId: number;
  transferNo: string;
  /** 要顯示的品項；只給一項 = 只看那一項 */
  skuLines: ModalSkuLine[];
  onClose: () => void;
}) {
  const [rows, setRows] = useState<OrderLine[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const onlySkuId = skuLines.length === 1 ? skuLines[0].skuId : null;

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb.rpc("rpc_get_orders_for_transfer", {
          p_transfer_id: transferId,
          p_sku_id: onlySkuId,
        });
        if (e) throw new Error(e.message);
        if (!cancelled) {
          setRows(
            ((data ?? []) as OrderLine[]).map((r) => ({ ...r, order_qty: Number(r.order_qty) })),
          );
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [transferId, onlySkuId]);

  // 依品項分組；自由轉貨沒有 sku_id，訂單一定對不到，直接歸在「無」
  const groups = useMemo(() => {
    return skuLines.map((line) => {
      const orders = (rows ?? []).filter((r) => line.skuId != null && r.sku_id === line.skuId);
      const orderQty = orders.reduce((s, r) => s + r.order_qty, 0);
      return { line, orders, orderQty, extra: line.qty - orderQty };
    });
  }, [skuLines, rows]);

  const approx = (rows ?? []).some((r) => r.match_kind === "store_sku");

  return (
    <Modal open onClose={onClose} title={`📋 訂單明細 — ${transferNo}`} maxWidth="max-w-4xl">
      <div className="space-y-4">
        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        {rows === null && !error && (
          <div className="flex items-center justify-center gap-2 py-8 text-sm text-zinc-500">
            <Spinner size={16} /> 載入訂單…
          </div>
        )}

        {rows !== null &&
          groups.map(({ line, orders, orderQty, extra }, i) => (
            <section
              key={i}
              className="overflow-hidden rounded-md border border-zinc-200 dark:border-zinc-800"
            >
              <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900/60">
                <span className="font-semibold">
                  {line.skuCode && (
                    <span className="mr-1.5 font-mono text-[10px] text-zinc-400">{line.skuCode}</span>
                  )}
                  {line.name}
                </span>
                <span className="text-xs text-zinc-500">
                  派出 <b className="text-zinc-800 dark:text-zinc-200">{line.qty}</b> 件 · 訂單{" "}
                  <b className="text-zinc-800 dark:text-zinc-200">{orderQty}</b> 件 ·{" "}
                  {orders.length} 筆
                </span>
                {extra > 0 && (
                  <span className="rounded-md bg-blue-100 px-2 py-0.5 text-[11px] font-medium text-blue-700 dark:bg-blue-950 dark:text-blue-300">
                    🎁 總倉多給 {extra} 件（沒有訂單對應）
                  </span>
                )}
                {extra < 0 && (
                  <span className="rounded-md bg-rose-100 px-2 py-0.5 text-[11px] font-medium text-rose-700 dark:bg-rose-950 dark:text-rose-300">
                    ⚠ 訂單比派出量多 {-extra} 件
                  </span>
                )}
              </div>

              {orders.length === 0 ? (
                <div className="px-3 py-4 text-center text-sm text-zinc-500">
                  這個品項查不到對應的訂單 — 可能是訂單已取消／過期，或這幾件是總倉多給的。
                  <br />
                  （補貨與自由轉貨的單本來就沒有顧客訂單，收貨頁不會給「看訂單」的入口。）
                </div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[520px] text-sm">
                    <thead>
                      <tr className="border-b border-zinc-200 text-[11px] text-zinc-500 dark:border-zinc-800">
                        <th className="px-3 py-1.5 text-left font-medium">訂單編號</th>
                        <th className="px-3 py-1.5 text-left font-medium">顧客</th>
                        <th className="px-3 py-1.5 text-right font-medium">數量</th>
                        <th className="px-3 py-1.5 text-right font-medium">狀態</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                      {orders.map((o) => (
                        <tr key={o.order_id}>
                          <td className="px-3 py-1.5 font-mono text-xs">{o.order_no}</td>
                          <td className="max-w-[260px] truncate px-3 py-1.5" title={o.customer ?? ""}>
                            {o.customer || "—"}
                          </td>
                          <td className="px-3 py-1.5 text-right font-semibold tabular-nums">
                            {o.order_qty}
                          </td>
                          <td className="px-3 py-1.5 text-right text-xs text-zinc-500">
                            {orderStatusLabel(o.order_status)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </section>
          ))}

        {approx && (
          <p className="text-[11px] text-zinc-500">
            ⚠ 這張單有品項查不到撿貨波次的開團資訊，改用「取貨店 + 品項」比對，可能會列到其他團的訂單。
          </p>
        )}
      </div>
    </Modal>
  );
}

export default TransferOrdersModal;

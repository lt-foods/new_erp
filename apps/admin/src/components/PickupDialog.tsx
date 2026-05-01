"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { withBasePath } from "@/lib/basePath";

type PickableItem = {
  id: number;
  qty: number;
  unit_price: number;
  status: string;
  sku: { id: number; sku_code: string; product_name: string | null; variant_name: string | null } | null;
};

export function PickupDialog({
  open,
  onClose,
  orderId,
  orderNo,
  onPickedUp,
}: {
  open: boolean;
  onClose: () => void;
  orderId: number;
  orderNo: string;
  onPickedUp: (result: { event_id: number; new_order_status: string; picked_count: number; active_remaining: number }) => void;
}) {
  const [items, setItems] = useState<PickableItem[] | null>(null);
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error } = await sb
        .from("customer_order_items")
        .select("id, qty, unit_price, status, sku:skus(id, sku_code, product_name, variant_name)")
        .eq("order_id", orderId)
        .in("status", ["pending", "reserved", "ready"])
        .order("id");
      if (cancelled) return;
      if (error) { setErr(error.message); return; }
      const list = (data ?? []) as unknown as PickableItem[];
      setItems(list);
      // 預設全選
      setPicked(new Set(list.map((it) => it.id)));
    })();
    return () => { cancelled = true; };
  }, [open, orderId]);

  function toggle(id: number) {
    setPicked((s) => {
      const next = new Set(s);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  async function submit() {
    if (picked.size === 0) { setErr("至少選一個 item"); return; }
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) { setErr("尚未登入"); return; }
      const { data, error } = await sb.rpc("rpc_record_pickup", {
        p_order_id: orderId,
        p_item_ids: Array.from(picked),
        p_operator: operator,
        p_notes: notes || null,
      });
      if (error) { setErr(error.message); return; }
      const result = data as { event_id: number; new_order_status: string; picked_count: number; active_remaining: number };
      // 自動開新分頁列印
      window.open(withBasePath(`/pickup/print?event_ids=${result.event_id}`), "_blank");
      onPickedUp(result);
    } finally {
      setBusy(false);
    }
  }

  const totalAmount = items
    ? items.filter((it) => picked.has(it.id)).reduce((s, it) => s + Number(it.qty) * Number(it.unit_price), 0)
    : 0;

  return (
    <Modal open={open} onClose={onClose} title={`✅ 確認取貨 — 訂單 ${orderNo}`} maxWidth="max-w-2xl">
      {items === null ? (
        <p className="text-sm text-zinc-500">載入中…</p>
      ) : items.length === 0 ? (
        <p className="text-sm text-zinc-500">無可取貨 item（皆已取貨/取消/逾期）。</p>
      ) : (
        <div className="space-y-3">
          <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="px-3 py-2 text-left text-xs">取</th>
                  <th className="px-3 py-2 text-left text-xs">商品</th>
                  <th className="px-3 py-2 text-right text-xs">數量</th>
                  <th className="px-3 py-2 text-right text-xs">單價</th>
                  <th className="px-3 py-2 text-right text-xs">小計</th>
                  <th className="px-3 py-2 text-left text-xs">狀態</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {items.map((it) => {
                  const sub = Number(it.qty) * Number(it.unit_price);
                  return (
                    <tr key={it.id} className={picked.has(it.id) ? "bg-emerald-50 dark:bg-emerald-950" : ""}>
                      <td className="px-3 py-2">
                        <input
                          type="checkbox"
                          checked={picked.has(it.id)}
                          onChange={() => toggle(it.id)}
                          className="h-4 w-4"
                        />
                      </td>
                      <td className="px-3 py-2">
                        <span className="font-medium">{it.sku?.variant_name ?? it.sku?.product_name ?? "—"}</span>
                        {it.sku?.sku_code && (
                          <span className="ml-2 font-mono text-[10px] text-zinc-400">{it.sku.sku_code}</span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right font-mono">{Number(it.qty)}</td>
                      <td className="px-3 py-2 text-right font-mono text-zinc-500">${Number(it.unit_price)}</td>
                      <td className="px-3 py-2 text-right font-mono">${sub}</td>
                      <td className="px-3 py-2 text-xs text-zinc-500">{it.status}</td>
                    </tr>
                  );
                })}
              </tbody>
              <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <td colSpan={4} className="px-3 py-2 text-right text-xs text-zinc-500">取貨小計</td>
                  <td className="px-3 py-2 text-right font-mono font-semibold">${totalAmount}</td>
                  <td className="px-3 py-2 text-xs text-zinc-500">{picked.size}/{items.length} 項</td>
                </tr>
              </tfoot>
            </table>
          </div>

          <label className="block text-sm">
            <span className="mb-1 block text-xs text-zinc-500">備註（選填）</span>
            <input
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              placeholder="如：客人現金付清"
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>

          {err && (
            <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
              <p className="font-mono text-xs">{err}</p>
            </div>
          )}

          <div className="flex justify-end gap-2">
            <button
              onClick={onClose}
              disabled={busy}
              className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              取消
            </button>
            <button
              onClick={submit}
              disabled={busy || picked.size === 0}
              className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
            >
              {busy ? "處理中…" : `✅ 確認取貨 (${picked.size} 項)`}
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}

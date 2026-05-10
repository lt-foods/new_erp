"use client";

import { useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";

const RETURNABLE_STATUSES = ["shipping", "ready", "partially_completed", "completed", "expired"] as const;

const STATUS_LABEL: Record<string, string> = {
  shipping: "派貨中",
  ready: "可取貨",
  partially_completed: "部分取貨",
  completed: "已完成",
  expired: "已過期",
};

type Store = { id: number; name: string; location_id: number | null };

type OrderRow = {
  id: number;
  order_no: string;
  status: string;
  pickup_store_id: number;
  nickname_snapshot: string | null;
  created_at: string;
};

type DeliveredSku = {
  sku_id: number;
  sku_code: string;
  sku_name: string;
  delivered: number;
  already_returned: number;
};

type LineInput = Record<number, string>;

export default function OrderReturnCreateModal({
  open,
  onClose,
  onCreated,
  prefillStoreId,
  prefillOrderId,
}: {
  open: boolean;
  onClose: () => void;
  onCreated: (transferId: number) => void;
  prefillStoreId?: number | null;
  prefillOrderId?: number | null;
}) {
  const isPrefilled = prefillOrderId != null && prefillStoreId != null;
  const [stores, setStores] = useState<Store[] | null>(null);
  const [storeId, setStoreId] = useState<number | null>(prefillStoreId ?? null);
  const [orders, setOrders] = useState<OrderRow[] | null>(null);
  const [orderId, setOrderId] = useState<number | null>(prefillOrderId ?? null);
  const [skus, setSkus] = useState<DeliveredSku[] | null>(null);
  const [qtys, setQtys] = useState<LineInput>({});
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    (async () => {
      const { data } = await getSupabase()
        .from("stores")
        .select("id, name, location_id")
        .order("name");
      setStores((data ?? []).filter((s) => s.location_id !== null) as Store[]);
    })();
  }, [open]);

  useEffect(() => {
    if (open) {
      // 重新打開時：套用 prefill（若有）
      setStoreId(prefillStoreId ?? null);
      setOrderId(prefillOrderId ?? null);
    } else {
      setStoreId(null);
      setOrderId(null);
      setOrders(null);
      setSkus(null);
      setQtys({});
      setReason("");
      setError(null);
    }
  }, [open, prefillStoreId, prefillOrderId]);

  useEffect(() => {
    if (isPrefilled) return; // prefill 模式不載清單
    setOrderId(null);
    setOrders(null);
    setSkus(null);
    setQtys({});
    if (storeId === null) return;
    (async () => {
      const { data } = await getSupabase()
        .from("customer_orders")
        .select("id, order_no, status, pickup_store_id, nickname_snapshot, created_at")
        .eq("pickup_store_id", storeId)
        .in("status", RETURNABLE_STATUSES as unknown as string[])
        .order("id", { ascending: false })
        .limit(100);
      setOrders((data ?? []) as OrderRow[]);
    })();
  }, [storeId, isPrefilled]);

  useEffect(() => {
    setSkus(null);
    setQtys({});
    if (orderId === null || storeId === null) return;
    (async () => {
      const sb = getSupabase();
      const store = stores?.find((s) => s.id === storeId);
      if (!store?.location_id) return;

      // 訂單行（customer_order_items 是已派該店的 single source of truth）
      const { data: itemRows } = await sb
        .from("customer_order_items")
        .select("sku_id, qty, status, skus(sku_code, products(name))")
        .eq("order_id", orderId)
        .not("status", "in", "(cancelled,expired)");

      const deliveredMap = new Map<number, { qty: number; sku_code: string; sku_name: string }>();
      // Supabase 自動 typegen 對 FK relation 一律當 array，雖然這裡實際是 1:1。
      // 用 unknown 中轉 cast，再對 array 取 [0]。
      type ItemRow = {
        sku_id: number;
        qty: number | null;
        skus: { sku_code: string; products: { name?: string } | { name?: string }[] | null } | Array<{
          sku_code: string;
          products: { name?: string } | { name?: string }[] | null;
        }> | null;
      };
      const rows = (itemRows ?? []) as unknown as ItemRow[];
      for (const row of rows) {
        if (row.sku_id == null) continue;
        const skuObj = Array.isArray(row.skus) ? row.skus[0] : row.skus;
        const prodObj = skuObj
          ? Array.isArray(skuObj.products)
            ? skuObj.products[0]
            : skuObj.products
          : null;
        const prev = deliveredMap.get(row.sku_id);
        const qty = Number(row.qty ?? 0);
        deliveredMap.set(row.sku_id, {
          qty: (prev?.qty ?? 0) + qty,
          sku_code: skuObj?.sku_code ?? prev?.sku_code ?? "",
          sku_name: prodObj?.name ?? prev?.sku_name ?? "",
        });
      }

      // 已退量（先前的 return_to_hq transfer 累加）
      const { data: returnedRows } = await sb
        .from("transfers")
        .select("id, transfer_type, status, source_location, transfer_items(sku_id, qty_shipped)")
        .eq("customer_order_id", orderId)
        .eq("transfer_type", "return_to_hq")
        .in("status", ["shipped", "received"])
        .eq("source_location", store.location_id);

      const returnedMap = new Map<number, number>();
      for (const t of (returnedRows ?? []) as Array<{
        transfer_items: Array<{ sku_id: number; qty_shipped: number | null }>;
      }>) {
        for (const ti of t.transfer_items ?? []) {
          if (ti.sku_id == null) continue;
          returnedMap.set(ti.sku_id, (returnedMap.get(ti.sku_id) ?? 0) + Number(ti.qty_shipped ?? 0));
        }
      }

      const list: DeliveredSku[] = Array.from(deliveredMap.entries()).map(([sku_id, info]) => ({
        sku_id,
        sku_code: info.sku_code,
        sku_name: info.sku_name,
        delivered: info.qty,
        already_returned: returnedMap.get(sku_id) ?? 0,
      }));
      list.sort((a, b) => a.sku_code.localeCompare(b.sku_code));
      setSkus(list);
    })();
  }, [orderId, storeId, stores]);

  const totalToReturn = useMemo(() => {
    if (!skus) return 0;
    return skus.reduce((acc, s) => acc + (Number(qtys[s.sku_id] ?? 0) || 0), 0);
  }, [skus, qtys]);

  const valid =
    storeId !== null &&
    orderId !== null &&
    skus !== null &&
    skus.length > 0 &&
    totalToReturn > 0 &&
    skus.every((s) => {
      const q = Number(qtys[s.sku_id] ?? 0) || 0;
      return q >= 0 && q <= s.delivered - s.already_returned;
    });

  async function handleSubmit() {
    setError(null);
    if (!valid || orderId === null) {
      setError("請至少填一個退貨數量、且不可超過可退量");
      return;
    }
    const lines = (skus ?? [])
      .map((s) => ({ sku_id: s.sku_id, qty: Number(qtys[s.sku_id] ?? 0) || 0 }))
      .filter((l) => l.qty > 0);
    if (lines.length === 0) {
      setError("請至少填一個退貨數量");
      return;
    }
    setBusy(true);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_create_order_return", {
        p_order_id: orderId,
        p_lines: lines,
        p_reason: reason.trim() || null,
      });
      if (err) throw err;
      const transferId = (data as { return_transfer_id?: number })?.return_transfer_id;
      onCreated(Number(transferId ?? 0));
    } catch (e) {
      const msg =
        e instanceof Error
          ? e.message
          : typeof e === "object" && e !== null && "message" in e
            ? String((e as { message: unknown }).message)
            : String(e);
      setError(msg);
    } finally {
      setBusy(false);
    }
  }

  const inputCls =
    "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <Modal open={open} onClose={onClose} title="↩ 退訂單回總倉" maxWidth="max-w-4xl">
      <div className="flex flex-col gap-4">
        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <p className="text-sm text-zinc-500">
          以訂單的 SKU 為準，退量不可超過訂單量 - 已退量；若店端庫存不足會被擋下。
        </p>

        {!isPrefilled && (
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">分店 *</span>
            <select
              value={storeId ?? ""}
              onChange={(e) => setStoreId(Number(e.target.value) || null)}
              className={inputCls}
              disabled={stores === null}
            >
              <option value="">— 請選 —</option>
              {(stores ?? []).map((s) => (
                <option key={s.id} value={s.id}>{s.name}</option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">訂單 *</span>
            <select
              value={orderId ?? ""}
              onChange={(e) => setOrderId(Number(e.target.value) || null)}
              className={inputCls}
              disabled={orders === null}
            >
              <option value="">
                {orders === null
                  ? storeId === null
                    ? "請先選分店"
                    : "載入中…"
                  : orders.length === 0
                    ? "此店無可退訂單"
                    : "— 請選 —"}
              </option>
              {(orders ?? []).map((o) => (
                <option key={o.id} value={o.id}>
                  {o.order_no} · {STATUS_LABEL[o.status] ?? o.status}
                  {o.nickname_snapshot ? ` · ${o.nickname_snapshot}` : ""}
                </option>
              ))}
            </select>
          </label>
        </div>
        )}

        {orderId !== null && (
          <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
            <table className="w-full text-sm">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                  <th className="px-3 py-2">SKU</th>
                  <th className="px-3 py-2">品名</th>
                  <th className="px-3 py-2 text-right">訂單量</th>
                  <th className="px-3 py-2 text-right">已退</th>
                  <th className="px-3 py-2 text-right">可退</th>
                  <th className="px-3 py-2 text-right">退多少 *</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                {skus === null ? (
                  <tr><td colSpan={6} className="p-4 text-center text-zinc-500">載入中…</td></tr>
                ) : skus.length === 0 ? (
                  <tr><td colSpan={6} className="p-4 text-center text-zinc-500">此訂單目前沒有可退的 SKU（全部已取消 / 過期）</td></tr>
                ) : skus.map((s) => {
                  const remaining = s.delivered - s.already_returned;
                  return (
                    <tr key={s.sku_id}>
                      <td className="px-3 py-2 font-mono text-xs">{s.sku_code}</td>
                      <td className="px-3 py-2">{s.sku_name || "—"}</td>
                      <td className="px-3 py-2 text-right">{s.delivered}</td>
                      <td className="px-3 py-2 text-right text-zinc-500">{s.already_returned}</td>
                      <td className="px-3 py-2 text-right font-medium">{remaining}</td>
                      <td className="px-3 py-2 text-right">
                        <input
                          type="number"
                          min="0"
                          max={remaining}
                          step="1"
                          value={qtys[s.sku_id] ?? ""}
                          onChange={(e) => setQtys((m) => ({ ...m, [s.sku_id]: e.target.value }))}
                          className={`w-24 text-right ${inputCls}`}
                          disabled={remaining <= 0}
                        />
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">退貨原因（選填）</span>
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className={`${inputCls} min-h-16`}
            placeholder="例：客戶取消、過期未取、收到瑕疵"
          />
        </label>

        <div className="flex gap-2">
          <SpinButton
            onClick={handleSubmit}
            disabled={busy || !valid}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
          >
            {busy ? "建立中…" : `建立退貨單（共退 ${totalToReturn}）`}
          </SpinButton>
          <SpinButton
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700"
          >
            取消
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

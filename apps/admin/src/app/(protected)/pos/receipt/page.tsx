"use client";

// 現場銷售小票（80mm 感熱紙）。版型比照 /pickup/print-list：
// @page size 80mm auto、等寬字、載入完自動跳列印。
//
// 它讀的是**已經結完帳的訂單**（WS- 單，品項一律 picked_up），所以可以重印 ——
// 客人要收據、或第一次沒印出來，回訂單頁點連結就好。

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

type Item = {
  id: number;
  qty: number;
  unit_price: number;
  status: string;
  sku: { sku_code: string | null; product_name: string | null; variant_name: string | null } | null;
};

type Order = {
  id: number;
  order_no: string;
  status: string;
  nickname_snapshot: string | null;
  discount_amount: number;
  payment_method: string | null;
  notes: string | null;
  created_at: string;
  member: { member_no: string; name: string | null; phone: string | null } | null;
  store: { name: string } | null;
};

const PAY_LABEL: Record<string, string> = {
  cash: "現金",
  transfer: "轉帳",
  credit_card: "刷卡",
  linepay: "LINE Pay",
  wallet: "儲值金",
};

function itemName(it: Item): string {
  const a = (it.sku?.product_name ?? "").trim();
  const b = (it.sku?.variant_name ?? "").trim();
  if (a && b && a !== b) return `${a} / ${b}`;
  return a || b || it.sku?.sku_code || "—";
}

function ReceiptInner() {
  const sp = useSearchParams();
  const orderId = sp.get("order");
  const [order, setOrder] = useState<Order | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  // 缺參數是「算得出來」的狀態，不要在 effect 裡 setState（cascading render）
  const error = loadError ?? (orderId ? null : "缺少訂單編號");

  useEffect(() => {
    if (!orderId) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [{ data: o, error: oe }, { data: its, error: ie }] = await Promise.all([
        sb
          .from("customer_orders")
          .select(
            "id, order_no, status, nickname_snapshot, discount_amount, payment_method, notes, created_at, member:members(member_no, name, phone), store:stores!customer_orders_pickup_store_id_fkey(name)",
          )
          .eq("id", Number(orderId))
          .maybeSingle(),
        sb
          .from("customer_order_items")
          .select("id, qty, unit_price, status, sku:skus(sku_code, product_name, variant_name)")
          .eq("order_id", Number(orderId))
          .order("id"),
      ]);
      if (cancelled) return;
      if (oe || ie) {
        setLoadError((oe ?? ie)?.message ?? "讀取失敗");
        return;
      }
      if (!o) {
        setLoadError("找不到訂單");
        return;
      }
      setOrder(o as unknown as Order);
      // 取消 / 作廢的列不印（客人沒付那些錢）
      setItems(
        ((its as unknown as Item[]) ?? []).filter((it) => !["cancelled", "expired"].includes(it.status)),
      );
    })();
    return () => {
      cancelled = true;
    };
  }, [orderId]);

  useEffect(() => {
    if (order && items) {
      const t = setTimeout(() => window.print(), 400);
      return () => clearTimeout(t);
    }
  }, [order, items]);

  if (error) return <div className="p-4 text-sm text-red-700">{error}</div>;
  if (!order || !items) return <div className="p-4 text-sm text-zinc-500">載入中…</div>;

  const subtotal = items.reduce((s, it) => s + Number(it.qty) * Number(it.unit_price), 0);
  const disc = Number(order.discount_amount ?? 0);
  const total = Math.max(0, subtotal - disc);
  const totalQty = items.reduce((s, it) => s + Number(it.qty), 0);
  const who = order.nickname_snapshot?.trim() || order.member?.name || "現場客";

  return (
    <>
      <style jsx global>{`
        @media print {
          @page { margin: 3mm; size: 80mm auto; }
          body { background: white !important; }
          .no-print { display: none !important; }
        }
        body { background: #f0f0f0; }
      `}</style>
      <div className="mx-auto my-4 max-w-[80mm] bg-white p-3 font-mono text-[14px] leading-tight text-black shadow print:my-0 print:shadow-none">
        <div className="no-print mb-3 flex justify-end gap-2">
          <SpinButton onClick={() => window.print()} className="rounded bg-zinc-900 px-3 py-1 text-xs text-white">
            🖨️ 列印
          </SpinButton>
          <SpinButton onClick={() => window.close()} className="rounded border border-zinc-300 px-3 py-1 text-xs">
            關閉
          </SpinButton>
        </div>

        <div className="text-center">
          <div className="text-[20px] font-bold">{order.store?.name ?? "門市"}</div>
          <div className="text-[13px]">銷售明細</div>
        </div>

        <div className="mt-2 border-y border-dashed border-black py-1.5 text-[13px]">
          <div className="text-[16px] font-bold">{who}</div>
          {order.member && !order.member.member_no.startsWith("WALKIN-") && (
            <div>
              {order.member.member_no}
              {order.member.phone && <span className="ml-2">{order.member.phone}</span>}
            </div>
          )}
          <div>單號：{order.order_no}</div>
          <div>{new Date(order.created_at).toLocaleString("zh-TW", { hour12: false })}</div>
        </div>

        <div className="mt-2 divide-y divide-dashed divide-zinc-300">
          {items.map((it) => (
            <div key={it.id} className="py-1">
              <div className="break-words text-[15px] font-bold">{itemName(it)}</div>
              <div className="flex justify-between text-[14px]">
                <span>
                  {Number(it.qty)} × ${Number(it.unit_price)}
                </span>
                <span className="font-bold">${Number(it.qty) * Number(it.unit_price)}</span>
              </div>
            </div>
          ))}
        </div>

        <div className="mt-2 border-t border-dashed border-black pt-1.5 text-[14px]">
          <div className="flex justify-between">
            <span>件數</span>
            <span>{totalQty}</span>
          </div>
          <div className="flex justify-between">
            <span>小計</span>
            <span>${subtotal}</span>
          </div>
          {disc > 0 && (
            <div className="flex justify-between font-bold">
              <span>折扣</span>
              <span>-${disc}</span>
            </div>
          )}
          <div className="mt-1 flex justify-between border-t border-black pt-1 text-[18px] font-bold">
            <span>應收</span>
            <span>${total}</span>
          </div>
          <div className="flex justify-between">
            <span>付款</span>
            <span>{PAY_LABEL[order.payment_method ?? ""] ?? order.payment_method ?? "—"}</span>
          </div>
        </div>

        <div className="mt-3 text-center text-[12px]">謝謝惠顧</div>
      </div>
    </>
  );
}

export default function PosReceiptPage() {
  return (
    <Suspense fallback={<div className="p-4 text-sm text-zinc-500">載入中…</div>}>
      <ReceiptInner />
    </Suspense>
  );
}

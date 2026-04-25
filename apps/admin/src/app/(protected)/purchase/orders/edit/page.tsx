"use client";

import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { SendPOModal } from "@/components/SendPOModal";

type Supplier = {
  id: number;
  name: string;
  code: string | null;
  preferred_po_channel: string | null;
  line_contact: string | null;
  email: string | null;
  phone: string | null;
};

type POHeader = {
  id: number;
  po_no: string;
  status: string;
  supplier_id: number;
  dest_location_id: number;
  order_date: string;
  expected_date: string | null;
  subtotal: number;
  total: number;
  payment_terms: string | null;
  notes: string | null;
  sent_at: string | null;
  sent_by: string | null;
  sent_channel: string | null;
  created_by: string | null;
  created_at: string | null;
  updated_at: string | null;
};

type Item = {
  id: number;
  sku_id: number;
  sku_code: string;
  product_name: string;
  variant_name: string | null;
  unit_uom: string | null;
  qty_ordered: number;
  qty_received: number;
  qty_returned: number;
  unit_cost: number;
  line_subtotal: number;
  notes: string | null;
};

const STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  sent: "已發送",
  partially_received: "部分到貨",
  fully_received: "全部到貨",
  closed: "已結案",
  cancelled: "已取消",
};

export default function EditPurchaseOrderPage() {
  const params = useSearchParams();
  const idStr = params.get("id");
  const id = idStr ? Number(idStr) : null;

  const [header, setHeader] = useState<POHeader | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [supplier, setSupplier] = useState<Supplier | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showSend, setShowSend] = useState(false);

  async function reload() {
    if (!id) return;
    setLoading(true);
    try {
      const supabase = getSupabase();
      const [{ data: poData, error: poErr }, { data: itemRows, error: itemErr }] = await Promise.all([
        supabase
          .from("purchase_orders")
          .select(
            "id, po_no, status, supplier_id, dest_location_id, order_date, expected_date, subtotal, total, payment_terms, notes, sent_at, sent_by, sent_channel, created_by, created_at, updated_at",
          )
          .eq("id", id)
          .maybeSingle(),
        supabase
          .from("purchase_order_items")
          .select("id, sku_id, qty_ordered, qty_received, qty_returned, unit_cost, line_subtotal, notes")
          .eq("po_id", id)
          .order("id"),
      ]);
      if (poErr || !poData) throw new Error(poErr?.message ?? "找不到採購訂單");
      if (itemErr) throw new Error(itemErr.message);
      setHeader(poData as POHeader);

      // supplier
      if (poData.supplier_id) {
        const { data: supRow } = await supabase
          .from("suppliers")
          .select("id, name, code, preferred_po_channel, line_contact, email, phone")
          .eq("id", poData.supplier_id)
          .maybeSingle();
        setSupplier((supRow as Supplier | null) ?? null);
      }

      // items + sku JOIN
      const skuIds = (itemRows ?? []).map((r) => r.sku_id);
      const { data: skuRows } = skuIds.length
        ? await supabase
            .from("skus")
            .select("id, sku_code, variant_name, base_unit, products!inner(name)")
            .in("id", skuIds)
        : { data: [] as unknown[] };

      type SkuLite = {
        id: number;
        sku_code: string;
        variant_name: string | null;
        base_unit: string | null;
        products: { name: string } | { name: string }[];
      };
      const skuMap = new Map<number, { sku_code: string; variant_name: string | null; product_name: string; unit_uom: string | null }>();
      for (const s of (skuRows as SkuLite[] | null) ?? []) {
        const prod = Array.isArray(s.products) ? s.products[0] : s.products;
        skuMap.set(s.id, {
          sku_code: s.sku_code,
          variant_name: s.variant_name,
          product_name: prod?.name ?? "?",
          unit_uom: s.base_unit ?? null,
        });
      }

      const merged: Item[] = (itemRows ?? []).map((r) => {
        const m = skuMap.get(r.sku_id);
        return {
          id: r.id,
          sku_id: r.sku_id,
          sku_code: m?.sku_code ?? "?",
          product_name: m?.product_name ?? "?",
          variant_name: m?.variant_name ?? null,
          unit_uom: m?.unit_uom ?? null,
          qty_ordered: Number(r.qty_ordered),
          qty_received: Number(r.qty_received),
          qty_returned: Number(r.qty_returned),
          unit_cost: Number(r.unit_cost),
          line_subtotal: Number(r.line_subtotal ?? 0),
          notes: r.notes,
        };
      });
      setItems(merged);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  const totals = useMemo(() => {
    const subtotal = items.reduce((s, r) => s + r.qty_ordered * r.unit_cost, 0);
    return { subtotal, withTax: subtotal * 1.05 };
  }, [items]);

  const editable = header?.status === "draft";
  const canSend = header?.status === "draft";
  const totalReceived = items.reduce((s, r) => s + r.qty_received, 0);
  const totalOrdered = items.reduce((s, r) => s + r.qty_ordered, 0);
  const recvPct = totalOrdered > 0 ? (totalReceived / totalOrdered) * 100 : 0;

  if (!id) {
    return (
      <div className="p-6 text-sm text-zinc-500">
        缺少 id 參數。請從 <a href="/purchase/orders" className="text-blue-600 underline">採購訂單列表</a> 進入。
      </div>
    );
  }
  if (loading) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  if (!header) return <div className="p-6 text-sm text-red-600">{error ?? "找不到採購訂單"}</div>;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">
            採購訂單 {header.po_no}
            <span className="ml-3 inline-block rounded bg-zinc-100 px-2 py-0.5 text-xs font-normal dark:bg-zinc-800">
              {STATUS_LABEL[header.status] ?? header.status}
            </span>
          </h1>
          <p className="text-sm text-zinc-500">
            供應商：{supplier?.name ?? "—"}
            {supplier?.code && <span className="text-zinc-400"> ({supplier.code})</span>}
            　·　訂購日 {header.order_date}　·　共 {items.length} 項
          </p>
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="grid gap-4 md:grid-cols-[280px_1fr]">
        <aside className="flex flex-col gap-4">
          {/* 摘要 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">摘要</h3>
            <dl className="space-y-2 text-sm">
              <Row label="品項數">{items.length}</Row>
              <Row label="訂購總量">{totalOrdered}</Row>
              <Row label="已收貨量">{totalReceived}</Row>
              <Row label="到貨進度">{recvPct.toFixed(0)}%</Row>
              <div className="my-2 border-t border-zinc-200 dark:border-zinc-700" />
              <Row label="未稅小計">${totals.subtotal.toFixed(0)}</Row>
              <Row label="含稅總計">
                <span className="text-lg font-semibold text-blue-600 dark:text-blue-400">
                  ${totals.withTax.toFixed(0)}
                </span>
              </Row>
            </dl>
          </section>

          {/* 動作 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">動作</h3>
            <div className="flex flex-col gap-2">
              {canSend && (
                <button
                  onClick={() => setShowSend(true)}
                  className="rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500"
                >
                  📤 發送供應商
                </button>
              )}
              {header.status === "sent" && (
                <div className="rounded-md border border-emerald-200 bg-emerald-50 p-2 text-xs text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
                  ✓ 已發送（{header.sent_channel}）
                  <br />
                  {header.sent_at && new Date(header.sent_at).toLocaleString("zh-TW")}
                </div>
              )}
              {!editable && !canSend && (
                <p className="text-xs text-zinc-500">此採購訂單已 {STATUS_LABEL[header.status]}。</p>
              )}
            </div>
          </section>

          {/* 供應商資訊 */}
          {supplier && (
            <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
              <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">供應商</h3>
              <dl className="space-y-1 text-xs">
                <Row label="名稱">{supplier.name}</Row>
                {supplier.line_contact && <Row label="LINE">{supplier.line_contact}</Row>}
                {supplier.email && <Row label="Email">{supplier.email}</Row>}
                {supplier.phone && <Row label="電話">{supplier.phone}</Row>}
                <Row label="偏好通路">{supplier.preferred_po_channel ?? "line"}</Row>
              </dl>
            </section>
          )}
        </aside>

        {/* 右側：line items 表格 */}
        <div className="flex flex-col rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-2 dark:border-zinc-800">
            <h3 className="text-sm font-semibold">📦 訂單明細</h3>
          </div>
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <Th>#</Th>
                  <Th>品名</Th>
                  <Th>單位</Th>
                  <Th className="text-right">訂購</Th>
                  <Th className="text-right">已收</Th>
                  <Th className="text-right">已退</Th>
                  <Th className="text-right">成本</Th>
                  <Th className="text-right">小計</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {items.length === 0 ? (
                  <tr>
                    <td colSpan={8} className="p-6 text-center text-zinc-500">無品項</td>
                  </tr>
                ) : (
                  items.map((r, idx) => (
                    <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                      <Td className="text-zinc-500">{idx + 1}</Td>
                      <Td>
                        <div>{r.product_name}{r.variant_name ? `-${r.variant_name}` : ""}</div>
                        <div className="font-mono text-xs text-zinc-500">{r.sku_code}</div>
                      </Td>
                      <Td className="text-zinc-500">{r.unit_uom ?? "—"}</Td>
                      <Td className="text-right">{r.qty_ordered}</Td>
                      <Td className="text-right text-emerald-600 dark:text-emerald-400">
                        {r.qty_received > 0 ? r.qty_received : "—"}
                      </Td>
                      <Td className="text-right text-zinc-500">
                        {r.qty_returned > 0 ? r.qty_returned : "—"}
                      </Td>
                      <Td className="text-right">${r.unit_cost.toFixed(0)}</Td>
                      <Td className="text-right font-mono">${(r.qty_ordered * r.unit_cost).toFixed(0)}</Td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <SendPOModal
        open={showSend}
        onClose={() => setShowSend(false)}
        poId={id}
        poNo={header.po_no}
        supplier={supplier}
        items={items.map((r) => ({
          sku_code: r.sku_code,
          product_name: r.product_name + (r.variant_name ? `-${r.variant_name}` : ""),
          qty_ordered: r.qty_ordered,
          unit_cost: r.unit_cost,
          unit_uom: r.unit_uom,
        }))}
        total={totals.subtotal}
        onSent={reload}
      />
    </div>
  );
}

function Th({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
  return (
    <th className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>
      {children}
    </th>
  );
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-3 py-2 ${className}`}>{children}</td>;
}
function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-zinc-500">{label}</dt>
      <dd className="font-mono">{children}</dd>
    </div>
  );
}

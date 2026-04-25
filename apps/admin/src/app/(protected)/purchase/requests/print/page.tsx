"use client";

import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

type PRHeader = {
  id: number;
  pr_no: string;
  source_close_date: string | null;
  notes: string | null;
};

type ItemRow = {
  id: number;
  sku_id: number;
  sku_code: string;
  product_name: string;
  variant_name: string | null;
  unit_uom: string | null;
  qty_requested: number;
  unit_cost: number;
  suggested_supplier_id: number | null;
  supplier_name: string | null;
  retail_price: number | null;
  franchise_price: number | null;
};

type SupplierFull = {
  id: number;
  name: string;
  code: string | null;
  tax_id: string | null;
  contact_name: string | null;
  phone: string | null;
  email: string | null;
  address: string | null;
  payment_terms: string | null;
  preferred_po_channel: string | null;
  line_contact: string | null;
  lead_time_days: number | null;
};

type Group = {
  supplier_id: number | null;
  supplier_name: string;
  supplier_full: SupplierFull | null;
  rows: ItemRow[];
  subtotal: number;
};

export default function PrintPurchaseRequestPage() {
  const params = useSearchParams();
  const idStr = params.get("id");
  const id = idStr ? Number(idStr) : null;

  const [header, setHeader] = useState<PRHeader | null>(null);
  const [items, setItems] = useState<ItemRow[]>([]);
  const [supplierMap, setSupplierMap] = useState<Map<number, SupplierFull>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [warehouseName, setWarehouseName] = useState<string>("");

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    (async () => {
      try {
        const supabase = getSupabase();
        const [
          { data: prData, error: prErr },
          { data: itemRows, error: itemErr },
        ] = await Promise.all([
          supabase
            .from("purchase_requests")
            .select("id, pr_no, source_close_date, notes, source_location_id")
            .eq("id", id)
            .maybeSingle(),
          supabase
            .from("purchase_request_items")
            .select("id, sku_id, qty_requested, unit_cost, suggested_supplier_id, retail_price, franchise_price")
            .eq("pr_id", id)
            .order("suggested_supplier_id", { nullsFirst: false })
            .order("id"),
        ]);

        if (cancelled) return;
        if (prErr || !prData) throw new Error(prErr?.message ?? "找不到採購單");
        if (itemErr) throw new Error(itemErr.message);

        setHeader(prData as PRHeader);

        if (prData.source_location_id) {
          const { data: locRow } = await supabase
            .from("locations")
            .select("name")
            .eq("id", prData.source_location_id)
            .maybeSingle();
          setWarehouseName(locRow?.name ?? "");
        }

        const skuIds = (itemRows ?? []).map((r) => r.sku_id);
        const supIds = Array.from(
          new Set((itemRows ?? []).map((r) => r.suggested_supplier_id).filter((x): x is number => !!x)),
        );

        const [{ data: skuRows }, { data: supRows }] = await Promise.all([
          skuIds.length
            ? supabase
                .from("skus")
                .select("id, sku_code, variant_name, base_unit, products!inner(name)")
                .in("id", skuIds)
            : Promise.resolve({ data: [] as unknown[] }),
          supIds.length
            ? supabase
                .from("suppliers")
                .select(
                  "id, name, code, tax_id, contact_name, phone, email, address, payment_terms, preferred_po_channel, line_contact, lead_time_days",
                )
                .in("id", supIds)
            : Promise.resolve({ data: [] as unknown[] }),
        ]);

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

        const supFullMap = new Map<number, SupplierFull>();
        for (const s of (supRows as SupplierFull[] | null) ?? []) {
          supFullMap.set(s.id, s);
        }
        const supMap = new Map<number, string>();
        for (const [id, s] of supFullMap) supMap.set(id, s.name);
        setSupplierMap(supFullMap);

        const merged: ItemRow[] = (itemRows ?? []).map((r) => {
          const m = skuMap.get(r.sku_id);
          return {
            id: r.id,
            sku_id: r.sku_id,
            sku_code: m?.sku_code ?? "?",
            product_name: m?.product_name ?? "?",
            variant_name: m?.variant_name ?? null,
            unit_uom: m?.unit_uom ?? null,
            qty_requested: Number(r.qty_requested),
            unit_cost: Number(r.unit_cost),
            suggested_supplier_id: r.suggested_supplier_id,
            supplier_name: r.suggested_supplier_id
              ? supMap.get(r.suggested_supplier_id) ?? "—"
              : null,
            retail_price: r.retail_price !== null && r.retail_price !== undefined ? Number(r.retail_price) : null,
            franchise_price: r.franchise_price !== null && r.franchise_price !== undefined ? Number(r.franchise_price) : null,
          };
        });

        setItems(merged);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id]);

  const groups: Group[] = useMemo(() => {
    const m = new Map<string, Group>();
    for (const r of items) {
      const key = String(r.suggested_supplier_id ?? "__none__");
      if (!m.has(key)) {
        m.set(key, {
          supplier_id: r.suggested_supplier_id,
          supplier_name: r.supplier_name ?? "未指派供應商",
          supplier_full: r.suggested_supplier_id
            ? supplierMap.get(r.suggested_supplier_id) ?? null
            : null,
          rows: [],
          subtotal: 0,
        });
      }
      const g = m.get(key)!;
      g.rows.push(r);
      g.subtotal += r.qty_requested * r.unit_cost;
    }
    // 未指派排最後
    return Array.from(m.values()).sort((a, b) => {
      if (a.supplier_id === null) return 1;
      if (b.supplier_id === null) return -1;
      return a.supplier_name.localeCompare(b.supplier_name, "zh-TW");
    });
  }, [items, supplierMap]);

  const grandTotal = groups.reduce((s, g) => s + g.subtotal, 0);
  const grandWithTax = grandTotal * 1.05;

  if (!id) return <div className="p-6">缺少 id 參數</div>;
  if (error) return <div className="p-6 text-red-600">{error}</div>;
  if (!header) return <div className="p-6 text-zinc-500">載入中…</div>;

  return (
    <div className="bg-white p-8 text-black print:p-4">
      <style>{`
        @media print {
          @page { size: A4; margin: 1cm; }
          .no-print { display: none !important; }
          body { background: white; }
          table { font-size: 10pt; }
          .group-section { break-inside: avoid; }
        }
      `}</style>

      <div className="no-print mb-4 flex justify-end gap-2">
        <button
          onClick={() => window.print()}
          className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500"
        >
          列印
        </button>
      </div>

      <header className="mb-4 text-center">
        <h1 className="text-2xl font-bold">
          {warehouseName || "總倉"} - 內部採購單
        </h1>
        <div className="mt-1 text-sm text-zinc-600">
          單號 {header.pr_no}　·　結單日 {header.source_close_date ?? "—"}
        </div>
      </header>

      {groups.map((g) => (
        <section key={g.supplier_id ?? "none"} className="group-section mb-6">
          <div
            className={`mb-2 flex items-baseline justify-between border-b-2 pb-1 text-sm font-semibold ${
              g.supplier_id === null ? "border-red-500 text-red-700" : "border-zinc-700"
            }`}
          >
            <span>供應商：{g.supplier_name}{g.supplier_full?.code ? `（${g.supplier_full.code}）` : ""}（{g.rows.length} 項）</span>
          </div>

          {g.supplier_full && (
            <div className="mb-2 grid grid-cols-2 gap-x-4 gap-y-0.5 rounded border border-zinc-200 bg-zinc-50 p-2 text-xs">
              {g.supplier_full.tax_id && (
                <Field label="統編">{g.supplier_full.tax_id}</Field>
              )}
              {g.supplier_full.contact_name && (
                <Field label="聯絡人">{g.supplier_full.contact_name}</Field>
              )}
              {g.supplier_full.phone && (
                <Field label="電話">{g.supplier_full.phone}</Field>
              )}
              {g.supplier_full.email && (
                <Field label="Email">{g.supplier_full.email}</Field>
              )}
              {g.supplier_full.address && (
                <Field label="地址" full>
                  {g.supplier_full.address}
                </Field>
              )}
              {g.supplier_full.payment_terms && (
                <Field label="付款條件">{g.supplier_full.payment_terms}</Field>
              )}
              {g.supplier_full.preferred_po_channel && (
                <Field label="下單通路">
                  {g.supplier_full.preferred_po_channel}
                  {g.supplier_full.line_contact ? `（${g.supplier_full.line_contact}）` : ""}
                </Field>
              )}
              {g.supplier_full.lead_time_days != null && (
                <Field label="交期">{g.supplier_full.lead_time_days} 天</Field>
              )}
            </div>
          )}

          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="border-b border-zinc-400 bg-zinc-100 text-xs">
                <Th>項次</Th>
                <Th>商品編號</Th>
                <Th>商品名稱</Th>
                <Th className="text-right">數量</Th>
                <Th className="text-right">成本</Th>
                <Th className="text-right">售價</Th>
                <Th className="text-right">分店價</Th>
                <Th className="text-right">利潤</Th>
                <Th className="text-right">利潤小計</Th>
                <Th className="text-right">小計</Th>
              </tr>
            </thead>
            <tbody>
              {g.rows.map((r, idx) => {
                const profit = (r.retail_price ?? 0) - r.unit_cost;
                const profitSubtotal = profit * r.qty_requested;
                const subtotal = r.qty_requested * r.unit_cost;
                return (
                  <tr key={r.id} className="border-b border-zinc-200">
                    <Td>{idx + 1}</Td>
                    <Td className="font-mono">{r.sku_code}</Td>
                    <Td>
                      {r.product_name}
                      {r.variant_name ? `-${r.variant_name}` : ""}
                    </Td>
                    <Td className="text-right">
                      {r.qty_requested}
                      {r.unit_uom ?? ""}
                    </Td>
                    <Td className="text-right">${r.unit_cost.toFixed(0)}</Td>
                    <Td className="text-right">
                      {r.retail_price !== null ? `$${r.retail_price.toFixed(0)}` : "—"}
                    </Td>
                    <Td className="text-right">
                      {r.franchise_price !== null ? `$${r.franchise_price.toFixed(0)}` : "—"}
                    </Td>
                    <Td className="text-right">${profit.toFixed(0)}</Td>
                    <Td className="text-right">${profitSubtotal.toFixed(0)}</Td>
                    <Td className="text-right font-medium">${subtotal.toFixed(0)}</Td>
                  </tr>
                );
              })}
              <tr className="bg-zinc-50 text-sm font-semibold">
                <td colSpan={9} className="px-2 py-1 text-right">
                  小計
                </td>
                <td className="px-2 py-1 text-right">${g.subtotal.toFixed(0)}</td>
              </tr>
            </tbody>
          </table>
        </section>
      ))}

      <div className="mt-6 border-t-2 border-zinc-700 pt-3 text-right">
        <div className="text-sm text-zinc-600">未稅總計：${grandTotal.toFixed(1)}</div>
        <div className="text-2xl font-bold">${grandWithTax.toFixed(1)}</div>
      </div>

      {header.notes && (
        <div className="mt-4 border-t border-zinc-300 pt-2 text-sm">
          <div className="font-semibold">備註：</div>
          <div className="whitespace-pre-wrap">{header.notes}</div>
        </div>
      )}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-2 py-1 text-left ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-2 py-1 ${className}`}>{children}</td>;
}
function Field({
  label,
  children,
  full = false,
}: {
  label: string;
  children: React.ReactNode;
  full?: boolean;
}) {
  return (
    <div className={full ? "col-span-2" : ""}>
      <span className="text-zinc-500">{label}：</span>
      <span className="text-zinc-800">{children}</span>
    </div>
  );
}

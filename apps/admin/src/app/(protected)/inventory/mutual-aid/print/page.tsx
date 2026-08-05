"use client";

// 互助交流板列印頁（A4）。
// 由 /inventory/mutual-aid 的「🖨️ 列印」用隱藏 iframe 載入（printViaIframe），
// 所以這頁要自己抓資料、抓完自動 window.print()，查詢條件完全對齊列表頁
// （status = active、created_at desc、limit 200，type 由 query 帶入）。

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

type PostType = "offer" | "request";

type Row = {
  id: number;
  post_type: PostType;
  offering_store_id: number;
  sku_id: number | null;
  qty_available: number;
  qty_remaining: number;
  expires_at: string;
  note: string | null;
  source_customer_order_id: number | null;
  spot_price: number | null;
  spot_title: string | null;
  spot_unit: string | null;
  spot_visible_to_other_stores: boolean;
  created_at: string;
  store_name: string;
  sku_label: string;
  source_order_no: string | null;
  replies_count: number;
};

type SkuOption = { id: number; sku_code: string; product_name: string; variant_name: string | null };

const TYPE_LABEL: Record<PostType, string> = { offer: "釋出", request: "需求" };

const FILTER_LABEL: Record<"all" | "request" | "offer", string> = {
  all: "全部",
  request: "需求中",
  offer: "釋出中",
};

export default function MutualAidPrintPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const sp = useSearchParams();
  const typeParam = sp.get("type");
  const filter: "all" | "request" | "offer" =
    typeParam === "request" || typeParam === "offer" ? typeParam : "all";

  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [printedAt, setPrintedAt] = useState<string>("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      // 列印時間在 client 決定（SSR 算出來的值會 hydration mismatch）
      setPrintedAt(fmtDt(new Date().toISOString()));
      try {
        const sb = getSupabase();
        let q = sb
          .from("mutual_aid_board")
          .select("id, post_type, offering_store_id, sku_id, qty_available, qty_remaining, expires_at, note, source_customer_order_id, spot_price, spot_title, spot_unit, spot_visible_to_other_stores, created_at")
          .eq("status", "active")
          .order("created_at", { ascending: false })
          .limit(200);
        if (filter !== "all") q = q.eq("post_type", filter);
        const { data, error: e } = await q;
        if (e) throw new Error(e.message);
        const base = (data ?? []) as Omit<Row, "store_name" | "sku_label" | "source_order_no" | "replies_count">[];
        if (base.length === 0) {
          if (!cancelled) setRows([]);
          return;
        }
        // 手打的手動現貨沒有 sku_id，別把 null 塞進 .in() 查詢
        const skuIds = Array.from(new Set(base.map((r) => r.sku_id).filter((x): x is number => x != null)));
        const storeIds = Array.from(new Set(base.map((r) => r.offering_store_id)));
        const boardIds = base.map((r) => r.id);
        const orderIds = Array.from(
          new Set(base.map((r) => r.source_customer_order_id).filter((x): x is number => x != null)),
        );

        const [skuRes, storeRes, replyRes, orderRes] = await Promise.all([
          skuIds.length > 0
            ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds)
            : Promise.resolve({ data: [], error: null }),
          sb.from("stores").select("id, name").in("id", storeIds),
          sb.from("mutual_aid_replies").select("board_id").in("board_id", boardIds),
          orderIds.length > 0
            ? sb.from("customer_orders").select("id, order_no").in("id", orderIds)
            : Promise.resolve({ data: [], error: null }),
        ]);
        const skuMap = new Map<number, SkuOption>(((skuRes.data ?? []) as SkuOption[]).map((s) => [s.id, s]));
        const storeMap = new Map<number, string>(
          ((storeRes.data ?? []) as { id: number; name: string }[]).map((s) => [s.id, s.name]),
        );
        const orderMap = new Map<number, string>(
          ((orderRes.data ?? []) as { id: number; order_no: string }[]).map((o) => [o.id, o.order_no]),
        );
        const replyCount = new Map<number, number>();
        for (const r of (replyRes.data ?? []) as { board_id: number }[]) {
          replyCount.set(r.board_id, (replyCount.get(r.board_id) ?? 0) + 1);
        }
        const enriched: Row[] = base.map((r) => {
          const sku = r.sku_id != null ? skuMap.get(r.sku_id) : undefined;
          return {
            ...r,
            store_name: storeMap.get(r.offering_store_id) ?? `#${r.offering_store_id}`,
            sku_label: sku
              ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""} (${sku.sku_code})`
              : r.sku_id != null
                ? `品項#${r.sku_id}`
                : r.spot_title ?? "（未命名）",
            source_order_no: r.source_customer_order_id
              ? orderMap.get(r.source_customer_order_id) ?? null
              : null,
            replies_count: replyCount.get(r.id) ?? 0,
          };
        });
        if (!cancelled) setRows(enriched);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [filter]);

  // 載入完自動觸發列印（沒資料也印，讓「今天板上是空的」也留得下紙本）
  useEffect(() => {
    if (rows === null) return;
    const t = setTimeout(() => window.print(), 400);
    return () => clearTimeout(t);
  }, [rows]);

  if (error) return <div className="p-6 text-sm text-red-700">{error}</div>;
  if (rows === null) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  const requestCount = rows.filter((r) => r.post_type === "request").length;
  const offerCount = rows.filter((r) => r.post_type === "offer").length;

  return (
    <div className="bg-white p-8 text-black print:p-0">
      <style>{`
        @media print {
          @page { size: A4 landscape; margin: 1cm; }
          .no-print { display: none !important; }
          body { background: white; }
          table { font-size: 9pt; }
          tr { break-inside: avoid; }
          thead { display: table-header-group; }
        }
      `}</style>

      <div className="no-print mb-4 flex justify-end gap-2">
        <SpinButton
          onClick={() => window.print()}
          className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500"
        >
          🖨️ 列印
        </SpinButton>
      </div>

      <header className="mb-3">
        <h1 className="text-xl font-bold">互助交流板 — {FILTER_LABEL[filter]}</h1>
        <div className="mt-1 flex flex-wrap gap-x-4 text-xs text-zinc-600">
          <span>列印時間 {printedAt}</span>
          <span>共 {rows.length} 則（需求 {requestCount}・釋出 {offerCount}）</span>
          <span>僅列出進行中的貼文</span>
        </div>
      </header>

      {rows.length === 0 ? (
        <div className="border border-dashed border-zinc-400 p-8 text-center text-sm text-zinc-500">
          目前沒有進行中的{filter === "request" ? "需求" : filter === "offer" ? "釋出" : ""}貼文
        </div>
      ) : (
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="border-b border-zinc-500 bg-zinc-100 text-xs">
              <Th className="w-8">#</Th>
              <Th className="w-12">類型</Th>
              <Th className="w-24">店別</Th>
              <Th>商品 / 品項</Th>
              <Th className="w-20 text-right">數量</Th>
              <Th className="w-20 text-right">單價</Th>
              <Th className="w-32">到期</Th>
              <Th className="w-24">源訂單</Th>
              <Th>備註</Th>
              <Th className="w-12 text-right">留言</Th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, idx) => {
              const isManual = r.post_type === "offer" && r.source_customer_order_id == null;
              return (
                <tr key={r.id} className="border-b border-zinc-300 align-top">
                  <Td>{idx + 1}</Td>
                  <Td className="font-medium">{TYPE_LABEL[r.post_type]}</Td>
                  <Td>{r.store_name}</Td>
                  <Td>
                    {r.sku_label}
                    {isManual && <span className="ml-1 text-[10px] text-zinc-500">[手動]</span>}
                    {r.post_type === "offer" && !r.spot_visible_to_other_stores && (
                      <span className="ml-1 text-[10px] text-zinc-500">[限本店會員]</span>
                    )}
                    {r.spot_title && r.sku_id != null && (
                      <div className="text-[10px] text-zinc-500">App 標題：{r.spot_title}</div>
                    )}
                  </Td>
                  <Td className="text-right font-mono">
                    {r.qty_remaining}
                    {r.spot_unit ?? ""}
                    {r.qty_remaining !== r.qty_available && (
                      <span className="ml-1 text-[10px] text-zinc-500">/ 原 {r.qty_available}</span>
                    )}
                  </Td>
                  <Td className="text-right font-mono">
                    {r.spot_price != null ? `$${r.spot_price.toLocaleString()}` : "—"}
                  </Td>
                  <Td className="whitespace-nowrap">{fmtDt(r.expires_at)}</Td>
                  <Td className="font-mono">{r.source_order_no ?? "—"}</Td>
                  <Td>{r.note ?? ""}</Td>
                  <Td className="text-right">{r.replies_count}</Td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-2 py-1 text-left font-semibold ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-2 py-1 ${className}`}>{children}</td>;
}

function fmtDt(s: string) {
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return s;
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  return `${y}/${m}/${day} ${hh}:${mm}`;
}

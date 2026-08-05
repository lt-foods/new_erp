"use client";

// 互助交流板「小白單」（80mm 感熱紙，給司機帶著跑的單）。
//
// 和同目錄的 /print（A4 整板清單）分工：那張是店裡自己看的總表，
// 這張是**一筆一張**、司機拿在手上對貨簽收用的。
//
// 由列表頁 / 貼文 modal 的「🖨️ 小白單」用隱藏 iframe 載入（printViaIframe），
// 所以這頁自己抓資料、抓完自動 window.print()。
// ?ids=1,2,3 可一次印多張（每張自成一頁），單筆就傳一個 id。

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

type PostType = "offer" | "request";

type Slip = {
  id: number;
  post_type: PostType;
  qty_remaining: number;
  qty_available: number;
  expires_at: string;
  note: string | null;
  created_at: string;
  spot_price: number | null;
  spot_unit: string | null;
  spot_title: string | null;
  source_customer_order_id: number | null;
  store_name: string;
  store_address: string | null;
  product_name: string;
  sku_code: string | null;
  source_order_no: string | null;
};

type RawPost = {
  id: number;
  post_type: PostType;
  offering_store_id: number;
  sku_id: number | null;
  qty_available: number;
  qty_remaining: number;
  expires_at: string;
  note: string | null;
  created_at: string;
  spot_price: number | null;
  spot_unit: string | null;
  spot_title: string | null;
  source_customer_order_id: number | null;
};

export default function MutualAidSlipPage() {
  return (
    <Suspense fallback={<div className="p-4 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const sp = useSearchParams();
  // 單筆用 ?id=，多筆用 ?ids=1,2,3（兩個都吃，方便之後做整批列印）
  const idsParam = sp.get("ids") ?? sp.get("id") ?? "";
  const ids = idsParam.split(",").map(Number).filter((n) => Number.isFinite(n) && n > 0);

  const [slips, setSlips] = useState<Slip[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [printedAt, setPrintedAt] = useState("");

  useEffect(() => {
    if (ids.length === 0) return;
    let cancelled = false;
    (async () => {
      // 列印時間在 client 決定（SSR 算出來的值會 hydration mismatch）
      setPrintedAt(fmtDt(new Date().toISOString()));
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("mutual_aid_board")
          .select("id, post_type, offering_store_id, sku_id, qty_available, qty_remaining, expires_at, note, created_at, spot_price, spot_unit, spot_title, source_customer_order_id")
          .in("id", ids);
        if (e) throw new Error(e.message);
        const posts = (data ?? []) as RawPost[];
        if (posts.length === 0) {
          if (!cancelled) setSlips([]);
          return;
        }
        // 手打的手動現貨沒有 sku_id，別把 null 塞進 .in() 查詢
        const skuIds = Array.from(new Set(posts.map((p) => p.sku_id).filter((x): x is number => x != null)));
        const storeIds = Array.from(new Set(posts.map((p) => p.offering_store_id)));
        const orderIds = Array.from(
          new Set(posts.map((p) => p.source_customer_order_id).filter((x): x is number => x != null)),
        );

        const [skuRes, storeRes, orderRes] = await Promise.all([
          skuIds.length > 0
            ? sb.from("skus").select("id, sku_code, product_name, variant_name, base_unit").in("id", skuIds)
            : Promise.resolve({ data: [] }),
          // 地址在 locations（stores 只有 location_id）— 司機要的就是這個
          sb.from("stores").select("id, name, location:locations(address)").in("id", storeIds),
          orderIds.length > 0
            ? sb.from("customer_orders").select("id, order_no").in("id", orderIds)
            : Promise.resolve({ data: [] }),
        ]);

        type RawSku = { id: number; sku_code: string; product_name: string; variant_name: string | null; base_unit: string | null };
        type RawStore = { id: number; name: string; location: { address: string | null } | { address: string | null }[] | null };
        const skuMap = new Map<number, RawSku>(((skuRes.data ?? []) as RawSku[]).map((s) => [s.id, s]));
        const storeMap = new Map<number, { name: string; address: string | null }>(
          ((storeRes.data ?? []) as unknown as RawStore[]).map((s) => {
            const loc = Array.isArray(s.location) ? s.location[0] : s.location;
            return [s.id, { name: s.name, address: loc?.address ?? null }];
          }),
        );
        const orderMap = new Map<number, string>(
          ((orderRes.data ?? []) as { id: number; order_no: string }[]).map((o) => [o.id, o.order_no]),
        );

        const built: Slip[] = posts
          // 依傳入順序印，使用者在列表上看到什麼順序就印什麼順序
          .sort((a, b) => ids.indexOf(a.id) - ids.indexOf(b.id))
          .map((p) => {
            const sku = p.sku_id != null ? skuMap.get(p.sku_id) : undefined;
            const store = storeMap.get(p.offering_store_id);
            return {
              id: p.id,
              post_type: p.post_type,
              qty_remaining: p.qty_remaining,
              qty_available: p.qty_available,
              expires_at: p.expires_at,
              note: p.note,
              created_at: p.created_at,
              spot_price: p.spot_price,
              // 單位：貼文自訂 > SKU 基本單位
              spot_unit: p.spot_unit ?? sku?.base_unit ?? null,
              spot_title: p.spot_title,
              source_customer_order_id: p.source_customer_order_id,
              store_name: store?.name ?? `#${p.offering_store_id}`,
              store_address: store?.address ?? null,
              // 品名優先用貼文自訂標題（會員 App 看到的也是它），其次才是 SKU 主檔
              product_name:
                p.spot_title ??
                (sku
                  ? `${sku.product_name}${sku.variant_name ? ` / ${sku.variant_name}` : ""}`
                  : p.sku_id != null
                    ? `品項#${p.sku_id}`
                    : "（未命名）"),
              sku_code: sku?.sku_code ?? null,
              source_order_no: p.source_customer_order_id
                ? orderMap.get(p.source_customer_order_id) ?? null
                : null,
            };
          });
        if (!cancelled) setSlips(built);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
    // ids 是每次 render 新建的陣列，用字串當 dep
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [idsParam]);

  // 載入完自動觸發列印
  useEffect(() => {
    if (slips && slips.length > 0) {
      const t = setTimeout(() => window.print(), 400);
      return () => clearTimeout(t);
    }
  }, [slips]);

  if (ids.length === 0) return <div className="p-4 text-sm text-red-700">缺少 id 參數</div>;
  if (error) return <div className="p-4 text-sm text-red-700">{error}</div>;
  if (!slips) return <div className="p-4 text-sm text-zinc-500">載入中…</div>;
  if (slips.length === 0) return <div className="p-4 text-sm text-zinc-500">找不到這則貼文</div>;

  return (
    <>
      <style jsx global>{`
        @media print {
          @page { margin: 3mm; size: 80mm auto; }
          body { background: white !important; }
          .no-print { display: none !important; }
          .slip { break-after: page; }
          .slip:last-child { break-after: auto; }
        }
        body { background: #f0f0f0; }
      `}</style>

      <div className="no-print mx-auto my-3 flex max-w-[80mm] justify-end gap-2">
        <SpinButton
          onClick={() => window.print()}
          className="rounded bg-zinc-900 px-3 py-1 text-xs text-white"
        >
          🖨️ 列印
        </SpinButton>
        <SpinButton
          onClick={() => window.close()}
          className="rounded border border-zinc-300 px-3 py-1 text-xs"
        >
          關閉
        </SpinButton>
      </div>

      {slips.map((s) => (
        <div
          key={s.id}
          className="slip mx-auto my-4 max-w-[80mm] bg-white p-3 font-mono text-[14px] leading-tight text-black shadow print:my-0 print:shadow-none"
        >
          <div className="text-center">
            <div className="text-[22px] font-bold">
              互助{s.post_type === "offer" ? "釋出" : "求助"}單
            </div>
            <div className="text-[12px]">貼文 #{s.id}</div>
          </div>

          <div className="mt-2 border-y border-dashed border-black py-1.5">
            <div className="text-[12px] text-zinc-600">
              {s.post_type === "offer" ? "取貨店（貨在這）" : "送達店（貨要送這）"}
            </div>
            <div className="text-[20px] font-bold">{s.store_name}</div>
            {s.store_address && <div className="text-[13px]">{s.store_address}</div>}
          </div>

          <div className="mt-2">
            <div className="break-words text-[18px] font-bold">{s.product_name}</div>
            {s.sku_code && <div className="text-[12px] text-zinc-600">{s.sku_code}</div>}
            <div className="mt-1 flex items-baseline justify-between">
              <span className="text-[13px] text-zinc-600">
                {s.post_type === "offer" ? "可釋出" : "需要"}
              </span>
              <span className="text-[24px] font-bold">
                {s.qty_remaining}
                {s.spot_unit ?? ""}
              </span>
            </div>
            {s.qty_remaining !== s.qty_available && (
              <div className="text-right text-[12px] text-zinc-600">原 {s.qty_available}</div>
            )}
            {s.spot_price != null && (
              <div className="flex items-baseline justify-between text-[14px]">
                <span className="text-zinc-600">單價</span>
                <span className="font-bold">${s.spot_price.toLocaleString()}</span>
              </div>
            )}
          </div>

          <div className="mt-2 border-t border-dashed border-black pt-1.5 text-[13px]">
            <div>到期　{fmtDt(s.expires_at)}</div>
            {s.source_order_no && <div>源訂單　{s.source_order_no}</div>}
            <div className="text-[12px] text-zinc-600">發佈 {fmtDt(s.created_at)}</div>
          </div>

          {s.note && (
            <div className="mt-1.5 break-words text-[14px] font-bold">📝 {s.note}</div>
          )}

          {/* 司機對貨用：實收量自己填，兩邊簽名 */}
          <div className="mt-3 border-t border-dashed border-black pt-2 text-[13px]">
            <div className="flex items-end gap-1">
              <span className="whitespace-nowrap">實際交貨數量</span>
              <span className="flex-1 border-b border-black">&nbsp;</span>
            </div>
            <div className="mt-3 flex items-end gap-1">
              <span className="whitespace-nowrap">司機簽名</span>
              <span className="flex-1 border-b border-black">&nbsp;</span>
            </div>
            <div className="mt-3 flex items-end gap-1">
              <span className="whitespace-nowrap">收貨簽名</span>
              <span className="flex-1 border-b border-black">&nbsp;</span>
            </div>
          </div>

          <div className="mt-2 text-center text-[11px] text-zinc-500">列印 {printedAt}</div>
        </div>
      ))}
    </>
  );
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

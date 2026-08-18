"use client";

// 互助交流板列印頁。兩種模式，由 query 決定：
//
//   ?type=all|request|offer  → 清單模式（A4 橫式表格）。由 /inventory/mutual-aid 的
//                              「🖨️ 列印」用隱藏 iframe 載入，查詢條件完全對齊列表頁
//                              （status = active、created_at desc、limit 200）。
//   ?id=<board_id>           → 單則模式（A4 直式單張）。板上每一則貼文自己的列印鈕，
//                              **不濾 status** —— 已認領 / 已過期的也要印得出來，
//                              店家常常是事後要補一張紙歸檔或跟對方對帳。
//
// 兩種都自己抓資料、抓完自動 window.print()。

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

type PostType = "offer" | "request";
type PostStatus = "active" | "exhausted" | "expired" | "cancelled";

type Row = {
  id: number;
  post_type: PostType;
  status: PostStatus;
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
  spot_description: string | null;
  spot_visible_to_other_stores: boolean;
  created_at: string;
  store_name: string;
  sku_code: string | null;
  sku_label: string;
  source_order_no: string | null;
  replies_count: number;
};

type Reply = {
  id: number;
  author_label: string | null;
  body: string;
  created_at: string;
};

type SkuOption = { id: number; sku_code: string; product_name: string; variant_name: string | null };

const SELECT_COLS =
  "id, post_type, status, offering_store_id, sku_id, qty_available, qty_remaining, expires_at, note, " +
  "source_customer_order_id, spot_price, spot_title, spot_unit, spot_description, " +
  "spot_visible_to_other_stores, created_at";

const TYPE_LABEL: Record<PostType, string> = { offer: "釋出", request: "需求" };

const STATUS_LABEL: Record<PostStatus, string> = {
  active: "進行中",
  exhausted: "已認領",
  expired: "已過期",
  cancelled: "已取消",
};

const FILTER_LABEL: Record<"all" | "request" | "offer", string> = {
  all: "全部",
  request: "需求中",
  offer: "釋出中",
};

/** TipTap HTML → 純文字（紙上不需要標籤） */
function htmlToText(raw: string | null | undefined): string {
  if (!raw) return "";
  return raw
    .replace(/<\/(p|div|h[1-6]|li|tr|blockquote)\s*>/gi, "\n")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export default function MutualAidPrintPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const sp = useSearchParams();
  const idParam = Number(sp.get("id"));
  const singleId = Number.isFinite(idParam) && idParam > 0 ? idParam : null;
  const typeParam = sp.get("type");
  const filter: "all" | "request" | "offer" =
    typeParam === "request" || typeParam === "offer" ? typeParam : "all";

  const [rows, setRows] = useState<Row[] | null>(null);
  const [replies, setReplies] = useState<Reply[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [printedAt, setPrintedAt] = useState<string>("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      // 列印時間在 client 決定（SSR 算出來的值會 hydration mismatch）
      setPrintedAt(fmtDt(new Date().toISOString()));
      try {
        const sb = getSupabase();
        let q = sb.from("mutual_aid_board").select(SELECT_COLS);
        if (singleId != null) {
          // 單則：不濾 status（已認領 / 已過期也要印得出來）
          q = q.eq("id", singleId);
        } else {
          q = q.eq("status", "active").order("created_at", { ascending: false }).limit(200);
          if (filter !== "all") q = q.eq("post_type", filter);
        }
        const { data, error: e } = await q;
        if (e) throw new Error(e.message);
        type Base = Omit<Row, "store_name" | "sku_code" | "sku_label" | "source_order_no" | "replies_count">;
        const base = (data ?? []) as unknown as Base[];
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
          // 單則要印出留言內容，清單只要則數
          singleId != null
            ? sb.from("mutual_aid_replies")
                .select("id, board_id, author_label, body, created_at")
                .in("board_id", boardIds)
                .order("created_at", { ascending: true })
            : sb.from("mutual_aid_replies").select("board_id").in("board_id", boardIds),
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
        const replyRows = (replyRes.data ?? []) as { board_id: number }[];
        const replyCount = new Map<number, number>();
        for (const r of replyRows) {
          replyCount.set(r.board_id, (replyCount.get(r.board_id) ?? 0) + 1);
        }
        if (cancelled) return;
        if (singleId != null) {
          setReplies(replyRows as unknown as Reply[]);
        }
        const enriched: Row[] = base.map((r) => {
          const sku = r.sku_id != null ? skuMap.get(r.sku_id) : undefined;
          return {
            ...r,
            store_name: storeMap.get(r.offering_store_id) ?? `#${r.offering_store_id}`,
            sku_code: sku?.sku_code ?? null,
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
  }, [filter, singleId]);

  // 載入完自動觸發列印（沒資料也印，讓「今天板上是空的」也留得下紙本）
  useEffect(() => {
    if (rows === null) return;
    const t = setTimeout(() => window.print(), 400);
    return () => clearTimeout(t);
  }, [rows]);

  if (error) return <div className="p-6 text-sm text-red-700">{error}</div>;
  if (rows === null) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  if (singleId != null) {
    return <SinglePost row={rows[0] ?? null} replies={replies} printedAt={printedAt} />;
  }

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

      <PrintBar />

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

// ============================================================
// 單則貼文（A4 直式）—— 夾在貨上 / 歸檔用，底下留簽收欄
// ============================================================
function SinglePost({
  row, replies, printedAt,
}: {
  row: Row | null;
  replies: Reply[];
  printedAt: string;
}) {
  if (!row) {
    return (
      <div className="bg-white p-8 text-black">
        <style>{`@media print { @page { size: A4 portrait; margin: 1.2cm; } .no-print { display: none !important; } }`}</style>
        <PrintBar />
        <div className="border border-dashed border-zinc-400 p-8 text-center text-sm text-zinc-500">
          找不到這則貼文（可能已被刪除）
        </div>
      </div>
    );
  }
  const isManual = row.post_type === "offer" && row.source_customer_order_id == null;
  const desc = htmlToText(row.spot_description);
  return (
    <div className="bg-white p-8 text-black print:p-0">
      <style>{`
        @media print {
          @page { size: A4 portrait; margin: 1.2cm; }
          .no-print { display: none !important; }
          body { background: white; }
          .avoid-break { break-inside: avoid; }
        }
      `}</style>

      <PrintBar />

      <header className="mb-4 border-b-2 border-black pb-2">
        <div className="flex items-baseline justify-between">
          <h1 className="text-2xl font-bold">
            互助交流單 — {TYPE_LABEL[row.post_type]}
          </h1>
          <span className="text-sm">貼文 #{row.id}</span>
        </div>
        <div className="mt-1 flex flex-wrap gap-x-4 text-xs text-zinc-600">
          <span>狀態：{STATUS_LABEL[row.status]}</span>
          <span>張貼 {fmtDt(row.created_at)}</span>
          <span>列印時間 {printedAt}</span>
        </div>
      </header>

      <table className="mb-4 w-full border-collapse text-sm avoid-break">
        <tbody>
          <FieldRow label={row.post_type === "offer" ? "釋出店" : "求助店"} value={row.store_name} />
          <FieldRow
            label="商品 / 品項"
            value={
              <>
                <span className="text-base font-semibold">{row.sku_label}</span>
                {isManual && <span className="ml-2 text-xs text-zinc-500">[手動新增現貨]</span>}
                {row.sku_id == null && (
                  <span className="ml-2 text-xs text-zinc-500">[未選商品，其他分店無法認領]</span>
                )}
                {row.spot_title && row.sku_id != null && (
                  <div className="text-xs text-zinc-500">App 標題：{row.spot_title}</div>
                )}
              </>
            }
          />
          <FieldRow
            label={row.post_type === "offer" ? "可釋出數量" : "需求數量"}
            value={
              <span className="font-mono text-base">
                {row.qty_remaining}{row.spot_unit ?? ""}
                {row.qty_remaining !== row.qty_available && (
                  <span className="ml-2 text-xs text-zinc-500">（原 {row.qty_available}）</span>
                )}
              </span>
            }
          />
          <FieldRow
            label="單價"
            value={row.spot_price != null ? `$${row.spot_price.toLocaleString()}` : "—"}
          />
          <FieldRow label="到期" value={fmtDt(row.expires_at)} />
          <FieldRow label="源訂單" value={row.source_order_no ?? "—（沒有掛訂單，跨店認領會走載體單）"} />
          {row.post_type === "offer" && (
            <FieldRow
              label="會員可見"
              value={row.spot_visible_to_other_stores ? "全部門市會員" : "🔒 僅限本店會員"}
            />
          )}
          <FieldRow label="備註" value={row.note ?? "—"} />
        </tbody>
      </table>

      {desc && (
        <section className="mb-4 avoid-break">
          <h2 className="mb-1 text-sm font-semibold">商品說明</h2>
          <div className="whitespace-pre-wrap border border-zinc-300 p-2 text-sm">{desc}</div>
        </section>
      )}

      <section className="mb-6">
        <h2 className="mb-1 text-sm font-semibold">留言（{replies.length}）</h2>
        {replies.length === 0 ? (
          <div className="border border-dashed border-zinc-400 p-3 text-center text-xs text-zinc-500">
            尚無留言
          </div>
        ) : (
          <ul className="divide-y divide-zinc-300 border border-zinc-300">
            {replies.map((rp) => (
              <li key={rp.id} className="avoid-break p-2 text-sm">
                <div className="text-xs text-zinc-500">
                  {rp.author_label ?? "—"}・{fmtDt(rp.created_at)}
                </div>
                <div className="whitespace-pre-wrap">{htmlToText(rp.body) || rp.body}</div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="avoid-break">
        <h2 className="mb-1 text-sm font-semibold">認領 / 點交</h2>
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="border border-zinc-500 bg-zinc-100 text-xs">
              <Th className="border border-zinc-400">認領店</Th>
              <Th className="w-24 border border-zinc-400 text-right">數量</Th>
              <Th className="w-32 border border-zinc-400">日期</Th>
              <Th className="w-40 border border-zinc-400">簽收</Th>
            </tr>
          </thead>
          <tbody>
            {[0, 1, 2].map((i) => (
              <tr key={i}>
                <Td className="h-9 border border-zinc-400" />
                <Td className="h-9 border border-zinc-400" />
                <Td className="h-9 border border-zinc-400" />
                <Td className="h-9 border border-zinc-400" />
              </tr>
            ))}
          </tbody>
        </table>
        <p className="mt-2 text-xs text-zinc-500">
          ※ 這張是溝通 / 歸檔用的交流單，不是出貨單。實際跨店認領成立後，貨會走訂單轉移，
          隨貨的「互助出貨單」請到該筆轉入單或儀表板的互助提醒列印。
        </p>
      </section>
    </div>
  );
}

function PrintBar() {
  return (
    <div className="no-print mb-4 flex justify-end gap-2">
      <SpinButton
        onClick={() => window.print()}
        className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500"
      >
        🖨️ 列印
      </SpinButton>
    </div>
  );
}

function FieldRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <tr className="border-b border-zinc-300 align-top">
      <th className="w-28 bg-zinc-100 px-2 py-1.5 text-left text-xs font-semibold">{label}</th>
      <td className="px-2 py-1.5">{value}</td>
    </tr>
  );
}

function Th({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
  return <th className={`px-2 py-1 text-left font-semibold ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
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

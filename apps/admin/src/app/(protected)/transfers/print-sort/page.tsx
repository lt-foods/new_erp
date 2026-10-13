"use client";

// 依客人分貨單（A4）：收貨前，照收貨視窗「預設勾誰」把這車的貨按客人列出來，倉庫可以先照著分袋。
// 網址：/transfers/print-sort?transfer_ids=1,2,3&style=list|cut
//   transfer_ids：已派出（shipped）、還沒收貨的派貨單。可以跨店（總倉在收貨頁批次勾選時）——
//     預覽 RPC 只收同一家店，所以本頁先依目的店分組，每家店只用自己那幾張單各算一次，
//     每家店從新的一頁開始。
//   style：list＝清單（預設）；cut＝一客一段（虛線框，可剪下貼袋）。畫面上也能切換。
//
// ⛔ 本頁只讀：只查 transfers / transfer_items / stores / picking_waves，再加上收貨視窗第一次
//    載入時呼叫的同一支預覽 rpc_get_transfer_allocation_preview（STABLE，p_lines = null ＝
//    實收照派出量）。不收貨、不配單、不通知、不改訂單。
// ⛔ 「預設勾誰」一律走 lib/receiveAllocation（跟收貨視窗共用），不要在這裡另寫一份挑法。
// ⚠ 照「列印當下」的資料算：印完到門市收貨之間有人取消／改量、或門市庫存被用掉，
//   收貨視窗預設勾的就會跟袋子不一樣 —— 紙上有印提醒，門市要照袋子核對勾選。
// ⚠ 同店還有別張派貨單沒收、又有相同商品時，兩張分貨單會列到同一批客人
//   （預覽挑客人不分是哪一車）→ 印紅框警告，並附「合併列印」連結。

import { Suspense, useEffect, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { transferStatusLabel } from "@/lib/transferStatus";
import {
  buildSortSheet,
  greedyItemsByTime,
  normalizeReceivePreview,
  type SortSheet,
  type SortSheetCustomer,
} from "@/lib/receiveAllocation";
import { parseWaveId } from "@/components/TransferReceiveModal";
import SpinButton from "@/components/SpinButton";

type SortStyle = "list" | "cut";

type TransferRow = {
  id: number;
  transfer_no: string;
  status: string;
  transfer_type: string;
  dest_location: number;
  shipped_at: string | null;
  received_at: string | null;
};

type SheetHead = {
  storeName: string;
  transfers: TransferRow[];
  waveCodes: string[];
};

type StoreSheet = {
  dest: number;
  sheet: SortSheet<SheetHead>;
  // 同店、也還沒收、又有相同商品的其他總倉派貨單
  overlaps: Array<{ id: number; transfer_no: string }>;
};

type Loaded = {
  stores: StoreSheet[];
  notStore: TransferRow[]; // 目的地不是分店（例如退回總倉）：沒有客人訂單可分
  loadedAt: string;
};

// .in(…) 一批最多幾個 id：總倉全選待收時 id 可能上百個，太多會撞網址長度上限（PostgREST 走 GET）
const IN_BATCH = 150;

function parseIds(raw: string): number[] {
  const out: number[] = [];
  for (const s of raw.split(",")) {
    const n = Number(s.trim());
    if (Number.isInteger(n) && n > 0 && !out.includes(n)) out.push(n);
  }
  return out;
}

const fmtTime = (iso: string) => new Date(iso).toLocaleString("zh-TW", { hour12: false });

const errMsg = (e: unknown) =>
  e instanceof Error ? e.message : (e as { message?: string } | null)?.message ?? String(e);

export default function PrintSortSheetPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const sp = useSearchParams();
  const idsKey = parseIds(sp.get("transfer_ids") ?? "").join(",");
  const [style, setStyle] = useState<SortStyle>(sp.get("style") === "cut" ? "cut" : "list");
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  // 不能印的原因（不是錯誤）：有單已經收貨 / 狀態不對
  const [blocked, setBlocked] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const paramError = idsKey ? null : "缺 transfer_ids 參數";

  useEffect(() => {
    if (!idsKey) return;
    const ids = idsKey.split(",").map(Number);
    let cancelled = false;
    (async () => {
      // 每次查詢一開始先把上一輪的錯誤與資料一起清掉（合併列印連結會換 id 重查）
      setError(null);
      setBlocked(null);
      setLoaded(null);
      try {
        const sb = getSupabase();

        const list: TransferRow[] = [];
        for (let i = 0; i < ids.length; i += IN_BATCH) {
          const batch = ids.slice(i, i + IN_BATCH);
          list.push(
            ...(await fetchAllRows<TransferRow>(() =>
              sb
                .from("transfers")
                .select("id, transfer_no, status, transfer_type, dest_location, shipped_at, received_at")
                .in("id", batch)
                .order("id"),
            )),
          );
        }
        if (list.length !== ids.length) {
          throw new Error(
            `有 ${ids.length - list.length} 張派貨單找不到（可能已刪除，或這個帳號看不到那家店的單）。`,
          );
        }
        // 收過貨（或狀態不對）就不算：預覽 RPC 只收 shipped，而且收過貨之後名單已經定了
        const notShipped = list.filter((t) => t.status !== "shipped");
        if (notShipped.length > 0) {
          if (!cancelled)
            setBlocked(
              notShipped
                .map((t) =>
                  t.status === "received" && t.received_at
                    ? `${t.transfer_no} 已在 ${fmtTime(t.received_at)} 收貨，分貨單只能在收貨前印。`
                    : `${t.transfer_no} 目前是「${transferStatusLabel(t.status)}」，分貨單只能在派出後、收貨前印。`,
                )
                .join("\n"),
            );
          return;
        }

        const dests = Array.from(new Set(list.map((t) => t.dest_location)));
        const { data: stRows, error: e2 } = await sb
          .from("stores")
          .select("id, name, location_id")
          .in("location_id", dests);
        if (e2) throw new Error(`分店資料載入失敗：${e2.message}`);
        const storeName = new Map<number, string>();
        for (const s of (stRows ?? []) as Array<{ name: string; location_id: number }>) {
          if (!storeName.has(s.location_id)) storeName.set(s.location_id, s.name);
        }

        const waveIds = Array.from(
          new Set(list.map((t) => parseWaveId(t.transfer_no)).filter((x): x is number => x !== null)),
        );
        const waveCode = new Map<number, string>();
        for (let i = 0; i < waveIds.length; i += IN_BATCH) {
          const batch = waveIds.slice(i, i + IN_BATCH);
          const { data: ws, error: e3 } = await sb
            .from("picking_waves")
            .select("id, wave_code")
            .in("id", batch);
          if (e3) throw new Error(`撿貨單載入失敗：${e3.message}`);
          for (const w of (ws ?? []) as Array<{ id: number; wave_code: string }>) waveCode.set(w.id, w.wave_code);
        }

        // 每家店各算一次（預覽 RPC 不收跨店：「跨分店的調撥單請分開處理」）
        const storeDests = dests.filter((d) => storeName.has(d));
        const stores: StoreSheet[] = [];
        for (const dest of storeDests) {
          const group = list.filter((t) => t.dest_location === dest);
          // 跟收貨視窗第一次載入一樣：實收照派出量（p_lines = null）
          const { data: d, error: e4 } = await sb.rpc("rpc_get_transfer_allocation_preview", {
            p_transfer_ids: group.map((t) => t.id),
            p_lines: null,
          });
          if (e4) throw new Error(e4.message);
          const pv = normalizeReceivePreview(d);
          const caps = new Map(pv.budgetRows.map((b) => [b.sku_id, b.cap]));
          const head: SheetHead = {
            storeName: storeName.get(dest) ?? `#${dest}`,
            transfers: group,
            waveCodes: Array.from(
              new Set(
                group
                  .map((t) => parseWaveId(t.transfer_no))
                  .map((w) => (w === null ? undefined : waveCode.get(w)))
                  .filter((c): c is string => !!c),
              ),
            ),
          };
          stores.push({ dest, sheet: buildSortSheet(pv, greedyItemsByTime(pv.orders, caps), head), overlaps: [] });
        }

        // 重疊檢查：同店其他已派出、還沒收的總倉派貨單，只要跟這車有相同商品（派出量 > 0），
        // 兩張分貨單就會列到同一批客人
        if (stores.length > 0) {
          const idSet = new Set(ids);
          const others = (
            await fetchAllRows<{ id: number; transfer_no: string; dest_location: number }>(() =>
              sb
                .from("transfers")
                .select("id, transfer_no, dest_location")
                .in("dest_location", storeDests)
                .eq("status", "shipped")
                .eq("transfer_type", "hq_to_store")
                .order("id"),
            )
          ).filter((t) => !idSet.has(t.id));
          const otherIds = others.map((t) => t.id);
          const hits: Array<{ transfer_id: number; sku_id: number }> = [];
          for (let i = 0; i < otherIds.length; i += IN_BATCH) {
            const batch = otherIds.slice(i, i + IN_BATCH);
            hits.push(
              ...(await fetchAllRows<{ transfer_id: number; sku_id: number }>(() =>
                sb
                  .from("transfer_items")
                  .select("id, transfer_id, sku_id")
                  .in("transfer_id", batch)
                  .gt("qty_shipped", 0)
                  .order("id"),
              )),
            );
          }
          for (const s of stores) {
            const mine = new Set(s.sheet.skus.map((k) => k.sku_id));
            const hitIds = new Set(hits.filter((h) => mine.has(h.sku_id)).map((h) => h.transfer_id));
            s.overlaps = others
              .filter((t) => t.dest_location === s.dest && hitIds.has(t.id))
              .map((t) => ({ id: t.id, transfer_no: t.transfer_no }));
          }
        }

        stores.sort((a, b) => a.sheet.meta.storeName.localeCompare(b.sheet.meta.storeName, "zh-TW"));
        if (cancelled) return;
        setLoaded({
          stores,
          notStore: list.filter((t) => !storeName.has(t.dest_location)),
          loadedAt: new Date().toISOString(),
        });
      } catch (e) {
        if (!cancelled) setError(errMsg(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [idsKey]);

  // PDF 存檔 / 列印對話框的預設檔名
  useEffect(() => {
    if (!loaded || loaded.stores.length === 0) return;
    const nos = loaded.stores.flatMap((s) => s.sheet.meta.transfers.map((t) => t.transfer_no));
    const original = document.title;
    document.title = `${nos.length <= 3 ? nos.join("、") : `${nos[0]}等${nos.length}張`}-依客人分貨單`;
    return () => {
      document.title = original;
    };
  }, [loaded]);

  const printable = !!loaded && loaded.stores.length > 0 && !error && !blocked;

  return (
    <>
      <style jsx global>{`
        @media print {
          @page {
            size: A4;
            margin: 12mm;
          }
          .no-print {
            display: none !important;
          }
          body {
            background: white !important;
          }
          .sort-root {
            -webkit-print-color-adjust: exact;
            print-color-adjust: exact;
          }
          .store-sheet + .store-sheet {
            break-before: page;
            page-break-before: always;
          }
        }
        .sort-root .avoid-break {
          break-inside: avoid;
          page-break-inside: avoid;
        }
      `}</style>

      {/* 列印頁是文件不是操作介面：一律白底深字，不跟深色模式 */}
      <div className="sort-root bg-white text-zinc-900 print:bg-white">
        <div className="no-print sticky top-0 z-20 flex flex-wrap items-center gap-3 border-b border-zinc-200 bg-zinc-50 p-3">
          <h1 className="text-base font-semibold">依客人分貨單</h1>
          <div className="flex overflow-hidden rounded-md border border-zinc-300 text-sm">
            <SpinButton
              type="button"
              onClick={() => setStyle("list")}
              className={
                style === "list" ? "bg-zinc-900 px-3 py-1 text-white" : "bg-white px-3 py-1 text-zinc-700 hover:bg-zinc-100"
              }
            >
              清單
            </SpinButton>
            <SpinButton
              type="button"
              onClick={() => setStyle("cut")}
              className={
                style === "cut" ? "bg-zinc-900 px-3 py-1 text-white" : "bg-white px-3 py-1 text-zinc-700 hover:bg-zinc-100"
              }
            >
              一客一段（可剪下）
            </SpinButton>
          </div>
          <span className={error ? "text-sm font-semibold text-red-700" : "text-sm text-zinc-500"}>
            {paramError ?? (error ? "⚠ 載入失敗（不是沒資料）" : blocked ? "不能印" : !loaded ? "載入中…" : loaded.stores.length > 1 ? `${loaded.stores.length} 家店，每家店從新的一頁開始` : "")}
          </span>
          <SpinButton
            onClick={() => window.print()}
            disabled={!printable}
            className="ml-auto rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
          >
            🖨️ 列印
          </SpinButton>
        </div>

        {paramError && <div className="p-6 text-sm text-red-700">{paramError}</div>}

        {error && (
          <div className="m-3 rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800">
            <div className="font-semibold">⚠ 資料載入失敗，已停用列印 —— 這不是「沒有客人」。</div>
            <div className="mt-1">請重新整理再試一次。</div>
            <div className="mt-1 break-words font-mono text-xs text-red-700">{error}</div>
          </div>
        )}

        {blocked && !error && (
          <div className="m-3 whitespace-pre-line rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
            {blocked}
          </div>
        )}

        {loaded && !error && !blocked && (
          <>
            {loaded.notStore.length > 0 && (
              <div className="m-3 rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
                這幾張的目的地不是分店（例如退回總倉），沒有客人訂單可以分，沒有印：
                {loaded.notStore.map((t) => t.transfer_no).join("、")}
              </div>
            )}
            {loaded.stores.map((s) => (
              <StoreSheetView
                key={s.dest}
                s={s}
                style={style}
                loadedAt={loaded.loadedAt}
                mergeHref={
                  s.overlaps.length > 0
                    ? `/transfers/print-sort?transfer_ids=${[
                        ...idsKey.split(",").map(Number),
                        ...s.overlaps.map((o) => o.id),
                      ]
                        .sort((a, b) => a - b)
                        .join(",")}&style=${style}`
                    : null
                }
              />
            ))}
          </>
        )}
      </div>
    </>
  );
}

function StoreSheetView({
  s,
  style,
  loadedAt,
  mergeHref,
}: {
  s: StoreSheet;
  style: SortStyle;
  loadedAt: string;
  mergeHref: string | null;
}) {
  const { meta, customers, fromStore, skus } = s.sheet;
  const surplusSkus = skus.filter((k) => k.surplus > 0);
  const shipTimes = Array.from(
    new Set(meta.transfers.map((t) => t.shipped_at).filter((x): x is string => !!x).map(fmtTime)),
  );

  return (
    <div className="store-sheet mx-auto my-6 max-w-[210mm] border border-zinc-300 bg-white p-8 print:my-0 print:max-w-none print:border-0 print:p-0">
      <div className="text-center text-lg font-bold">依客人分貨單</div>

      {/* 單頭：單號類可能很多張，一律獨佔整行（被 grid 關在半欄會爆行） */}
      <div className="mt-2 space-y-0.5 text-sm">
        <div className="flex min-w-0">
          <span className="w-20 shrink-0 text-zinc-500">目的店</span>
          <span className="min-w-0 break-words text-base font-bold">{meta.storeName}</span>
        </div>
        <div className="flex min-w-0">
          <span className="w-20 shrink-0 text-zinc-500">派貨單號</span>
          <span className="min-w-0 break-words font-mono">{meta.transfers.map((t) => t.transfer_no).join("、")}</span>
        </div>
        <div className="flex min-w-0">
          <span className="w-20 shrink-0 text-zinc-500">撿貨單號</span>
          <span className="min-w-0 break-words font-mono">{meta.waveCodes.join("、") || "—"}</span>
        </div>
        <div className="flex min-w-0">
          <span className="w-20 shrink-0 text-zinc-500">派出時間</span>
          <span className="min-w-0 break-words">{shipTimes.join("、") || "—"}</span>
        </div>
        <div className="flex min-w-0">
          <span className="w-20 shrink-0 text-zinc-500">列印時間</span>
          <span className="min-w-0 break-words">{fmtTime(loadedAt)}</span>
        </div>
      </div>
      <p className="mt-2 border border-zinc-500 px-2 py-1 text-xs font-semibold">
        ※ 這是照列印當下資料算的，不是配單；門市收貨時請照袋子核對勾選。
      </p>

      {/* 紅框：顏色以外另有文字，沒勾「背景圖形」或黑白印也看得懂 */}
      {s.overlaps.length > 0 && (
        <div className="mt-3 border-2 border-red-600 p-2 text-sm font-semibold text-red-700">
          ⚠ 注意：這家店還有 {s.overlaps.length} 張派貨單也還沒收貨、而且有相同商品（
          {s.overlaps.map((o) => o.transfer_no).join("、")}）。系統挑客人不分是哪一車，
          這張分貨單跟那幾張會列到同一批客人 —— 請改印「合併版」照著分，門市收貨時也要這幾車一起收。
          {mergeHref && (
            <div className="no-print mt-2">
              <Link
                href={mergeHref}
                className="inline-block rounded-md border border-red-600 bg-white px-3 py-1 text-sm text-red-700 hover:bg-red-50"
              >
                改印合併版（{meta.transfers.length + s.overlaps.length} 張一起算）
              </Link>
            </div>
          )}
        </div>
      )}

      {/* 客人段：這車要分的 */}
      <h2 className="mt-4 mb-1 text-base font-bold">客人（照名字排序）· 共 {customers.length} 位</h2>
      {customers.length === 0 ? (
        <div className="border border-zinc-400 p-3 text-sm text-zinc-600">
          這車沒有要分給客人的貨（例如純補貨），全部列在下面「多出來的」。
        </div>
      ) : style === "list" ? (
        <CustomerTable customers={customers} />
      ) : (
        <div className="grid grid-cols-2 gap-3">
          {customers.map((c) => (
            <CutCard key={c.key} c={c} storeName={meta.storeName} />
          ))}
        </div>
      )}

      {/* 門市現貨段：收貨視窗的可配上限含店裡原本多的量，超過這車的那幾位不用倉庫分 */}
      {fromStore.length > 0 && (
        <>
          <h2 className="mt-5 mb-1 text-base font-bold">門市現貨（這幾位的貨不在這車，門市現有庫存拿，倉庫不用分）</h2>
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="bg-zinc-100">
                <th className="border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">客人</th>
                <th className="border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">商品</th>
                <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">數量</th>
              </tr>
            </thead>
            <tbody>
              {fromStore.flatMap((c) =>
                c.lines.map((l) => (
                  <tr key={`${c.key}-${l.sku_id}`} className="avoid-break">
                    <td className="border border-zinc-400 px-2 py-0.5">{c.customer}</td>
                    <td className="border border-zinc-400 px-2 py-0.5">{l.name}</td>
                    <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono">{l.qty}</td>
                  </tr>
                )),
              )}
            </tbody>
          </table>
        </>
      )}

      {/* 多出來的：這車有、但沒有客人要的量 */}
      {surplusSkus.length > 0 && (
        <>
          <h2 className="mt-5 mb-1 text-base font-bold">多出來的（這車有、沒有客人要的量，倉庫另外放）</h2>
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="bg-zinc-100">
                <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">編號</th>
                <th className="border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">商品</th>
                <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">數量</th>
              </tr>
            </thead>
            <tbody>
              {surplusSkus.map((k) => (
                <tr key={k.sku_id} className="avoid-break">
                  <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 font-mono text-xs">{k.sku_code ?? "—"}</td>
                  <td className="border border-zinc-400 px-2 py-0.5">
                    {k.name}
                    {k.fillDeficit > 0 && (
                      <div className="text-[11px] text-zinc-600">其中 {k.fillDeficit} 個會先補門市帳上不足</div>
                    )}
                  </td>
                  <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono font-bold">{k.surplus}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}

      {/* 頁尾合計：倉管照這張對實際點到的數 */}
      <h2 className="mt-5 mb-1 text-base font-bold">每個商品合計</h2>
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr className="bg-zinc-100">
            <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">編號</th>
            <th className="border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">商品</th>
            <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">派出</th>
            <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">分給客人</th>
            <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">多出來</th>
          </tr>
        </thead>
        <tbody>
          {skus.map((k) => (
            <tr key={k.sku_id} className="avoid-break">
              <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 font-mono text-xs">{k.sku_code ?? "—"}</td>
              <td className="border border-zinc-400 px-2 py-0.5">
                {k.name}
                {k.fromStore > 0 && (
                  <div className="text-[11px] text-zinc-600">另有 {k.fromStore} 個由門市現貨拿（不在這車）</div>
                )}
              </td>
              <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono">{k.shipped}</td>
              <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono">{k.toCustomers}</td>
              <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono">{k.surplus}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// 清單樣式：一位客人一個 tbody（不跨頁），表頭每頁重複
function CustomerTable({ customers }: { customers: SortSheetCustomer[] }) {
  return (
    <table className="w-full border-collapse text-sm">
      <thead>
        <tr className="bg-zinc-100">
          <th className="border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">客人</th>
          <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">編號</th>
          <th className="border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">商品</th>
          <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">數量</th>
          <th className="w-6 border border-zinc-400 px-2 py-1" />
        </tr>
      </thead>
      {customers.map((c) => (
        <tbody key={c.key} className="avoid-break">
          {c.lines.map((l, i) => (
            <tr key={l.sku_id}>
              {i === 0 && (
                <td rowSpan={c.lines.length} className="border border-zinc-400 px-2 py-1 align-top">
                  <div className="break-words font-bold">{c.customer}</div>
                  <div className="whitespace-nowrap text-[11px] text-zinc-600">共 {c.qty} 件</div>
                  <div className="break-all font-mono text-[10px] text-zinc-500">{c.order_nos.join("、")}</div>
                </td>
              )}
              <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 font-mono text-xs">{l.sku_code ?? "—"}</td>
              <td className="border border-zinc-400 px-2 py-0.5">{l.name}</td>
              <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono text-base font-bold">
                {l.qty}
              </td>
              <td className="border border-zinc-400 px-2 py-0.5" />
            </tr>
          ))}
        </tbody>
      ))}
    </table>
  );
}

// 一客一段：虛線框可剪下貼袋，每段不跨頁
function CutCard({ c, storeName }: { c: SortSheetCustomer; storeName: string }) {
  return (
    <div className="avoid-break border-2 border-dashed border-zinc-500 p-3">
      <div className="flex items-baseline justify-between gap-2">
        <span className="min-w-0 break-words text-lg font-bold">{c.customer}</span>
        <span className="whitespace-nowrap text-sm">共 {c.qty} 件</span>
      </div>
      <div className="break-words text-[11px] text-zinc-600">{storeName}</div>
      <div className="mt-1 divide-y divide-dashed divide-zinc-300 border-t border-zinc-400">
        {c.lines.map((l) => (
          <div key={l.sku_id} className="flex items-baseline justify-between gap-2 py-0.5 text-sm">
            <span className="min-w-0 break-words">{l.name}</span>
            <span className="whitespace-nowrap font-mono text-base font-bold">× {l.qty}</span>
          </div>
        ))}
      </div>
      <div className="mt-1 break-all font-mono text-[10px] text-zinc-500">{c.order_nos.join("、")}</div>
    </div>
  );
}

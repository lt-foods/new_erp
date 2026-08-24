"use client";

// 儀表板提醒：本店名下**還在路上的互助轉移**，轉出（要交出去）與轉入（在等的貨）
// 兩個方向都列出來，每一筆都能就地列印互助出貨單。
//
// 為什麼要主動提醒：互助的貨是「別人來拿 / 別人送來」，不像顧客取貨有人站在櫃檯催。
// 轉出店不知道自己名下有貨等著被載走，就不會去印單 —— 司機來了拿了貨、紙上什麼都沒有，
// 中途少一箱沒人說得清（2026-08-15 店家回報）。轉入店同理：不知道有貨在路上，
// 箱子到了也不會去「收貨」頁收單，訂單就一直卡著。
//
// 判定：轉入單（互助單）還沒被收貨店收掉（pending / confirmed / shipping）。
//   - pending   = 剛轉出、總倉還沒收到（**經總倉的轉入單一開始就是這個狀態**，
//                 見 rpc_transfer_order_to_store / _partial：跨店非空中轉建成 pending）
//   - confirmed = 總倉已收、還沒派貨；空中轉的話是自動出貨上線前卡住的舊單
//   - shipping  = 已建 AT- 轉移單，但收貨店還沒收 → 貨可能還在店裡等司機
//   收貨店收掉就變 ready，兩邊的提醒都自動消失。
//
// 方向：轉出＝來源單的 pickup_store 是本店；轉入＝這張轉入單的 pickup_store 是本店。
// 同店轉單（只是換客人）貨沒離開本店，兩邊都不算。
// 儀表板選「全部門市」（HQ）時不分方向，一份清單看全站在途的互助。
//
// ⚠ pending 不可以漏（2026-08-18 南平→三峽）：原本只撈 confirmed/shipping，而
// 經總倉的單要等總倉「收到貨」才被推 confirmed —— 也就是箱子早就離開店裡了提醒才出現。
// 轉出店在最需要印隨貨單的那一段（貨還在自己手上）畫面上什麼都沒有，
// 店家的原話是「南平自己看不到轉給三峽的資料，找不到轉貨單可印」。

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { printViaIframe } from "@/lib/printIframe";
import { withBasePath } from "@/lib/basePath";
import {
  AID_IN_FLIGHT_STATUSES, TRANSFER_LINK_SELECT, type TransferLink,
  activeQty, aidRouteLabel, aidStageLabel, linkItems,
} from "@/lib/aidTransfer";

type AidShipment = {
  // 一列 = 一次轉移（一條 link），不是一張轉入單：追加分支會把多家店的貨併進
  // 同一張轉入單，每家店只該看到自己那一趟。key 用 link id。
  linkId: number;
  id: number;
  order_no: string;
  status: string;
  is_air_transfer: boolean;
  dest_store: string;
  dest_store_id: number | null;
  source_store: string;
  source_store_id: number | null;
  qty: number;
};

const PRINTED_KEY = "aid_ship_printed_v1";

function loadPrinted(): Set<number> {
  try {
    const raw = localStorage.getItem(PRINTED_KEY);
    const arr = raw ? (JSON.parse(raw) as unknown) : [];
    return new Set(Array.isArray(arr) ? arr.map(Number).filter(Number.isFinite) : []);
  } catch {
    return new Set();
  }
}

export default function AidShipmentReminder({ storeId }: { storeId: number | null }) {
  const [rows, setRows] = useState<AidShipment[] | null>(null);
  // rows 還沒載完（含 SSR）時整個元件回 null，所以這裡讀 localStorage 不會有 hydration 落差
  const [printed, setPrinted] = useState<Set<number>>(
    () => (typeof window === "undefined" ? new Set<number>() : loadPrinted()),
  );

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        // 從連結表出發（不是從轉入單），一趟轉移一列 —— 追加轉入把多家店的貨
        // 併進同一張轉入單時，每家店都要看得到自己那一趟（見 lib/aidTransfer 的說明）
        const { data } = await sb
          .from("customer_order_transfer_links")
          .select(
            TRANSFER_LINK_SELECT + ", " +
              "src:customer_orders!customer_order_transfer_links_source_order_id_fkey(" +
              "pickup_store_id, store:stores!customer_orders_pickup_store_id_fkey(name)), " +
              // !inner + dest.status 篩選要在**伺服端**做：連結表只增不減
              // （567 筆起跳、每次轉單再加一列），拉回來才在前端濾會愈來愈慢，
              // 而且一旦超過 limit 就會靜默漏掉最舊的那幾筆 —— 提醒漏掉＝貨沒人送
              "dest:customer_orders!customer_order_transfer_links_dest_order_id_fkey!inner(" +
              "id, order_no, status, pickup_store_id, " +
              "store:stores!customer_orders_pickup_store_id_fkey(name), " +
              "items:customer_order_items(id, qty, status, source))",
          )
          .in("dest.status", [...AID_IN_FLIGHT_STATUSES])
          .order("transferred_at", { ascending: true })
          .limit(500);
        if (cancelled) return;
        type StoreRef = { name: string } | { name: string }[] | null;
        type Raw = TransferLink & {
          src: { pickup_store_id: number | null; store: StoreRef } | null;
          dest: {
            id: number; order_no: string; status: string; pickup_store_id: number | null;
            store: StoreRef;
            items: { id: number; qty: number; status: string; source: string | null }[] | null;
          } | null;
        };
        const raw = (data ?? []) as unknown as Raw[];
        const nameOf = (s: StoreRef) => (Array.isArray(s) ? s[0]?.name : s?.name) ?? "—";

        const list = raw.flatMap((r): AidShipment[] => {
          const src = r.src, dest = r.dest;
          if (!src || !dest) return [];
          // 收貨店收掉（ready 之後）就沒人需要為它做事了
          if (!(AID_IN_FLIGHT_STATUSES as readonly string[]).includes(dest.status)) return [];
          // 同店轉單（只是換客人）貨沒離開本店，不用出貨也不用收貨
          if (src.pickup_store_id === dest.pickup_store_id) return [];
          // 品項全被取消掉的單沒有實體貨在走，別再叫人去印一張空白單
          const qty = activeQty(linkItems(r, dest.items ?? []));
          if (qty <= 0) return [];
          return [{
            linkId: r.id,
            id: dest.id,
            order_no: dest.order_no,
            status: dest.status,
            is_air_transfer: r.is_air_transfer === true,
            dest_store: nameOf(dest.store),
            dest_store_id: dest.pickup_store_id,
            source_store: nameOf(src.store),
            source_store_id: src.pickup_store_id,
            qty,
          }];
        });
        setRows(list);
      } catch {
        // 提醒失敗不該擋住整個儀表板
        if (!cancelled) setRows([]);
      }
    })();
    return () => { cancelled = true; };
    // 查詢是全 tenant 的，方向與門市過濾都在 render 時做 —— 換門市不需要重打
  }, []);

  const markPrinted = useCallback((id: number) => {
    setPrinted((prev) => {
      const next = new Set(prev);
      next.add(id);
      try { localStorage.setItem(PRINTED_KEY, JSON.stringify([...next])); } catch { /* 隱私模式 */ }
      return next;
    });
  }, []);

  if (!rows || rows.length === 0) return null;

  // 選了門市（分店帳號一律鎖自己那家）→ 拆成轉出 / 轉入兩區；
  // 全部門市（HQ）→ 不分方向，一份在途清單
  const outgoing = storeId == null ? [] : rows.filter((r) => r.source_store_id === storeId);
  const incoming = storeId == null ? [] : rows.filter((r) => r.dest_store_id === storeId);
  const both = storeId == null ? rows : [];
  if (outgoing.length === 0 && incoming.length === 0 && both.length === 0) return null;

  return (
    <div className="space-y-3">
      {both.length > 0 && (
        <AidSection
          tone="all"
          title={`🤝 全站有 ${both.length} 筆互助的貨在路上`}
          hint="收貨店收貨後就會從這裡消失"
          rows={both}
          printed={printed}
          showPrinted={false}
          onPrinted={markPrinted}
        />
      )}
      {outgoing.length > 0 && (
        <AidSection
          tone="out"
          title={`🤝 有 ${outgoing.length} 筆互助的貨要交出去`}
          subtitle={(() => {
            const todo = outgoing.filter((r) => !printed.has(r.id)).length;
            return todo > 0 ? `（${todo} 筆還沒列印）` : undefined;
          })()}
          hint="印出來夾在箱子上交給司機；收貨店收貨後這裡就會消失"
          rows={outgoing}
          printed={printed}
          showPrinted
          onPrinted={markPrinted}
        />
      )}
      {incoming.length > 0 && (
        <AidSection
          tone="in"
          title={`📥 有 ${incoming.length} 筆互助的貨要進來`}
          hint="貨到了請到「收貨」頁收單；印一張對照著點收，數量不對當場就看得出來"
          rows={incoming}
          printed={printed}
          showPrinted={false}
          onPrinted={markPrinted}
        />
      )}
    </div>
  );
}

const TONE = {
  out: {
    section: "border-fuchsia-300 bg-fuchsia-50 dark:border-fuchsia-800 dark:bg-fuchsia-950/40",
    heading: "text-fuchsia-900 dark:text-fuchsia-200",
    hint: "text-fuchsia-700 dark:text-fuchsia-300",
    item: "border-fuchsia-200 dark:border-fuchsia-900",
    button: "border-fuchsia-400 text-fuchsia-700 hover:bg-fuchsia-50 dark:border-fuchsia-700 dark:text-fuchsia-300 dark:hover:bg-fuchsia-950",
  },
  in: {
    section: "border-sky-300 bg-sky-50 dark:border-sky-800 dark:bg-sky-950/40",
    heading: "text-sky-900 dark:text-sky-200",
    hint: "text-sky-700 dark:text-sky-300",
    item: "border-sky-200 dark:border-sky-900",
    button: "border-sky-400 text-sky-700 hover:bg-sky-50 dark:border-sky-700 dark:text-sky-300 dark:hover:bg-sky-950",
  },
  all: {
    section: "border-zinc-300 bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900",
    heading: "text-zinc-900 dark:text-zinc-100",
    hint: "text-zinc-600 dark:text-zinc-400",
    item: "border-zinc-200 dark:border-zinc-800",
    button: "border-zinc-400 text-zinc-700 hover:bg-zinc-100 dark:border-zinc-600 dark:text-zinc-300 dark:hover:bg-zinc-800",
  },
} as const;

function AidSection({
  tone, title, subtitle, hint, rows, printed, showPrinted, onPrinted,
}: {
  tone: keyof typeof TONE;
  title: string;
  subtitle?: string;
  hint: string;
  rows: AidShipment[];
  printed: Set<number>;
  // 「✓ 已列印」只對轉出方有意義（該印的人是他）；轉入方印的是核對聯，不要標
  showPrinted: boolean;
  onPrinted: (id: number) => void;
}) {
  const t = TONE[tone];
  return (
    <section className={`rounded-md border p-4 ${t.section}`}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className={`text-sm font-semibold ${t.heading}`}>
          {title}
          {subtitle && <span className="ml-2 font-normal">{subtitle}</span>}
        </h2>
        <span className={`text-xs ${t.hint}`}>{hint}</span>
      </div>
      <ul className="mt-3 space-y-2">
        {rows.map((r) => (
          <li
            key={r.linkId}
            className={`flex flex-wrap items-center gap-x-3 gap-y-1 rounded border bg-white px-3 py-2 text-sm dark:bg-zinc-900 ${t.item}`}
          >
            <span className="font-mono text-xs">{r.order_no}</span>
            <span className="font-medium">
              {r.source_store} <span className="font-normal text-zinc-400">→</span>{" "}
              {r.is_air_transfer ? "" : "總倉 → "}
              {r.dest_store}
            </span>
            <span className="text-xs text-zinc-500">{r.qty} 件</span>
            <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-[11px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
              {aidRouteLabel(r.is_air_transfer)}・{aidStageLabel(r.status, r.is_air_transfer)}
            </span>
            {showPrinted && printed.has(r.linkId) && (
              <span className="text-[11px] text-emerald-600 dark:text-emerald-400">✓ 已列印</span>
            )}
            <div className="ml-auto flex items-center gap-2">
              {tone === "in" && (
                <Link
                  href="/wms/inbound"
                  className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                >
                  去收貨
                </Link>
              )}
              <Link
                // 一定要帶 storeId=收貨店：訂單列表的門市篩選對分店帳號會預設帶回自家店，
                // 而這張轉入單掛在收貨店名下 —— 不帶就會搜出 0 筆（看起來像貨消失了）
                href={
                  `/orders?q=${encodeURIComponent(r.order_no)}` +
                  (r.dest_store_id != null ? `&storeId=${r.dest_store_id}` : "")
                }
                className="text-xs text-blue-600 hover:underline dark:text-blue-400"
              >
                查看訂單
              </Link>
              <SpinButton
                onClick={async () => {
                  onPrinted(r.linkId);
                  // 一定要帶 link：同一張轉入單可能併了好幾家店的貨，
                  // 只帶 order_id 會把別家店的品項也印進這張隨貨單
                  await printViaIframe(
                    withBasePath(`/transfers/print-aid?order_id=${r.id}&link=${r.linkId}`),
                  );
                }}
                className={`rounded-md border bg-white px-3 py-1 text-xs font-medium dark:bg-zinc-900 ${t.button}`}
                title="列印互助出貨單（司機聯 + 店家存根聯），格式跟內部調撥的轉貨單一樣"
              >
                🖨 列印出貨單
              </SpinButton>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}

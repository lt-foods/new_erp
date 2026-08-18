"use client";

// 儀表板提醒：本店有互助的貨要交出去，提醒店家把出貨單印出來給司機。
//
// 為什麼要主動提醒：互助的貨是「別人來拿」，出貨動作不像取貨那樣有客人站在櫃檯催。
// 店家不知道自己名下有貨等著被載走，就不會去印單 —— 司機來了拿了貨、紙上什麼都沒有，
// 中途少一箱沒人說得清（2026-08-15 店家回報）。
//
// 判定：轉入單（互助單）還沒被收貨店收掉（pending / confirmed / shipping），
// 而它的來源單是本店。
//   - pending   = 剛轉出、總倉還沒收到（**經總倉的轉入單一開始就是這個狀態**，
//                 見 rpc_transfer_order_to_store / _partial：跨店非空中轉建成 pending）
//   - confirmed = 總倉已收、還沒派貨；空中轉的話是自動出貨上線前卡住的舊單
//   - shipping  = 已建 AT- 轉移單，但收貨店還沒收 → 貨可能還在店裡等司機
//   收貨店收掉就變 ready，提醒自動消失。
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
import { AID_IN_FLIGHT_STATUSES, aidRouteLabel, aidStageLabel } from "@/lib/aidTransfer";

type PendingShip = {
  id: number;
  order_no: string;
  status: string;
  is_air_transfer: boolean;
  dest_store: string;
  dest_store_id: number | null;
  source_store: string;
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
  const [rows, setRows] = useState<PendingShip[] | null>(null);
  // rows 還沒載完（含 SSR）時整個元件回 null，所以這裡讀 localStorage 不會有 hydration 落差
  const [printed, setPrinted] = useState<Set<number>>(
    () => (typeof window === "undefined" ? new Set<number>() : loadPrinted()),
  );

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        // 還沒被收貨店收掉的互助轉入單（全 tenant，數量很少）
        const { data } = await sb
          .from("customer_orders")
          .select(
            "id, order_no, status, is_air_transfer, pickup_store_id, transferred_from_order_id, created_at, " +
              "store:stores!customer_orders_pickup_store_id_fkey(name), " +
              "items:customer_order_items!inner(qty, status, source)",
          )
          .eq("items.source", "aid_transfer")
          .in("status", [...AID_IN_FLIGHT_STATUSES])
          .not("transferred_from_order_id", "is", null)
          .order("created_at", { ascending: true })
          .limit(200);
        if (cancelled) return;
        type Raw = {
          id: number; order_no: string; status: string; is_air_transfer: boolean | null;
          pickup_store_id: number | null; transferred_from_order_id: number;
          store: { name: string } | { name: string }[] | null;
          items: { qty: number; status: string; source: string | null }[] | null;
        };
        const raw = (data ?? []) as unknown as Raw[];
        if (raw.length === 0) { setRows([]); return; }

        // 來源單 → 出貨店（貨從誰手上出去）
        const srcIds = Array.from(new Set(raw.map((r) => r.transferred_from_order_id)));
        const { data: srcData } = await sb
          .from("customer_orders")
          .select("id, pickup_store_id, store:stores!customer_orders_pickup_store_id_fkey(name)")
          .in("id", srcIds);
        if (cancelled) return;
        type SrcRaw = {
          id: number; pickup_store_id: number | null;
          store: { name: string } | { name: string }[] | null;
        };
        const nameOf = (s: { name: string } | { name: string }[] | null) =>
          (Array.isArray(s) ? s[0]?.name : s?.name) ?? "—";
        const srcMap = new Map<number, SrcRaw>(
          ((srcData ?? []) as unknown as SrcRaw[]).map((s) => [s.id, s]),
        );

        const list = raw.flatMap((r): PendingShip[] => {
          const src = srcMap.get(r.transferred_from_order_id);
          if (!src) return [];
          // 同店轉單（只是換客人）貨沒離開本店，不用出貨也不用印
          if (src.pickup_store_id === r.pickup_store_id) return [];
          // 儀表板選了門市（分店帳號一律鎖自己那家）→ 只提醒「要出貨的是本店」
          if (storeId != null && src.pickup_store_id !== storeId) return [];
          // 品項全被取消掉的單沒有實體貨要交，別再叫人去印一張空白單
          const qty = (r.items ?? [])
            .filter((it) => !["cancelled", "expired"].includes(it.status))
            .reduce((s, it) => s + Number(it.qty), 0);
          if (qty <= 0) return [];
          return [{
            id: r.id,
            order_no: r.order_no,
            status: r.status,
            is_air_transfer: r.is_air_transfer === true,
            dest_store: nameOf(r.store),
            dest_store_id: r.pickup_store_id,
            source_store: nameOf(src.store),
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
  }, [storeId]);

  const markPrinted = useCallback((id: number) => {
    setPrinted((prev) => {
      const next = new Set(prev);
      next.add(id);
      try { localStorage.setItem(PRINTED_KEY, JSON.stringify([...next])); } catch { /* 隱私模式 */ }
      return next;
    });
  }, []);

  if (!rows || rows.length === 0) return null;

  const todo = rows.filter((r) => !printed.has(r.id)).length;

  return (
    <section className="rounded-md border border-fuchsia-300 bg-fuchsia-50 p-4 dark:border-fuchsia-800 dark:bg-fuchsia-950/40">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-sm font-semibold text-fuchsia-900 dark:text-fuchsia-200">
          🤝 有 {rows.length} 筆互助的貨要交出去
          {todo > 0 && <span className="ml-2 font-normal">（{todo} 筆還沒列印）</span>}
        </h2>
        <span className="text-xs text-fuchsia-700 dark:text-fuchsia-300">
          印出來夾在箱子上交給司機；收貨店收貨後這裡就會消失
        </span>
      </div>
      <ul className="mt-3 space-y-2">
        {rows.map((r) => (
          <li
            key={r.id}
            className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded border border-fuchsia-200 bg-white px-3 py-2 text-sm dark:border-fuchsia-900 dark:bg-zinc-900"
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
            {printed.has(r.id) && (
              <span className="text-[11px] text-emerald-600 dark:text-emerald-400">✓ 已列印</span>
            )}
            <div className="ml-auto flex items-center gap-2">
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
                  markPrinted(r.id);
                  await printViaIframe(withBasePath(`/transfers/print-aid?order_id=${r.id}`));
                }}
                className="rounded-md border border-fuchsia-400 bg-white px-3 py-1 text-xs font-medium text-fuchsia-700 hover:bg-fuchsia-50 dark:border-fuchsia-700 dark:bg-zinc-900 dark:text-fuchsia-300 dark:hover:bg-fuchsia-950"
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

"use client";

// 店家少收的貨 — 總倉處理視窗
// 顯示:
//   - 這一筆的派出 / 實收 / 少收
//   - 這家店這個品項還有沒有客人在等(一句話講完,明細在下面)
//   - 三顆處理鈕 + 備註
//
// ⭐⭐⭐ 這支檔案的第一鐵則:畫面上每一句「系統會怎樣」的話,都要能指出出處。
//   2026-08-21 上一版在紅框裡寫了一句沒查證的推論(「古華那筆沒有任何人能再派它」),
//   Codex 審的是「程式對不對」,抓不到「畫面上寫的話是不是真的」⇒ 整輪審過了還是錯的。
//   ⛔ 查不到出處的話寧可少講一句。⛔ 不要寫「永遠」「沒有任何人」這種絕對句。
//   (那句話錯在只查了派貨工作台的路 1。路 2 補貨申請的可配量直接讀總倉真實庫存
//    stock_balances.on_hand —— v_picking_demand_no_po 最新版
//    20260612000040_approve_restock_via_picking_workstation.sql:73-78 的 hq_supply CTE
//    ⇒ 貨記回總倉之後,開一張補貨申請就派得出去。古華等兩個月的真因是沒人知道要開申請。)
//
// ⚠️ 三顆都是單行道(按下去回不來):
//   異常清單的 transfer_short 分支要求 ti.shortage_resolution IS NULL
//   (或 replenish 且還沒補到)才會列出來
//   (v_hq_exceptions 最新版 20260811020010_hq_exceptions_drop_customer_shortage.sql:141-162),
//   而 rpc_resolve_transfer_item_shortage 對所有 resolution 一律寫入 shortage_resolution
//   (最新版 20260811020000_transfer_shortage_redispatch.sql:262-270,沒有任何例外)
//   ⇒ 按完這一筆就從清單消失,之後不能再改選別的。
//   ⛔ 也因此不可以做批次 / 全選 / 一鍵處理(2026-08-21 老闆裁示)。
//
// ⚠️⚠️ 為什麼警語要做成擋眼的色底、不是灰色小字
//   2026-08-21 正式庫唯讀實測(hq_to_store、已收貨、實收<派出、已處理過的分組):
//     restock_hq  85 筆 / 230 件   accept 31 筆 / 89 件   redispatch 23 筆 / 155 件
//   ⇒ 「不補」被按的次數是「補一批」的 3.7 倍(85:23),而還有客人在等時正解是「補一批」。
//   ⛔ 不要為了版面清爽把它改回小灰字。
//   (數字是當時快照、會過期;⛔ 刻意不放進畫面文案,免得變成一句過期的謊)
//
// ⚠️ 畫面上只留三顆,但 DB 的允許值仍是六種
//   (20260811020000:69 的 CHECK 含 replenish/cancel_orders/vendor_claim)。
//   歷史資料還會有那三種值 —— 本檔只負責「新的選擇」,不負責顯示舊值;
//   舊值的顯示字串是 DB view 自己組的(20260811020010:118「· 已標補出貨,尚未補到」),
//   前端沒有任何 resolution → 文字的對照表 ⇒ 移除選項不會讓舊資料顯示成 undefined。
//   ⛔ 只動畫面,零 RPC 變更、零 migration。

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import { Modal } from "@/components/Modal";
import { ORDER_STATUS_LABEL, type OrderStatus } from "@/lib/orderStatus";

export type ShortageContext = {
  transfer_item_id: number;
  transfer_id: number;
  transfer_no: string;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  qty_shipped: number;
  qty_received: number;
  shortage_qty: number;
  dest_location: number;
  dest_store_id?: number | null;
  dest_store_name: string;
};

// 畫面上只給這三顆。老闆的模型:總倉只有兩個決定 —— 貨要不要退回總倉、店家的帳要不要扣。
//   退 + 扣 → redispatch(補一批) / restock_hq(不補)
//   不退 + 扣 → accept
//   不退 + 不扣(把貨算回給店家)→ 系統目前做不到,要另開案 ⇒ 畫面上不放。
type Resolution = "redispatch" | "restock_hq" | "accept";

const RESOLUTION_OPTIONS: Array<{
  value: Resolution;
  icon: string;
  title: string;
  desc: string;
  // 按下去會發生什麼「回不去」的事。一律顯示(不是選中才出現)—— 要在按之前就看到才有用。
  warn: string;
  warnTone: "danger" | "caution" | "info";
}> = [
  {
    value: "redispatch",
    icon: "🔁",
    title: "接受退回 — 貨回總倉，補一批給店家",
    desc:
      "少收的數量以原出庫成本記回總倉庫存，並自動開一張撿貨單給該店 —— " +
      "撿貨單會出現在收件匣的「📋 撿貨單」，樓下撿完再送一次。",
    warnTone: "info",
    // 出處:記回總倉 20260811020000:188-206(rpc_inbound 到 transfers.source_location);
    //      自動開 draft 撿貨單 20260811020000:222-245;
    //      draft 在收件匣撿貨單匣算待處理 hq/inbox/page.tsx 的 classifyPicking。
    // ⛔ 刻意不寫「客人訂單會自動推進」:那要再走 rpc_mark_orders_shipping_for_wave
    //    (20260614000050 最新版)且要 campaign 對得上,本檔沒有實測過 ⇒ 不寫進畫面。
    warn: "還有客人在等這批貨 → 選這顆。按完這一筆會從清單消失，但貨已經回到總倉、撿貨單也開好了。",
  },
  {
    value: "restock_hq",
    icon: "🏭",
    title: "接受退回 — 貨回總倉，不補",
    desc: "少收的數量以原出庫成本記回總倉庫存，不會自動再送給店家。",
    warnTone: "caution",
    // 出處:記回總倉 20260811020000:140-163;
    //      「開補貨申請就派得出去」= v_picking_demand_no_po 最新版 20260612000040:60-78
    //      (需求來自 restock_requests 且 status='approved_transfer';
    //       可配量 hq_supply 直接讀 stock_balances.on_hand,不需要採購單、不需要進貨單)。
    warn:
      "按下去回不來，這一筆會從清單消失。之後要再補給這家店：請該店開一張補貨申請，" +
      "總倉核准後就能從補貨申請直接派 —— 貨已經在總倉帳上，不用再進一次貨。",
  },
  {
    value: "accept",
    icon: "✋",
    title: "不接受退回",
    desc: "貨不回總倉，店家的帳照扣。",
    warnTone: "danger",
    // 出處:accept 在 RPC 裡沒有任何分支,只會走到最後那段 UPDATE
    //      (20260811020000:112-270,只有 restock_hq / redispatch 有 rpc_inbound);
    //      函式 COMMENT 原話「其餘 resolution 僅打標記」(20260811020000:281)。
    warn:
      "⚠️ 系統目前還不會把貨算回給店家，這筆損失公司會吃掉。請在下面寫清楚不接受的原因（會留在紀錄上）。",
  },
];

// warn 方塊的色底 —— 刻意用「擋眼」的實心底色,不是灰色小字(理由見檔頭的實測數字)
const WARN_TONE_CLASS: Record<"danger" | "caution" | "info", string> = {
  danger:
    "border-rose-400 bg-rose-100 font-semibold text-rose-900 dark:border-rose-600 dark:bg-rose-950 dark:text-rose-200",
  caution:
    "border-amber-300 bg-amber-100 text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-200",
  info: "border-blue-200 bg-blue-50 text-blue-900 dark:border-blue-800 dark:bg-blue-950/60 dark:text-blue-200",
};

type AffectedOrder = {
  id: number;
  order_no: string;
  member_id: number | null;
  pending_qty: number;
  status: string;
};

export function TransferShortageResolveModal({
  ctx,
  onClose,
  onSubmitted,
}: {
  ctx: ShortageContext;
  onClose: () => void;
  onSubmitted: () => void;
}) {
  const [resolution, setResolution] = useState<Resolution | null>(null);
  const [notes, setNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [affected, setAffected] = useState<AffectedOrder[] | null>(null);
  // 查不到(沒有分店 id / 查詢失敗)。⛔ 不可以跟「查到 0 張」混在一起顯示成
  // 「沒有客人在等」—— 那是把「我沒查到」講成「確定沒有」,正是本檔要根絕的那種假話。
  const [affectedFailed, setAffectedFailed] = useState(false);
  // 這張單的出貨端是不是總倉。null = 還在查 / 查不到 → 什麼都不多講(按鈕文案照預設)。
  // false = 確定不是總倉(店對店、店退回總倉)→ 上面兩顆的「貨回總倉」對這張單不成立,
  // 要明講,否則畫面就在說謊。
  const [srcIsHq, setSrcIsHq] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      // 沒有分店 id ＝ 這張單的收貨端不是分店(例如店退回總倉)→ 查不出客人訂單。
      // ⛔ 放在 async 裡而不是 effect body:effect body 同步 setState 會被
      //    react-hooks/set-state-in-effect 擋(原版就在這一行被標紅)。
      if (!ctx.dest_store_id) {
        if (!cancelled) { setAffected([]); setAffectedFailed(true); }
        return;
      }
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("customer_orders")
          .select(`id, order_no, status, member_id,
                   items:customer_order_items!inner(qty, status, sku_id)`)
          .eq("pickup_store_id", ctx.dest_store_id)
          .in("status", ["pending", "confirmed", "shipping", "ready"])
          .eq("items.sku_id", ctx.sku_id)
          .is("transferred_from_order_id", null)
          .limit(50);
        if (e) throw new Error(e.message);
        if (cancelled) return;
        const rows = ((data ?? []) as Array<{
          id: number;
          order_no: string;
          status: string;
          member_id: number | null;
          items: Array<{ qty: number; status: string; sku_id: number }>;
        }>).map((o) => {
          const matchingItems = o.items.filter((i) => i.sku_id === ctx.sku_id && !["cancelled", "expired"].includes(i.status));
          const pending = matchingItems.reduce((s, i) => s + Number(i.qty), 0);
          return { id: o.id, order_no: o.order_no, member_id: o.member_id, pending_qty: pending, status: o.status };
        }).filter((x) => x.pending_qty > 0);
        setAffected(rows);
        setAffectedFailed(false);
      } catch (e) {
        if (!cancelled) {
          // ⛔ 不要塞進 error 那個紅框:那個框是「送出失敗」用的,會讓人以為按鈕壞了。
          console.warn("查客人訂單失敗:", e);
          setAffected([]);
          setAffectedFailed(true);
        }
      }
    })();
    return () => { cancelled = true; };
  }, [ctx.dest_store_id, ctx.sku_id]);

  // 出貨端是不是總倉 —— 只為了「畫面別說謊」而查:
  //   ① 兩顆「貨回總倉」實際是把貨記回 transfers.source_location(20260811020000:155/193),
  //      店對店的單記回去的是「原本那家店」,不是總倉。
  //   ② 「補一批」對非總倉出貨的單會被 RPC 直接擋下
  //      (20260811020000:172-177 RAISE「出貨端不是總倉，無法自動重派」)。
  // 查不到就不顯示(維持預設文案),不要拿「查不到」當「確定不是」。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: t, error: e1 } = await sb
          .from("transfers")
          .select("source_location")
          .eq("id", ctx.transfer_id)
          .maybeSingle();
        if (e1) throw new Error(e1.message);
        const locId = (t as { source_location: number | null } | null)?.source_location;
        if (locId == null) return;
        const { data: l, error: e2 } = await sb
          .from("locations")
          .select("type")
          .eq("id", locId)
          .maybeSingle();
        if (e2) throw new Error(e2.message);
        if (cancelled) return;
        setSrcIsHq(((l as { type: string | null } | null)?.type ?? "") === "central_warehouse");
      } catch (e) {
        if (!cancelled) console.warn("查出貨端失敗:", e);
      }
    })();
    return () => { cancelled = true; };
  }, [ctx.transfer_id]);

  // 「不接受退回」＝公司吃掉這筆損失,一定要留下原因(老闆 2026-08-21 指定必填)
  const reasonRequired = resolution === "accept";
  const reasonMissing = reasonRequired && notes.trim() === "";

  async function submit() {
    if (!resolution) {
      setError("請選擇怎麼處理");
      return;
    }
    if (reasonMissing) {
      setError("選「不接受退回」一定要寫原因。");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_resolve_transfer_item_shortage", {
        p_transfer_item_id: ctx.transfer_item_id,
        p_resolution: resolution,
        p_notes: notes || null,
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      onSubmitted();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  const totalAffectedQty = affected?.reduce((s, o) => s + o.pending_qty, 0) ?? 0;

  return (
    <Modal open onClose={onClose} title="處理店家少收的貨" maxWidth="max-w-3xl">
      {/* 這一筆的數字 */}
      <div className="rounded-md border border-rose-200 bg-rose-50 p-3 dark:border-rose-900 dark:bg-rose-950/40">
        <div className="flex flex-wrap items-baseline gap-2">
          <span className="font-mono text-sm">{ctx.transfer_no}</span>
          <span className="text-xs text-zinc-500">→ {ctx.dest_store_name}</span>
        </div>
        <div className="mt-1 text-sm">
          <span className="font-mono text-[11px] text-zinc-500">{ctx.sku_code}</span>
          <span className="ml-1 font-medium">{ctx.sku_label}</span>
        </div>
        <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
          <div className="rounded border border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="text-zinc-500">派出</div>
            <div className="font-mono text-base font-semibold">{ctx.qty_shipped}</div>
          </div>
          <div className="rounded border border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="text-zinc-500">店家實收</div>
            <div className="font-mono text-base font-semibold">{ctx.qty_received}</div>
          </div>
          <div className="rounded border border-rose-300 bg-rose-100 p-2 dark:border-rose-700 dark:bg-rose-900/40">
            <div className="text-rose-700 dark:text-rose-300">少收</div>
            <div className="font-mono text-base font-bold text-rose-700 dark:text-rose-300">{ctx.shortage_qty}</div>
          </div>
        </div>
      </div>

      {/* 有沒有客人在等 —— 第一眼就要看懂,這是決定按哪一顆的唯一依據。
          ⛔ 舊版標題寫「📊 該店該品項待處理客戶訂單分析」,老闆看不懂(2026-08-21 退件)。 */}
      <div className="mt-4 rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        {affected === null ? (
          <div className="p-3 text-xs text-zinc-500">查詢中…</div>
        ) : affectedFailed ? (
          <div className="rounded-md border-l-4 border-amber-400 bg-amber-50 p-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            ⚠️ 查不到這一項的客人訂單，請自行確認有沒有人在等。
          </div>
        ) : affected.length === 0 ? (
          <div className="rounded-md border-l-4 border-emerald-400 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900 dark:bg-emerald-950 dark:text-emerald-200">
            ✅ 目前沒有客人在等這一項
            <div className="mt-0.5 text-[11px] font-normal opacity-80">
              （只算這家店、這個品項、還沒取消也還沒取走的訂單）
            </div>
          </div>
        ) : (
          <div>
            <div className="rounded-md border-l-4 border-rose-500 bg-rose-50 p-3 text-sm font-bold text-rose-900 dark:bg-rose-950 dark:text-rose-200">
              🔴 這一項還有 {affected.length} 張客人訂單在等（合計 {totalAffectedQty} 件）
              <div className="mt-0.5 text-[11px] font-normal opacity-80">
                {totalAffectedQty <= ctx.shortage_qty
                  ? "少收的量比客人要的還多 → 這些訂單可能全部拿不到貨"
                  : `少收 ${ctx.shortage_qty} 件 / 客人要 ${totalAffectedQty} 件 → 有一部分拿不到`}
              </div>
            </div>
            <ul className="max-h-32 space-y-0.5 overflow-y-auto px-3 py-2 text-xs">
              {affected.slice(0, 10).map((o) => (
                <li key={o.id} className="flex items-baseline gap-2">
                  <span className="font-mono text-zinc-700 dark:text-zinc-300">{o.order_no}</span>
                  <span className="text-zinc-500">會員 #{o.member_id ?? "—"}</span>
                  <span className="text-zinc-500">{o.pending_qty} 件</span>
                  <span className="rounded bg-zinc-100 px-1 py-0.5 text-[9px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                    {ORDER_STATUS_LABEL[o.status as OrderStatus] ?? o.status}
                  </span>
                </li>
              ))}
              {affected.length > 10 && (
                <li className="text-[11px] text-zinc-400">… 還有 {affected.length - 10} 張</li>
              )}
            </ul>
          </div>
        )}
      </div>

      {/* 三顆處理鈕 */}
      <div className="mt-4 space-y-2">
        <div className="text-xs font-semibold text-zinc-700 dark:text-zinc-300">要怎麼處理？ *</div>

        <div className="rounded border-2 border-rose-400 bg-rose-100 p-2 text-[11px] leading-relaxed text-rose-900 dark:border-rose-600 dark:bg-rose-950 dark:text-rose-200">
          <div className="font-bold">⚠️ 三顆都是按下去就回不來，先想清楚再按</div>
          <div className="mt-0.5">
            按完之後這一筆就會從「異常」清單消失，<span className="font-bold">不能再改選別的</span>。
          </div>
        </div>

        {/* 只在「確定出貨端不是總倉」時才出現:這種單上面兩顆的「回總倉」不成立。 */}
        {srcIsHq === false && (
          <div className="rounded border-2 border-amber-400 bg-amber-100 p-2 text-[11px] leading-relaxed text-amber-900 dark:border-amber-600 dark:bg-amber-950 dark:text-amber-200">
            <span className="font-bold">這張單不是總倉派出去的。</span>
            貨會退回<span className="font-bold">原本出貨的那個地方</span>（不是總倉），
            而且第一顆「補一批給店家」會被系統擋下來。
          </div>
        )}

        {RESOLUTION_OPTIONS.map((opt) => {
          const active = resolution === opt.value;
          return (
            <label
              key={opt.value}
              className={`flex cursor-pointer items-start gap-3 rounded-md border p-3 transition ${
                active
                  ? "border-blue-400 bg-blue-50 dark:border-blue-700 dark:bg-blue-950/30"
                  : "border-zinc-200 bg-white hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:hover:bg-zinc-950"
              }`}
            >
              <input
                type="radio"
                name="resolution"
                value={opt.value}
                checked={active}
                onChange={() => setResolution(opt.value)}
                className="mt-1"
              />
              <div className="flex-1">
                <div className="flex items-baseline gap-2">
                  <span className="text-base">{opt.icon}</span>
                  <span className="font-medium">{opt.title}</span>
                </div>
                <div className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">{opt.desc}</div>
                {/* 「按下去會發生什麼回不去的事」一律顯示,不只在選中時才出現 ——
                    要在按之前就看到才有用。⛔ 不可以改回無底色的小灰字:2026-08-21 實測
                    「不補」被誤按的次數是「補一批」的 3.7 倍(理由見檔頭)。 */}
                <div
                  className={`mt-1.5 rounded border px-2 py-1.5 text-[11px] leading-relaxed ${
                    WARN_TONE_CLASS[opt.warnTone]
                  }`}
                >
                  {opt.warn}
                </div>
              </div>
            </label>
          );
        })}
      </div>

      {/* 備註 —— 選「不接受退回」時必填 */}
      <label className="mt-4 block text-xs">
        <span className="block font-semibold text-zinc-700 dark:text-zinc-300">
          {reasonRequired ? "不接受的原因（必填）*" : "備註（選填）"}
        </span>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          placeholder={
            reasonRequired
              ? "例如：店家自己弄丟的 / 已跟店長談過由店家自行吸收 / 送達時清點無誤"
              : "例如：已通知司機張先生補送 / 物流單號 XXX-XX / 顧客同意延期至下批貨"
          }
          rows={2}
          className={`mt-1 w-full rounded-md border bg-white px-2 py-1 text-sm dark:bg-zinc-800 ${
            reasonMissing
              ? "border-rose-400 dark:border-rose-600"
              : "border-zinc-300 dark:border-zinc-700"
          }`}
        />
        {reasonMissing && (
          <span className="mt-1 block text-[11px] font-semibold text-rose-600 dark:text-rose-400">
            這筆損失公司會吃掉，請先寫清楚原因才能送出。
          </span>
        )}
      </label>

      {error && (
        <div className="mt-3 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="mt-4 flex justify-end gap-2">
        <SpinButton
          onClick={onClose}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          取消
        </SpinButton>
        <SpinButton
          onClick={submit}
          disabled={!resolution || reasonMissing || submitting}
          className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
        >
          {submitting ? "處理中…" : "✓ 送出"}
        </SpinButton>
      </div>
    </Modal>
  );
}

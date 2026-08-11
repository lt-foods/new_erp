"use client";

import { Suspense, useEffect, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { PickupDialog } from "@/components/PickupDialog";
import OrderReturnCreateModal from "@/components/OrderReturnCreateModal";
import { withBasePath } from "@/lib/basePath";
import { printViaIframe } from "@/lib/printIframe";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import PickupAgingPanel from "@/components/PickupAgingPanel";
import { dropPickupRecent, getPickupRecents, recordPickupRecent, type RecentCustomer } from "@/lib/pickupRecents";
import { publicProductUrl } from "@/lib/campaignCover";
import { parseReturnNote } from "@/lib/returnNote";
import { fetchReprintableEvents, pickupEventLabel, type PickupEventRow } from "@/lib/pickupReceipt";
import { itemDisplayName } from "@/lib/skuLabel";

type Member = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  admin_note: string | null;
  no_notify_pickup: boolean;
  no_new_order: boolean;
};

type OpenOrder = {
  id: number;
  order_no: string;
  status: string;
  pickup_deadline: string | null;
  pickup_store_id: number | null;
  discount_amount: number;
  ready_at: string | null;       // 到貨時間 (shipping → ready 自動寫入)
  transferred_from_order_id: number | null; // 互助轉入單才有；用來判斷是否走「退回原店」
  last_notify_pickup_at: string | null;
  notify_pickup_count: number;
  campaign: { id: number; campaign_no: string; name: string; cutoff_date: string | null } | null;
  store: { id: number; name: string } | null;
  items: {
    id: number;
    sku_id: number | null;
    qty: number;
    unit_price: number;
    status: string;
    sku: {
      variant_name: string | null;
      product_name: string | null;
      product: { images: string[] | null } | null;
    } | null;
  }[];
};

const ACTIVE_STATUSES = ["pending", "confirmed", "reserved", "ready", "partially_ready", "partially_completed", "shipping"];
const INACTIVE_ITEM_STATUSES = new Set(["cancelled", "picked_up", "expired"]);
// 「已取貨」模式：取過的單（partially_completed 兩邊都會出現 — 未取模式看還沒取的，
// 已取模式看已經取走的那部分）。一次最多列這麼多張，避免老客戶幾百張單全撈回來。
const PICKED_STATUSES = ["completed", "partially_completed"];
const PICKED_LIMIT = 50;

type PickupMode = "open" | "picked";

function activeItems(order: OpenOrder) {
  return order.items.filter((it) => !INACTIVE_ITEM_STATUSES.has(it.status));
}

export default function PickupPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PickupPageContent />
    </Suspense>
  );
}

function PickupPageContent() {
  const searchParams = useSearchParams();
  const initialQuery = searchParams.get("q") ?? "";
  const [query, setQuery] = useState(initialQuery);
  const [searching, setSearching] = useState(false);
  const [members, setMembers] = useState<Member[] | null>(null);
  const [orders, setOrders] = useState<Map<number, OpenOrder[]>>(new Map());
  // item.id → 該品項是否已到貨可取（v_order_item_pickup_ready）。
  // 部分到貨的 shipping 單靠這個讓「已到的品項」可先取。
  const [itemReady, setItemReady] = useState<Map<number, boolean>>(new Map());
  // item.id → 未取退貨量（return_to_hq transfer 依 SKU 聚合後分攤到各品項行，
  // 與 PickupDialog 同構）。退回總倉的量店裡沒有、不可再取。
  const [returnedByItem, setReturnedByItem] = useState<Map<number, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const autoSearchedRef = useRef(false);
  // 最後一次真的查成功的關鍵字。常用顧客快選與 ?q= 進來時刻意不寫進搜尋框，
  // 之後的重查（取貨後 reload、切換未取/已取）就沒有關鍵字可用 → 會誤報「請至少輸入 2 字」。
  const lastSearchRef = useRef("");

  // 該品項未取退貨量 / 扣掉已退後仍可取量
  function returnedOf(it: OpenOrder["items"][number]): number {
    return returnedByItem.get(it.id) ?? 0;
  }
  function remainingQty(it: OpenOrder["items"][number]): number {
    return Math.max(0, Number(it.qty) - returnedOf(it));
  }

  // 可取貨品項：ready 單＝全部 active 品項；shipping / partially_completed 單＝
  // 逐品項看到貨狀態（部分到貨的單可先取已到的品項）。
  // itemReady 查無資料時的 fallback 沿用舊行為：partially_completed 可取、shipping 不可取。
  // 一律排除「量已被未取退貨蓋掉」的品項行（退回總倉的貨不可再取）。
  function pickableItems(order: OpenOrder) {
    const act = activeItems(order).filter((it) => remainingQty(it) > 0);
    // ready 單原本整單放行，但「少發配貨」會把沒配到的品項標成待補貨
    // （customer_order_items.backorder_at → is_order_item_pickup_ready 回 false）。
    // 不濾掉的話店員會勾得到、按下去才被 rpc_record_pickup 擋，訊息還會誤導成「尚未到貨」。
    if (order.status === "ready") return act.filter((it) => itemReady.get(it.id) !== false);
    if (order.status === "partially_completed") return act.filter((it) => itemReady.get(it.id) !== false);
    if (order.status === "shipping") return act.filter((it) => itemReady.get(it.id) === true);
    return [];
  }
  function isPickable(order: OpenOrder): boolean {
    return pickableItems(order).length > 0;
  }
  // 該品項是否為「少發沒配到」→ 取貨頁要明講待補貨，不要只是消失
  function isBackordered(order: OpenOrder, it: OpenOrder["items"][number]): boolean {
    return order.status !== "shipping" && itemReady.get(it.id) === false;
  }

  const [pickup, setPickup] = useState<{ orderId: number; orderNo: string } | null>(null);
  const [returnTarget, setReturnTarget] = useState<{ orderId: number; storeId: number | null } | null>(null);
  const [recents, setRecents] = useState<RecentCustomer[]>([]);
  const [bulking, setBulking] = useState<number | null>(null);
  const [bulkConfirm, setBulkConfirm] = useState<Member | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  // 未取貨（預設，可取貨/合併取貨）↔ 已取貨（補印收據用）
  const [mode, setMode] = useState<PickupMode>("open");
  // 已取貨模式：order_id → 可補印的取貨事件（已濾掉被撤銷的）
  const [pickedEvents, setPickedEvents] = useState<Map<number, PickupEventRow[]>>(new Map());
  // 已取貨模式的合併列印確認視窗（對齊未取貨的「一次全取」— 先看清單與合計再印）
  const [printConfirm, setPrintConfirm] = useState<Member | null>(null);
  // 已取貨模式的「品項層級」勾選（item.id）。客人這批只要 A/B/D 不要 C 時就挑品項；
  // 整張勾＝把該張的已取品項全部加進來，兩種粒度共用同一個集合。
  const [selectedItems, setSelectedItems] = useState<Set<number>>(new Set());

  // overrideQuery：常用顧客快選按鈕用 — 直接帶該顧客查單，
  // 刻意「不」寫進搜尋框（保持輸入框乾淨，按鈕本身就是捷徑）
  async function search(e?: React.FormEvent, overrideQuery?: string, overrideMode?: PickupMode) {
    e?.preventDefault();
    const activeMode = overrideMode ?? mode;
    const q = (overrideQuery ?? (query.trim() || lastSearchRef.current)).trim();
    if (q.length < 2) {
      setError("請至少輸入 2 字 (姓名 / 電話末 N 碼 / 會員編號)");
      return;
    }
    lastSearchRef.current = q;
    setSearching(true);
    setError(null);
    setMembers(null);
    setOrders(new Map());
    setPickedEvents(new Map());
    setSelected(new Set());
    setSelectedItems(new Set());
    try {
      const sb = getSupabase();
      // 與會員頁 / 開團入單 / 轉單同一支 RPC（Google 式多 token 搜尋）。
      // 直接查 members 只擋 deleted 會把已合併 (merged) 的舊帳號也搜出來 —
      // 訂單早已搬到新會員身上，對舊檔什麼都做不了；RPC 會把命中的舊檔
      // 翻譯成併入的新會員並去重
      const { data: ms, error: e1 } = await sb.rpc("rpc_search_members", { p_term: q, p_limit: 20 });
      if (e1) { setError(e1.message); return; }
      const list = (ms ?? []) as Member[];
      setMembers(list);

      // 快選鈕是用 member_no 帶進來查的（q === rc.member_no）。若那個 member_no 的
      // 本人沒出現在結果裡，代表它已被合併到別人身上（RPC 翻成新會員了）或已刪除 →
      // 淘汰這顆幽靈鈕，免得櫃台一直看到一排點了對不上人的舊名字。
      const ghost = recents.find((r) => r.member_no === q);
      if (ghost && !list.some((m) => m.id === ghost.id)) {
        dropPickupRecent(ghost.id);
        setRecents(getPickupRecents());
      }

      if (list.length === 0) return;

      // 搜尋有結果即記入「常用顧客」（不必等取貨）。
      // ≤5 筆視為「找到特定顧客」才記；>5 視為廣搜（如只打姓氏），不記以免洗版。
      if (list.length <= 5) {
        for (const mem of list) {
          recordPickupRecent({ id: mem.id, name: mem.name, member_no: mem.member_no, phone: mem.phone });
        }
        setRecents(getPickupRecents());
      }

      const ordQ = sb
        .from("customer_orders")
        .select(
          `id, order_no, status, pickup_deadline, pickup_store_id, discount_amount, ready_at, transferred_from_order_id, last_notify_pickup_at, notify_pickup_count, member_id,
           campaign:group_buy_campaigns(id, campaign_no, name, cutoff_date),
           store:stores!customer_orders_pickup_store_id_fkey(id, name),
           items:customer_order_items(id, sku_id, qty, unit_price, status, sku:skus(variant_name, product_name, product:products(images)))`,
        )
        .in("member_id", list.map((m) => m.id));
      const { data: ords, error: e2 } = await (
        activeMode === "picked"
          // 已取貨：最近取的排前面（completed_at 由 rpc_record_pickup 寫入、撤銷取貨時清空）
          ? ordQ
              .in("status", PICKED_STATUSES)
              .order("completed_at", { ascending: false, nullsFirst: false })
              .order("updated_at", { ascending: false })
              .limit(PICKED_LIMIT)
          // 未取貨：到貨時間早 (久) 的排前面（催客人取貨優先）；尚未到貨的擺後面
          : ordQ
              .in("status", ACTIVE_STATUSES)
              .order("ready_at", { ascending: true, nullsFirst: false })
              .order("updated_at", { ascending: false })
      );
      if (e2) { setError(e2.message); return; }

      const orderIds = (ords ?? []).map((r) => (r as { id: number }).id);

      // 已取貨模式只需要「哪幾張還印得出收據」— 到貨狀態 / 未取退貨都與補印無關，不查。
      if (activeMode === "picked") {
        setPickedEvents(await fetchReprintableEvents(orderIds));
        setItemReady(new Map());
        setReturnedByItem(new Map());
        const pm = new Map<number, OpenOrder[]>();
        for (const r of (ords ?? []) as unknown as (OpenOrder & { member_id: number })[]) {
          const arr = pm.get(r.member_id) ?? [];
          arr.push(r);
          pm.set(r.member_id, arr);
        }
        setOrders(pm);   // 順序沿用查詢的 completed_at DESC（最近取的在最上面）
        return;
      }

      // 品項到貨狀態（部分到貨的 shipping 單要逐品項判斷哪些可先取）
      const readyMap = new Map<number, boolean>();
      if (orderIds.length > 0) {
        const { data: irs } = await sb
          .from("v_order_item_pickup_ready")
          .select("item_id, pickup_ready")
          .in("order_id", orderIds);
        for (const r of (irs ?? []) as { item_id: number; pickup_ready: boolean }[]) {
          readyMap.set(r.item_id, !!r.pickup_ready);
        }
      }
      setItemReady(readyMap);

      // 未取退貨量（return_to_hq transfer）— 退掉的貨店裡沒有、不可再取。
      // 依 SKU 聚合後分攤到各 active 品項行（行序 by id，與 PickupDialog 同構）。
      // 「取貨後退回」(|取貨後退回) 是客戶已取走的貨，不佔未取品項的可取量。
      const retMap = new Map<number, number>();
      if (orderIds.length > 0) {
        const { data: rts } = await sb
          .from("transfers")
          .select("customer_order_id, notes, transfer_items(sku_id, qty_shipped)")
          .in("customer_order_id", orderIds)
          .eq("transfer_type", "return_to_hq")
          .in("status", ["shipped", "received"]);
        const retBySku = new Map<number, Map<number, number>>(); // orderId → skuId → 已退量
        for (const t of (rts ?? []) as { customer_order_id: number; notes: string | null; transfer_items: { sku_id: number | null; qty_shipped: number | null }[] | null }[]) {
          if (parseReturnNote(t.notes).isRestock) continue;
          const m2 = retBySku.get(t.customer_order_id) ?? new Map<number, number>();
          for (const ti of t.transfer_items ?? []) {
            if (ti.sku_id == null) continue;
            m2.set(ti.sku_id, (m2.get(ti.sku_id) ?? 0) + Number(ti.qty_shipped ?? 0));
          }
          retBySku.set(t.customer_order_id, m2);
        }
        for (const r of (ords ?? []) as unknown as OpenOrder[]) {
          const m2 = retBySku.get(r.id);
          if (!m2 || m2.size === 0) continue;
          const remaining = new Map(m2);
          const acts = activeItems(r).slice().sort((a, b) => a.id - b.id);
          for (const it of acts) {
            if (it.sku_id == null) continue;
            const rem = remaining.get(it.sku_id) ?? 0;
            if (rem <= 0) continue;
            const alloc = Math.min(Number(it.qty), rem);
            retMap.set(it.id, alloc);
            remaining.set(it.sku_id, rem - alloc);
          }
        }
      }
      setReturnedByItem(retMap);

      const m = new Map<number, OpenOrder[]>();
      for (const r of (ords ?? []) as unknown as (OpenOrder & { member_id: number })[]) {
        const arr = m.get(r.member_id) ?? [];
        arr.push(r);
        m.set(r.member_id, arr);
      }
      // 依「可取貨」優先 + 到貨時間久的優先（催客人取貨）
      // status='ready' 在前；group 內 ready_at ASC NULLS LAST；末層 updated_at DESC
      for (const arr of m.values()) {
        arr.sort((a, b) => {
          const aReady = a.status === "ready";
          const bReady = b.status === "ready";
          if (aReady !== bReady) return aReady ? -1 : 1;
          const aT = a.ready_at ? Date.parse(a.ready_at) : Number.POSITIVE_INFINITY;
          const bT = b.ready_at ? Date.parse(b.ready_at) : Number.POSITIVE_INFINITY;
          if (aT !== bT) return aT - bT;
          return 0;
        });
      }
      setOrders(m);
    } finally {
      setSearching(false);
    }
  }

  // 該張單「已取走」的品項（撤銷取貨會把品項還原成 pending，所以撤銷過的不會出現）
  function pickedItemsOf(order: OpenOrder) {
    return order.items.filter((it) => it.status === "picked_up");
  }
  function orderSelState(order: OpenOrder): "all" | "some" | "none" {
    const its = pickedItemsOf(order);
    if (its.length === 0) return "none";
    const n = its.filter((it) => selectedItems.has(it.id)).length;
    return n === 0 ? "none" : n === its.length ? "all" : "some";
  }
  function toggleItem(itemId: number) {
    setSelectedItems((s) => {
      const next = new Set(s);
      if (next.has(itemId)) next.delete(itemId); else next.add(itemId);
      return next;
    });
  }
  // 整張的勾選框＝該張所有已取品項一起加/減
  function toggleOrderItems(order: OpenOrder) {
    const its = pickedItemsOf(order);
    const all = orderSelState(order) === "all";
    setSelectedItems((s) => {
      const next = new Set(s);
      for (const it of its) { if (all) next.delete(it.id); else next.add(it.id); }
      return next;
    });
  }

  // 已取貨模式：算出「這次要印哪些」。沒勾任何東西＝該會員全部已取品項。
  // 一次只印一個會員 — 列印頁的表頭與合計都取第一張的會員，跨會員合印會印錯人。
  function pickedSelection(member: Member) {
    const memberOrders = (orders.get(member.id) ?? []).filter((o) => pickedItemsOf(o).length > 0);
    const anySelected = memberOrders.some((o) => orderSelState(o) !== "none");
    const groups = memberOrders
      .map((o) => ({
        order: o,
        items: anySelected
          ? pickedItemsOf(o).filter((it) => selectedItems.has(it.id))
          : pickedItemsOf(o),
      }))
      .filter((g) => g.items.length > 0);
    // 全都是「整張全取」且每張都有取貨事件 → 可以印回「當時那張收據」（依取貨當次分段）；
    // 只要有一張是挑品項的，就改印品項明細（收據是以取貨事件為單位，挑不了單一品項）。
    const wholeOrders = groups.every(
      (g) => g.items.length === pickedItemsOf(g.order).length && (pickedEvents.get(g.order.id)?.length ?? 0) > 0,
    );
    const itemIds = groups.flatMap((g) => g.items.map((it) => it.id)).sort((a, b) => a - b);
    const eventIds = groups
      .flatMap((g) => (pickedEvents.get(g.order.id) ?? []).map((e) => e.id))
      .sort((a, b) => a - b);
    return { groups, wholeOrders, itemIds, eventIds };
  }

  // 送印：整張全取 → 原樣收據（/pickup/print）；挑品項 → 品項明細（/pickup/print-picked）
  function printPickedMerged(member: Member) {
    const { groups, wholeOrders, itemIds, eventIds } = pickedSelection(member);
    setPrintConfirm(null);
    if (groups.length === 0) {
      setError("沒有可列印的已取品項（取貨可能已被撤銷）");
      return;
    }
    setError(null);
    printViaIframe(withBasePath(
      wholeOrders
        ? `/pickup/print?event_ids=${eventIds.join(",")}`
        : `/pickup/print-picked?item_ids=${itemIds.join(",")}`,
    ));
  }

  function toggleSelect(orderId: number) {
    setSelected((s) => {
      const next = new Set(s);
      if (next.has(orderId)) next.delete(orderId); else next.add(orderId);
      return next;
    });
  }

  async function bulkPickAllConfirmed(member: Member) {
    const memberId = member.id;
    const allMemberOrders = (orders.get(memberId) ?? []).filter((o) => isPickable(o));
    // 若有勾選 → 只取勾選的（且可取貨）；無勾選 → 全取
    const memberSelected = allMemberOrders.filter((o) => selected.has(o.id));
    const memberOrders = memberSelected.length > 0 ? memberSelected : allMemberOrders;
    if (memberOrders.length === 0) return;
    setBulkConfirm(null);
    setBulking(memberId);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) { setError("尚未登入"); return; }
      let okCount = 0;
      const errors: string[] = [];
      const eventIds: number[] = [];
      for (const o of memberOrders) {
        // 只取已到貨的品項（部分到貨的單，未到品項留待補貨後續取）
        const picks = pickableItems(o);
        const itemIds = picks.map((it) => it.id);
        // 部分退貨的品項行只取「扣掉已退」的量（整行取會被後端退貨守門擋下）
        const itemQtys: Record<string, number> = {};
        for (const it of picks) {
          const take = remainingQty(it);
          if (take < Number(it.qty)) itemQtys[String(it.id)] = take;
        }
        const { data, error: e } = await sb.rpc("rpc_record_pickup", {
          p_order_id: o.id,
          p_item_ids: itemIds,
          p_operator: operator,
          p_notes: "一次全取",
          ...(Object.keys(itemQtys).length > 0 ? { p_item_qtys: itemQtys } : {}),
        });
        if (e) errors.push(`${o.order_no}: ${e.message}`);
        else {
          okCount++;
          const ev = data as { event_id: number };
          if (ev?.event_id) eventIds.push(ev.event_id);
        }
      }
      if (errors.length > 0) setError(errors.join("\n"));
      if (eventIds.length > 0) {
        // 自動列印 — 大張取貨單 + 熱感應小白單（隱藏 iframe,不跳新分頁;依序印）
        printViaIframe(withBasePath(`/pickup/print?event_ids=${eventIds.join(",")}`));
        const okOrderIds = memberOrders.map((o) => o.id).join(",");
        printViaIframe(withBasePath(`/pickup/print-list?order_ids=${okOrderIds}`));
      }
      alert(`完成 ${okCount}/${memberOrders.length} 張取貨${errors.length > 0 ? `\n失敗 ${errors.length} 張：\n${errors.join("\n")}` : ""}`);
      setReloadTick((t) => t + 1);
    } finally {
      setBulking(null);
    }
  }

  // 單張一鍵取貨 — 不開明細視窗，直接取走所有「可取(已到貨)」品項並列印（＝「一次全取」的單張版）。
  // 需要 折扣 / 只取部分品項 / 扣儲值金 時，改按旁邊的 ✏️（進階）開 PickupDialog。
  async function quickPickup(order: OpenOrder) {
    const picks = pickableItems(order);
    const itemIds = picks.map((it) => it.id);
    if (itemIds.length === 0) return;
    setError(null);
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id;
    if (!operator) { setError("尚未登入"); return; }
    // 部分退貨的品項行只取「扣掉已退」的量（整行取會被後端退貨守門擋下）
    const itemQtys: Record<string, number> = {};
    for (const it of picks) {
      const take = remainingQty(it);
      if (take < Number(it.qty)) itemQtys[String(it.id)] = take;
    }
    const { data, error: e } = await sb.rpc("rpc_record_pickup", {
      p_order_id: order.id,
      p_item_ids: itemIds,
      p_operator: operator,
      p_notes: null,
      ...(Object.keys(itemQtys).length > 0 ? { p_item_qtys: itemQtys } : {}),
    });
    if (e) { setError(`${order.order_no}：${translateRpcError(e)}`); return; }
    const ev = data as { event_id: number; active_remaining: number };
    if (ev?.event_id) {
      // 取貨單一定印；還有未取品項(部分到貨) → 追加取貨清單提醒剩下未取的
      printViaIframe(withBasePath(`/pickup/print?event_ids=${ev.event_id}`));
      if (ev.active_remaining > 0) {
        printViaIframe(withBasePath(`/pickup/print-list?order_ids=${order.id}`));
      }
    }
    setReloadTick((n) => n + 1);
  }

  // 取消訂單 — 沿用訂單頁完全相同的 rpc_cancel_aid_order 流程：
  // pending/confirmed 直接取消；shipping 若有掛單的派貨單（互助單）會撤回並反向回收已出庫存，
  // 波次出貨的一般訂單沒有 per-order transfer → 直接取消、不動庫存。
  // 取消後 reloadTick++ 重跑搜尋，該單因不在 ACTIVE_STATUSES 而從列表消失。
  async function cancelOrder(order: OpenOrder) {
    const reason = prompt(
      order.status === "shipping"
        ? `撤回派貨：${order.order_no}\n互助單會撤回派貨單並反向回收已出庫存；波次出貨的訂單不動庫存。請輸入原因：`
        : `取消訂單：${order.order_no}\n請輸入取消原因：`,
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { error: rpcErr } = await sb.rpc("rpc_cancel_aid_order", {
      p_order_id: order.id,
      p_reason: reason,
      p_operator: operator,
    });
    if (rpcErr) { alert(`取消失敗：${translateRpcError(rpcErr)}`); return; }
    alert("已取消");
    setReloadTick((n) => n + 1);
  }

  // 互助單已收貨(ready)退回原店：反向退回原調出店並還原來源單（rpc_return_aid_order）。
  // 貨源是分店不是總倉，所以不走「退貨回總倉」。
  async function returnAidToSource(order: OpenOrder) {
    const reason = prompt(
      `退回原店：${order.order_no}\n會把已收貨品反向退回原調出店，並把來源單還原。請輸入原因：`,
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { data, error: rpcErr } = await sb.rpc("rpc_return_aid_order", {
      p_order_id: order.id,
      p_reason: reason,
      p_operator: operator,
    });
    if (rpcErr) { alert(`退回失敗：${translateRpcError(rpcErr)}`); return; }
    const refunded = Number((data as { wallet_refunded?: number } | null)?.wallet_refunded ?? 0);
    alert(refunded > 0
      ? `已退回原店，已退回 $${refunded} 儲值金到會員餘額`
      : "已退回原店，貨已退回原調出店");
    setReloadTick((n) => n + 1);
  }

  // 重新跑搜尋（取貨後 reload）
  useEffect(() => {
    if (reloadTick > 0 && members && members.length > 0) {
      search();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reloadTick]);

  // 通知個別客人來取貨：寫 in-app + push（admin-notify edge fn）+ 更新 last_notify_pickup_at
  const [notifyingId, setNotifyingId] = useState<number | null>(null);
  async function notifyPickup(member: Member, order: OpenOrder) {
    if (member.no_notify_pickup) {
      alert(`${member.name ?? member.member_no} 已設「不通知」，無法發送取貨通知。`);
      return;
    }
    if (order.status !== "ready") {
      alert("此訂單尚未到貨，無法通知");
      return;
    }
    if (notifyingId != null) return;
    const since = order.last_notify_pickup_at
      ? `（已通知 ${order.notify_pickup_count} 次，上次 ${new Date(order.last_notify_pickup_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}）`
      : "";
    if (!confirm(`要通知 ${member.name ?? member.member_no} 來取「${order.campaign?.name ?? "—"}」嗎？${since}`)) return;
    setNotifyingId(order.id);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const token = sess.session?.access_token;
      const operator = sess.session?.user?.id;
      if (!token || !operator) { setError("尚未登入"); return; }

      const resp = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/admin-notify`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({
          member_id: member.id,
          title: "您的訂單已到貨可取",
          message: `「${order.campaign?.name ?? ""}」已在 ${order.store?.name ?? ""} 等候您取貨，請儘速前來。`,
          url: "/orders",
          category: "order_arrived",
        }),
      });
      const result = await resp.json();
      if (!resp.ok) { alert(`推播失敗：${result.error || resp.status}`); return; }

      const { error: rpcErr } = await sb.rpc("rpc_mark_pickup_notified", {
        p_order_id: order.id,
        p_operator: operator,
      });
      if (rpcErr) { alert(`記錄失敗：${rpcErr.message}`); return; }

      alert(`已通知（推播 ${result.sent ?? 0} 個裝置）`);
      setReloadTick((n) => n + 1);
    } finally {
      setNotifyingId(null);
    }
  }

  // 常用顧客快選列：mount 後才讀 localStorage（避免 SSR/prerender hydration mismatch）
  useEffect(() => {
    setRecents(getPickupRecents());
  }, []);

  // 從 /members 點「查訂單」帶 ?q= 進來,首次自動觸發搜尋
  useEffect(() => {
    if (!autoSearchedRef.current && initialQuery.trim().length >= 2) {
      autoSearchedRef.current = true;
      // 明確帶入 ?q=（不能只靠 query state — 它是首次 render 的快照，
      // searchParams 晚一步到位時會是空字串，變成「請至少輸入 2 字」）
      search(undefined, initialQuery);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">取貨</h1>
        <p className="text-sm text-zinc-500">
          {mode === "open"
            ? "輸入 姓名 / 電話末 N 碼 / 會員編號 → 找出本人未取訂單 → 確認取貨。"
            : "輸入 姓名 / 電話末 N 碼 / 會員編號 → 找出本人已取訂單 → 勾選後合併補印收據。"}
        </p>
      </header>

      <PickupAgingPanel />

      {/* 未取貨 ↔ 已取貨：同一個搜尋框，切換時直接重查 */}
      <div className="flex gap-1 rounded-md border border-zinc-200 bg-zinc-50 p-1 text-sm dark:border-zinc-800 dark:bg-zinc-900 sm:w-fit">
        {([
          { v: "open" as PickupMode, label: "🛍️ 未取貨" },
          { v: "picked" as PickupMode, label: "✅ 已取貨（補印）" },
        ]).map((t) => (
          <SpinButton
            key={t.v}
            type="button"
            onClick={() => {
              if (mode === t.v) return;
              setMode(t.v);
              setSelected(new Set());
              setBulkConfirm(null);
              if (query.trim().length >= 2 || members) search(undefined, undefined, t.v);
            }}
            className={`flex-1 rounded px-3 py-1.5 text-center font-medium transition sm:flex-none ${
              mode === t.v
                ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                : "text-zinc-600 hover:bg-zinc-200 dark:text-zinc-300 dark:hover:bg-zinc-800"
            }`}
          >
            {t.label}
          </SpinButton>
        ))}
      </div>

      <form onSubmit={search} className="flex items-end gap-2">
        <label className="text-sm flex-1 max-w-md">
          <span className="mb-1 block text-xs text-zinc-500">姓名 / 電話 / 會員編號</span>
          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            autoFocus
            placeholder="例: 王小明 / 123456 / M20260501..."
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-base dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <SpinButton
          type="submit"
          disabled={searching || query.trim().length < 2}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
        >
          {searching ? "搜尋中…" : "🔍 搜尋"}
        </SpinButton>
        {(members || error) && (
          <SpinButton
            type="button"
            onClick={() => { setQuery(""); setMembers(null); setOrders(new Map()); setError(null); }}
            className="rounded-md border border-zinc-300 px-3 py-2 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            清空
          </SpinButton>
        )}
      </form>

      <section className="rounded-md border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mb-2 text-xs font-medium text-zinc-500">
          ⚡ 常用顧客快選
          <span className="ml-1 font-normal text-zinc-400">· 取貨後自動累積，點按鈕直接查單（最多 10 位）</span>
        </div>
        {recents.length === 0 ? (
          <p className="text-xs text-zinc-400">
            完成取貨後，最近常取貨的顧客會自動列在這裡，方便下次一鍵查單。
          </p>
        ) : (
          <div className="flex flex-wrap gap-2">
            {recents.map((rc) => (
              <SpinButton
                key={rc.id}
                type="button"
                onClick={() => search(undefined, rc.member_no)}
                title={`${rc.name ?? rc.member_no}（${rc.member_no}）· 點擊快速查單`}
                className="flex items-center gap-1.5 rounded-full border border-zinc-300 bg-white px-3 py-1.5 text-xs transition hover:border-emerald-400 hover:bg-emerald-50 dark:border-zinc-700 dark:bg-zinc-800 dark:hover:border-emerald-700 dark:hover:bg-emerald-950"
              >
                <span className="font-medium">{rc.name ?? rc.member_no}</span>
                {rc.phone && (
                  <span className="font-mono text-[10px] text-zinc-400">···{rc.phone.slice(-3)}</span>
                )}
              </SpinButton>
            ))}
          </div>
        )}
      </section>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{error}</p>
        </div>
      )}

      {members !== null && (
        members.length === 0 ? (
          <p className="rounded-md border border-zinc-200 bg-zinc-50 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            找不到「{query}」的會員。
          </p>
        ) : (
          <div className="space-y-3">
            {members.map((m) => {
              const memberOrders = orders.get(m.id) ?? [];
              return (
                <div key={m.id} className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
                  <div className="mb-2 flex flex-wrap items-baseline gap-2">
                    <h2 className="text-base font-semibold">{m.name ?? "—"}</h2>
                    {m.admin_note && (
                      <span className="rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300" title="管理員備註（不對外顯示）">
                        🔒 {m.admin_note}
                      </span>
                    )}
                    {m.no_notify_pickup && (
                      <span className="rounded bg-zinc-200 px-2 py-0.5 text-[10px] font-medium text-zinc-700 dark:bg-zinc-700 dark:text-zinc-200">🔕 不通知</span>
                    )}
                    {m.no_new_order && (
                      <span className="rounded bg-red-100 px-2 py-0.5 text-[10px] font-medium text-red-800 dark:bg-red-950 dark:text-red-300">🚫 禁加單</span>
                    )}
                    <span className="font-mono text-xs text-zinc-500">{m.member_no}</span>
                    <span className="font-mono text-sm text-zinc-700 dark:text-zinc-300">{m.phone ?? "—"}</span>
                    {mode === "picked" && memberOrders.length > 0 && (() => {
                      const { groups, wholeOrders, itemIds } = pickedSelection(m);
                      if (groups.length === 0) return null;
                      const anySelected = memberOrders.some((o) => orderSelState(o) !== "none");
                      return (
                        <SpinButton
                          onClick={() => setPrintConfirm(m)}
                          title={wholeOrders
                            ? "整張全取 → 補印當時那張收據（多張合併成一張）"
                            : "只挑了部分品項 → 印一張「取貨明細」，只列勾到的品項"}
                          className="ml-auto rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
                        >
                          🖨️ {anySelected
                            ? `合併列印選定的 ${itemIds.length} 項`
                            : `合併列印（${groups.length} 張、${itemIds.length} 項）`}
                        </SpinButton>
                      );
                    })()}
                    {mode === "open" && memberOrders.length > 0 && (() => {
                      const pickableOrders = memberOrders.filter((o) => isPickable(o));
                      const selectedHere = pickableOrders.filter((o) => selected.has(o.id));
                      const useSel = selectedHere.length > 0;
                      const count = useSel ? selectedHere.length : pickableOrders.length;
                      if (pickableOrders.length === 0) return null;
                      return (
                        <SpinButton
                          onClick={() => setBulkConfirm(m)}
                          disabled={bulking === m.id}
                          className="ml-auto rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-emerald-700 disabled:opacity-50"
                        >
                          {bulking === m.id ? "處理中…" : useSel ? `📦 取選定的 ${count} 張` : `📦 一次全取（${count} 張）`}
                        </SpinButton>
                      );
                    })()}
                  </div>
                  {mode === "picked" ? (
                    memberOrders.length === 0 ? (
                      <p className="text-xs text-zinc-500">無已取訂單。</p>
                    ) : (
                      <ul className="space-y-2">
                        {memberOrders.map((o) => {
                          const evs = pickedEvents.get(o.id) ?? [];
                          const picked = pickedItemsOf(o);
                          const amount = picked.reduce((s, it) => s + Number(it.qty) * Number(it.unit_price), 0);
                          const canReprint = evs.length > 0;
                          const selState = orderSelState(o);
                          return (
                            <li
                              key={o.id}
                              className={`flex flex-col gap-3 rounded-md border p-3 sm:flex-row sm:items-center ${
                                selState !== "none"
                                  ? "border-emerald-400 bg-emerald-50 dark:border-emerald-700 dark:bg-emerald-950"
                                  : "border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-950"
                              }`}
                            >
                              <div className="flex min-w-0 flex-1 items-start gap-3">
                                <input
                                  type="checkbox"
                                  checked={selState === "all"}
                                  ref={(el) => { if (el) el.indeterminate = selState === "some"; }}
                                  onChange={() => toggleOrderItems(o)}
                                  disabled={picked.length === 0}
                                  title={picked.length === 0 ? "此單沒有已取品項" : "整張勾選（也可只勾下面個別品項）"}
                                  className="mt-1 h-4 w-4 shrink-0"
                                />
                                <OrderThumb order={o} />
                                <div className="min-w-0 flex-1 text-sm">
                                  <div className="flex flex-wrap items-baseline gap-2">
                                    <span>{o.campaign?.name ?? "(未知活動)"}</span>
                                    <CutoffChip order={o} />
                                    {o.status === "partially_completed" && (
                                      <span className="rounded bg-teal-100 px-2 py-0.5 text-[10px] font-medium text-teal-800 dark:bg-teal-950 dark:text-teal-300">
                                        部分已取
                                      </span>
                                    )}
                                  </div>
                                  {/* 品項層級勾選 — 客人這批只要 A/B/D 不要 C 時就挑這裡 */}
                                  <ul className="mt-0.5 space-y-0.5 text-xs text-zinc-700 dark:text-zinc-300">
                                    {picked.map((it) => (
                                      <li key={it.id}>
                                        <label className="flex cursor-pointer items-baseline gap-1.5">
                                          <input
                                            type="checkbox"
                                            checked={selectedItems.has(it.id)}
                                            onChange={() => toggleItem(it.id)}
                                            className="h-3.5 w-3.5 shrink-0 translate-y-0.5"
                                          />
                                          <span className="font-bold">{itemDisplayName(it.sku, o.campaign?.name)}</span>
                                          <span className="font-mono text-zinc-500">× {Number(it.qty)}</span>
                                          <span className="font-mono text-zinc-400">${Number(it.qty) * Number(it.unit_price)}</span>
                                        </label>
                                      </li>
                                    ))}
                                    {picked.length === 0 && <li className="text-zinc-400">（無已取品項）</li>}
                                  </ul>
                                  <div className="mt-1 text-xs text-zinc-500">
                                    取貨店：{o.store?.name ?? "—"}
                                    <span className="ml-2 font-mono font-semibold text-zinc-700 dark:text-zinc-200">${amount}</span>
                                    {canReprint ? (
                                      <span
                                        className="ml-2 font-semibold text-emerald-700 dark:text-emerald-400"
                                        title={evs.map((e) => pickupEventLabel(e)).join("\n")}
                                      >
                                        ✅ {pickupEventLabel(evs[evs.length - 1])}
                                        {evs.length > 1 && `（共 ${evs.length} 次）`}
                                      </span>
                                    ) : (
                                      <span className="ml-2 text-amber-600 dark:text-amber-400">⚠️ 無取貨紀錄可補印（取貨已撤銷？）</span>
                                    )}
                                  </div>
                                </div>
                              </div>
                              <div className="flex flex-wrap gap-2 sm:shrink-0">
                                <SpinButton
                                  onClick={() =>
                                    printViaIframe(
                                      withBasePath(`/pickup/print?event_ids=${evs.map((e) => e.id).join(",")}`),
                                    )
                                  }
                                  disabled={!canReprint}
                                  title="只補印這一張"
                                  className="rounded-md border border-zinc-300 px-3 py-2 text-xs font-medium text-zinc-700 hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                                >
                                  🖨️ 補印
                                </SpinButton>
                              </div>
                            </li>
                          );
                        })}
                      </ul>
                    )
                  ) : memberOrders.length === 0 ? (
                    <p className="text-xs text-zinc-500">無未取訂單。</p>
                  ) : (
                    <ul className="space-y-2">
                      {memberOrders.map((o) => {
                        const active = activeItems(o);
                        // 扣掉未取退貨後仍有量的品項（退回總倉的貨不可再取）
                        const activeRemaining = active.filter((it) => remainingQty(it) > 0);
                        const fullyReturned = active.length > 0 && activeRemaining.length === 0;
                        const pickable = pickableItems(o);
                        const pickableIds = new Set(pickable.map((it) => it.id));
                        const pickableCount = pickable.length;
                        const canPickup = pickableCount > 0;
                        // 部分到貨：有品項可取、但還有（未被退光的）active 品項未到
                        const partialArrival = canPickup && pickableCount < activeRemaining.length;
                        // 金額扣掉已退量（未取退貨不收錢，與應收 payable 扣減一致）
                        const subAmt = active.reduce((s, it) => s + remainingQty(it) * Number(it.unit_price), 0);
                        const discAmt = Number(o.discount_amount ?? 0);
                        const totalAmt = Math.max(0, subAmt - discAmt);
                        return (
                          <li key={o.id} className={`flex flex-col gap-3 rounded-md border p-3 sm:flex-row sm:items-center ${selected.has(o.id) ? "border-emerald-400 bg-emerald-50 dark:border-emerald-700 dark:bg-emerald-950" : "border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-950"}`}>
                            <div className="flex min-w-0 flex-1 items-start gap-3">
                            <input
                              type="checkbox"
                              checked={selected.has(o.id)}
                              onChange={() => toggleSelect(o.id)}
                              disabled={!canPickup}
                              className="mt-1 h-4 w-4 shrink-0"
                            />
                            <OrderThumb order={o} />
                            <div className="min-w-0 flex-1 text-sm">
                              <div className="flex flex-wrap items-baseline gap-2">
                                <span>{o.campaign?.name ?? "(未知活動)"}</span>
                                <CutoffChip order={o} />
                                {o.status === "partially_completed" && (
                                  <span className="rounded bg-teal-100 px-2 py-0.5 text-[10px] font-medium text-teal-800 dark:bg-teal-950 dark:text-teal-300">
                                    部分已取
                                  </span>
                                )}
                              </div>
                              <ul className="mt-0.5 space-y-0.5 text-xs text-zinc-700 dark:text-zinc-300">
                                {active.map((it) => (
                                  <li key={it.id} className="flex items-baseline gap-1.5">
                                    <span className="font-bold">{itemDisplayName(it.sku, o.campaign?.name)}</span>
                                    <span className="font-mono text-zinc-500">× {Number(it.qty)}</span>
                                    {returnedOf(it) > 0 && (
                                      <span className="rounded bg-orange-100 px-1 py-0.5 text-[10px] font-medium text-orange-800 dark:bg-orange-950 dark:text-orange-300">↩ 已退 {returnedOf(it)}</span>
                                    )}
                                    {/* 少發配貨沒配到 → 明講「待補貨」，別讓品項無聲消失讓店員以為是系統壞了 */}
                                    {remainingQty(it) > 0 && isBackordered(o, it) ? (
                                      <span
                                        className="rounded bg-amber-100 px-1 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                                        title="這批到貨量不夠分，這筆沒配到，要等下一批補貨"
                                      >
                                        ⏳ 待補貨
                                      </span>
                                    ) : (
                                      partialArrival && remainingQty(it) > 0 && !pickableIds.has(it.id) && (
                                        <span className="rounded bg-amber-100 px-1 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">⏳ 未到貨</span>
                                      )
                                    )}
                                  </li>
                                ))}
                              </ul>
                              <div className="mt-1 text-xs text-zinc-500">
                                取貨店：{o.store?.name ?? "—"}
                                {partialArrival ? (
                                  <span className="ml-2 font-semibold text-amber-700 dark:text-amber-400">
                                    🚚 部分到貨
                                  </span>
                                ) : o.ready_at ? (
                                  <span className="ml-2 font-semibold text-emerald-700 dark:text-emerald-400">
                                    到貨：{new Date(o.ready_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
                                  </span>
                                ) : canPickup ? (
                                  <span className="ml-2 font-semibold text-emerald-700 dark:text-emerald-400">
                                    ✅ 已到貨
                                  </span>
                                ) : (
                                  <span className="ml-2 text-zinc-400">⏳ 未到貨</span>
                                )}
                                {o.pickup_deadline && <span className="ml-2">截止：{o.pickup_deadline}</span>}
                                {/* 訂單金額一律顯示（含未到貨的單），方便核帳 */}
                                <span className="ml-2 font-mono font-semibold text-zinc-700 dark:text-zinc-200">${totalAmt}</span>
                                {discAmt > 0 && (
                                  <span className="ml-1 text-[10px] text-red-600 dark:text-red-400" title={`小計 $${subAmt} − 折扣 $${discAmt}`}>
                                    (含 ${discAmt} 折扣)
                                  </span>
                                )}
                                {canPickup ? (
                                  <span className="ml-2">{partialArrival ? `${pickableCount}/${activeRemaining.length} 項可取` : `${pickableCount} 項可取`}</span>
                                ) : fullyReturned ? (
                                  <span className="ml-2 font-semibold text-orange-700 dark:text-orange-400">↩ 已全數退回總倉，無可取貨項目</span>
                                ) : (
                                  <span className="ml-2 text-amber-600 dark:text-amber-400">⏳ 分店尚未收貨，無法取貨</span>
                                )}
                                {o.last_notify_pickup_at && (
                                  <span className="ml-2 text-[11px] text-blue-700 dark:text-blue-300" title={`已通知 ${o.notify_pickup_count} 次`}>
                                    📨 上次通知 {new Date(o.last_notify_pickup_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
                                  </span>
                                )}
                              </div>
                            </div>
                            </div>
                            <div className="flex flex-wrap gap-2 sm:shrink-0">
                            <SpinButton
                              onClick={() => notifyPickup(m, o)}
                              disabled={o.status !== "ready" || notifyingId === o.id || m.no_notify_pickup || fullyReturned}
                              title={m.no_notify_pickup ? "此會員已設「不通知」" : fullyReturned ? "商品已全數退回總倉，無可取貨項目" : o.status !== "ready" ? "尚未全部到貨無法通知" : "通知顧客來取貨（推播 + 站內訊息）"}
                              className="rounded-md border border-blue-300 px-2 py-2 text-xs font-medium text-blue-700 hover:bg-blue-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950"
                            >
                              {notifyingId === o.id ? "⌛" : "🔔 通知"}
                            </SpinButton>
                            <SpinButton
                              onClick={() => quickPickup(o)}
                              disabled={!canPickup}
                              title="一鍵取走已到貨品項並列印（不開明細視窗）"
                              className="rounded-md bg-emerald-600 px-3 py-2 text-xs font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
                            >
                              ✅ 取貨
                            </SpinButton>
                            <SpinButton
                              onClick={() => setPickup({ orderId: o.id, orderNo: o.order_no })}
                              disabled={!canPickup}
                              title="進階：折扣 / 只取部分品項 / 扣儲值金"
                              className="rounded-md border border-emerald-300 px-2 py-2 text-xs font-medium text-emerald-700 transition hover:bg-emerald-50 disabled:opacity-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
                            >
                              ✏️
                            </SpinButton>
                            {["ready", "partially_completed"].includes(o.status)
                              && !(o.status === "ready" && o.transferred_from_order_id != null) && (
                              <SpinButton
                                onClick={() => setReturnTarget({ orderId: o.id, storeId: o.pickup_store_id ?? o.store?.id ?? null })}
                                title="已收貨，無法取消；點此退貨回總倉（反向回收已派庫存）"
                                className="rounded-md border border-orange-300 px-2 py-2 text-xs font-medium text-orange-700 hover:bg-orange-50 dark:border-orange-800 dark:text-orange-300 dark:hover:bg-orange-950"
                              >
                                ↩ 退貨
                              </SpinButton>
                            )}
                            {/* 互助單已收貨：退回原調出店（貨源是分店不是總倉） */}
                            {o.status === "ready" && o.transferred_from_order_id != null && (
                              <SpinButton
                                onClick={() => returnAidToSource(o)}
                                title="互助單已收貨：反向退回原調出店並還原來源單"
                                className="rounded-md border border-orange-300 px-2 py-2 text-xs font-medium text-orange-700 hover:bg-orange-50 dark:border-orange-800 dark:text-orange-300 dark:hover:bg-orange-950"
                              >
                                ↩ 退回原店
                              </SpinButton>
                            )}
                            {["pending", "confirmed", "shipping"].includes(o.status) && (
                              <SpinButton
                                onClick={() => cancelOrder(o)}
                                title={o.status === "shipping" ? "撤回派貨並反向回收已出庫存" : "取消此訂單（尚未收貨也可取消）"}
                                className="rounded-md border border-red-300 px-2 py-2 text-xs font-medium text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
                              >
                                取消訂單
                              </SpinButton>
                            )}
                            </div>
                          </li>
                        );
                      })}
                    </ul>
                  )}
                </div>
              );
            })}
          </div>
        )
      )}

      {pickup && (
        <PickupDialog
          open={true}
          onClose={() => setPickup(null)}
          orderId={pickup.orderId}
          orderNo={pickup.orderNo}
          onPickedUp={(r) => {
            setPickup(null);
            alert(`取貨完成 (${r.picked_count} 項)\n訂單狀態：${r.new_order_status}`);
            setReloadTick((n) => n + 1);
          }}
        />
      )}

      <OrderReturnCreateModal
        open={returnTarget !== null}
        onClose={() => setReturnTarget(null)}
        onCreated={() => { setReturnTarget(null); setReloadTick((n) => n + 1); }}
        prefillOrderId={returnTarget?.orderId ?? null}
        prefillStoreId={returnTarget?.storeId ?? null}
      />

      {/* 已取貨：合併補印確認 — 版型對齊「一次全取」，先看清單與合計再印 */}
      <Modal
        open={printConfirm !== null}
        onClose={() => setPrintConfirm(null)}
        title={printConfirm ? `🖨️ 合併補印 — ${printConfirm.name ?? "—"} (${printConfirm.member_no})` : ""}
        maxWidth="max-w-2xl"
      >
        {printConfirm && (() => {
          const { groups, wholeOrders, itemIds, eventIds } = pickedSelection(printConfirm);
          const totalQty = groups.reduce((s, g) => s + g.items.reduce((ss, it) => ss + Number(it.qty), 0), 0);
          const totalSubtotal = groups.reduce(
            (s, g) => s + g.items.reduce((ss, it) => ss + Number(it.qty) * Number(it.unit_price), 0),
            0,
          );
          // 整單折扣是單頭層級的：整張全取才攤得準，挑品項時不計入（列印頁也會註明）
          const totalDiscount = wholeOrders
            ? groups.reduce((s, g) => s + Number(g.order.discount_amount ?? 0), 0)
            : 0;
          const totalAmount = Math.max(0, totalSubtotal - totalDiscount);
          return (
            <div className="space-y-3">
              <p className="text-sm text-zinc-600 dark:text-zinc-300">
                即將列印 <b>{groups.length}</b> 張訂單裡的 <b>{itemIds.length}</b> 項商品（共 {totalQty} 件），合併成 <b>1 張</b>。
                {totalDiscount > 0 ? (
                  <>
                    <br />
                    小計 <span className="font-mono">${totalSubtotal}</span> − 折扣 <span className="font-mono text-red-600 dark:text-red-400">${totalDiscount}</span> = <b className="font-mono text-base text-zinc-900 dark:text-zinc-100">${totalAmount}</b>
                  </>
                ) : (
                  <>合計 <b className="font-mono text-base text-zinc-900 dark:text-zinc-100">${totalAmount}</b></>
                )}
              </p>
              <p className="text-xs text-zinc-500">
                {wholeOrders
                  ? `整張全取 → 補印「取貨收據」，依取貨當次分段列出（共 ${eventIds.length} 次取貨紀錄）。`
                  : "只挑了部分品項 → 印「取貨明細」，只列勾到的品項；單頭的整單折扣不計入（攤到部分品項會失真）。"}
                {" "}金額為現行單價與折扣，非取貨當下的快照。
              </p>
              <div className="max-h-80 space-y-3 overflow-y-auto rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                {groups.map((g) => {
                  const evs = pickedEvents.get(g.order.id) ?? [];
                  const partial = g.items.length < pickedItemsOf(g.order).length;
                  return (
                    <div key={g.order.id} className="text-sm">
                      <div className="mb-1 flex flex-wrap items-baseline gap-2">
                        <span>{g.order.campaign?.name ?? "(未知活動)"}</span>
                        <CutoffChip order={g.order} />
                        <span className="text-[10px] text-zinc-500">取貨店：{g.order.store?.name ?? "—"}</span>
                        {evs.length > 0 && (
                          <span className="text-[10px] text-emerald-700 dark:text-emerald-400">
                            {pickupEventLabel(evs[evs.length - 1])}
                            {evs.length > 1 && `（共 ${evs.length} 次）`}
                          </span>
                        )}
                        {partial && (
                          <span className="rounded bg-amber-100 px-1 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                            只印 {g.items.length}/{pickedItemsOf(g.order).length} 項
                          </span>
                        )}
                      </div>
                      <ul className="ml-4 space-y-0.5 text-xs">
                        {g.items.map((it) => (
                          <li key={it.id} className="flex items-baseline gap-2">
                            <span className="font-bold">{itemDisplayName(it.sku, g.order.campaign?.name)}</span>
                            <span className="font-mono">×{Number(it.qty)}</span>
                          </li>
                        ))}
                      </ul>
                    </div>
                  );
                })}
              </div>
              <div className="flex flex-wrap justify-end gap-2">
                <SpinButton
                  onClick={() => setPrintConfirm(null)}
                  className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  取消
                </SpinButton>
                <SpinButton
                  onClick={() => printPickedMerged(printConfirm)}
                  className="rounded-md border border-zinc-700 bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:border-zinc-300 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
                >
                  🖨️ {wholeOrders ? "合併列印收據" : "列印取貨明細"}（{itemIds.length} 項、${totalAmount}）
                </SpinButton>
              </div>
            </div>
          );
        })()}
      </Modal>

      <Modal
        open={bulkConfirm !== null}
        onClose={() => setBulkConfirm(null)}
        title={bulkConfirm ? `📦 一次全取 — ${bulkConfirm.name ?? "—"} (${bulkConfirm.member_no})` : ""}
        maxWidth="max-w-2xl"
      >
        {bulkConfirm && (() => {
          const allMemberOrders = (orders.get(bulkConfirm.id) ?? []).filter((o) => isPickable(o));
          const selectedHere = allMemberOrders.filter((o) => selected.has(o.id));
          const memberOrders = selectedHere.length > 0 ? selectedHere : allMemberOrders;
          const totalItems = memberOrders.reduce((s, o) => s + pickableItems(o).length, 0);
          const totalSubtotal = memberOrders.reduce(
            (s, o) => s + pickableItems(o).reduce((ss, it) => ss + Number(it.qty) * Number(it.unit_price), 0),
            0,
          );
          const totalDiscount = memberOrders.reduce((s, o) => s + Number(o.discount_amount ?? 0), 0);
          const totalAmount = Math.max(0, totalSubtotal - totalDiscount);
          return (
            <div className="space-y-3">
              <p className="text-sm text-zinc-600 dark:text-zinc-300">
                即將取走 <b>{memberOrders.length}</b> 張訂單、共 <b>{totalItems}</b> 項商品。
                {totalDiscount > 0 ? (
                  <>
                    <br />
                    小計 <span className="font-mono">${totalSubtotal}</span> − 折扣 <span className="font-mono text-red-600 dark:text-red-400">${totalDiscount}</span> = 應收 <b className="font-mono text-base text-zinc-900 dark:text-zinc-100">${totalAmount}</b>
                  </>
                ) : (
                  <>合計 <b className="font-mono text-base text-zinc-900 dark:text-zinc-100">${totalAmount}</b></>
                )}
              </p>
              <div className="max-h-80 space-y-3 overflow-y-auto rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                {memberOrders.map((o) => {
                  const pickItems = pickableItems(o);
                  return (
                    <div key={o.id} className="text-sm">
                      <div className="mb-1 flex flex-wrap items-baseline gap-2">
                        <span>{o.campaign?.name ?? "(未知活動)"}</span>
                        <CutoffChip order={o} />
                        <span className="text-[10px] text-zinc-500">取貨店：{o.store?.name ?? "—"}</span>
                      </div>
                      <ul className="ml-4 space-y-0.5 text-xs">
                        {pickItems.map((it) => (
                          <li key={it.id} className="flex items-baseline gap-2">
                            <span className="font-bold">{itemDisplayName(it.sku, o.campaign?.name)}</span>
                            <span className="font-mono">×{Number(it.qty)}</span>
                          </li>
                        ))}
                      </ul>
                    </div>
                  );
                })}
              </div>
              <div className="flex flex-wrap justify-end gap-2">
                <SpinButton
                  onClick={() => setBulkConfirm(null)}
                  className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  取消
                </SpinButton>
                <SpinButton
                  onClick={() => {
                    const ids = memberOrders.map((o) => o.id).join(",");
                    printViaIframe(withBasePath(`/pickup/print-list?order_ids=${ids}`));
                  }}
                  className="rounded-md border border-zinc-700 bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:border-zinc-300 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
                >
                  🖨️ 列印小白單
                </SpinButton>
                <SpinButton
                  onClick={() => bulkPickAllConfirmed(bulkConfirm)}
                  className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700"
                >
                  ✅ 確認取貨（{memberOrders.length} 張、{totalItems} 項、${totalAmount}）
                </SpinButton>
              </div>
            </div>
          );
        })()}
      </Modal>
    </div>
  );
}

// 結單日（團的 cutoff_date）— 櫃台常要靠它分辨同一個團的不同批次 / 回答客人
// 「我這張是哪一次訂的」。內部補貨單等沒有團的單子沒有結單日，就不畫。
function CutoffChip({ order }: { order: OpenOrder }) {
  if (!order.campaign?.cutoff_date) return null;
  return (
    <span
      className="rounded bg-zinc-200 px-1.5 py-0.5 font-mono text-[10px] font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
      title="此團的結單日"
    >
      結單日 {order.campaign.cutoff_date}
    </span>
  );
}

function OrderThumb({ order }: { order: OpenOrder }) {
  // 取第一個 active item 的 product 第一張 image。
  // DB 存的是 storage 相對路徑，必須經 productImageUrl 轉成 public URL，
  // 否則 <img> 直接吃相對路徑會壞圖（顯示破圖 ?）。
  const rawImg = order.items
    .map((it) => it.sku?.product?.images?.[0])
    .find((u): u is string => typeof u === "string" && !!u);
  // DB 存的是 storage 物件 key，需轉成 products bucket 的 public URL（已是完整 URL 則原樣使用）。
  // 原本直接把相對路徑塞進 <img src> 導致破圖（顯示 ?）。
  const firstImg = publicProductUrl(rawImg);
  if (!firstImg) {
    return (
      <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-md bg-zinc-200 text-xs text-zinc-500 dark:bg-zinc-800">
        —
      </div>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img src={firstImg} alt="" className="h-12 w-12 shrink-0 rounded-md object-cover" />
  );
}

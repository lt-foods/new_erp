"use client";

import { Fragment, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { OrderTransferModal } from "@/components/OrderTransferModal";
import OrderReturnCreateModal from "@/components/OrderReturnCreateModal";
import TransferDetailModal from "@/components/TransferDetailModal";
import { PickupDialog } from "@/components/PickupDialog";
import { AidOrderTimeline } from "@/components/AidOrderTimeline";
import { OrderAuditDrawer } from "@/components/OrderAuditDrawer";
import { WalletPayOrderModal } from "@/components/WalletPayOrderModal";
import { EditableNumber, EditableText } from "@/components/EditableCell";
import { EditableDiscount, deriveDiscount, type DiscountValue } from "@/components/EditableDiscount";
import { useAuth } from "@/components/AuthProvider";
import { useRole } from "@/lib/role";
import { useHasStaffPerm } from "@/lib/staffPerms";
import { orderStatusLabel as statusLabel, canPayWithWallet } from "@/lib/orderStatus";
import { summarizeOrderSource } from "@/lib/orderSource";
import { ItemSourceBadge, OrderSourceBadge } from "@/components/OrderSourceBadge";
import { withBasePath } from "@/lib/basePath";
import { printViaIframe } from "@/lib/printIframe";
import { aidRouteLabel, aidStageLabel, isAidInFlight } from "@/lib/aidTransfer";
import { internalOrderSource } from "@/lib/orderTitle";
import { translateRpcError } from "@/lib/rpcError";
import { parseReturnNote } from "@/lib/returnNote";
import {
  fetchReprintableEvents,
  pickupEventLabel,
  type PickupEventRow,
} from "@/lib/pickupReceipt";
import SpinButton from "@/components/SpinButton";

type OrderHead = {
  id: number;
  order_no: string;
  status: string;
  stockout_at: string | null;
  pickup_deadline: string | null;
  nickname_snapshot: string | null;
  created_at: string;
  updated_at: string;
  pickup_store_id: number | null;
  campaign_id: number | null;
  transferred_from_order_id: number | null;
  is_air_transfer: boolean | null;
  discount_amount: number;
  discount_percent: number;
  wallet_paid_amount: number;
  payment_status: string | null;
  paid_at: string | null;
  notes: string | null;
  member: { id: number; name: string | null; phone: string | null; member_no: string } | null;
  campaign: { id: number; campaign_no: string; name: string } | null;
  store: { id: number; name: string } | null;
};

type ItemRow = {
  id: number;
  qty: number;
  unit_price: number;
  status: string;
  stockout_at: string | null;
  source: string;
  notes: string | null;
  discount_amount: number;
  discount_percent: number;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
  sku: { id: number; sku_code: string; product_name: string | null; variant_name: string | null } | null;
};

// 退貨單（return_to_hq transfer）— customer_order_id 反向掛到此訂單
type ReturnLine = {
  sku_id: number;
  qty_shipped: number;
  notes: string | null;
};
type ReturnTransfer = {
  id: number;
  transfer_no: string;
  status: string;          // shipped | received
  notes: string | null;
  shipped_at: string | null;
  received_at: string | null;
  shipped_by: string | null;
  lines: ReturnLine[];
};

// 從本單空中轉出去、還等著轉出店出貨的轉入單（confirmed、還沒建 AT- 轉移單）。
// 空中轉自 20260814030000 起在轉單當下就自動出貨（轉入單直接 shipping），
// 所以這裡只會撈到那之前卡住的舊單 —— 留這顆鈕當補推的後備入口，
// 操作者是轉出店（貨從他們手上出去），也就是看著本單的人。
type PendingAirShipment = {
  id: number;
  order_no: string;
  pickup_store_id: number | null;
  store_name: string;
  qty: number;
};

// 從本單互助 / 空中轉出去的轉入單（本單 → 別家店）。
// 跟 PendingAirShipment 不同：不限空中轉、也不限 confirmed —— 經總倉的轉入單一開始
// 是 pending（等總倉收）、派貨後才 shipping，兩段都是轉出店要印單隨貨走的時候。
//
// 這裡**收全部狀態**（含已收貨 / 已取貨的舊單）當「轉出記錄」給轉出店看：
// 轉入單掛在收貨店名下，轉出店的訂單列表一列都撈不到，來源單上不寫就等於
// 「貨從店裡出去了、系統上查無此事」（2026-08-18 南平→三峽）。
// 頂部那排列印鈕另外只取還在路上的（isAidInFlight），不用舊單洗版。
type OutgoingAidOrder = {
  id: number;
  order_no: string;
  // 收貨店 —— 連到訂單列表時一定要一起帶（列表的門市篩選對分店帳號會預設帶回自家店，
  // 不帶就會搜出 0 筆，看起來像貨憑空消失）
  store_id: number | null;
  store_name: string;
  is_air_transfer: boolean;
  status: string;
  qty: number;
  created_at: string;
};

// 品項狀態標籤（部分取貨會把一行拆成「已取」+「待取」兩行，標籤讓兩者一眼可分）
function itemStatusBadge(status: string, stockout = false): { label: string; cls: string } | null {
  // 斷貨取消（stockout_at 有值）與一般取消區分顯示
  if (stockout && status === "cancelled") {
    return { label: "斷貨", cls: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300" };
  }
  switch (status) {
    case "picked_up":
      return { label: "已取", cls: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300" };
    case "pending":
    case "reserved":
    case "ready":
      return { label: "待取", cls: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300" };
    case "cancelled":
      return { label: "已取消", cls: "bg-zinc-200 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300" };
    case "expired":
      return { label: "已逾期", cls: "bg-zinc-200 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300" };
    default:
      return null;
  }
}

function computeLineSubtotal(qty: number, unitPrice: number, d: DiscountValue): number {
  const gross = Number(qty) * Number(unitPrice);  const pct = d.kind === "percent" ? Number(d.value) : 0;
  const amt = d.kind === "amount" ? Number(d.value) : 0;
  const afterPct = gross * (1 - pct / 100);
  return Math.max(0, Math.round(afterPct * 10000) / 10000 - amt);
}

function applyOrderDiscount(subtotal: number, d: DiscountValue): { deduction: number; payable: number } {
  const pct = d.kind === "percent" ? Number(d.value) : 0;
  const amt = d.kind === "amount" ? Number(d.value) : 0;
  // 應收四捨五入到整數 NTD（對齊 v_customer_order_summary + rpc_wallet_pay_order）
  const payable = Math.max(0, Math.round(subtotal * (1 - pct / 100) - amt));
  return {
    deduction: subtotal - payable,
    payable,
  };
}

type ItemDraft = {
  qty?: number;
  unit_price?: number;
  notes?: string | null;
  discount?: DiscountValue;
};
type OrderDraft = {
  notes?: string | null;
  discount?: DiscountValue;
  items: Map<number, ItemDraft>;
};
const EMPTY_DRAFT: OrderDraft = { items: new Map() };

const HQ_ROLES = new Set(["owner", "admin", "hq_manager", "hq_accountant", ""]);

type TimelineStep = {
  label: string;
  ts: string | null;
  done: boolean;
  detail?: string;
  detailHref?: string;
  detailOnClick?: () => void;
};

// STATUS_LABEL / statusLabel imported from @/lib/orderStatus

function staffLabel(uid: string | null, names: Map<string, string>): string {
  if (!uid) return "—";
  return names.get(uid) ?? uid.slice(0, 8);
}

function fmtDt(iso: string): string {
  return new Date(iso).toLocaleString("zh-TW", { hour12: false });
}

export function OrderDetail({
  orderId,
  onNavigate,
}: {
  orderId: number;
  onNavigate?: (orderId: number, orderNo: string) => void;
}) {
  const [head, setHead] = useState<OrderHead | null>(null);
  const [items, setItems] = useState<ItemRow[] | null>(null);
  const [returns, setReturns] = useState<ReturnTransfer[] | null>(null);
  // item.id → 是否已到貨可取（v_order_item_pickup_ready）。shipping 單部分到貨時，已到品項可先取
  const [itemReady, setItemReady] = useState<Map<number, boolean>>(new Map());
  const [returnDetailId, setReturnDetailId] = useState<number | null>(null);
  // 該訂單的取貨事件（append-only）— 取貨後補印收據用，見 /pickup/print?event_ids=
  const [pickupEvents, setPickupEvents] = useState<PickupEventRow[]>([]);
  const [timeline, setTimeline] = useState<TimelineStep[] | null>(null);
  const [staffNames, setStaffNames] = useState<Map<string, string>>(new Map());
  // 本單空中轉出去、還沒出貨的轉入單（舊單補推用；新單轉單時就自動出貨了）
  const [pendingAirOut, setPendingAirOut] = useState<PendingAirShipment[]>([]);
  // 從本單轉出去、還在路上的互助單（轉出店印出貨單隨貨走）
  const [outgoingAid, setOutgoingAid] = useState<OutgoingAidOrder[]>([]);
  // 本單自己是空中轉轉入單且還在等出貨時，轉出店店名（給接收店看「在等誰」）
  const [awaitingAirFrom, setAwaitingAirFrom] = useState<string | null>(null);
  // sku_id → 現行分店價（prices scope=branch, effective_to IS NULL）
  const [branchPrices, setBranchPrices] = useState<Map<number, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [transferOpen, setTransferOpen] = useState(false);
  const [returnOpen, setReturnOpen] = useState(false);
  const [pickupOpen, setPickupOpen] = useState(false);
  const [walletPayOpen, setWalletPayOpen] = useState(false);
  const [auditOpen, setAuditOpen] = useState(false);
  const [draft, setDraft] = useState<OrderDraft>(EMPTY_DRAFT);
  const [saving, setSaving] = useState(false);
  const [editReason, setEditReason] = useState("");

  function clearDraft() { setDraft({ items: new Map() }); setEditReason(""); }
  function setOrderDraft(patch: Partial<{ notes: string | null; discount: DiscountValue }>) {
    setDraft((d) => ({ ...d, ...patch }));
  }
  function setItemDraft(itemId: number, patch: ItemDraft) {
    setDraft((d) => {
      const next = new Map(d.items);
      next.set(itemId, { ...next.get(itemId), ...patch });
      return { ...d, items: next };
    });
  }

  const { user } = useAuth();
  const role = useRole();
  const userStores = (user?.app_metadata?.stores as unknown[] | undefined) ?? [];
  // 整單編輯（單價/折扣）— 限 HQ tier 或總倉成員
  const canEdit = useMemo(() => {
    if (role === null) return false;
    if (HQ_ROLES.has(role)) return true;
    if (Array.isArray(userStores) && userStores.includes("總倉")) return true;
    return false;
  }, [role, userStores]);

  // 店長 qty 編輯：自家 pickup_store 的 pending 訂單
  const isStoreOfThisOrder = !!head?.store?.name
    && Array.isArray(userStores)
    && userStores.includes(head.store.name);

  // 金額編輯（單價／整單折扣／單品折扣）— 與 DB 守衛 _check_order_edit_perm 逐條對齊
  //   1. HQ tier：照舊全開，不受功能權限影響
  //   2. 其餘角色：要有「訂單金額：可改單價與折扣」功能權限（owner/admin 在 /staff 逐人勾），
  //      且只能改自己店的單（stores 含「總倉」視同不鎖店，同 DB 判定）
  // 沒權限就把欄位鎖成唯讀，不要讓人改了按儲存才跳 permission denied。
  const hasEditAmountPerm = useHasStaffPerm("orders_edit_amount");
  const isWarehouseMember = Array.isArray(userStores) && userStores.includes("總倉");
  const canEditAmount = (role !== null && HQ_ROLES.has(role))
    || (hasEditAmountPerm && (isWarehouseMember || isStoreOfThisOrder));

  // qty 只有 pending 訂單可改;一旦被 PR 鎖定變 confirmed 就唯讀
  const canEditQty = (canEdit || isStoreOfThisOrder) && head?.status === "pending";

  // 備註（單頭/品項）：店長店員也可編自店訂單，對齊 _check_order_edit_notes_perm
  const canEditNotes = canEdit || isStoreOfThisOrder;

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [hRes, iRes, rRes, arvRes, pevRes, airRes] = await Promise.all([
        sb.from("customer_orders")
          .select("id, order_no, status, stockout_at, pickup_deadline, nickname_snapshot, created_at, updated_at, pickup_store_id, campaign_id, transferred_from_order_id, is_air_transfer, discount_amount, discount_percent, wallet_paid_amount, payment_status, paid_at, notes, member:members(id, name, phone, member_no), campaign:group_buy_campaigns(id, campaign_no, name), store:stores!customer_orders_pickup_store_id_fkey(id, name)")
          .eq("id", orderId).maybeSingle(),
        sb.from("customer_order_items")
          .select("id, qty, unit_price, status, stockout_at, source, notes, discount_amount, discount_percent, created_at, updated_at, created_by, updated_by, sku:skus(id, sku_code, product_name, variant_name)")
          .eq("order_id", orderId)
          .order("created_at", { ascending: true }),
        sb.from("transfers")
          .select("id, transfer_no, status, notes, shipped_at, received_at, shipped_by, transfer_items(sku_id, qty_shipped, notes)")
          .eq("customer_order_id", orderId)
          .eq("transfer_type", "return_to_hq")
          .in("status", ["shipped", "received"])
          .order("shipped_at", { ascending: false }),
        sb.from("v_order_item_pickup_ready")
          .select("item_id, pickup_ready")
          .eq("order_id", orderId),
        fetchReprintableEvents([orderId]),
        // 從本單互助 / 空中轉出去的轉入單。三個用途：
        //   1. 還卡在 confirmed 的空中轉 → 「✈ 補出貨」（自動出貨上線前的舊單，
        //      空中轉不經總倉，補推要由轉出店＝正在看本單的人按下，否則沒人有入口）
        //   2. 收貨店還沒收到的（pending/confirmed/shipping）→ 「🖨 出貨單」隨貨走
        //   3. 全部（含已收貨、已取消）→ 下方的「↗ 轉出記錄」。轉入單掛在收貨店名下，
        //      轉出店的訂單列表撈不到，不在這裡寫出來就等於系統上查無此事
        // 反查 transferred_from_order_id，不要用 transferred_to_order_id：部分轉出不寫那一欄
        sb.from("customer_orders")
          .select("id, order_no, pickup_store_id, status, is_air_transfer, created_at, store:stores!customer_orders_pickup_store_id_fkey(name), items:customer_order_items(qty, status, source)")
          .eq("transferred_from_order_id", orderId)
          .order("created_at", { ascending: false }),
      ]);
      if (cancelled) return;
      if (hRes.error) { setError(hRes.error.message); return; }
      const headData = hRes.data as unknown as OrderHead;
      setHead(headData);
      if (iRes.error) { setError(iRes.error.message); return; }
      const itemsData = (iRes.data ?? []) as unknown as ItemRow[];
      setItems(itemsData);

      const arrivedMap = new Map<number, boolean>();
      for (const r of (arvRes.data ?? []) as { item_id: number; pickup_ready: boolean }[]) {
        arrivedMap.set(r.item_id, !!r.pickup_ready);
      }
      setItemReady(arrivedMap);

      setPickupEvents(pevRes.get(orderId) ?? []);

      // ========== 從本單轉出去的互助 / 空中轉（本單 → 其他店）==========
      type AirRow = {
        id: number; order_no: string; pickup_store_id: number | null;
        status: string; is_air_transfer: boolean | null; created_at: string;
        store: { name: string } | { name: string }[] | null;
        items: { qty: number; status: string; source: string | null }[] | null;
      };
      const childRows = ((airRes.data ?? []) as unknown as AirRow[])
        // 同店轉單（換客人）不是出貨，貨沒離開本店；rpc_ship_aid_order 也會以
        //「source/dest 同 location」擋下 —— 不算互助出貨，兩個用途都不該出現
        .filter((r) => r.pickup_store_id !== headData.pickup_store_id)
        // 互助品項才是真的要寄出去的貨
        .filter((r) => (r.items ?? []).some((it) => it.source === "aid_transfer"));
      const storeNameOf = (r: AirRow) =>
        (Array.isArray(r.store) ? r.store[0]?.name : r.store?.name) ?? "—";
      setPendingAirOut(
        childRows
          .filter((r) => r.is_air_transfer === true && r.status === "confirmed")
          .map((r): PendingAirShipment => ({
            id: r.id,
            order_no: r.order_no,
            pickup_store_id: r.pickup_store_id,
            store_name: storeNameOf(r),
            qty: (r.items ?? [])
              .filter((it) => !["cancelled", "expired"].includes(it.status))
              .reduce((s, it) => s + Number(it.qty), 0),
          })),
      );
      // 轉出記錄：全部留著（含已取消的，店家要看得出「那批貨後來怎麼了」）。
      // 頂部的列印鈕另外只取還在路上的那幾張。
      setOutgoingAid(
        childRows.map((r): OutgoingAidOrder => ({
          id: r.id,
          order_no: r.order_no,
          store_id: r.pickup_store_id,
          store_name: storeNameOf(r),
          is_air_transfer: r.is_air_transfer === true,
          status: r.status,
          created_at: r.created_at,
          qty: (r.items ?? [])
            .filter((it) => it.source === "aid_transfer" && !["cancelled", "expired"].includes(it.status))
            .reduce((s, it) => s + Number(it.qty), 0),
        })),
      );

      // 本單自己就是等出貨的空中轉轉入單 → 讓接收店看得到在等哪一家出貨
      if (headData.is_air_transfer && headData.status === "confirmed" && headData.transferred_from_order_id) {
        const { data: srcRow } = await sb
          .from("customer_orders")
          .select("pickup_store_id, store:stores!customer_orders_pickup_store_id_fkey(name)")
          .eq("id", headData.transferred_from_order_id)
          .maybeSingle();
        const src = srcRow as unknown as
          { pickup_store_id: number | null; store: { name: string } | { name: string }[] | null } | null;
        const st = src?.store;
        // 同店不需要出貨（rpc_ship_aid_order 也會擋），不掛「等出貨」
        const sameStore = src?.pickup_store_id === headData.pickup_store_id;
        if (!cancelled) {
          setAwaitingAirFrom(sameStore ? null : (Array.isArray(st) ? st[0]?.name : st?.name) ?? "轉出店");
        }
      } else if (!cancelled) {
        setAwaitingAirFrom(null);
      }

      // ========== 整理退貨單（return_to_hq transfer）==========
      type RetRow = {
        id: number; transfer_no: string; status: string; notes: string | null;
        shipped_at: string | null; received_at: string | null; shipped_by: string | null;
        transfer_items: ReturnLine[] | null;
      };
      const retRows = ((rRes.data ?? []) as unknown as RetRow[]).map((r): ReturnTransfer => ({
        id: r.id, transfer_no: r.transfer_no, status: r.status, notes: r.notes,
        shipped_at: r.shipped_at, received_at: r.received_at, shipped_by: r.shipped_by,
        lines: (r.transfer_items ?? []).map((l) => ({
          sku_id: Number(l.sku_id), qty_shipped: Number(l.qty_shipped), notes: l.notes,
        })),
      }));
      setReturns(retRows);

      // ========== 載入各 SKU 現行分店價（prices scope=branch, 生效中）==========
      const priceSkuIds = Array.from(
        new Set(itemsData.map((it) => it.sku?.id).filter((x): x is number => !!x)),
      );
      if (priceSkuIds.length > 0) {
        const { data: priceRows } = await sb
          .from("prices")
          .select("sku_id, price")
          .eq("scope", "branch")
          .is("scope_id", null)
          .is("effective_to", null)
          .in("sku_id", priceSkuIds);
        if (!cancelled) {
          const pm = new Map<number, number>();
          for (const p of (priceRows ?? []) as { sku_id: number; price: number }[]) {
            pm.set(Number(p.sku_id), Number(p.price));
          }
          setBranchPrices(pm);
        }
      }

      // ========== 載入加單者 / 退貨經手人 user names ==========
      const uids = new Set<string>();
      for (const it of itemsData) {
        if (it.created_by) uids.add(it.created_by);
        if (it.updated_by) uids.add(it.updated_by);
      }
      for (const r of retRows) {
        if (r.shipped_by) uids.add(r.shipped_by);
      }
      if (uids.size > 0) {
        const { data: names } = await sb.rpc("rpc_get_staff_names", {
          p_uids: Array.from(uids),
        });
        const m = new Map<string, string>();
        for (const n of (names as { id: string; display_name: string }[] | null) ?? []) {
          m.set(n.id, n.display_name);
        }
        if (!cancelled) setStaffNames(m);
      }

      // ========== 載入 timeline ==========
      const skuIds = itemsData.map((it) => it.sku?.id).filter((x): x is number => !!x);
      const tl = await buildTimeline(headData, skuIds, onNavigate);
      if (!cancelled) setTimeline(tl);

    })();
    return () => { cancelled = true; };
  }, [orderId, reloadTick]);

  if (error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {error}
      </div>
    );
  }
  if (!head || !items) return <div className="text-sm text-zinc-500">載入中…</div>;

  // ----- 從 head + draft 取「目前生效的值」 -----
  const itemEffective = (it: ItemRow) => {
    const d = draft.items.get(it.id);
    const qty = d?.qty ?? Number(it.qty);
    const unit_price = d?.unit_price ?? Number(it.unit_price);
    const notes = d && Object.prototype.hasOwnProperty.call(d, "notes") ? d.notes! : it.notes;
    const discount: DiscountValue = d?.discount ?? deriveDiscount(it.discount_percent, it.discount_amount);
    return { qty, unit_price, notes, discount };
  };
  const orderDiscountValue: DiscountValue = draft.discount ?? deriveDiscount(head.discount_percent, head.discount_amount);
  const orderNotesValue: string | null = Object.prototype.hasOwnProperty.call(draft, "notes") ? draft.notes! : head.notes;

  // 已取消 / 斷貨 / 過期的品項行照樣列在下面的表格（紅標「斷貨」「已取消」），
  // 但不計入件數與金額 —— 客人拿不到的貨不收錢。
  // 與 v_customer_order_summary.items_total / rpc_wallet_pay_order 同一套過濾
  //（migration 20260808000010）。
  const activeItems = items.filter((i) => !["cancelled", "expired"].includes(i.status));

  const totalQty = activeItems.reduce((s, i) => s + Number(itemEffective(i).qty), 0);
  const grossTotal = activeItems.reduce((s, i) => {
    const eff = itemEffective(i);
    return s + Number(eff.qty) * Number(eff.unit_price);
  }, 0);
  const subtotal = activeItems.reduce((s, i) => {
    const eff = itemEffective(i);
    return s + computeLineSubtotal(Number(eff.qty), eff.unit_price, eff.discount);
  }, 0);
  const lineDiscountTotal = Math.round((grossTotal - subtotal) * 10000) / 10000;

  // ----- 未取退貨扣減：退回總倉的貨不收錢；「取貨後退回」不扣（錢已在取貨時收，退款走儲值金）-----
  // 退貨單只記 SKU+量：依品項行序把退貨量分攤到該 SKU 未取消行，以該行小計差額折算金額
  // （對齊 v_customer_order_summary.returned_deduction 的分攤邏輯）
  const unpickedReturnedBySku = new Map<number, number>();
  for (const r of returns ?? []) {
    if (parseReturnNote(r.notes).isRestock) continue;
    for (const l of r.lines) {
      unpickedReturnedBySku.set(l.sku_id, (unpickedReturnedBySku.get(l.sku_id) ?? 0) + Number(l.qty_shipped));
    }
  }
  let returnedDeduction = 0;
  {
    const remaining = new Map(unpickedReturnedBySku);
    for (const it of activeItems) {
      const skuId = it.sku?.id;
      const rem = skuId != null ? (remaining.get(skuId) ?? 0) : 0;
      if (skuId == null || rem <= 0) continue;
      const eff = itemEffective(it);
      const alloc = Math.min(Number(eff.qty), rem);
      returnedDeduction +=
        computeLineSubtotal(Number(eff.qty), eff.unit_price, eff.discount) -
        computeLineSubtotal(Number(eff.qty) - alloc, eff.unit_price, eff.discount);
      remaining.set(skuId, rem - alloc);
    }
    returnedDeduction = Math.round(returnedDeduction * 10000) / 10000;
  }
  const netSubtotal = Math.max(0, Math.round((subtotal - returnedDeduction) * 10000) / 10000);
  const { deduction: orderDeduction, payable: payableAmount } = applyOrderDiscount(netSubtotal, orderDiscountValue);

  // ----- 退貨彙整：總退貨件數 + SKU lookup（給 ReturnList 顯示品名）-----
  const totalReturnedQty = (returns ?? []).reduce(
    (s, r) => s + r.lines.reduce((s2, l) => s2 + Number(l.qty_shipped), 0),
    0,
  );
  const skuLookup = new Map<number, { sku_code: string; product_name: string | null; variant_name: string | null }>();
  for (const it of items) {
    if (it.sku) skuLookup.set(it.sku.id, {
      sku_code: it.sku.sku_code,
      product_name: it.sku.product_name,
      variant_name: it.sku.variant_name,
    });
  }

  // ----- draft 修改數計算 -----
  const itemDraftCount = Array.from(draft.items.values()).reduce(
    (n, d) => n + Object.keys(d).length, 0,
  );
  const orderDraftCount = (draft.discount ? 1 : 0) + (Object.prototype.hasOwnProperty.call(draft, "notes") ? 1 : 0);
  const draftCount = itemDraftCount + orderDraftCount;

  async function saveAllDraft() {
    if (!head || !items) return;
    if (draftCount === 0) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    setSaving(true);
    const errors: string[] = [];
    const reason = editReason.trim() === "" ? null : editReason.trim();
    try {
      // 訂單頭部備註
      if (Object.prototype.hasOwnProperty.call(draft, "notes")) {
        const { error } = await sb.rpc("rpc_update_order_notes", {
          p_order_id: head.id,
          p_new_notes: draft.notes ?? null,
          p_operator: operator,
          p_reason: reason,
        });
        if (error) errors.push(`整單備註：${translateRpcError(error)}`);
      }
      // 訂單頭部折扣（型別二擇一，把對方歸零）
      if (draft.discount) {
        const d = draft.discount;
        const newPct = d.kind === "percent" ? Number(d.value) : 0;
        const newAmt = d.kind === "amount" ? Number(d.value) : 0;
        if (Number(head.discount_percent ?? 0) !== newPct) {
          const { error } = await sb.rpc("rpc_update_order_discount_percent", {
            p_order_id: head.id, p_new_percent: newPct, p_operator: operator, p_reason: reason,
          });
          if (error) errors.push(`整單折扣%：${translateRpcError(error)}`);
        }
        if (Number(head.discount_amount ?? 0) !== newAmt) {
          const { error } = await sb.rpc("rpc_update_order_discount", {
            p_order_id: head.id, p_new_discount: newAmt, p_operator: operator, p_reason: reason,
          });
          if (error) errors.push(`整單折扣$：${translateRpcError(error)}`);
        }
      }
      // 商品 (qty / unit_price / notes / discount)
      for (const [itemId, d] of draft.items) {
        const it = items.find((x) => x.id === itemId);
        if (!it) continue;
        if (d.qty !== undefined && Number(d.qty) !== Number(it.qty)) {
          const { error } = await sb.rpc("rpc_update_order_item_qty", {
            p_order_id: head.id, p_item_id: itemId,
            p_new_qty: Number(d.qty), p_operator: operator, p_reason: reason,
          });
          if (error) errors.push(`#${itemId} 數量：${translateRpcError(error)}`);
        }
        if (d.unit_price !== undefined && Number(d.unit_price) !== Number(it.unit_price)) {
          const { error } = await sb.rpc("rpc_update_order_item_price", {
            p_order_id: head.id, p_item_id: itemId,
            p_new_unit_price: Number(d.unit_price), p_operator: operator, p_reason: reason,
          });
          if (error) errors.push(`#${itemId} 單價：${translateRpcError(error)}`);
        }
        if (Object.prototype.hasOwnProperty.call(d, "notes") && d.notes !== it.notes) {
          const { error } = await sb.rpc("rpc_update_order_item_notes", {
            p_order_id: head.id, p_item_id: itemId,
            p_new_notes: d.notes ?? null, p_operator: operator, p_reason: reason,
          });
          if (error) errors.push(`#${itemId} 備註：${translateRpcError(error)}`);
        }
        if (d.discount) {
          const newPct = d.discount.kind === "percent" ? Number(d.discount.value) : 0;
          const newAmt = d.discount.kind === "amount" ? Number(d.discount.value) : 0;
          if (Number(it.discount_percent ?? 0) !== newPct) {
            const { error } = await sb.rpc("rpc_update_order_item_discount_percent", {
              p_order_id: head.id, p_item_id: itemId,
              p_new_percent: newPct, p_operator: operator, p_reason: reason,
            });
            if (error) errors.push(`#${itemId} 折扣%：${translateRpcError(error)}`);
          }
          if (Number(it.discount_amount ?? 0) !== newAmt) {
            const { error } = await sb.rpc("rpc_update_order_item_discount_amount", {
              p_order_id: head.id, p_item_id: itemId,
              p_new_amount: newAmt, p_operator: operator, p_reason: reason,
            });
            if (error) errors.push(`#${itemId} 折扣$：${translateRpcError(error)}`);
          }
        }
      }
    } finally {
      setSaving(false);
    }
    if (errors.length > 0) {
      alert(`儲存部分失敗：\n${errors.join("\n")}`);
    } else {
      clearDraft();
    }
    setReloadTick((n) => n + 1);
  }

  // 互助單：有來源單 + 至少一個 aid_transfer 品項（對齊 rpc_return_aid_order 的判定）
  const isAidOrder = head.transferred_from_order_id != null && items.some((it) => it.source === "aid_transfer");
  // 還在路上（收貨店還沒收）的轉出單 —— 頂部的「🖨 出貨單」鈕只掛這幾張，
  // 已收貨 / 已取消的舊單留在下面「轉出記錄」區塊即可
  const outgoingAidInFlight = outgoingAid.filter((o) => isAidInFlight(o.status));
  const totalOutgoingQty = outgoingAid.reduce((s, o) => s + o.qty, 0);
  // 跨店轉單要等到貨（status='ready'）；同店換客人到貨前也可轉
  // (跟 DB rpc_transfer_order_* 20260814000020 的 gate 一致；modal 會鎖定接收店＝原店)
  const transferBeforeArrival = ["pending", "confirmed", "reserved", "shipping"].includes(head.status);
  // 部分取貨的單也能轉剩餘品項（20260814000020）：內部現貨池臨櫃賣掉一件就進
  // partially_completed，不開放等於池子賣過一次就不能再轉給客人。
  // 已取走的品項不會進轉移清單（modal 吃 pickableItems），且一律走部分轉出 RPC。
  const transferAfterPartialPickup =
    head.status === "partially_completed" &&
    items.some((it) => ["pending", "reserved", "ready"].includes(it.status));
  const canTransfer = head.status === "ready" || transferBeforeArrival || transferAfterPartialPickup;
  // 現貨直配（SP-）單一建立就是 'ready'，但還沒扣庫存 → 取消是安全的，
  // 只是把可分配量放回去（20260816000070 放寬了伺服端守衛）。
  // 不放寬一般 ready 單：那代表貨已配到客人頭上，取消的連動完全不同。
  const isSpotSale = head.order_no?.startsWith("SP-") ?? false;
  const canCancel =
    ["pending", "confirmed", "shipping"].includes(head.status) ||
    (isSpotSale && head.status === "ready");
  // 還沒到貨（pending/confirmed/shipping）也可以列印小白單；ready 透過 PickupDialog 已有入口。
  // partially_completed 也開放（對齊 /orders 列表）— 小白單只列還沒取的品項，已取走的不會重複出現。
  const canPrintSlip = ["pending", "confirmed", "shipping", "ready", "partially_completed"].includes(head.status);
  // 取貨收據補印：取貨當下才會自動印一次，事後只能靠 order_pickup_events 的 id 找回來。
  // 小白單(print-list)在這裡幫不上忙 — 它只列 pending/reserved/ready 品項，取完貨會印成空單。
  const canReprintReceipt = pickupEvents.length > 0;
  // 一般顧客訂單退回總倉（rpc_create_order_return）— 互助單不走這條（貨應退回原 source 店）
  const canReturn = !isAidOrder && ["shipping", "ready", "partially_completed", "completed", "expired"].includes(head.status);
  // 互助單已收貨未取貨（status=ready）退單：退回原 source 店（rpc_return_aid_order，#234）
  const canAidReturn = isAidOrder && head.status === "ready";
  const isTransferredOut = head.status === "transferred_out";
  // 復原取消（rpc_restore_cancelled_order）。伺服端還有一輪守衛，這裡先把三種
  // 一定會被擋的單藏起來，免得店員按了只拿到錯誤訊息：
  //   斷貨取消 → 要去採購單按「回復斷貨」；轉入單 → 貨已還給來源單，回那邊重轉；
  //   SP- 現貨直配 → 取消＝退回可分配，要再配就重開一張。
  const canRestoreCancel =
    head.status === "cancelled" &&
    !head.stockout_at &&
    head.transferred_from_order_id == null &&
    !isSpotSale;

  async function cancelOrder() {
    if (!head) return;
    const walletPaid = Number(head.wallet_paid_amount ?? 0);
    const walletNote = walletPaid > 0
      ? `\n\n⚠️ 此訂單已用儲值金 $${walletPaid}，取消後會自動退回會員餘額。`
      : "";
    const reason = prompt(
      (head.status === "shipping"
        ? `撤回派貨：${head.order_no}\n${isAidOrder ? "會撤回派貨單並反向回收已出庫存" : "波次出貨的訂單不動庫存，貨留在店端"}，請輸入原因：`
        : isSpotSale
          ? `退回庫存：${head.order_no}\n這張單的貨還沒扣庫存，退回後會變回「可分配」，可以再配給別人。\n請輸入原因：`
          : `取消訂單：${head.order_no}\n請輸入取消原因：`) + walletNote
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { data, error: rpcErr } = await sb.rpc("rpc_cancel_aid_order", {
      p_order_id: head.id,
      p_reason: reason,
      p_operator: operator,
    });
    if (rpcErr) { alert(`取消失敗：${translateRpcError(rpcErr)}`); return; }
    const refunded = Number((data as { wallet_refunded?: number } | null)?.wallet_refunded ?? 0);
    alert(refunded > 0
      ? `已取消，已退回 $${refunded} 儲值金到會員餘額`
      : isSpotSale
        ? "✅ 已退回庫存，這些貨變回「可分配」了"
        : "已取消");
    setReloadTick((n) => n + 1);
  }

  // 復原取消（rpc_restore_cancelled_order）：誤按取消、或客人取消後又反悔。
  // 單頭回到取消前的狀態；貨其實已經到店的話伺服端會直接推到「可取貨」。
  async function restoreCancelledOrder() {
    if (!head) return;
    const walletPaid = Number(head.wallet_paid_amount ?? 0);
    const walletNote = walletPaid > 0
      ? `\n\n⚠️ 此訂單取消時退了 $${walletPaid} 儲值金，復原會重新從會員餘額扣回（餘額不足會復原失敗）。`
      : "";
    const reason = prompt(
      `復原取消：${head.order_no}\n` +
      `訂單會回到取消前的狀態，名額與可分配量也會重新算給這張單。\n` +
      `※ 取消時釋放掉的庫存減抵單覆蓋不會自動長回來，需要的話請重開減抵單。${walletNote}\n\n` +
      `請輸入復原原因：`,
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { data, error: rpcErr } = await sb.rpc("rpc_restore_cancelled_order", {
      p_order_id: head.id,
      p_operator: operator,
      p_reason: reason.trim() === "" ? null : reason.trim(),
    });
    if (rpcErr) { alert(`復原失敗：${translateRpcError(rpcErr)}`); return; }
    const r = (data ?? {}) as {
      status?: string; items_restored?: number;
      needs_redispatch?: boolean; wallet_recharged?: number;
    };
    alert(
      `✅ 已復原，訂單狀態：${statusLabel(r.status ?? "")}` +
      (Number(r.items_restored ?? 0) > 0 ? `\n一併還原 ${Number(r.items_restored)} 項品項` : "") +
      (Number(r.wallet_recharged ?? 0) > 0 ? `\n已重新扣回 $${Number(r.wallet_recharged)} 儲值金` : "") +
      (r.needs_redispatch ? "\n\n⚠️ 這張單原本派貨中，取消時派貨單已被回收、貨退回轉出端，請重新派貨。" : ""),
    );
    setReloadTick((n) => n + 1);
  }

  // 刪除 pending 訂單裡的單一品項（rpc_delete_order_item：軟刪 status->cancelled）。
  // 權限/狀態閘與「改數量」一致（canEditQty）；刪到最後一項會自動取消整單。
  async function deleteItem(it: ItemRow) {
    if (!head) return;
    const label = it.sku
      ? `${it.sku.product_name ?? it.sku.sku_code}${it.sku.variant_name ? ` / ${it.sku.variant_name}` : ""}`
      : `#${it.id}`;
    const onlyActive = (items ?? []).filter((x) => !["cancelled", "expired"].includes(x.status)).length <= 1;
    const reason = prompt(
      `刪除品項：${label}（${head.order_no}）` +
        (onlyActive ? "\n\n⚠️ 這是訂單最後一個品項，刪除後整單會一併取消。" : "") +
        "\n請輸入刪除原因：",
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { data, error: rpcErr } = await sb.rpc("rpc_delete_order_item", {
      p_order_id: head.id,
      p_item_id: it.id,
      p_operator: operator,
      p_reason: reason.trim() === "" ? null : reason.trim(),
    });
    if (rpcErr) { alert(`刪除失敗：${translateRpcError(rpcErr)}`); return; }
    const cancelled = !!(data as { order_cancelled?: boolean } | null)?.order_cancelled;
    alert(cancelled ? "已刪除品項，整單已一併取消" : "已刪除品項");
    setReloadTick((n) => n + 1);
  }

  // 空中轉補出貨：建 AT- 轉移單（store_to_store, shipped）＋本店即時出庫，
  // 轉入單 confirmed → shipping。接收店隨後在「收貨」頁收掉就變成可取貨。
  // 新單在轉單當下就走完這一段（rpc_transfer_order_* → _air_ship_order_items），
  // 這支只用在自動出貨上線前卡住的舊單。
  async function shipAir(s: PendingAirShipment) {
    if (!head) return;
    if (!confirm(
      `✈ 空中轉補出貨：${s.order_no}（${s.store_name}）\n\n` +
      `會從本店庫存扣掉 ${s.qty} 件並建立轉移單，${s.store_name}在「收貨」頁收貨後即可交給顧客。\n` +
      `確定貨已經寄出／交給司機了嗎？`,
    )) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { error: rpcErr } = await sb.rpc("rpc_ship_aid_order", {
      p_order_id: s.id,
      p_operator: operator,
    });
    if (rpcErr) { alert(`出貨失敗：${translateRpcError(rpcErr)}`); return; }
    alert(`已出貨，等 ${s.store_name} 在「收貨」頁收貨`);
    setReloadTick((n) => n + 1);
  }

  async function aidReturn() {
    if (!head) return;
    const walletPaid = Number(head.wallet_paid_amount ?? 0);
    const walletNote = walletPaid > 0
      ? `\n\n⚠️ 此單已用儲值金 $${walletPaid}，退單後會自動退回會員餘額。`
      : "";
    const reason = prompt(
      `退單（已收貨）：${head.order_no}\n會把已收貨品反向退回原調出店，並把來源單還原。請輸入原因：${walletNote}`
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { data, error: rpcErr } = await sb.rpc("rpc_return_aid_order", {
      p_order_id: head.id,
      p_reason: reason,
      p_operator: operator,
    });
    if (rpcErr) { alert(`退單失敗：${translateRpcError(rpcErr)}`); return; }
    const refunded = Number((data as { wallet_refunded?: number } | null)?.wallet_refunded ?? 0);
    alert(refunded > 0
      ? `已退單，已退回 $${refunded} 儲值金到會員餘額`
      : "已退單，貨已退回原調出店");
    setReloadTick((n) => n + 1);
  }

  // 撤銷最近一次取貨（誤點取貨用）：庫存反向沖回、品項還原待取、訂單狀態重算。金流不動。
  async function undoPickup() {
    if (!head) return;
    const reason = prompt(
      `撤銷取貨：${head.order_no}\n會把最近一次取貨的品項還原為「待取」並沖回門市庫存。\n請輸入原因：`,
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { data, error: rpcErr } = await sb.rpc("rpc_undo_pickup", {
      p_order_id: head.id,
      p_operator: operator,
      p_reason: reason || null,
    });
    if (rpcErr) { alert(`撤銷失敗：${translateRpcError(rpcErr)}`); return; }
    const r = data as { items_restored: number; new_status: string; wallet_paid_amount: number };
    const walletNote = Number(r.wallet_paid_amount ?? 0) > 0
      ? `\n⚠️ 此單已收儲值金 $${Number(r.wallet_paid_amount)}，仍保留在訂單上（之後取貨不需再付；要退款請走取消流程）。`
      : "";
    alert(`已撤銷取貨（${r.items_restored} 項還原為待取）\n訂單狀態：${statusLabel(r.new_status)}${walletNote}`);
    setReloadTick((n) => n + 1);
  }
  const pickableItems = items.filter((it) => ["pending", "reserved", "ready"].includes(it.status));
  // ready 單全可取；shipping / partially_completed 單看品項到貨狀態（部分到貨可先取已到品項）
  const canPickup =
    head.status === "ready"
      ? pickableItems.length > 0
      : ["shipping", "partially_completed"].includes(head.status) &&
        pickableItems.some((it) => itemReady.get(it.id) === true);
  // 撤銷取貨：有已取品項且訂單未進入取消/逾期/轉出終態。權限對齊 rpc_undo_pickup 的 gate
  const canUndoPickup =
    role !== null &&
    ["owner", "admin", "hq_manager", "store_manager", ""].includes(role) &&
    items.some((it) => it.status === "picked_up") &&
    !["cancelled", "expired", "transferred_out"].includes(head.status);
  const memberLabel = head.member
    ? `${head.member.name ?? "—"} (${head.member.member_no})`
    : `(${head.nickname_snapshot ?? "—"})`;
  // 下單來源：由品項 source 推導（liff=App / manual=小幫手 …）
  const orderSource = summarizeOrderSource(items.map((it) => it.source));
  // 混合來源才逐品項標；單一來源整單已由「下單來源」欄表示，逐列重複反而吵
  const showItemSource = orderSource.kind === "mixed";

  return (
    <div className="space-y-4 text-sm">
      <div className="flex flex-wrap items-center justify-end gap-2">
        <SpinButton
          onClick={() => setAuditOpen(true)}
          className="rounded-md border border-zinc-300 px-3 py-1 text-xs font-medium text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
          title="售價 / 備註變更歷史"
        >
          📜 查看編輯歷史
        </SpinButton>
      </div>

      {draftCount > 0 && (
        <div className="flex flex-wrap items-center gap-2 rounded-md border border-yellow-300 bg-yellow-50 p-3 dark:border-yellow-800 dark:bg-yellow-950/40">
          <span className="text-xs font-medium text-yellow-800 dark:text-yellow-300">
            ⚠️ 您有 {draftCount} 項未儲存的修改
          </span>
          <input
            type="text"
            value={editReason}
            onChange={(e) => setEditReason(e.target.value)}
            placeholder="修改原因（選填，會記錄到編輯歷史）"
            className="ml-auto w-72 rounded-md border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-900"
          />
          <SpinButton
            onClick={clearDraft}
            disabled={saving}
            className="rounded-md border border-zinc-300 px-3 py-1 text-xs font-medium text-zinc-700 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
          >
            取消修改
          </SpinButton>
          <SpinButton
            onClick={saveAllDraft}
            disabled={saving}
            className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            {saving ? "儲存中…" : `💾 儲存（${draftCount}）`}
          </SpinButton>
        </div>
      )}
      {(canPrintSlip || canReprintReceipt || canTransfer || canPickup || canUndoPickup || canCancel || canRestoreCancel || canReturn || canAidReturn || isTransferredOut || pendingAirOut.length > 0 || outgoingAidInFlight.length > 0 || awaitingAirFrom) && (
        <div className="flex flex-wrap items-center justify-end gap-2">
          {awaitingAirFrom && (
            <span className="text-xs text-amber-700 dark:text-amber-400">
              ✈ 等 {awaitingAirFrom} 補出貨（出貨後本店在「收貨」頁收貨）
            </span>
          )}
          {/* 本單是互助轉入單 → 收貨店自己重印一份（單子丟了、要補簽收） */}
          {isAidOrder && (
            <SpinButton
              onClick={() => printViaIframe(withBasePath(`/transfers/print-aid?order_id=${head.id}`))}
              className="rounded-md border border-fuchsia-300 px-3 py-1 text-xs font-medium text-fuchsia-700 hover:bg-fuchsia-50 dark:border-fuchsia-800 dark:text-fuchsia-300 dark:hover:bg-fuchsia-950"
              title="列印互助出貨單（隨貨聯 + 出貨店存根聯）"
            >
              🖨 互助出貨單
            </SpinButton>
          )}
          {/* 本單把貨互助給別店 → 轉出店裝箱時印一張夾在貨上，
              經總倉的單上面就寫著最終要送到哪一家店，總倉照單轉交、不會掉 */}
          {outgoingAidInFlight.map((o) => (
            <SpinButton
              key={`aid-print-${o.id}`}
              onClick={() => printViaIframe(withBasePath(`/transfers/print-aid?order_id=${o.id}`))}
              className="rounded-md border border-fuchsia-300 px-3 py-1 text-xs font-medium text-fuchsia-700 hover:bg-fuchsia-50 dark:border-fuchsia-800 dark:text-fuchsia-300 dark:hover:bg-fuchsia-950"
              title={
                `列印互助出貨單（${o.order_no}・${o.is_air_transfer ? "空中轉直送" : "經總倉中轉"}）：` +
                `隨貨聯夾在箱子上，${o.is_air_transfer ? "" : "總倉、"}${o.store_name}照單點收簽名`
              }
            >
              🖨 出貨單 → {o.store_name}
            </SpinButton>
          ))}
          {pendingAirOut.map((s) => (
            <SpinButton
              key={s.id}
              onClick={() => shipAir(s)}
              className="rounded-md border border-sky-300 px-3 py-1 text-xs font-medium text-sky-700 hover:bg-sky-50 dark:border-sky-800 dark:text-sky-300 dark:hover:bg-sky-950"
              title={`這張空中轉單還沒出貨（自動出貨上線前的舊單）：按下會從本店出庫 ${s.qty} 件並建立轉移單，交給 ${s.store_name} 收貨（${s.order_no}）`}
            >
              ✈ 補出貨到 {s.store_name}
            </SpinButton>
          ))}
          {canReprintReceipt && (
            <SpinButton
              onClick={() =>
                printViaIframe(
                  withBasePath(`/pickup/print?event_ids=${pickupEvents.map((e) => e.id).join(",")}`),
                )
              }
              title={
                pickupEvents.length > 1
                  ? `補印取貨收據（${pickupEvents.length} 次取貨，依序各印一張）\n${pickupEvents.map((e) => pickupEventLabel(e)).join("\n")}`
                  : `補印取貨收據（${pickupEventLabel(pickupEvents[0])}）`
              }
              className="rounded-md border border-zinc-300 px-3 py-1 text-xs font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
            >
              補印收據{pickupEvents.length > 1 ? `（${pickupEvents.length}）` : ""}
            </SpinButton>
          )}
          {canPrintSlip && (
            <SpinButton
              onClick={() =>
                printViaIframe(withBasePath(`/pickup/print-list?order_ids=${head.id}`))
              }
              title="列印小白單（取貨清單，貨還沒到也可印）"
              className="rounded-md border border-zinc-300 px-3 py-1 text-xs font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
            >
              列印
            </SpinButton>
          )}
          {canPickup && (
            <SpinButton
              onClick={() => setPickupOpen(true)}
              className="rounded-md border border-emerald-300 px-3 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
              title="顧客取貨 — 可選哪些 item"
            >
              ✅ 確認取貨
            </SpinButton>
          )}
          {canUndoPickup && (
            <SpinButton
              onClick={undoPickup}
              className="rounded-md border border-amber-300 px-3 py-1 text-xs font-medium text-amber-700 hover:bg-amber-50 dark:border-amber-800 dark:text-amber-300 dark:hover:bg-amber-950"
              title="誤點取貨用：還原最近一次取貨的品項為待取，庫存反向沖回門市"
            >
              ⎌ 撤銷取貨
            </SpinButton>
          )}
          {canTransfer && (
            <SpinButton
              onClick={() => setTransferOpen(true)}
              className="rounded-md border border-blue-300 px-3 py-1 text-xs font-medium text-blue-700 hover:bg-blue-50 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950"
              title="貨留在店裡不動，只把這張單改掛給另一位客人（客人棄單、改給朋友、轉到其他店店長、互助接手都用這個）"
            >
              ↗ 轉給別人
            </SpinButton>
          )}
          {canReturn && (
            <SpinButton
              onClick={() => setReturnOpen(true)}
              className="rounded-md border border-orange-300 px-3 py-1 text-xs font-medium text-orange-700 hover:bg-orange-50 dark:border-orange-800 dark:text-orange-300 dark:hover:bg-orange-950"
              title="把此訂單已派到該店的 SKU 從本店扣掉、送回總倉；若只是要換人拿，請改用「↗ 轉給別人」"
            >
              ↩ 退貨回總倉
            </SpinButton>
          )}
          {canAidReturn && (
            <SpinButton
              onClick={aidReturn}
              className="rounded-md border border-orange-300 px-3 py-1 text-xs font-medium text-orange-700 hover:bg-orange-50 dark:border-orange-800 dark:text-orange-300 dark:hover:bg-orange-950"
              title="互助單已收貨：把貨反向退回原調出店，並還原來源單"
            >
              ↩ 退單（已收貨）
            </SpinButton>
          )}
          {canCancel && (
            <SpinButton
              onClick={cancelOrder}
              className={`rounded-md border px-3 py-1 text-xs font-medium ${
                isSpotSale
                  ? "border-amber-300 text-amber-700 hover:bg-amber-50 dark:border-amber-800 dark:text-amber-300 dark:hover:bg-amber-950"
                  : "border-red-300 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
              }`}
              title={
                head.status === "shipping"
                  ? "撤回派貨並反向回收已出庫存"
                  : isSpotSale
                    ? "這張單的貨還沒扣庫存，退回後會變回「可分配」，可以再配給別人"
                    : "取消訂單"
              }
            >
              {/* 現貨直配的貨是從庫存配出去的，退掉＝貨回到可分配，
                  講「取消」像是作廢一筆買賣，跟店員腦中的動作對不起來（2026-08-16 回報）*/}
              {isSpotSale ? "↩ 退回庫存" : "取消"}
              {Number(head.wallet_paid_amount ?? 0) > 0 && (
                <span className="ml-1 text-[10px] font-normal text-zinc-500">(將退 ${Number(head.wallet_paid_amount)})</span>
              )}
            </SpinButton>
          )}
          {canRestoreCancel && (
            <SpinButton
              onClick={restoreCancelledOrder}
              className="rounded-md border border-emerald-300 px-3 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
              title="誤按取消 / 客人反悔：把訂單救回取消前的狀態（貨已到店會直接變成可取貨）"
            >
              ⎌ 復原取消
            </SpinButton>
          )}
          {isTransferredOut && (
            <span className="text-xs text-zinc-500">⚠️ 此訂單已轉出</span>
          )}
        </div>
      )}

      <OrderReturnCreateModal
        open={returnOpen}
        onClose={() => setReturnOpen(false)}
        onCreated={() => {
          setReturnOpen(false);
          setReloadTick((n) => n + 1);
        }}
        prefillOrderId={head.id}
        prefillStoreId={head.pickup_store_id}
      />

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Field label="訂單號" value={<span className="font-mono">{head.order_no}</span>} />
        <Field
          label="狀態"
          value={
            <>
            <span
              className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${
                head.status === "cancelled"
                  ? "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300"
                  : head.status === "expired"
                  ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                  : head.status === "transferred_out"
                  ? "bg-zinc-300 text-zinc-700 line-through dark:bg-zinc-700 dark:text-zinc-300"
                  : head.status === "completed"
                  ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300"
              }`}
            >
              {statusLabel(head.status)}
            </span>
              {head.stockout_at && (
                <span
                  title={`供應商斷貨於 ${new Date(head.stockout_at).toLocaleString("zh-TW")}`}
                  className="ml-1 inline-block rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-medium text-red-800 dark:bg-red-950 dark:text-red-300"
                >
                  ⛔ 斷貨
                </span>
              )}
            </>
          }
        />
        <Field label="取貨截止" value={head.pickup_deadline ?? "—"} />
        <Field
          label="會員"
          value={
            head.member ? (
              <span>
                {head.member.name ?? "—"}{" "}
                <span className="font-mono text-xs text-zinc-500">{head.member.member_no}</span>
                <br />
                <span className="font-mono text-xs text-zinc-500">{head.member.phone ?? "—"}</span>
              </span>
            ) : (
              <span className="text-zinc-500">({head.nickname_snapshot ?? "—"})</span>
            )
          }
        />
        {/* 內部 sentinel 團的單（現貨直配 / 補貨 / 轉單…）不要照實印
            「__INTERNAL_RESTOCK__【內部】補貨申請」—— 那是共用假團的名字，
            一張現貨直配單寫著「補貨申請」店員會看錯（2026-08-16 回報）。
            改標實際來源；真團維持印開團名稱。 */}
        {(() => {
          const internal =
            head.campaign?.campaign_no?.startsWith("__")
              ? internalOrderSource(head.order_no)
              : null;
          if (internal) {
            return (
              <Field
                label="來源"
                value={
                  <span title={internal.hint}>
                    {internal.label}
                    <span className="ml-1.5 text-xs text-zinc-500">{internal.hint}</span>
                  </span>
                }
              />
            );
          }
          return (
            <Field
              label="開團"
              value={head.campaign ? `${head.campaign.campaign_no} ${head.campaign.name}` : "—"}
            />
          );
        })()}
        <Field label="取貨店" value={head.store?.name ?? "—"} />
        <Field
          label="下單來源"
          value={
            orderSource.kind === "none" ? (
              <span className="text-zinc-400">—</span>
            ) : (
              <OrderSourceBadge summary={orderSource} />
            )
          }
        />
        <Field label="建立" value={fmtDt(head.created_at)} />
        <Field label="最後更新" value={fmtDt(head.updated_at)} />
        <Field
          label="整單折扣"
          value={
            <EditableDiscount
              value={orderDiscountValue}
              disabled={!canEditAmount}
              onChange={(v) => setOrderDraft({ discount: v })}
              referenceAmount={netSubtotal}
            />
          }
        />
        <Field
          label="單頭備註"
          value={
            <EditableText
              value={orderNotesValue}
              disabled={!canEditNotes}
              placeholder="（點此加備註）"
              onSave={async (v) => setOrderDraft({ notes: v })}
              multiline
            />
          }
        />
      </div>

      <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-200 bg-zinc-50 px-3 py-2 text-xs font-medium dark:border-zinc-800 dark:bg-zinc-900">
          <span>
            {/* 項數 / 件數不算已取消 / 斷貨的行（那些行仍列在表格裡，紅標標示） */}
            明細（{activeItems.length} 項 · {totalQty} 件
            {totalReturnedQty > 0 && (
              <span className="ml-1 text-orange-700 dark:text-orange-400">· ↩ 已退 {totalReturnedQty} 件</span>
            )}
            ）
          </span>
          <div className="flex flex-wrap items-center gap-3 font-mono">
            <span className="text-zinc-500">原價 ${Math.round(grossTotal)}</span>
            {lineDiscountTotal > 0 && (
              <span className="text-zinc-500">− 單品折扣 ${Math.round(lineDiscountTotal)}</span>
            )}
            <span className="text-zinc-500">小計 ${Math.round(subtotal)}</span>
            {returnedDeduction > 0 && (
              <span className="text-orange-700 dark:text-orange-400">− 退貨 ${Math.round(returnedDeduction)}</span>
            )}
            {orderDeduction > 0 && (
              <span className="text-zinc-500">
                − 整單折扣
                {orderDiscountValue.kind === "percent" && orderDiscountValue.value > 0
                  ? ` ${orderDiscountValue.value}% (= $${Math.round(orderDeduction)})`
                  : ` $${Math.round(orderDeduction)}`}
              </span>
            )}
            <span className="text-base">= 應收 <span className="font-semibold">${payableAmount}</span></span>
            {Number(head.wallet_paid_amount) > 0 && (
              <span className="text-zinc-500">− 已用儲值金 ${Number(head.wallet_paid_amount)}</span>
            )}
            {(() => {
              const balDue = Math.max(0, payableAmount - Number(head.wallet_paid_amount ?? 0));
              const isPaid = head.payment_status === "paid";
              const canPay = !!head.member && balDue > 0 && canPayWithWallet(head.status, head.payment_status);
              return (
                <>
                  {Number(head.wallet_paid_amount) > 0 && (
                    <span className="text-base">= 應付剩餘 <span className={`font-semibold ${balDue === 0 ? "text-emerald-700 dark:text-emerald-400" : ""}`}>${balDue}</span></span>
                  )}
                  {isPaid && (
                    <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">✅ 已付清</span>
                  )}
                  {canPay && (
                    <SpinButton
                      onClick={() => setWalletPayOpen(true)}
                      className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-medium text-white hover:bg-emerald-700"
                    >💳 用儲值金結帳</SpinButton>
                  )}
                </>
              );
            })()}
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">商品</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">數量</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">單價</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">分店價</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">折扣</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">小計</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">備註</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">第一次加</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">最後更新</th>
                {canEditQty && <th className="px-3 py-2 text-right font-medium text-zinc-500">操作</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {items.length === 0 ? (
                <tr><td colSpan={canEditQty ? 10 : 9} className="p-4 text-center text-zinc-500">尚無明細</td></tr>
              ) : items.map((it) => {
                const eff = itemEffective(it);
                const sub = computeLineSubtotal(Number(eff.qty), eff.unit_price, eff.discount);
                const isDirty = draft.items.has(it.id);
                const badge = itemStatusBadge(it.status, !!it.stockout_at);
                const isPicked = it.status === "picked_up";
                return (
                  <tr key={it.id} className={isDirty ? "bg-yellow-50 dark:bg-yellow-950/30" : isPicked ? "bg-emerald-50/40 dark:bg-emerald-950/20" : ""}>
                    <td className="px-3 py-2">
                      {it.sku ? (
                        <span>
                          {it.sku.product_name ?? "—"}
                          {it.sku.variant_name && <span className="text-zinc-500"> / {it.sku.variant_name}</span>}
                          <span className="ml-1 font-mono text-zinc-400">{it.sku.sku_code}</span>
                        </span>
                      ) : "—"}
                      {badge && (
                        <span className={`ml-1.5 rounded px-1.5 py-0.5 text-[10px] font-medium ${badge.cls}`}>
                          {badge.label}
                        </span>
                      )}
                      {showItemSource && <ItemSourceBadge source={it.source} className="ml-1.5" />}
                    </td>
                    <td className="px-3 py-2 text-right font-mono">
                      {isPicked ? (
                        <span title="此行已取貨，數量不可改" className="text-zinc-500">{Number(it.qty)}</span>
                      ) : canEditQty ? (
                        <input
                          type="number"
                          min={1}
                          step={1}
                          value={Number(eff.qty)}
                          onChange={(e) => {
                            const v = Number(e.target.value);
                            if (Number.isFinite(v) && v >= 1) {
                              setItemDraft(it.id, { qty: v });
                            }
                          }}
                          className="w-20 rounded border border-zinc-300 bg-white px-2 py-1 text-right font-mono dark:border-zinc-600 dark:bg-zinc-800"
                        />
                      ) : (canEdit || isStoreOfThisOrder) && head?.status === "confirmed" ? (
                        <span title="已被請購單鎖定,如需調整請聯絡總部" className="cursor-help text-zinc-500">
                          {Number(it.qty)} 🔒
                        </span>
                      ) : (
                        Number(it.qty)
                      )}
                    </td>
                    <td className="px-3 py-2 text-right font-mono">
                      <EditableNumber
                        value={Number(eff.unit_price)}
                        min={0}
                        prefix="$"
                        disabled={!canEditAmount || isPicked}
                        onSave={async (v) => setItemDraft(it.id, { unit_price: v })}
                      />
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-zinc-500">
                      {it.sku && branchPrices.has(it.sku.id)
                        ? `$${branchPrices.get(it.sku.id)!.toFixed(0)}`
                        : "—"}
                    </td>
                    <td className="px-3 py-2 text-right font-mono">
                      <EditableDiscount
                        value={eff.discount}
                        disabled={!canEditAmount || isPicked}
                        onChange={(v) => setItemDraft(it.id, { discount: v })}
                        compact
                        referenceAmount={Number(eff.qty) * Number(eff.unit_price)}
                      />
                    </td>
                    <td className="px-3 py-2 text-right font-mono">${Math.round(sub)}</td>
                    <td className="px-3 py-2">
                      <EditableText
                        value={eff.notes}
                        disabled={!canEditNotes}
                        placeholder="（點此加備註）"
                        onSave={async (v) => setItemDraft(it.id, { notes: v })}
                      />
                    </td>
                    <td className="px-3 py-2 text-zinc-500">
                      {fmtDt(it.created_at)}<br />
                      <span className="text-[10px]">by {staffLabel(it.created_by, staffNames)}</span>
                    </td>
                    <td className="px-3 py-2 text-zinc-500">
                      {fmtDt(it.updated_at)}<br />
                      <span className="text-[10px]">by {staffLabel(it.updated_by, staffNames)}</span>
                    </td>
                    {canEditQty && (
                      <td className="px-3 py-2 text-right">
                        {!["cancelled", "expired"].includes(it.status) && !isPicked ? (
                          <SpinButton
                            onClick={() => deleteItem(it)}
                            title="刪除此品項（待確認訂單，刪到最後一項會自動取消整單）"
                            className="rounded-md border border-red-300 px-2 py-1 text-[11px] font-medium text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950"
                          >
                            刪除
                          </SpinButton>
                        ) : null}
                      </td>
                    )}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {/* 退貨記錄（return_to_hq transfer 反掛到此訂單） */}
      {returns !== null && returns.length > 0 && (
        <div className="rounded-md border border-orange-200 dark:border-orange-900">
          <div className="border-b border-orange-200 bg-orange-50 px-3 py-2 text-xs font-medium text-orange-900 dark:border-orange-900 dark:bg-orange-950/40 dark:text-orange-200">
            ↩ 退貨記錄（{returns.length} 張單 · 共退 {totalReturnedQty} 件）
          </div>
          <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {returns.map((r) => {
              const isReceived = r.status === "received";
              const note = parseReturnNote(r.notes);
              return (
                <li key={r.id} className="p-3 text-xs">
                  <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                    <button
                      type="button"
                      onClick={() => setReturnDetailId(r.id)}
                      className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                      title="開啟退貨單明細"
                    >
                      {r.transfer_no}
                    </button>
                    <span
                      className={`rounded px-2 py-0.5 text-[10px] font-medium ${
                        isReceived
                          ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                          : "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                      }`}
                    >
                      {isReceived ? "已退回總倉" : "店端已出貨、待總倉收貨"}
                    </span>
                    {note.isRestock && (
                      <span className="rounded bg-purple-100 px-2 py-0.5 text-[10px] font-medium text-purple-800 dark:bg-purple-950 dark:text-purple-300">
                        客戶已取貨後退回
                      </span>
                    )}
                    {note.isDamage && (
                      <span className="rounded bg-red-100 px-2 py-0.5 text-[10px] font-medium text-red-800 dark:bg-red-950 dark:text-red-300">
                        破損
                      </span>
                    )}
                    {r.shipped_at && (
                      <span className="text-zinc-500">出貨 {fmtDt(r.shipped_at)}</span>
                    )}
                    {r.received_at && (
                      <span className="text-zinc-500">收貨 {fmtDt(r.received_at)}</span>
                    )}
                    {r.shipped_by && (
                      <span className="text-zinc-500">by {staffLabel(r.shipped_by, staffNames)}</span>
                    )}
                  </div>
                  {(note.reason || note.extra) && (
                    <div className="mt-1 text-zinc-600 dark:text-zinc-400">
                      {note.reason && <span>原因：{note.reason}</span>}
                      {note.reason && note.extra && <br />}
                      {note.extra && <span>{note.extra}</span>}
                    </div>
                  )}
                  <ul className="mt-2 grid gap-1 sm:grid-cols-2">
                    {r.lines.map((l, i) => {
                      const sku = skuLookup.get(l.sku_id);
                      const skuLabel = sku
                        ? `${sku.product_name ?? "—"}${sku.variant_name ? " / " + sku.variant_name : ""}`
                        : `SKU #${l.sku_id}`;
                      const skuCode = sku?.sku_code ?? "";
                      return (
                        <li key={i} className="flex flex-wrap items-baseline gap-1">
                          <span>• {skuLabel}</span>
                          {skuCode && <span className="font-mono text-zinc-400">{skuCode}</span>}
                          <span className="font-mono">× {Number(l.qty_shipped)}</span>
                          {l.notes && <span className="text-zinc-500">— {l.notes}</span>}
                        </li>
                      );
                    })}
                  </ul>
                </li>
              );
            })}
          </ul>
        </div>
      )}

      {/* 轉出記錄（本單 → 別家店）。轉入單掛在收貨店名下、轉出店的訂單列表撈不到，
          不在來源單上寫出來，貨從店裡出去就等於系統上查無此事（2026-08-18 南平→三峽）。 */}
      {outgoingAid.length > 0 && (
        <div className="rounded-md border border-fuchsia-200 dark:border-fuchsia-900">
          <div className="border-b border-fuchsia-200 bg-fuchsia-50 px-3 py-2 text-xs font-medium text-fuchsia-900 dark:border-fuchsia-900 dark:bg-fuchsia-950/40 dark:text-fuchsia-200">
            ↗ 轉出記錄（{outgoingAid.length} 張單 · 共 {totalOutgoingQty} 件）
            <span className="ml-2 font-normal">貨從本店出去，隨貨的出貨單在這裡印</span>
          </div>
          <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {outgoingAid.map((o) => (
              <li key={`aid-out-${o.id}`} className="flex flex-wrap items-center gap-x-3 gap-y-1 p-3 text-xs">
                {onNavigate ? (
                  <button
                    type="button"
                    onClick={() => onNavigate(o.id, o.order_no)}
                    className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                    title="開啟轉入單"
                  >
                    {o.order_no}
                  </button>
                ) : (
                  <a
                    href={withBasePath(
                      `/orders?q=${encodeURIComponent(o.order_no)}` +
                      (o.store_id != null ? `&storeId=${o.store_id}` : ""),
                    )}
                    className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {o.order_no}
                  </a>
                )}
                <span className="font-medium">
                  → {o.is_air_transfer ? "" : "總倉 → "}{o.store_name}
                </span>
                <span className="font-mono">{o.qty} 件</span>
                <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                  {aidRouteLabel(o.is_air_transfer)}・{aidStageLabel(o.status, o.is_air_transfer)}
                </span>
                <span className="text-zinc-500">{fmtDt(o.created_at)}</span>
                {isAidInFlight(o.status) && (
                  <SpinButton
                    onClick={() => printViaIframe(withBasePath(`/transfers/print-aid?order_id=${o.id}`))}
                    className="ml-auto rounded-md border border-fuchsia-300 px-2 py-1 text-[11px] font-medium text-fuchsia-700 hover:bg-fuchsia-50 dark:border-fuchsia-800 dark:text-fuchsia-300 dark:hover:bg-fuchsia-950"
                    title={
                      `列印互助出貨單（${o.order_no}）：隨貨聯夾在箱子上，` +
                      `${o.is_air_transfer ? "" : "總倉、"}${o.store_name}照單點收簽名`
                    }
                  >
                    🖨 出貨單
                  </SpinButton>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* 進度 timeline（採購到貨 → 撿貨 → 派貨 → 分店收貨） */}
      <Timeline steps={timeline} />

      {/* Aid order 專屬：互助轉移進度 */}
      {head.transferred_from_order_id != null && (
        <AidOrderTimeline orderId={head.id} />
      )}

      <OrderTransferModal
        open={transferOpen}
        onClose={() => setTransferOpen(false)}
        orderId={head.id}
        orderNo={head.order_no}
        sameStoreOnly={!["ready", "partially_completed"].includes(head.status)}
        partialOnly={head.status === "partially_completed"}
        canReturnToHq={canReturn}
        currentPickupStoreId={head.pickup_store_id}
        currentMemberLabel={memberLabel}
        items={pickableItems
          .filter((it) => it.sku?.id != null)
          .map((it) => ({
            id: it.id,
            sku_id: it.sku!.id,
            qty: Number(it.qty),
            product_name: it.sku?.product_name ?? null,
            variant_name: it.sku?.variant_name ?? null,
            sku_code: it.sku?.sku_code ?? null,
          }))}
        onSubmitted={(r) => {
          setTransferOpen(false);
          setReloadTick((n) => n + 1);
          if (!r.crossStore) {
            // 同店換客人：貨沒離開本店，沒有隨貨單要印
            alert(`轉出完成 → 訂單 #${r.newOrderId}（部分轉出時原單保留未轉出品項）`);
            return;
          }
          // 跨店＝貨要離開本店，裝箱當下就該把隨貨單印出來夾在箱子上。
          // 事後才想到要印的話，本單下方的「↗ 轉出記錄」還可以再印一次。
          const ok = confirm(
            `轉出完成 → ${r.toStoreName}（部分轉出時原單保留未轉出品項）\n\n` +
            `要現在列印互助出貨單嗎？\n` +
            `隨貨聯夾在箱子上，${r.isAir ? "" : "總倉、"}${r.toStoreName} 照單點收簽名。`,
          );
          if (ok) void printViaIframe(withBasePath(`/transfers/print-aid?order_id=${r.newOrderId}`));
        }}
      />
      <PickupDialog
        open={pickupOpen}
        onClose={() => setPickupOpen(false)}
        orderId={head.id}
        orderNo={head.order_no}
        onPickedUp={(r) => {
          setPickupOpen(false);
          alert(`取貨完成 (${r.picked_count} 項)\n訂單狀態：${statusLabel(r.new_order_status)}`);
          setReloadTick((n) => n + 1);
        }}
      />
      <OrderAuditDrawer
        open={auditOpen}
        onClose={() => setAuditOpen(false)}
        orderId={head.id}
      />
      <TransferDetailModal
        open={returnDetailId !== null}
        transferId={returnDetailId}
        onClose={() => setReturnDetailId(null)}
      />
      {head.member && (
        <WalletPayOrderModal
          open={walletPayOpen}
          onClose={() => setWalletPayOpen(false)}
          onSuccess={() => setReloadTick((n) => n + 1)}
          orderId={head.id}
          orderNo={head.order_no}
          memberId={head.member.id}
          memberName={head.member.name}
          balanceDue={Math.max(0, payableAmount - Number(head.wallet_paid_amount ?? 0))}
        />
      )}
    </div>
  );
}

// 顧客取貨時間：取 order_pickup_events 中最新一筆取貨事件（picked_up / partial_pickup）的 created_at。
// order_pickup_events 為 append-only，是取貨時間的權威來源（customer_orders.updated_at 會被改折扣等其它操作覆寫）。
async function fetchPickupTs(orderId: number): Promise<string | null> {
  const sb = getSupabase();
  const { data } = await sb
    .from("order_pickup_events")
    .select("created_at")
    .eq("order_id", orderId)
    .in("event_type", ["picked_up", "partial_pickup"])
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  return (data as { created_at: string } | null)?.created_at ?? null;
}

async function buildTimeline(
  head: OrderHead,
  skuIds: number[],
  onNavigate?: (orderId: number, orderNo: string) => void,
): Promise<TimelineStep[]> {
  const sb = getSupabase();

  // transferred_out: 訂單已關閉、流程不再進行；只顯示一個結束 step
  if (head.status === "transferred_out") {
    // 找新訂單號做 detail link（從 customer_orders 用 transferred_to_order_id）
    let newOrderInfo = "已轉出（流程關閉、不入金額統計）";
    let newOrderHref: string | undefined;
    let newOrderClick: (() => void) | undefined;
    const { data: self } = await sb
      .from("customer_orders")
      .select("transferred_to_order_id")
      .eq("id", head.id)
      .maybeSingle();
    const newId = (self as { transferred_to_order_id: number | null } | null)?.transferred_to_order_id;
    if (newId) {
      const { data: newOrd } = await sb
        .from("customer_orders")
        .select("order_no")
        .eq("id", newId)
        .maybeSingle();
      const newNo = (newOrd as { order_no: string } | null)?.order_no;
      if (newNo) {
        newOrderInfo = `已轉出 → 新訂單 ${newNo}`;
        if (onNavigate) {
          newOrderClick = () => onNavigate(newId, newNo);
        } else {
          newOrderHref = `/orders?id=${newId}`;
        }
      }
    }
    return [
      {
        label: "訂單關閉（已轉出）",
        ts: head.updated_at,
        done: true,
        detail: newOrderInfo,
        detailHref: newOrderHref,
        detailOnClick: newOrderClick,
      },
    ];
  }

  // transferred-in: 從別張訂單轉進來（5b-1 整單轉 / 5c partial 拆單）
  // 不走採購／撿貨／派貨流程，改顯示「轉出店 → 運送中 → 分店收貨 → 顧客取貨」
  if (head.transferred_from_order_id) {
    const { data: src } = await sb
      .from("customer_orders")
      .select("id, order_no, pickup_store_id, store:stores!customer_orders_pickup_store_id_fkey(name)")
      .eq("id", head.transferred_from_order_id)
      .maybeSingle();
    type SrcRow = { id: number; order_no: string; pickup_store_id: number | null; store: { name: string } | { name: string }[] | null };
    const s = src as unknown as SrcRow | null;
    const srcStoreName = s?.store
      ? (Array.isArray(s.store) ? s.store[0]?.name : s.store.name) ?? "—"
      : "—";
    const srcDetail = s ? `來源：${srcStoreName} 訂單 ${s.order_no}` : `來源訂單 #${head.transferred_from_order_id}`;
    const srcHref = s ? `/orders?id=${s.id}` : undefined;
    const srcClick = (s && onNavigate) ? () => onNavigate(s.id, s.order_no) : undefined;

    // Status → step done 的 rank：每步驟有「需 status >= X 才 done」的閾值
    const TRANSFER_RANK: Record<string, number> = {
      pending: 0, confirmed: 1, reserved: 2, shipping: 3,
      ready: 4, partially_ready: 4,
      partially_completed: 5, completed: 5,
      expired: -1, cancelled: -1, transferred_out: -1,
    };
    const rank = TRANSFER_RANK[head.status] ?? 0;

    const sourceStep: TimelineStep = {
      label: "轉出店",
      ts: head.created_at,
      done: true,
      detail: srcDetail,
      detailHref: onNavigate ? undefined : srcHref,
      detailOnClick: srcClick,
    };
    const customerStep: TimelineStep = {
      label: "顧客取貨",
      ts: rank >= 5 ? await fetchPickupTs(head.id) : null,
      done: rank >= 5,
      detail: rank >= 5 ? "已完成" : `當前：${statusLabel(head.status)}`,
    };

    if (head.is_air_transfer) {
      // 空中轉：店對店直送，全程不經總倉 —— 轉單當下就自動出貨（無派貨步驟）
      return [
        sourceStep,
        {
          label: "轉出店出貨",
          ts: null,
          done: rank >= 3,
          detail: rank >= 3
            ? "（轉單時已自動出庫、轉移單已建立）"
            : `（等 ${srcStoreName} 在來源訂單按「✈ 補出貨」）`,
        },
        {
          label: "分店收貨",
          ts: null,
          done: rank >= 4,
          detail: rank >= 4 ? "（分店已可取貨）" : "（在「收貨」頁收 AT- 轉移單）",
        },
        customerStep,
      ];
    }
    // 非空中轉：經總倉
    return [
      sourceStep,
      {
        label: "總倉收到",
        ts: null,
        done: rank >= 1,
        detail: rank >= 1 ? "（訂單已確認）" : "（待確認→已確認後標記）",
      },
      {
        label: "運送中",
        ts: null,
        done: rank >= 3,
        detail: rank >= 3 ? "（總倉已出貨）" : "（總倉出貨）",
      },
      {
        label: "分店收貨",
        ts: null,
        done: rank >= 4,
        detail: rank >= 4 ? "（分店已可取貨）" : "（暫無系統紀錄）",
      },
      customerStep,
    ];
  }

  const campaignId = head.campaign_id;
  const storeId = head.pickup_store_id;
  const status = head.status;

  // Step 1: 採購到貨 — campaign 對應的 POs 是否都 fully_received
  let poDone = false;
  let poTs: string | null = null;
  let poDetail = "";
  // 只看這張訂單裡實際 SKU 對應的 PO（過濾掉同 campaign 但其它 SKU 用到的 PO）
  if (campaignId && skuIds.length > 0) {
    const { data: pris } = await sb
      .from("purchase_request_items")
      .select("po_item_id")
      .eq("source_campaign_id", campaignId)
      .in("sku_id", skuIds)
      .not("po_item_id", "is", null);
    const poItemIds = ((pris as { po_item_id: number | null }[] | null) ?? [])
      .map((r) => r.po_item_id)
      .filter((x): x is number => x !== null);
    if (poItemIds.length > 0) {
      const { data: pois } = await sb
        .from("purchase_order_items")
        .select("po_id")
        .in("id", poItemIds);
      const poIds = Array.from(
        new Set(((pois as { po_id: number }[] | null) ?? []).map((r) => r.po_id)),
      );
      if (poIds.length > 0) {
        const { data: pos } = await sb
          .from("purchase_orders")
          .select("id, status, updated_at")
          .in("id", poIds);
        const poList = ((pos as { id: number; status: string; updated_at: string }[] | null) ?? []);
        const allDone = poList.length > 0 && poList.every((p) => p.status === "fully_received" || p.status === "closed");
        if (allDone) {
          poDone = true;
          poTs = poList
            .map((p) => p.updated_at)
            .sort()
            .reverse()[0] ?? null;
        }
        poDetail = `${poList.filter((p) => p.status === "fully_received" || p.status === "closed").length}/${poList.length} PO`;
      }
    }
  }

  // Step 2/3/4: wave → transfer
  let wavePicked = false;
  let waveTs: string | null = null;
  let waveDetail = "";
  let waveHref: string | undefined;
  let xferShipped = false;
  let shippedTs: string | null = null;
  let xferReceived = false;
  let receivedTs: string | null = null;
  let xferDetail = "";
  let xferHref: string | undefined;

  if (campaignId && storeId && skuIds.length > 0) {
    // 找此 order 對應的 wave_ids（同 campaign + 同店 + 同 sku）
    const { data: pwis } = await sb
      .from("picking_wave_items")
      .select("wave_id")
      .eq("campaign_id", campaignId)
      .eq("store_id", storeId)
      .in("sku_id", skuIds);
    const waveIds = Array.from(
      new Set(((pwis as { wave_id: number }[] | null) ?? []).map((r) => r.wave_id)),
    );

    if (waveIds.length > 0) {
      // wave 狀態
      const { data: ws } = await sb
        .from("picking_waves")
        .select("id, wave_code, status, updated_at")
        .in("id", waveIds);
      const waves = ((ws as { id: number; wave_code: string; status: string; updated_at: string }[] | null) ?? []);
      const allPicked = waves.length > 0 && waves.every((w) => ["picked", "shipped", "cancelled"].includes(w.status));
      if (allPicked) {
        wavePicked = true;
        waveTs = waves
          .map((w) => w.updated_at)
          .sort()
          .reverse()[0] ?? null;
      }
      if (waves.length === 1) {
        waveDetail = waves[0].wave_code;
        waveHref = `/wms/picking/history?wave=${waves[0].id}`;
      } else if (waves.length > 1) {
        waveDetail = `${waves.length} 張撿貨單`;
        waveHref = `/wms/picking/history`;
      }

      // transfer for each wave to this store
      const transferNos = waveIds.map((wid) => `WAVE-${wid}-S${storeId}`);
      const { data: ts } = await sb
        .from("transfers")
        .select("transfer_no, status, shipped_at, received_at")
        .in("transfer_no", transferNos);
      const xfers = ((ts as { transfer_no: string; status: string; shipped_at: string | null; received_at: string | null }[] | null) ?? []);
      if (xfers.length === 1) {
        xferDetail = xfers[0].transfer_no;
        xferHref = `/hq/inbox?source=transfer`;
      } else if (xfers.length > 1) {
        xferDetail = `${xfers.length} 張 TR`;
        xferHref = `/hq/inbox?source=transfer`;
      }
      if (xfers.length > 0) {
        const allShipped = xfers.every((t) => ["shipped", "received", "closed"].includes(t.status));
        if (allShipped) {
          xferShipped = true;
          shippedTs = xfers
            .map((t) => t.shipped_at)
            .filter((x): x is string => !!x)
            .sort()
            .reverse()[0] ?? null;
        }
        const allReceived = xfers.every((t) => ["received", "closed"].includes(t.status));
        if (allReceived) {
          xferReceived = true;
          receivedTs = xfers
            .map((t) => t.received_at)
            .filter((x): x is string => !!x)
            .sort()
            .reverse()[0] ?? null;
        }
      }
    }
  }

  // Step 5: 顧客取貨 — order.status
  const pickedUp = status === "completed" || status === "picked_up";
  // 已（部分）取貨才查事件時間，避免對未取貨訂單多打一次 DB
  const pickedUpTs =
    pickedUp || status === "partially_completed" ? await fetchPickupTs(head.id) : null;

  return [
    { label: "採購到貨", ts: poTs, done: poDone, detail: poDetail || undefined },
    { label: "撿貨完成", ts: waveTs, done: wavePicked, detail: waveDetail || undefined, detailHref: waveHref },
    { label: "派貨出倉", ts: shippedTs, done: xferShipped, detail: xferDetail || undefined, detailHref: xferHref },
    { label: "分店收貨", ts: receivedTs, done: xferReceived, detail: xferDetail || undefined, detailHref: xferHref },
    { label: "顧客取貨", ts: pickedUpTs, done: pickedUp, detail: statusLabel(status) },
  ];
}

function Timeline({ steps }: { steps: TimelineStep[] | null }) {
  if (steps === null) {
    return (
      <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
        進度載入中…
      </div>
    );
  }
  return (
    <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="mb-2 text-xs font-medium text-zinc-500">進度</div>
      <ol className="flex items-start gap-1 overflow-x-auto text-xs">
        {steps.map((s, i) => (
          <Fragment key={s.label}>
            <li className="flex min-w-0 flex-col items-center text-center">
              <span
                className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[10px] font-semibold ${
                  s.done
                    ? "bg-emerald-600 text-white"
                    : "bg-zinc-300 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
                }`}
              >
                {s.done ? "✓" : i + 1}
              </span>
              <div className={`mt-1 text-[11px] ${s.done ? "font-medium" : "text-zinc-500"}`}>
                {s.label}
              </div>
              {s.detail && (
                s.detailOnClick ? (
                  <SpinButton
                    type="button"
                    onClick={s.detailOnClick}
                    className="text-[10px] font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {s.detail}
                  </SpinButton>
                ) : s.detailHref ? (
                  <a
                    href={withBasePath(s.detailHref)}
                    className="text-[10px] font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {s.detail}
                  </a>
                ) : (
                  <div className="text-[10px] text-zinc-500">{s.detail}</div>
                )
              )}
              {s.ts && (
                <div className="text-[10px] text-zinc-400">
                  {new Date(s.ts).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
                </div>
              )}
            </li>
            {i < steps.length - 1 && (
              <li
                aria-hidden
                className={`mt-3 h-[2px] flex-1 ${
                  steps[i + 1].done ? "bg-emerald-400" : "bg-zinc-300 dark:bg-zinc-700"
                }`}
              />
            )}
          </Fragment>
        ))}
      </ol>
    </div>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <div className="text-xs text-zinc-500">{label}</div>
      <div>{value}</div>
    </div>
  );
}

"use client";

import { Fragment, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { OrderTransferModal } from "@/components/OrderTransferModal";
import OrderReturnCreateModal from "@/components/OrderReturnCreateModal";
import { PickupDialog } from "@/components/PickupDialog";
import { AidOrderTimeline } from "@/components/AidOrderTimeline";
import { OrderAuditDrawer } from "@/components/OrderAuditDrawer";
import { WalletPayOrderModal } from "@/components/WalletPayOrderModal";
import { EditableNumber, EditableText } from "@/components/EditableCell";
import { EditableDiscount, deriveDiscount, type DiscountValue } from "@/components/EditableDiscount";
import { useAuth } from "@/components/AuthProvider";
import { useRole } from "@/lib/role";
import { orderStatusLabel as statusLabel, canPayWithWallet } from "@/lib/orderStatus";
import { withBasePath } from "@/lib/basePath";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";

type OrderHead = {
  id: number;
  order_no: string;
  status: string;
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

function computeLineSubtotal(qty: number, unitPrice: number, d: DiscountValue): number {
  const gross = Number(qty) * Number(unitPrice);
  const pct = d.kind === "percent" ? Number(d.value) : 0;
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
  const [timeline, setTimeline] = useState<TimelineStep[] | null>(null);
  const [staffNames, setStaffNames] = useState<Map<string, string>>(new Map());
  const [pickupReady, setPickupReady] = useState<boolean>(false);
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
  const canEdit = useMemo(() => {
    if (role === null) return false;
    if (HQ_ROLES.has(role)) return true;
    if (Array.isArray(userStores) && userStores.includes("總倉")) return true;
    if (head?.store?.name && Array.isArray(userStores) && userStores.includes(head.store.name)) return true;
    return false;
  }, [role, userStores, head?.store?.name]);

  // qty 只有 pending 訂單可改;一旦被 PR 鎖定變 confirmed 就唯讀
  const canEditQty = canEdit && head?.status === "pending";

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [hRes, iRes] = await Promise.all([
        sb.from("customer_orders")
          .select("id, order_no, status, pickup_deadline, nickname_snapshot, created_at, updated_at, pickup_store_id, campaign_id, transferred_from_order_id, is_air_transfer, discount_amount, discount_percent, wallet_paid_amount, payment_status, paid_at, notes, member:members(id, name, phone, member_no), campaign:group_buy_campaigns(id, campaign_no, name), store:stores!customer_orders_pickup_store_id_fkey(id, name)")
          .eq("id", orderId).maybeSingle(),
        sb.from("customer_order_items")
          .select("id, qty, unit_price, status, source, notes, discount_amount, discount_percent, created_at, updated_at, created_by, updated_by, sku:skus(id, sku_code, product_name, variant_name)")
          .eq("order_id", orderId)
          .order("created_at", { ascending: true }),
      ]);
      if (cancelled) return;
      if (hRes.error) { setError(hRes.error.message); return; }
      const headData = hRes.data as unknown as OrderHead;
      setHead(headData);
      if (iRes.error) { setError(iRes.error.message); return; }
      const itemsData = (iRes.data ?? []) as unknown as ItemRow[];
      setItems(itemsData);

      // ========== 載入加單者 user names ==========
      const uids = new Set<string>();
      for (const it of itemsData) {
        if (it.created_by) uids.add(it.created_by);
        if (it.updated_by) uids.add(it.updated_by);
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

      // ========== 載入 pickup_ready (基於分店收貨 transfer 實際狀態) ==========
      const { data: prData } = await sb
        .from("v_order_pickup_ready")
        .select("pickup_ready")
        .eq("order_id", orderId)
        .maybeSingle();
      if (!cancelled) {
        setPickupReady(((prData as { pickup_ready: boolean } | null)?.pickup_ready) ?? false);
      }
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

  const totalQty = items.reduce((s, i) => s + Number(itemEffective(i).qty), 0);
  const grossTotal = items.reduce((s, i) => {
    const eff = itemEffective(i);
    return s + Number(eff.qty) * Number(eff.unit_price);
  }, 0);
  const subtotal = items.reduce((s, i) => {
    const eff = itemEffective(i);
    return s + computeLineSubtotal(Number(eff.qty), eff.unit_price, eff.discount);
  }, 0);
  const lineDiscountTotal = Math.round((grossTotal - subtotal) * 10000) / 10000;
  const { deduction: orderDeduction, payable: payableAmount } = applyOrderDiscount(subtotal, orderDiscountValue);

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
  const canTransfer = ["pending", "confirmed", "reserved", "ready"].includes(head.status);
  const canCancel = ["pending", "confirmed", "shipping"].includes(head.status);
  // 一般顧客訂單退回總倉（rpc_create_order_return）— 互助單不走這條（貨應退回原 source 店）
  const canReturn = !isAidOrder && ["shipping", "ready", "partially_completed", "completed", "expired"].includes(head.status);
  // 互助單已收貨未取貨（status=ready）退單：退回原 source 店（rpc_return_aid_order，#234）
  const canAidReturn = isAidOrder && head.status === "ready";
  const isTransferredOut = head.status === "transferred_out";

  async function cancelOrder() {
    if (!head) return;
    const walletPaid = Number(head.wallet_paid_amount ?? 0);
    const walletNote = walletPaid > 0
      ? `\n\n⚠️ 此訂單已用儲值金 $${walletPaid}，取消後會自動退回會員餘額。`
      : "";
    const reason = prompt(
      (head.status === "shipping"
        ? `撤回派貨：${head.order_no}\n會反向回收已出庫存，請輸入原因：`
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
      : "已取消");
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
  const pickableItems = items.filter((it) => ["pending", "reserved", "ready"].includes(it.status));
  // 取貨判斷改用 v_order_pickup_ready (基於分店收貨 transfer 實際狀態)
  // 不再依賴 customer_orders.status === 'ready'（status 同步可能漏推）
  const canPickup = pickableItems.length > 0
    && !["completed","expired","cancelled","transferred_out"].includes(head.status)
    && pickupReady;
  const memberLabel = head.member
    ? `${head.member.name ?? "—"} (${head.member.member_no})`
    : `(${head.nickname_snapshot ?? "—"})`;

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
      {(canTransfer || canPickup || canCancel || canReturn || canAidReturn || isTransferredOut) && (
        <div className="flex items-center justify-end gap-2">
          {canPickup && (
            <SpinButton
              onClick={() => setPickupOpen(true)}
              className="rounded-md border border-emerald-300 px-3 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
              title="顧客取貨 — 可選哪些 item"
            >
              ✅ 確認取貨
            </SpinButton>
          )}
          {canTransfer && (
            <SpinButton
              onClick={() => setTransferOpen(true)}
              className="rounded-md border border-blue-300 px-3 py-1 text-xs font-medium text-blue-700 hover:bg-blue-50 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950"
              title="客人棄單 / 轉到其他店店長 / 互助接手"
            >
              ↗ 轉出此訂單
            </SpinButton>
          )}
          {canReturn && (
            <SpinButton
              onClick={() => setReturnOpen(true)}
              className="rounded-md border border-orange-300 px-3 py-1 text-xs font-medium text-orange-700 hover:bg-orange-50 dark:border-orange-800 dark:text-orange-300 dark:hover:bg-orange-950"
              title="把此訂單已派到該店的 SKU 退回總倉"
            >
              ↩ 退訂單
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
              className="rounded-md border border-red-300 px-3 py-1 text-xs font-medium text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
              title={head.status === "shipping" ? "撤回派貨並反向回收已出庫存" : "取消訂單"}
            >
              ✕ 取消訂單
              {Number(head.wallet_paid_amount ?? 0) > 0 && (
                <span className="ml-1 text-[10px] font-normal text-zinc-500">(將退 ${Number(head.wallet_paid_amount)})</span>
              )}
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
        <Field label="開團" value={head.campaign ? `${head.campaign.campaign_no} ${head.campaign.name}` : "—"} />
        <Field label="取貨店" value={head.store?.name ?? "—"} />
        <Field label="建立" value={fmtDt(head.created_at)} />
        <Field label="最後更新" value={fmtDt(head.updated_at)} />
        <Field
          label="整單折扣"
          value={
            <EditableDiscount
              value={orderDiscountValue}
              disabled={!canEdit}
              onChange={(v) => setOrderDraft({ discount: v })}
              referenceAmount={subtotal}
            />
          }
        />
        <Field
          label="單頭備註"
          value={
            <EditableText
              value={orderNotesValue}
              disabled={!canEdit}
              placeholder="（點此加備註）"
              onSave={async (v) => setOrderDraft({ notes: v })}
              multiline
            />
          }
        />
      </div>

      <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-200 bg-zinc-50 px-3 py-2 text-xs font-medium dark:border-zinc-800 dark:bg-zinc-900">
          <span>明細（{items.length} 項 · {totalQty} 件）</span>
          <div className="flex flex-wrap items-center gap-3 font-mono">
            <span className="text-zinc-500">原價 ${Math.round(grossTotal)}</span>
            {lineDiscountTotal > 0 && (
              <span className="text-zinc-500">− 單品折扣 ${Math.round(lineDiscountTotal)}</span>
            )}
            <span className="text-zinc-500">小計 ${Math.round(subtotal)}</span>
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
                <th className="px-3 py-2 text-right font-medium text-zinc-500">折扣</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">小計</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">備註</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">第一次加</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">最後更新</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {items.length === 0 ? (
                <tr><td colSpan={8} className="p-4 text-center text-zinc-500">尚無明細</td></tr>
              ) : items.map((it) => {
                const eff = itemEffective(it);
                const sub = computeLineSubtotal(Number(eff.qty), eff.unit_price, eff.discount);
                const isDirty = draft.items.has(it.id);
                return (
                  <tr key={it.id} className={isDirty ? "bg-yellow-50 dark:bg-yellow-950/30" : ""}>
                    <td className="px-3 py-2">
                      {it.sku ? (
                        <span>
                          {it.sku.product_name ?? "—"}
                          {it.sku.variant_name && <span className="text-zinc-500"> / {it.sku.variant_name}</span>}
                          <span className="ml-1 font-mono text-zinc-400">{it.sku.sku_code}</span>
                        </span>
                      ) : "—"}
                    </td>
                    <td className="px-3 py-2 text-right font-mono">
                      {canEditQty ? (
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
                      ) : canEdit && head?.status === "confirmed" ? (
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
                        disabled={!canEdit}
                        onSave={async (v) => setItemDraft(it.id, { unit_price: v })}
                      />
                    </td>
                    <td className="px-3 py-2 text-right font-mono">
                      <EditableDiscount
                        value={eff.discount}
                        disabled={!canEdit}
                        onChange={(v) => setItemDraft(it.id, { discount: v })}
                        compact
                        referenceAmount={Number(eff.qty) * Number(eff.unit_price)}
                      />
                    </td>
                    <td className="px-3 py-2 text-right font-mono">${Math.round(sub)}</td>
                    <td className="px-3 py-2">
                      <EditableText
                        value={eff.notes}
                        disabled={!canEdit}
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
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

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
        currentPickupStoreId={head.pickup_store_id}
        currentMemberLabel={memberLabel}
        onSubmitted={(newId) => {
          setTransferOpen(false);
          alert(`訂單已轉出 → 新訂單 #${newId}`);
          setReloadTick((n) => n + 1);
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
      ts: null,
      done: rank >= 5,
      detail: rank >= 5 ? "已完成" : `當前：${statusLabel(head.status)}`,
    };

    if (head.is_air_transfer) {
      // 空中轉：店對店直送
      return [
        sourceStep,
        {
          label: "分店收貨",
          ts: null,
          done: rank >= 4,
          detail: rank >= 4 ? "（分店已可取貨）" : "（空中轉、暫無系統紀錄）",
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

  return [
    { label: "採購到貨", ts: poTs, done: poDone, detail: poDetail || undefined },
    { label: "撿貨完成", ts: waveTs, done: wavePicked, detail: waveDetail || undefined, detailHref: waveHref },
    { label: "派貨出倉", ts: shippedTs, done: xferShipped, detail: xferDetail || undefined, detailHref: xferHref },
    { label: "分店收貨", ts: receivedTs, done: xferReceived, detail: xferDetail || undefined, detailHref: xferHref },
    { label: "顧客取貨", ts: null, done: pickedUp, detail: statusLabel(status) },
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

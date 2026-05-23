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
import { getPickupRecents, recordPickupRecent, type RecentCustomer } from "@/lib/pickupRecents";

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
  last_notify_pickup_at: string | null;
  notify_pickup_count: number;
  pickup_ready?: boolean; // 從 v_order_pickup_ready merge 進來
  campaign: { id: number; campaign_no: string; name: string } | null;
  store: { id: number; name: string } | null;
  items: {
    id: number;
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

// 取貨判斷改用 v_order_pickup_ready (基於分店收貨 transfer 實際狀態)
// 不再依賴 customer_orders.status === 'ready'（status 同步可能漏推）
function isPickable(order: OpenOrder): boolean {
  return order.pickup_ready === true;
}
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
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const autoSearchedRef = useRef(false);

  const [pickup, setPickup] = useState<{ orderId: number; orderNo: string } | null>(null);
  const [returnTarget, setReturnTarget] = useState<{ orderId: number; storeId: number | null } | null>(null);
  const [recents, setRecents] = useState<RecentCustomer[]>([]);
  const [bulking, setBulking] = useState<number | null>(null);
  const [bulkConfirm, setBulkConfirm] = useState<Member | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());

  // overrideQuery：常用顧客快選按鈕用 — 直接帶該顧客查單，
  // 刻意「不」寫進搜尋框（保持輸入框乾淨，按鈕本身就是捷徑）
  async function search(e?: React.FormEvent, overrideQuery?: string) {
    e?.preventDefault();
    const q = (overrideQuery ?? query).trim();
    if (q.length < 2) {
      setError("請至少輸入 2 字 (姓名 / 電話末 N 碼 / 會員編號)");
      return;
    }
    setSearching(true);
    setError(null);
    setMembers(null);
    setOrders(new Map());
    try {
      const sb = getSupabase();
      // Google 式：以空白 / + 拆 token，每個 token 都要在 name / phone / member_no 至少一欄命中
      const safe = q.replace(/[%,()]/g, " ");
      const tokens = safe.split(/[\s+]+/).filter(Boolean);
      let memberQ = sb
        .from("members")
        .select("id, member_no, name, phone, admin_note, no_notify_pickup, no_new_order")
        .neq("status", "deleted")
        .order("last_visit_at", { ascending: false, nullsFirst: false })
        .limit(20);
      for (const tok of tokens) {
        memberQ = memberQ.or(`name.ilike.%${tok}%,phone.ilike.%${tok}%,member_no.ilike.%${tok}%`);
      }
      const { data: ms, error: e1 } = await memberQ;
      if (e1) { setError(e1.message); return; }
      const list = (ms ?? []) as Member[];
      setMembers(list);
      if (list.length === 0) return;

      // 搜尋有結果即記入「常用顧客」（不必等取貨）。
      // ≤5 筆視為「找到特定顧客」才記；>5 視為廣搜（如只打姓氏），不記以免洗版。
      if (list.length <= 5) {
        for (const mem of list) {
          recordPickupRecent({ id: mem.id, name: mem.name, member_no: mem.member_no, phone: mem.phone });
        }
        setRecents(getPickupRecents());
      }

      const { data: ords, error: e2 } = await sb
        .from("customer_orders")
        .select(
          `id, order_no, status, pickup_deadline, pickup_store_id, discount_amount, ready_at, last_notify_pickup_at, notify_pickup_count, member_id,
           campaign:group_buy_campaigns(id, campaign_no, name),
           store:stores!customer_orders_pickup_store_id_fkey(id, name),
           items:customer_order_items(id, qty, unit_price, status, sku:skus(variant_name, product_name, product:products(images)))`,
        )
        .in("member_id", list.map((m) => m.id))
        .in("status", ACTIVE_STATUSES)
        // 到貨時間早 (久) 的排前面（催客人取貨優先）；尚未到貨的擺後面
        .order("ready_at", { ascending: true, nullsFirst: false })
        .order("updated_at", { ascending: false });
      if (e2) { setError(e2.message); return; }

      // 一次撈所有訂單的 pickup_ready
      const orderIds = (ords ?? []).map((o) => o.id);
      const { data: prData } = orderIds.length > 0
        ? await sb.from("v_order_pickup_ready").select("order_id, pickup_ready").in("order_id", orderIds)
        : { data: [] as { order_id: number; pickup_ready: boolean }[] };
      const prMap = new Map<number, boolean>();
      for (const row of (prData as { order_id: number; pickup_ready: boolean }[]) ?? []) {
        prMap.set(row.order_id, row.pickup_ready);
      }

      const m = new Map<number, OpenOrder[]>();
      for (const r of (ords ?? []) as unknown as (OpenOrder & { member_id: number })[]) {
        // merge pickup_ready 進每筆 order
        r.pickup_ready = prMap.get(r.id) ?? false;
        const arr = m.get(r.member_id) ?? [];
        arr.push(r);
        m.set(r.member_id, arr);
      }
      // 依「可取貨」優先 + 到貨時間久的優先（催客人取貨）
      // pickup_ready=true 在前；group 內 ready_at ASC NULLS LAST；末層 updated_at DESC
      for (const arr of m.values()) {
        arr.sort((a, b) => {
          if (a.pickup_ready !== b.pickup_ready) return a.pickup_ready ? -1 : 1;
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

  function toggleSelect(orderId: number) {
    setSelected((s) => {
      const next = new Set(s);
      if (next.has(orderId)) next.delete(orderId); else next.add(orderId);
      return next;
    });
  }

  async function bulkPickAllConfirmed(member: Member) {
    const memberId = member.id;
    const allMemberOrders = (orders.get(memberId) ?? []).filter((o) =>
      isPickable(o) && activeItems(o).length > 0,
    );
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
        const itemIds = activeItems(o).map((it) => it.id);
        const { data, error: e } = await sb.rpc("rpc_record_pickup", {
          p_order_id: o.id,
          p_item_ids: itemIds,
          p_operator: operator,
          p_notes: "一次全取",
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

  // 取消訂單 — 沿用訂單頁完全相同的 rpc_cancel_aid_order 流程：
  // pending/confirmed 直接取消；shipping 撤回派貨並反向回收已出庫存。
  // 取消後 reloadTick++ 重跑搜尋，該單因不在 ACTIVE_STATUSES 而從列表消失。
  async function cancelOrder(order: OpenOrder) {
    const reason = prompt(
      order.status === "shipping"
        ? `撤回派貨：${order.order_no}\n會反向回收已出庫存，請輸入原因：`
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
    if (!order.pickup_ready) {
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
      search();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">取貨</h1>
        <p className="text-sm text-zinc-500">輸入 姓名 / 電話末 N 碼 / 會員編號 → 找出本人未取訂單 → 確認取貨。</p>
      </header>

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
                    {memberOrders.length > 0 && (() => {
                      const pickableOrders = memberOrders.filter((o) => isPickable(o) && activeItems(o).length > 0);
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
                  {memberOrders.length === 0 ? (
                    <p className="text-xs text-zinc-500">無未取訂單。</p>
                  ) : (
                    <ul className="space-y-2">
                      {memberOrders.map((o) => {
                        const canPickup = isPickable(o);
                        const active = activeItems(o);
                        const pickableCount = canPickup ? active.length : 0;
                        const subAmt = active.reduce((s, it) => s + Number(it.qty) * Number(it.unit_price), 0);
                        const discAmt = Number(o.discount_amount ?? 0);
                        const totalAmt = Math.max(0, subAmt - discAmt);
                        return (
                          <li key={o.id} className={`flex items-center gap-3 rounded-md border p-3 ${selected.has(o.id) ? "border-emerald-400 bg-emerald-50 dark:border-emerald-700 dark:bg-emerald-950" : "border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-950"}`}>
                            <input
                              type="checkbox"
                              checked={selected.has(o.id)}
                              onChange={() => toggleSelect(o.id)}
                              disabled={!canPickup || pickableCount === 0}
                              className="h-4 w-4"
                            />
                            <OrderThumb order={o} />
                            <div className="flex-1 text-sm">
                              <div className="flex items-baseline gap-2">
                                <span>{o.campaign?.name ?? "(未知活動)"}</span>
                                {o.status === "partially_completed" && (
                                  <span className="rounded bg-teal-100 px-2 py-0.5 text-[10px] font-medium text-teal-800 dark:bg-teal-950 dark:text-teal-300">
                                    部分已取
                                  </span>
                                )}
                              </div>
                              <ul className="mt-0.5 space-y-0.5 text-xs text-zinc-700 dark:text-zinc-300">
                                {activeItems(o).map((it) => (
                                  <li key={it.id} className="flex items-baseline gap-1.5">
                                    <span className="font-bold">{it.sku?.variant_name || it.sku?.product_name || "—"}</span>
                                    <span className="font-mono text-zinc-500">× {Number(it.qty)}</span>
                                  </li>
                                ))}
                              </ul>
                              <div className="mt-1 text-xs text-zinc-500">
                                取貨店：{o.store?.name ?? "—"}
                                {o.ready_at ? (
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
                                {canPickup ? (
                                  <>
                                    <span className="ml-2">{pickableCount} 項可取</span>
                                    <span className="ml-2 font-mono text-zinc-700 dark:text-zinc-200">${totalAmt}</span>
                                    {discAmt > 0 && (
                                      <span className="ml-1 text-[10px] text-red-600 dark:text-red-400" title={`小計 $${subAmt} − 折扣 $${discAmt}`}>
                                        (含 ${discAmt} 折扣)
                                      </span>
                                    )}
                                  </>
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
                            <SpinButton
                              onClick={() => notifyPickup(m, o)}
                              disabled={!canPickup || notifyingId === o.id || m.no_notify_pickup}
                              title={m.no_notify_pickup ? "此會員已設「不通知」" : !canPickup ? "尚未到貨無法通知" : "通知顧客來取貨（推播 + 站內訊息）"}
                              className="rounded-md border border-blue-300 px-2 py-2 text-xs font-medium text-blue-700 hover:bg-blue-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950"
                            >
                              {notifyingId === o.id ? "⌛" : "🔔 通知"}
                            </SpinButton>
                            <SpinButton
                              onClick={() => setPickup({ orderId: o.id, orderNo: o.order_no })}
                              disabled={!canPickup || pickableCount === 0}
                              className="rounded-md bg-emerald-600 px-3 py-2 text-xs font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
                            >
                              ✅ 取貨
                            </SpinButton>
                            {["ready", "partially_completed"].includes(o.status) && (
                              <SpinButton
                                onClick={() => setReturnTarget({ orderId: o.id, storeId: o.pickup_store_id ?? o.store?.id ?? null })}
                                title="已收貨，無法取消；點此退貨回總倉（反向回收已派庫存）"
                                className="rounded-md border border-orange-300 px-2 py-2 text-xs font-medium text-orange-700 hover:bg-orange-50 dark:border-orange-800 dark:text-orange-300 dark:hover:bg-orange-950"
                              >
                                ↩ 退貨
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

      <Modal
        open={bulkConfirm !== null}
        onClose={() => setBulkConfirm(null)}
        title={bulkConfirm ? `📦 一次全取 — ${bulkConfirm.name ?? "—"} (${bulkConfirm.member_no})` : ""}
        maxWidth="max-w-2xl"
      >
        {bulkConfirm && (() => {
          const allMemberOrders = (orders.get(bulkConfirm.id) ?? []).filter((o) =>
            isPickable(o) && activeItems(o).length > 0,
          );
          const selectedHere = allMemberOrders.filter((o) => selected.has(o.id));
          const memberOrders = selectedHere.length > 0 ? selectedHere : allMemberOrders;
          const totalItems = memberOrders.reduce((s, o) => s + activeItems(o).length, 0);
          const totalSubtotal = memberOrders.reduce(
            (s, o) => s + activeItems(o).reduce((ss, it) => ss + Number(it.qty) * Number(it.unit_price), 0),
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
                  const pickItems = activeItems(o);
                  return (
                    <div key={o.id} className="text-sm">
                      <div className="mb-1">
                        <span>{o.campaign?.name ?? "(未知活動)"}</span>
                        <span className="ml-2 text-[10px] text-zinc-500">取貨店：{o.store?.name ?? "—"}</span>
                      </div>
                      <ul className="ml-4 space-y-0.5 text-xs">
                        {pickItems.map((it) => (
                          <li key={it.id} className="flex items-baseline gap-2">
                            <span className="font-bold">{it.sku?.variant_name || it.sku?.product_name || "—"}</span>
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

function OrderThumb({ order }: { order: OpenOrder }) {
  // 取第一個 active item 的 product 第一張 image
  const firstImg = order.items
    .map((it) => it.sku?.product?.images?.[0])
    .find((u): u is string => typeof u === "string" && !!u);
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

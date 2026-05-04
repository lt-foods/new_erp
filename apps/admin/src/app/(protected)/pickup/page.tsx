"use client";

import { Suspense, useEffect, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { PickupDialog } from "@/components/PickupDialog";
import { withBasePath } from "@/lib/basePath";

type Member = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
};

type OpenOrder = {
  id: number;
  order_no: string;
  status: string;
  pickup_deadline: string | null;
  pickup_store_id: number | null;
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
  const [bulking, setBulking] = useState<number | null>(null);
  const [bulkConfirm, setBulkConfirm] = useState<Member | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());

  async function search(e?: React.FormEvent) {
    e?.preventDefault();
    const q = query.trim();
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
      // 一個關鍵字同時對 name / phone / member_no 做 ilike,任一命中皆列出
      const safe = q.replace(/[%,()]/g, " ");
      const { data: ms, error: e1 } = await sb
        .from("members")
        .select("id, member_no, name, phone")
        .or(`name.ilike.%${safe}%,phone.ilike.%${safe}%,member_no.ilike.%${safe}%`)
        .neq("status", "deleted")
        .order("last_visit_at", { ascending: false, nullsFirst: false })
        .limit(20);
      if (e1) { setError(e1.message); return; }
      const list = (ms ?? []) as Member[];
      setMembers(list);
      if (list.length === 0) return;

      const { data: ords, error: e2 } = await sb
        .from("customer_orders")
        .select(
          `id, order_no, status, pickup_deadline, pickup_store_id, member_id,
           campaign:group_buy_campaigns(id, campaign_no, name),
           store:stores!customer_orders_pickup_store_id_fkey(id, name),
           items:customer_order_items(id, qty, unit_price, status, sku:skus(variant_name, product_name, product:products(images)))`,
        )
        .in("member_id", list.map((m) => m.id))
        .in("status", ACTIVE_STATUSES)
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
        // 自動開列印（一張頁面、多張收據連續分頁）
        window.open(withBasePath(`/pickup/print?event_ids=${eventIds.join(",")}`), "_blank");
      }
      alert(`完成 ${okCount}/${memberOrders.length} 張取貨${errors.length > 0 ? `\n失敗 ${errors.length} 張：\n${errors.join("\n")}` : ""}`);
      setReloadTick((t) => t + 1);
    } finally {
      setBulking(null);
    }
  }

  // 重新跑搜尋（取貨後 reload）
  useEffect(() => {
    if (reloadTick > 0 && members && members.length > 0) {
      search();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reloadTick]);

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
        <button
          type="submit"
          disabled={searching || query.trim().length < 2}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
        >
          {searching ? "搜尋中…" : "🔍 搜尋"}
        </button>
        {(members || error) && (
          <button
            type="button"
            onClick={() => { setQuery(""); setMembers(null); setOrders(new Map()); setError(null); }}
            className="rounded-md border border-zinc-300 px-3 py-2 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            清空
          </button>
        )}
      </form>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{error}</p>
        </div>
      )}

      {members !== null && (
        members.length === 0 ? (
          <p className="rounded-md border border-zinc-200 bg-zinc-50 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            找不到電話含「{suffix}」的會員。
          </p>
        ) : (
          <div className="space-y-3">
            {members.map((m) => {
              const memberOrders = orders.get(m.id) ?? [];
              return (
                <div key={m.id} className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
                  <div className="mb-2 flex items-baseline gap-3">
                    <h2 className="text-base font-semibold">{m.name ?? "—"}</h2>
                    <span className="font-mono text-xs text-zinc-500">{m.member_no}</span>
                    <span className="font-mono text-sm text-zinc-700 dark:text-zinc-300">{m.phone ?? "—"}</span>
                    {memberOrders.length > 0 && (() => {
                      const pickableOrders = memberOrders.filter((o) => isPickable(o) && activeItems(o).length > 0);
                      const selectedHere = pickableOrders.filter((o) => selected.has(o.id));
                      const useSel = selectedHere.length > 0;
                      const count = useSel ? selectedHere.length : pickableOrders.length;
                      if (pickableOrders.length === 0) return null;
                      return (
                        <button
                          onClick={() => setBulkConfirm(m)}
                          disabled={bulking === m.id}
                          className="ml-auto rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-emerald-700 disabled:opacity-50"
                        >
                          {bulking === m.id ? "處理中…" : useSel ? `📦 取選定的 ${count} 張` : `📦 一次全取（${count} 張）`}
                        </button>
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
                        const totalAmt = active.reduce((s, it) => s + Number(it.qty) * Number(it.unit_price), 0);
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
                                <span className="font-mono font-medium">{o.order_no}</span>
                                <span className={`rounded px-2 py-0.5 text-[10px] font-medium ${
                                  o.status === "ready" ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300" :
                                  o.status === "partially_completed" ? "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300" :
                                  o.status === "shipping" ? "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300" :
                                  "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
                                }`}>
                                  {o.status === "shipping" ? "運送中" :
                                   o.status === "ready" ? "可取貨" :
                                   o.status === "partially_completed" ? "部分已取" :
                                   o.status}
                                </span>
                              </div>
                              {o.campaign && (
                                <div className="text-[10px] text-zinc-400">
                                  <span className="font-mono">{o.campaign.campaign_no}</span> {o.campaign.name}
                                </div>
                              )}
                              <div className="mt-1 text-xs text-zinc-500">
                                取貨店：{o.store?.name ?? "—"}
                                {o.pickup_deadline && <span className="ml-2">截止：{o.pickup_deadline}</span>}
                                {canPickup ? (
                                  <>
                                    <span className="ml-2">{pickableCount} 項可取</span>
                                    <span className="ml-2 font-mono text-zinc-700 dark:text-zinc-200">${totalAmt}</span>
                                  </>
                                ) : (
                                  <span className="ml-2 text-amber-600 dark:text-amber-400">⏳ 分店尚未收貨，無法取貨</span>
                                )}
                              </div>
                            </div>
                            <button
                              onClick={() => setPickup({ orderId: o.id, orderNo: o.order_no })}
                              disabled={!canPickup || pickableCount === 0}
                              className="rounded-md bg-emerald-600 px-3 py-2 text-xs font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
                            >
                              ✅ 取貨
                            </button>
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
          const totalAmount = memberOrders.reduce(
            (s, o) => s + activeItems(o).reduce((ss, it) => ss + Number(it.qty) * Number(it.unit_price), 0),
            0,
          );
          return (
            <div className="space-y-3">
              <p className="text-sm text-zinc-600 dark:text-zinc-300">
                即將取走 <b>{memberOrders.length}</b> 張訂單、共 <b>{totalItems}</b> 項商品、合計 <b className="font-mono text-base text-zinc-900 dark:text-zinc-100">${totalAmount}</b>：
              </p>
              <div className="max-h-80 space-y-3 overflow-y-auto rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                {memberOrders.map((o) => {
                  const pickItems = activeItems(o);
                  return (
                    <div key={o.id} className="text-sm">
                      <div className="mb-1">
                        <span className="font-mono font-semibold">{o.order_no}</span>
                        {o.campaign && (
                          <span className="ml-2 text-[10px] text-zinc-400">
                            {o.campaign.campaign_no} {o.campaign.name}
                          </span>
                        )}
                        <span className="ml-2 text-[10px] text-zinc-500">取貨店：{o.store?.name ?? "—"}</span>
                      </div>
                      <ul className="ml-4 space-y-0.5 text-xs">
                        {pickItems.map((it) => (
                          <li key={it.id} className="flex items-baseline gap-2">
                            <span>{it.sku?.variant_name ?? it.sku?.product_name ?? "—"}</span>
                            <span className="font-mono">×{Number(it.qty)}</span>
                          </li>
                        ))}
                      </ul>
                    </div>
                  );
                })}
              </div>
              <div className="flex justify-end gap-2">
                <button
                  onClick={() => setBulkConfirm(null)}
                  className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  取消
                </button>
                <button
                  onClick={() => bulkPickAllConfirmed(bulkConfirm)}
                  className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700"
                >
                  ✅ 確認取貨（{memberOrders.length} 張、{totalItems} 項、${totalAmount}）
                </button>
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

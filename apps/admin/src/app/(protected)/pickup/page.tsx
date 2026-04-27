"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { PickupDialog } from "@/components/PickupDialog";

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
  campaign: { id: number; campaign_no: string; name: string } | null;
  store: { id: number; name: string } | null;
  items: { id: number; qty: number; status: string }[];
};

const ACTIVE_STATUSES = ["pending", "confirmed", "reserved", "ready", "partially_ready", "partially_completed", "shipping"];

export default function PickupPage() {
  const [suffix, setSuffix] = useState("");
  const [searching, setSearching] = useState(false);
  const [members, setMembers] = useState<Member[] | null>(null);
  const [orders, setOrders] = useState<Map<number, OpenOrder[]>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);

  const [pickup, setPickup] = useState<{ orderId: number; orderNo: string } | null>(null);

  async function search(e?: React.FormEvent) {
    e?.preventDefault();
    if (suffix.length < 3) {
      setError("請至少輸入 3 碼（建議後 6 碼）");
      return;
    }
    setSearching(true);
    setError(null);
    setMembers(null);
    setOrders(new Map());
    try {
      const sb = getSupabase();
      const { data: ms, error: e1 } = await sb
        .from("members")
        .select("id, member_no, name, phone")
        .like("phone", `%${suffix}`)
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
           items:customer_order_items(id, qty, status)`,
        )
        .in("member_id", list.map((m) => m.id))
        .in("status", ACTIVE_STATUSES)
        .order("updated_at", { ascending: false });
      if (e2) { setError(e2.message); return; }
      const m = new Map<number, OpenOrder[]>();
      for (const r of (ords ?? []) as unknown as (OpenOrder & { member_id: number })[]) {
        const arr = m.get(r.member_id) ?? [];
        arr.push(r);
        m.set(r.member_id, arr);
      }
      setOrders(m);
    } finally {
      setSearching(false);
    }
  }

  // 重新跑搜尋（取貨後 reload）
  useEffect(() => {
    if (reloadTick > 0 && members && members.length > 0) {
      search();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reloadTick]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">取貨</h1>
        <p className="text-sm text-zinc-500">輸入顧客電話後幾碼（建議 6 碼）→ 找出本人未取訂單 → 確認取貨。</p>
      </header>

      <form onSubmit={search} className="flex items-end gap-2">
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">電話後 N 碼（≥3）</span>
          <input
            type="tel"
            inputMode="numeric"
            pattern="\d*"
            value={suffix}
            onChange={(e) => setSuffix(e.target.value.replace(/\D/g, "").slice(0, 10))}
            autoFocus
            placeholder="123456"
            className="w-40 rounded-md border border-zinc-300 bg-white px-3 py-2 text-lg font-mono dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <button
          type="submit"
          disabled={searching || suffix.length < 3}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
        >
          {searching ? "搜尋中…" : "🔍 搜尋"}
        </button>
        {(members || error) && (
          <button
            type="button"
            onClick={() => { setSuffix(""); setMembers(null); setOrders(new Map()); setError(null); }}
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
                  </div>
                  {memberOrders.length === 0 ? (
                    <p className="text-xs text-zinc-500">無未取訂單。</p>
                  ) : (
                    <ul className="space-y-2">
                      {memberOrders.map((o) => {
                        const pickableCount = o.items.filter((it) => ["pending","reserved","ready"].includes(it.status)).length;
                        return (
                          <li key={o.id} className="flex items-center gap-3 rounded-md border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-950">
                            <div className="flex-1 text-sm">
                              <div className="flex items-baseline gap-2">
                                <span className="font-mono font-medium">{o.order_no}</span>
                                <span className={`rounded px-2 py-0.5 text-[10px] ${o.status === "ready" ? "bg-emerald-100 text-emerald-800" : "bg-zinc-200 text-zinc-700"}`}>
                                  {o.status}
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
                                <span className="ml-2">{pickableCount} 項可取</span>
                              </div>
                            </div>
                            <button
                              onClick={() => setPickup({ orderId: o.id, orderNo: o.order_no })}
                              disabled={pickableCount === 0}
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
    </div>
  );
}

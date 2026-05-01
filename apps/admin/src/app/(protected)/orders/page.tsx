"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { OrderDetail } from "@/components/OrderDetail";
import { PickupDialog } from "@/components/PickupDialog";

type OrderStatus =
  | "pending" | "confirmed" | "reserved" | "shipping" | "ready" | "partially_ready"
  | "partially_completed" | "completed" | "expired" | "cancelled" | "transferred_out";

type Row = {
  id: number;
  order_no: string;
  campaign_id: number;
  member_id: number | null;
  nickname_snapshot: string | null;
  pickup_store_id: number;
  pickup_deadline: string | null;
  status: OrderStatus;
  updated_at: string;
};

type Campaign = { id: number; campaign_no: string; name: string };
type Store = { id: number; code: string; name: string };
type Member = { id: number; name: string | null; phone: string | null; member_no: string };

const STATUS_LABEL: Record<OrderStatus, string> = {
  pending: "待確認", confirmed: "已確認", reserved: "已保留", shipping: "派貨中",
  ready: "可取貨", partially_ready: "部分可取", partially_completed: "部分取貨",
  completed: "已完成", expired: "逾期", cancelled: "已取消",
  transferred_out: "已轉出",
};

const PAGE_SIZE = 50;

export default function OrdersListPage() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [campaignId, setCampaignId] = useState("");
  const [status, setStatus] = useState("");
  const [storeId, setStoreId] = useState("");
  const [page, setPage] = useState(1);

  const [campaigns, setCampaigns] = useState<Campaign[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  const [members, setMembers] = useState<Map<number, Member>>(new Map());
  const [itemSummary, setItemSummary] = useState<
    Map<number, { lineCount: number; totalQty: number; totalAmount: number }>
  >(new Map());
  const [pickupReady, setPickupReady] = useState<Map<number, boolean>>(new Map());
  const [detailId, setDetailId] = useState<number | null>(null);
  const [detailNo, setDetailNo] = useState<string>("");
  const [pickup, setPickup] = useState<{ id: number; no: string } | null>(null);
  const [reloadOrders, setReloadOrders] = useState(0);

  useEffect(() => { setPage(1); }, [campaignId, status, storeId]);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [c, s] = await Promise.all([
        sb.from("group_buy_campaigns").select("id, campaign_no, name").order("updated_at", { ascending: false }).limit(200),
        sb.from("stores").select("id, code, name").order("name"),
      ]);
      setCampaigns((c.data as Campaign[]) ?? []);
      setStores((s.data as Store[]) ?? []);
    })();
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        let q = getSupabase()
          .from("customer_orders")
          .select("id, order_no, campaign_id, member_id, nickname_snapshot, pickup_store_id, pickup_deadline, status, updated_at", { count: "exact" })
          .order("updated_at", { ascending: false })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        if (campaignId) q = q.eq("campaign_id", Number(campaignId));
        if (status) q = q.eq("status", status);
        else q = q.neq("status", "transferred_out"); // 預設隱藏已轉出（5a-1：視同關閉、金額/數量不入統計）
        if (storeId) q = q.eq("pickup_store_id", Number(storeId));

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) { setError(error.message); return; }
        setError(null);
        setRows((data ?? []) as Row[]);
        setTotal(count ?? 0);

        const ids = (data ?? []).map((r) => r.id);
        const memIds = Array.from(new Set((data ?? []).map((r) => r.member_id).filter((x): x is number => x != null)));
        const [ic, ms, pr] = await Promise.all([
          ids.length
            ? getSupabase().from("customer_order_items").select("order_id, qty, unit_price").in("order_id", ids)
            : Promise.resolve({ data: [] as { order_id: number; qty: number; unit_price: number }[] }),
          memIds.length
            ? getSupabase().from("members").select("id, name, phone, member_no").in("id", memIds)
            : Promise.resolve({ data: [] as Member[] }),
          ids.length
            ? getSupabase().from("v_order_pickup_ready").select("order_id, pickup_ready").in("order_id", ids)
            : Promise.resolve({ data: [] as { order_id: number; pickup_ready: boolean }[] }),
        ]);
        const im = new Map<number, { lineCount: number; totalQty: number; totalAmount: number }>();
        for (const id of ids) im.set(id, { lineCount: 0, totalQty: 0, totalAmount: 0 });
        for (const it of (ic.data as { order_id: number; qty: number; unit_price: number }[]) ?? []) {
          const cur = im.get(it.order_id) ?? { lineCount: 0, totalQty: 0, totalAmount: 0 };
          cur.lineCount += 1;
          cur.totalQty += Number(it.qty);
          cur.totalAmount += Number(it.qty) * Number(it.unit_price);
          im.set(it.order_id, cur);
        }
        const mm = new Map<number, Member>();
        for (const m of (ms.data as Member[]) ?? []) mm.set(m.id, m);
        const prMap = new Map<number, boolean>();
        for (const row of (pr.data as { order_id: number; pickup_ready: boolean }[]) ?? []) {
          prMap.set(row.order_id, row.pickup_ready);
        }
        if (!cancelled) { setItemSummary(im); setMembers(mm); setPickupReady(prMap); }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [campaignId, status, storeId, page, reloadOrders]);

  const campaignMap = useMemo(() => new Map(campaigns.map((c) => [c.id, c])), [campaigns]);
  const storeMap = useMemo(() => new Map(stores.map((s) => [s.id, s])), [stores]);
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">訂單</h1>
          <p className="text-sm text-zinc-500">
            {loading ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（${fromIdx}-${toIdx}）`}
          </p>
        </div>
      </header>

      <div className="grid gap-3 sm:grid-cols-3">
        <select value={campaignId} onChange={(e) => setCampaignId(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部開團</option>
          {campaigns.map((c) => <option key={c.id} value={c.id}>{c.campaign_no} {c.name}</option>)}
        </select>
        <select value={status} onChange={(e) => setStatus(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部狀態</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
        <select value={storeId} onChange={(e) => setStoreId(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部取貨店</option>
          {stores.map((s) => <option key={s.id} value={s.id}>{s.name} ({s.code})</option>)}
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p><p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>訂單號</Th><Th>開團</Th><Th>會員 / 暱稱</Th><Th>取貨店</Th><Th>取貨截止</Th><Th>狀態</Th><Th className="text-right">項數</Th><Th className="text-right">總數量</Th><Th className="text-right">總金額</Th><Th className="text-right">更新</Th><Th className="text-right">操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={11} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={11} className="p-6 text-center text-zinc-500">{total === 0 && !campaignId && !status && !storeId ? "尚無訂單。" : "沒有符合條件的訂單。"}</td></tr>
            ) : rows.map((r) => {
              const m = r.member_id ? members.get(r.member_id) : null;
              const c = campaignMap.get(r.campaign_id);
              const s = storeMap.get(r.pickup_store_id);
              return (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="font-mono">
                    <button
                      onClick={() => { setDetailId(r.id); setDetailNo(r.order_no); }}
                      className="hover:underline"
                    >
                      {r.order_no}
                    </button>
                  </Td>
                  <Td>{c ? <span className="text-xs text-zinc-600 dark:text-zinc-400"><span className="font-mono">{c.campaign_no}</span> {c.name}</span> : "—"}</Td>
                  <Td>
                    {m ? (
                      <span>
                        <Link href={`/members/detail?id=${m.id}`} className="hover:underline">{m.name ?? "—"}</Link>
                        <span className="ml-1 font-mono text-xs text-zinc-500">{m.phone}</span>
                      </span>
                    ) : r.nickname_snapshot ? (
                      <span className="text-zinc-500">({r.nickname_snapshot})</span>
                    ) : "—"}
                  </Td>
                  <Td className="text-xs">{s?.name ?? "—"}</Td>
                  <Td className="text-xs">{r.pickup_deadline ?? "—"}</Td>
                  <Td><StatusBadge s={r.status} /></Td>
                  <Td className="text-right font-mono">{itemSummary.get(r.id)?.lineCount ?? 0}</Td>
                  <Td className="text-right font-mono">{itemSummary.get(r.id)?.totalQty ?? 0}</Td>
                  <Td className="text-right font-mono">${itemSummary.get(r.id)?.totalAmount ?? 0}</Td>
                  <Td className="text-right text-xs text-zinc-500">{new Date(r.updated_at).toLocaleString("zh-TW")}</Td>
                  <Td className="text-right">
                    {!["completed","expired","cancelled","transferred_out"].includes(r.status) && (() => {
                      // 取貨判斷改用 v_order_pickup_ready (基於分店收貨 transfer 實際狀態)
                      // 不再依賴 customer_orders.status === 'ready'（status 同步可能漏推）
                      const canPickup = pickupReady.get(r.id) === true;
                      return (
                        <button
                          onClick={() => setPickup({ id: r.id, no: r.order_no })}
                          disabled={!canPickup}
                          title={canPickup ? undefined : "分店尚未收貨，無法取貨"}
                          className="rounded-md bg-emerald-600 px-2 py-1 text-[11px] font-medium text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-200 disabled:text-zinc-400 disabled:hover:bg-zinc-200 dark:disabled:bg-zinc-800 dark:disabled:text-zinc-600 dark:disabled:hover:bg-zinc-800"
                        >
                          ✅ 取貨
                        </button>
                      );
                    })()}
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {pickup && (
        <PickupDialog
          open={true}
          onClose={() => setPickup(null)}
          orderId={pickup.id}
          orderNo={pickup.no}
          onPickedUp={(r) => {
            setPickup(null);
            alert(`取貨完成 (${r.picked_count} 項)\n訂單狀態：${STATUS_LABEL[r.new_order_status as OrderStatus] ?? r.new_order_status}`);
            setReloadOrders((n) => n + 1);
          }}
        />
      )}

      <Modal
        open={detailId !== null}
        onClose={() => setDetailId(null)}
        title={`訂單明細 ${detailNo}`}
        maxWidth="max-w-4xl"
      >
        {detailId !== null && (
          <OrderDetail
            orderId={detailId}
            onNavigate={(id, no) => {
              setDetailId(id);
              setDetailNo(no);
            }}
          />
        )}
      </Modal>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn disabled={page === 1} onClick={() => setPage(1)}>« 第一頁</PagerBtn>
          <PagerBtn disabled={page === 1} onClick={() => setPage((p) => p - 1)}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage((p) => p + 1)}>下頁 ›</PagerBtn>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage(totalPages)}>最末頁 »</PagerBtn>
        </div>
      )}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}
function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return <button onClick={onClick} disabled={disabled} className="rounded-md border border-zinc-300 px-2 py-1 transition-colors hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800">{children}</button>;
}
function StatusBadge({ s }: { s: OrderStatus }) {
  const st: Record<OrderStatus, string> = {
    pending: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
    reserved: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
    shipping: "bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300",
    ready: "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
    partially_ready: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
    partially_completed: "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300",
    completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
    expired: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
    transferred_out: "bg-zinc-300 text-zinc-700 line-through dark:bg-zinc-700 dark:text-zinc-400",
  };
  return <span className={`inline-block rounded px-2 py-0.5 text-xs ${st[s]}`}>{STATUS_LABEL[s]}</span>;
}

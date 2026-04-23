"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type Counts = {
  products: number;
  members: number;
  campaigns: number;
  campaignsOpen: number;
  orders: number;
  suppliers: number;
};

type RecentOrder = {
  id: number;
  order_no: string;
  status: string;
  campaign_id: number;
  pickup_store_id: number;
  member_id: number | null;
  nickname_snapshot: string | null;
  pickup_deadline: string | null;
  updated_at: string;
};

type RecentMember = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  status: string;
  updated_at: string;
};

type Store = { id: number; code: string; name: string };

const STATUS_LABEL_ORDER: Record<string, string> = {
  pending: "待確認", confirmed: "已確認", reserved: "已保留", ready: "可取貨",
  partially_ready: "部分可取", partially_completed: "部分取貨", completed: "已完成",
  expired: "逾期", cancelled: "已取消",
};

export default function Dashboard() {
  const [storeId, setStoreId] = useState<string>("");
  const [stores, setStores] = useState<Store[]>([]);
  const [counts, setCounts] = useState<Counts | null>(null);
  const [recentOrders, setRecentOrders] = useState<RecentOrder[]>([]);
  const [recentMembers, setRecentMembers] = useState<RecentMember[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data } = await getSupabase()
        .from("stores").select("id, code, name").eq("is_active", true).order("name");
      setStores((data as Store[]) ?? []);
    })();
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      try {
        const sid = storeId ? Number(storeId) : null;

        const ordersQ = sb.from("customer_orders").select("id", { count: "exact", head: true });
        const membersQ = sb.from("members").select("id", { count: "exact", head: true }).neq("status", "deleted");
        const recentOrdersQ = sb.from("customer_orders")
          .select("id, order_no, status, campaign_id, pickup_store_id, member_id, nickname_snapshot, pickup_deadline, updated_at")
          .order("updated_at", { ascending: false }).limit(10);
        const recentMembersQ = sb.from("members")
          .select("id, member_no, name, phone, status, updated_at")
          .order("updated_at", { ascending: false }).limit(10);

        if (sid) {
          ordersQ.eq("pickup_store_id", sid);
          membersQ.eq("home_store_id", sid);
          recentOrdersQ.eq("pickup_store_id", sid);
          recentMembersQ.eq("home_store_id", sid);
        }

        const [p, m, c, co, o, s, ro, rm] = await Promise.all([
          sb.from("products").select("id", { count: "exact", head: true }),
          membersQ,
          sb.from("group_buy_campaigns").select("id", { count: "exact", head: true }),
          sb.from("group_buy_campaigns").select("id", { count: "exact", head: true }).eq("status", "open"),
          ordersQ,
          sb.from("suppliers").select("id", { count: "exact", head: true }).eq("is_active", true),
          recentOrdersQ,
          recentMembersQ,
        ]);
        if (cancelled) return;
        if (p.error) throw p.error;
        setCounts({
          products: p.count ?? 0,
          members: m.count ?? 0,
          campaigns: c.count ?? 0,
          campaignsOpen: co.count ?? 0,
          orders: o.count ?? 0,
          suppliers: s.count ?? 0,
        });
        setRecentOrders((ro.data as RecentOrder[]) ?? []);
        setRecentMembers((rm.data as RecentMember[]) ?? []);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [storeId]);

  const today = new Date().toLocaleDateString("zh-TW", { year: "numeric", month: "2-digit", day: "2-digit" });
  const storeMap = new Map(stores.map((s) => [s.id, s]));
  const selectedStore = storeId ? storeMap.get(Number(storeId)) : null;

  return (
    <div className="flex flex-1 flex-col">
      <header className="border-b border-zinc-200 bg-white px-6 py-4 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold">儀表板</h1>
            <p className="text-sm text-zinc-500">
              {today} · {selectedStore ? `門市：${selectedStore.name}` : "全部門市"}
            </p>
          </div>
          <label className="flex items-center gap-2 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">門市</span>
            <select
              value={storeId}
              onChange={(e) => setStoreId(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            >
              <option value="">全部門市</option>
              {stores.map((s) => (
                <option key={s.id} value={s.id}>{s.name} ({s.code})</option>
              ))}
            </select>
          </label>
        </div>
      </header>

      <div className="flex-1 space-y-6 p-6">
        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-6">
          <StatCard href="/orders" label={selectedStore ? "本店訂單" : "全部訂單"} value={counts?.orders} accent="text-blue-600 dark:text-blue-400" />
          <StatCard href="/campaigns" label="進行中開團" value={counts?.campaignsOpen} sub={counts ? `／${counts.campaigns} 總` : undefined} accent="text-emerald-600 dark:text-emerald-400" />
          <StatCard href="/members" label={selectedStore ? "本店會員" : "全部會員"} value={counts?.members} accent="text-amber-600 dark:text-amber-400" />
          <StatCard href="/products" label="商品" value={counts?.products} accent="text-indigo-600 dark:text-indigo-400" />
          <StatCard href="/suppliers" label="供應商（啟用）" value={counts?.suppliers} accent="text-purple-600 dark:text-purple-400" />
          <StatCard href="/campaigns" label="全部開團" value={counts?.campaigns} accent="text-zinc-600 dark:text-zinc-400" />
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <div className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
              <h2 className="text-sm font-semibold">最近訂單 {selectedStore && <span className="font-normal text-zinc-500">/ {selectedStore.name}</span>}</h2>
              <Link href="/orders" className="text-xs text-blue-600 hover:underline dark:text-blue-400">全部 →</Link>
            </div>
            <div className="overflow-x-auto">
              <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                <thead className="bg-zinc-50 dark:bg-zinc-900">
                  <tr>
                    <Th>訂單號</Th><Th>會員</Th><Th>狀態</Th><Th className="text-right">更新</Th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {recentOrders.length === 0 ? (
                    <tr><td colSpan={4} className="p-6 text-center text-zinc-500">尚無訂單</td></tr>
                  ) : recentOrders.map((r) => (
                    <tr key={r.id}>
                      <Td className="font-mono text-xs">{r.order_no}</Td>
                      <Td className="text-xs">{r.nickname_snapshot ?? (r.member_id ? `#${r.member_id}` : "—")}</Td>
                      <Td className="text-xs">{STATUS_LABEL_ORDER[r.status] ?? r.status}</Td>
                      <Td className="text-right text-xs text-zinc-500">{new Date(r.updated_at).toLocaleDateString("zh-TW")}</Td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <div className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
              <h2 className="text-sm font-semibold">最近會員 {selectedStore && <span className="font-normal text-zinc-500">/ {selectedStore.name}</span>}</h2>
              <Link href="/members" className="text-xs text-blue-600 hover:underline dark:text-blue-400">全部 →</Link>
            </div>
            <div className="overflow-x-auto">
              <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                <thead className="bg-zinc-50 dark:bg-zinc-900">
                  <tr>
                    <Th>編號</Th><Th>姓名</Th><Th>手機</Th><Th className="text-right">更新</Th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {recentMembers.length === 0 ? (
                    <tr><td colSpan={4} className="p-6 text-center text-zinc-500">尚無會員</td></tr>
                  ) : recentMembers.map((r) => (
                    <tr key={r.id}>
                      <Td className="font-mono text-xs">
                        <Link href={`/members/detail?id=${r.id}`} className="hover:underline">{r.member_no}</Link>
                      </Td>
                      <Td className="text-xs">{r.name ?? "—"}</Td>
                      <Td className="font-mono text-xs">{r.phone ?? "—"}</Td>
                      <Td className="text-right text-xs text-zinc-500">{new Date(r.updated_at).toLocaleDateString("zh-TW")}</Td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}

function StatCard({
  href, label, value, sub, accent,
}: {
  href: string; label: string; value: number | undefined;
  sub?: string; accent?: string;
}) {
  return (
    <Link
      href={href}
      className="block rounded-md border border-zinc-200 bg-white p-4 transition hover:shadow-sm dark:border-zinc-800 dark:bg-zinc-900"
    >
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-1 text-2xl font-semibold ${accent ?? ""}`}>
        {value ?? "…"}
        {sub && <span className="ml-1 text-sm font-normal text-zinc-500">{sub}</span>}
      </div>
    </Link>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-3 py-2 ${className}`}>{children}</td>;
}

"use client";

import { Suspense, useEffect, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

type Member = {
  id: number;
  member_no: string;
  phone: string | null;
  name: string | null;
  gender: "M" | "F" | "O" | null;
  birthday: string | null;
  email: string | null;
  tier_id: number | null;
  status: string;
  notes: string | null;
  joined_at: string;
  last_visit_at: string | null;
};
type Tier = { id: number; name: string };

type PointsEntry = {
  id: number;
  change: number;
  balance_after: number;
  source_type: string;
  reason: string | null;
  created_at: string;
};

type WalletEntry = {
  id: number;
  change: number;
  balance_after: number;
  type: string;
  payment_method: string | null;
  reason: string | null;
  created_at: string;
};

export default function MemberDetailPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const params = useSearchParams();
  const id = params.get("id");
  const [member, setMember] = useState<Member | null>(null);
  const [tier, setTier] = useState<Tier | null>(null);
  const [points, setPoints] = useState(0);
  const [wallet, setWallet] = useState(0);
  const [pLedger, setPLedger] = useState<PointsEntry[]>([]);
  const [wLedger, setWLedger] = useState<WalletEntry[]>([]);
  const [tab, setTab] = useState<"points" | "wallet">("points");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) { setError("缺少 id 參數"); return; }
    (async () => {
      const sb = getSupabase();
      const mid = Number(id);
      const { data: m, error: err } = await sb
        .from("members")
        .select("id, member_no, phone, name, gender, birthday, email, tier_id, status, notes, joined_at, last_visit_at")
        .eq("id", mid).maybeSingle<Member>();
      if (err) { setError(err.message); return; }
      if (!m) { setError("找不到會員"); return; }
      setMember(m);

      const [tierQ, pb, wb, pl, wl] = await Promise.all([
        m.tier_id ? sb.from("member_tiers").select("id, name").eq("id", m.tier_id).maybeSingle<Tier>() : Promise.resolve({ data: null }),
        sb.from("member_points_balance").select("balance").eq("member_id", mid).maybeSingle<{ balance: number }>(),
        sb.from("wallet_balances").select("balance").eq("member_id", mid).maybeSingle<{ balance: number }>(),
        sb.from("points_ledger").select("id, change, balance_after, source_type, reason, created_at").eq("member_id", mid).order("created_at", { ascending: false }).limit(50),
        sb.from("wallet_ledger").select("id, change, balance_after, type, payment_method, reason, created_at").eq("member_id", mid).order("created_at", { ascending: false }).limit(50),
      ]);
      setTier(tierQ.data as Tier | null);
      setPoints(Number(pb.data?.balance ?? 0));
      setWallet(Number(wb.data?.balance ?? 0));
      setPLedger((pl.data as PointsEntry[]) ?? []);
      setWLedger((wl.data as WalletEntry[]) ?? []);
    })();
  }, [id]);

  if (error) {
    return (
      <div className="mx-auto max-w-4xl p-6">
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      </div>
    );
  }
  if (!member) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  return (
    <div className="mx-auto w-full max-w-4xl space-y-6 p-6">
      <div className="flex items-center justify-between">
        <div>
          <Link href="/members" className="text-sm text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200">← 會員列表</Link>
          <h1 className="mt-1 text-xl font-semibold">
            {member.name ?? "—"} <span className="font-mono text-sm text-zinc-500">#{member.member_no}</span>
          </h1>
        </div>
        <Link
          href={`/members/edit?id=${member.id}`}
          className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          編輯
        </Link>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <Card label="等級">{tier?.name ?? "—"}</Card>
        <Card label="積分餘額"><span className="text-lg font-mono">{points.toLocaleString()}</span></Card>
        <Card label="儲值餘額"><span className="text-lg font-mono">{wallet.toLocaleString()}</span></Card>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <Card label="手機"><span className="font-mono">{member.phone ?? "—"}</span></Card>
        <Card label="Email">{member.email ?? "—"}</Card>
        <Card label="性別">{member.gender === "M" ? "男" : member.gender === "F" ? "女" : member.gender === "O" ? "其他" : "—"}</Card>
        <Card label="生日">{member.birthday ?? "—"}</Card>
        <Card label="加入時間">{new Date(member.joined_at).toLocaleString("zh-TW")}</Card>
        <Card label="最後消費">{member.last_visit_at ? new Date(member.last_visit_at).toLocaleString("zh-TW") : "—"}</Card>
      </div>

      {member.notes && (
        <Card label="備註"><div className="whitespace-pre-wrap text-sm">{member.notes}</div></Card>
      )}

      <div>
        <div className="flex gap-2 border-b border-zinc-200 dark:border-zinc-800">
          <TabBtn active={tab === "points"} onClick={() => setTab("points")}>積分流水 ({pLedger.length})</TabBtn>
          <TabBtn active={tab === "wallet"} onClick={() => setTab("wallet")}>儲值流水 ({wLedger.length})</TabBtn>
        </div>
        <div className="mt-3 overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          {tab === "points" ? (
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <Th>時間</Th><Th>來源</Th><Th className="text-right">變動</Th><Th className="text-right">餘額</Th><Th>備註</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {pLedger.length === 0 ? (
                  <tr><td colSpan={5} className="p-6 text-center text-zinc-500">尚無紀錄</td></tr>
                ) : pLedger.map((e) => (
                  <tr key={e.id}>
                    <Td className="text-xs text-zinc-500">{new Date(e.created_at).toLocaleString("zh-TW")}</Td>
                    <Td>{e.source_type}</Td>
                    <Td className={`text-right font-mono ${Number(e.change) >= 0 ? "text-green-700 dark:text-green-400" : "text-red-700 dark:text-red-400"}`}>
                      {Number(e.change) >= 0 ? "+" : ""}{Number(e.change)}
                    </Td>
                    <Td className="text-right font-mono">{Number(e.balance_after)}</Td>
                    <Td className="text-xs text-zinc-500">{e.reason ?? "—"}</Td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <Th>時間</Th><Th>類型</Th><Th>支付</Th><Th className="text-right">變動</Th><Th className="text-right">餘額</Th><Th>備註</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {wLedger.length === 0 ? (
                  <tr><td colSpan={6} className="p-6 text-center text-zinc-500">尚無紀錄</td></tr>
                ) : wLedger.map((e) => (
                  <tr key={e.id}>
                    <Td className="text-xs text-zinc-500">{new Date(e.created_at).toLocaleString("zh-TW")}</Td>
                    <Td>{e.type}</Td>
                    <Td className="text-xs">{e.payment_method ?? "—"}</Td>
                    <Td className={`text-right font-mono ${Number(e.change) >= 0 ? "text-green-700 dark:text-green-400" : "text-red-700 dark:text-red-400"}`}>
                      {Number(e.change) >= 0 ? "+" : ""}{Number(e.change)}
                    </Td>
                    <Td className="text-right font-mono">{Number(e.balance_after)}</Td>
                    <Td className="text-xs text-zinc-500">{e.reason ?? "—"}</Td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}

function Card({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className="mt-1">{children}</div>
    </div>
  );
}

function TabBtn({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className={
        active
          ? "border-b-2 border-zinc-900 px-3 py-2 text-sm font-medium dark:border-zinc-100"
          : "border-b-2 border-transparent px-3 py-2 text-sm text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
      }
    >
      {children}
    </button>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}

function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}

"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import MemberTabBar from "@/components/MemberTabBar";
import SubTabs from "@/components/SubTabs";
import SettlementCard, { type SettlementRow } from "@/components/SettlementCard";

type Tab = "unpaid" | "shipped";

export default function SettlementsPage() {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("unpaid");
  const [list, setList] = useState<SettlementRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace("/");
      return;
    }
    (async () => {
      setLoading(true);
      setErr(null);
      try {
        const d = await callLiffApi<{ settlements: SettlementRow[] }>(s.token, {
          action: "list_my_settlements",
          tab,
        });
        setList(d.settlements);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [tab, router]);

  return (
    <main className="mx-auto w-full max-w-md">
      <MemberTabBar />
      <SubTabs
        value={tab}
        onChange={(v) => setTab(v as Tab)}
        options={[
          { value: "unpaid",  label: "待付款" },
          { value: "shipped", label: "已寄出" },
        ]}
      />

      <div className="space-y-3 p-4">
        {loading && <p className="text-sm text-zinc-400">載入中…</p>}

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            {err}
          </div>
        )}

        {!loading && !err && list.length === 0 && (
          <p className="py-12 text-center text-sm text-zinc-400">
            目前沒有{tab === "unpaid" ? "待付款" : "已寄出"}結單
          </p>
        )}

        {list.map((s) => (
          <SettlementCard key={s.id} settlement={s} />
        ))}
      </div>
    </main>
  );
}

"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
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
    <PageShell title="我的結單">
      <SubTabs
        value={tab}
        onChange={(v) => setTab(v as Tab)}
        options={[
          { value: "unpaid", label: "待付款" },
          { value: "shipped", label: "已寄出" },
        ]}
      />

      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && (
          <p className="px-1 text-[15px] text-[var(--tertiary-label)]">載入中…</p>
        )}

        {err && (
          <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[14px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && list.length === 0 && (
          <div className="flex flex-col items-center py-20 text-center">
            <div
              className="flex h-24 w-24 items-center justify-center rounded-full text-5xl"
              style={{ background: "linear-gradient(135deg, var(--brand-soft) 0%, #fff4f6 100%)" }}
            >
              🧾
            </div>
            <p className="mt-4 text-[16px] font-semibold text-[var(--foreground)]">
              目前沒有{tab === "unpaid" ? "待付款" : "已寄出"}結單
            </p>
          </div>
        )}

        {list.map((s, i) => (
          <div
            key={s.id}
            className="animate-in"
            style={{ animationDelay: `${Math.min(i, 8) * 50}ms` }}
          >
            <SettlementCard settlement={s} />
          </div>
        ))}
      </div>
    </PageShell>
  );
}

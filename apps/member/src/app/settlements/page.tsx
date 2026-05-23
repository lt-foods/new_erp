"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import Spinner, { LoadingScreen } from "@/components/Spinner";
import SubTabs from "@/components/SubTabs";
import SettlementCard, { type SettlementRow } from "@/components/SettlementCard";

type Tab = "unpaid" | "shipped";
type ListResp = { settlements: SettlementRow[]; has_more: boolean; next_cursor: number | null };

export default function SettlementsPage() {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("unpaid");
  const [list, setList] = useState<SettlementRow[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
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
        const d = await callLiffApi<ListResp>(s.token, {
          action: "list_my_settlements",
          tab,
          limit: 30,
        });
        setList(d.settlements);
        setHasMore(Boolean(d.has_more));
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [tab, router]);

  async function loadMore() {
    if (loadingMore || list.length === 0) return;
    const s = getSession();
    if (!s) return;
    setLoadingMore(true);
    try {
      const beforeId = list[list.length - 1].id;
      const r = await callLiffApi<ListResp>(s.token, {
        action: "list_my_settlements",
        tab,
        limit: 30,
        before_id: beforeId,
      });
      setList((prev) => [...prev, ...r.settlements]);
      setHasMore(Boolean(r.has_more));
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoadingMore(false);
    }
  }

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
        {loading && <LoadingScreen />}

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

        {hasMore && !loading && (
          <button
            onClick={loadMore}
            disabled={loadingMore}
            className="flex w-full items-center justify-center gap-2 rounded-2xl border border-[var(--separator)] bg-[var(--card-bg)] px-4 py-3 text-[15px] text-[var(--brand-strong)] active:bg-[#76768033] disabled:opacity-50"
          >
            {loadingMore ? <Spinner size={18} /> : "載入更多"}
          </button>
        )}
      </div>
    </PageShell>
  );
}

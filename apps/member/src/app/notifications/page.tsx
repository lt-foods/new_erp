"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import Spinner, { LoadingScreen } from "@/components/Spinner";
import NotificationCard, { type NotificationRow } from "@/components/NotificationCard";

type ListResp = { notifications: NotificationRow[]; has_more: boolean; next_cursor: number | null };

export default function NotificationsPage() {
  const router = useRouter();
  const [items, setItems] = useState<NotificationRow[]>([]);
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
          action: "list_my_notifications",
          limit: 30,
        });
        setItems(d.notifications);
        setHasMore(Boolean(d.has_more));
        // 進頁面就把所有未讀標已讀,讓 bar badge 歸零
        await callLiffApi<{ ok: boolean }>(s.token, {
          action: "mark_notification_read",
          mark_all: true,
        });
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  async function loadMore() {
    if (loadingMore || items.length === 0) return;
    const s = getSession();
    if (!s) return;
    setLoadingMore(true);
    try {
      const beforeId = items[items.length - 1].id;
      const r = await callLiffApi<ListResp>(s.token, {
        action: "list_my_notifications",
        limit: 30,
        before_id: beforeId,
      });
      setItems((prev) => [...prev, ...r.notifications]);
      setHasMore(Boolean(r.has_more));
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoadingMore(false);
    }
  }

  return (
    <PageShell title="通知">
      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && <LoadingScreen />}
        {err && (
          <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[14px] text-[#c4271d]">
            {err}
          </div>
        )}
        {!loading && !err && items.length === 0 && (
          <div className="flex flex-col items-center py-20 text-center">
            <div
              className="flex h-24 w-24 items-center justify-center rounded-full text-5xl"
              style={{ background: "linear-gradient(135deg, var(--brand-soft) 0%, #fff4f6 100%)" }}
            >
              📬
            </div>
            <p className="mt-4 text-[16px] font-semibold text-[var(--foreground)]">
              還沒有任何通知
            </p>
          </div>
        )}
        {items.map((n, i) => (
          <div
            key={n.id}
            className="animate-in"
            style={{ animationDelay: `${Math.min(i, 8) * 50}ms` }}
          >
            <NotificationCard n={n} />
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

"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import NotificationCard, { type NotificationRow } from "@/components/NotificationCard";

export default function NotificationsPage() {
  const router = useRouter();
  const [items, setItems] = useState<NotificationRow[]>([]);
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
        const d = await callLiffApi<{ notifications: NotificationRow[] }>(s.token, {
          action: "list_my_notifications",
        });
        setItems(d.notifications);
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

  return (
    <PageShell title="通知">
      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && (
          <p className="px-1 text-[15px] text-[var(--tertiary-label)]">載入中…</p>
        )}
        {err && (
          <div className="rounded-2xl bg-[#ff3b30]/10 p-3 text-[14px] text-[#c4271d]">
            {err}
          </div>
        )}
        {!loading && !err && items.length === 0 && (
          <div className="py-16 text-center">
            <div className="text-3xl">📬</div>
            <p className="mt-2 text-[15px] text-[var(--tertiary-label)]">還沒有任何通知</p>
          </div>
        )}
        {items.map((n) => (
          <NotificationCard key={n.id} n={n} />
        ))}
      </div>
    </PageShell>
  );
}

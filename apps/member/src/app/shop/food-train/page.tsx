"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import { LoadingScreen } from "@/components/Spinner";
import CampaignCard, { type CampaignSummary } from "@/components/CampaignCard";

export default function FoodTrainPage() {
  const router = useRouter();
  const [campaigns, setCampaigns] = useState<CampaignSummary[]>([]);
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
      try {
        const d = await callLiffApi<{ campaigns: CampaignSummary[] }>(s.token, {
          action: "list_active_campaigns",
          category: "food_train",
        });
        setCampaigns(d.campaigns);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  // 前端防線：擋掉內部 sentinel 活動，與 /shop 一致
  const visible = campaigns.filter((c) => !c.campaign_no.startsWith("__"));
  const hero = visible[0];

  return (
    <PageShell title="美食列車">
      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && <LoadingScreen />}

        {err && (
          <div className="rounded-2xl bg-[#ff3b30]/10 p-3 text-[15px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && visible.length === 0 && (
          <div className="overflow-hidden rounded-2xl bg-gradient-to-br from-emerald-500/10 to-teal-500/10 p-6 text-center">
            <div className="text-5xl">🚂</div>
            <h2 className="mt-3 text-[18px] font-semibold text-[var(--foreground)]">
              目前沒有美食列車
            </h2>
            <p className="mt-2 whitespace-pre-line text-[15px] leading-relaxed text-[var(--secondary-label)]">
              店長正在挑下一波美食中{"\n"}新團上架會即時通知你
            </p>
            <a
              href="/shop"
              className="mt-5 inline-block rounded-full bg-emerald-600 px-5 py-2 text-[15px] font-medium text-white active:opacity-80"
            >
              先看看其他商品 →
            </a>
          </div>
        )}

        {hero && <CampaignCard campaign={hero} variant="hero" />}

        {visible.slice(1).length > 0 && (
          <div className="grid grid-cols-2 gap-3 pt-1">
            {visible.slice(1).map((c) => (
              <CampaignCard key={c.id} campaign={c} />
            ))}
          </div>
        )}
      </div>
    </PageShell>
  );
}

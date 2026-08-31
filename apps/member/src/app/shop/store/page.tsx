"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession, loginPath } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import { LoadingScreen } from "@/components/Spinner";
import CampaignCard, { isStoreCampaign, type CampaignSummary } from "@/components/CampaignCard";
import { setCampaignHints } from "@/lib/campaignHints";

/**
 * 門市限定專區 —— 你的取貨門市自己開的團。
 *
 * 沒有像 /shop/flash 那樣用 close_type 過濾：門市自開團的判準是
 * owner_store_id（誰開的），不是收單方式，所以拉全清單再在前端挑。
 * 安全性不靠這層 —— liff-api 的 list_active_campaigns 本來就只會回
 * 「總倉團 + 這位會員自己門市的團」，別店的團根本不在 response 裡。
 */
export default function StoreCampaignPage() {
  const router = useRouter();
  const [campaigns, setCampaigns] = useState<CampaignSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace(loginPath());
      return;
    }
    (async () => {
      try {
        const d = await callLiffApi<{ campaigns: CampaignSummary[] }>(s.token, {
          action: "list_active_campaigns",
        });
        setCampaigns(d.campaigns);
        setCampaignHints(d.campaigns);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  // 前端防線：擋掉內部 sentinel 活動（__INTERNAL_RESTOCK__ 等），與 /shop 一致
  const visible = campaigns.filter(
    (c) => !c.campaign_no.startsWith("__") && isStoreCampaign(c),
  );
  const hero = visible[0];

  return (
    <PageShell title="門市限定">
      <div className="space-y-3 px-4 pt-3 pb-6">
        {loading && <LoadingScreen />}

        {err && (
          <div className="rounded-2xl bg-[#ff3b30]/10 p-3 text-[15px] text-[#c4271d]">
            {err}
          </div>
        )}

        {!loading && !err && visible.length === 0 && (
          <div className="overflow-hidden rounded-2xl bg-gradient-to-br from-indigo-500/8 to-violet-500/8 p-6 text-center">
            <div className="text-5xl">🏪</div>
            <h2 className="mt-3 text-[18px] font-semibold text-[var(--foreground)]">
              門市目前沒有自己開的團
            </h2>
            <p className="mt-2 whitespace-pre-line text-[15px] leading-relaxed text-[var(--secondary-label)]">
              這裡只會出現你取貨門市自己開的團{"\n"}一上架就會出現在商品頁最上面
            </p>
            <a
              href="/shop"
              className="mt-5 inline-block rounded-full bg-[var(--brand-strong)] px-5 py-2 text-[15px] font-medium text-white active:opacity-80"
            >
              先看看其他商品 →
            </a>
          </div>
        )}

        {!loading && !err && visible.length > 0 && (
          <p className="px-1 text-[14px] text-[var(--secondary-label)]">
            這些團由你的取貨門市自己開、自己備貨，只有本店會員看得到。
          </p>
        )}

        {hero && <CampaignCard campaign={hero} variant="hero" />}

        {visible.length > 1 && (
          <div className="grid grid-cols-2 gap-3">
            {visible.slice(1).map((c) => (
              <CampaignCard key={c.id} campaign={c} />
            ))}
          </div>
        )}
      </div>
    </PageShell>
  );
}

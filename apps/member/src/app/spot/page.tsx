"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import PullToRefresh from "@/components/PullToRefresh";
import { LoadingScreen } from "@/components/Spinner";
import SubTabs from "@/components/SubTabs";
import SpotProductCard, { type SpotProduct } from "@/components/SpotProductCard";

type Resp = {
  items: SpotProduct[];
  my_store_id: number;
  my_store_name: string | null;
};

/**
 * 現貨專區（底部 tab bar 正中間的一級入口）。
 *
 * 資料來源是互助交流板的「我有庫存可提供」貼文（post_type='offer'）——
 * 店家把手上多的現貨釋出，這裡就看得到。金額只在「自己所在店家」釋出時顯示，
 * 跨店的金額後端不回（見 liff-api listSpotProducts）。
 */
export default function SpotPage() {
  const router = useRouter();
  const [items, setItems] = useState<SpotProduct[]>([]);
  const [myStoreName, setMyStoreName] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  // 預設停在自己的店 —— 那些才看得到金額、才真的拿得到貨；
  // 想看別店的再自己切到「全部」。
  const [tab, setTab] = useState<"all" | "mine">("mine");

  const load = async () => {
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace("/");
      return;
    }
    try {
      const d = await callLiffApi<Resp>(s.token, { action: "list_spot_products" });
      setItems(d.items ?? []);
      setMyStoreName(d.my_store_name ?? null);
      setErr(null);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  };

  useEffect(() => {
    consumeFragmentToSession();
    (async () => {
      await load();
      setLoading(false);
    })();
    // load 只讀 localStorage 取 session，掛載時跑一次就夠
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [router]);

  const mine = items.filter((i) => i.is_my_store);
  const visible = tab === "mine" ? mine : items;

  return (
    <PageShell title="現貨專區">
      <PullToRefresh onRefresh={load}>
        <SubTabs
          value={tab}
          onChange={(v) => setTab(v as "all" | "mine")}
          // 本店排左邊、也是預設選中的那格 —— 主要動線放前面，「全部」是次要
          options={[
            { value: "mine", label: myStoreName ?? "我的店", count: mine.length },
            { value: "all", label: "全部", count: items.length },
          ]}
        />

        <div className="space-y-3 px-4 pt-3 pb-6">
          {loading && <LoadingScreen />}

          {err && (
            <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[15px] text-[#c4271d]">
              {err}
            </div>
          )}

          {!loading && !err && visible.length === 0 && (
            <div className="flex flex-col items-center py-16 text-center">
              {/* 用品牌色線稿箱子，不用 📦 emoji —— emoji 的咖啡色在粉色底上
                  很跳，而且和卡片沒有圖時的 CoverFallback 是同一支圖示語言。 */}
              <div
                className="flex h-24 w-24 items-center justify-center rounded-full"
                style={{
                  background:
                    "linear-gradient(135deg, var(--brand-soft) 0%, #fff4f6 100%)",
                }}
              >
                <svg
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="var(--brand)"
                  strokeWidth={1.3}
                  className="h-12 w-12 opacity-80"
                  aria-hidden
                >
                  <path strokeLinecap="round" strokeLinejoin="round" d="M3 8.5 12 4l9 4.5v7L12 20l-9-4.5v-7Z" />
                  <path strokeLinecap="round" strokeLinejoin="round" d="m3 8.5 9 4.5 9-4.5M12 13v7" />
                </svg>
              </div>
              <p className="mt-4 text-[17px] font-semibold text-[var(--foreground)]">
                {tab === "mine" ? "你的店目前沒有現貨" : "目前沒有店家釋出現貨"}
              </p>
              <p className="mt-1 text-[14px] text-[var(--secondary-label)]">
                下拉重新整理，有店家釋出就會出現在這裡
              </p>
              {/* 預設就停在「我的店」，本店沒貨時別讓人卡在空畫面
                  —— 其他分店有貨就給一條路過去 */}
              {tab === "mine" && items.length > 0 && (
                <button
                  type="button"
                  onClick={() => setTab("all")}
                  className="mt-4 rounded-full bg-[var(--brand-soft)] px-4 py-2 text-[14px] font-semibold text-[var(--brand-strong)] active:scale-95"
                >
                  看看其他分店的現貨（{items.length}）
                </button>
              )}
            </div>
          )}

          {visible.length > 0 && (
            <div className="grid grid-cols-2 gap-3">
              {visible.map((item) => (
                <SpotProductCard key={item.id} item={item} />
              ))}
            </div>
          )}
        </div>
      </PullToRefresh>
    </PageShell>
  );
}

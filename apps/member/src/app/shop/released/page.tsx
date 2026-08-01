"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import PullToRefresh from "@/components/PullToRefresh";
import { LoadingScreen } from "@/components/Spinner";
import SubTabs from "@/components/SubTabs";
import ReleasedProductCard, {
  type ReleasedProduct,
} from "@/components/ReleasedProductCard";

type Resp = {
  items: ReleasedProduct[];
  my_store_id: number;
  my_store_name: string | null;
};

/**
 * 店家釋出商品專區。
 *
 * 資料來源是互助交流板的「我有庫存可提供」貼文（post_type='offer'）——
 * 店家把手上多的貨釋出，這裡就看得到。金額只在「自己所在店家」釋出時顯示，
 * 跨店的金額後端不回（見 liff-api listReleasedProducts）。
 */
export default function ReleasedProductsPage() {
  const router = useRouter();
  const [items, setItems] = useState<ReleasedProduct[]>([]);
  const [myStoreName, setMyStoreName] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [tab, setTab] = useState<"all" | "mine">("all");

  const load = async () => {
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace("/");
      return;
    }
    try {
      const d = await callLiffApi<Resp>(s.token, { action: "list_released_products" });
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
    // load 只依賴 router（getSession 是讀 localStorage），掛載時跑一次就夠
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [router]);

  const mine = items.filter((i) => i.is_my_store);
  const visible = tab === "mine" ? mine : items;

  return (
    <PageShell title="店家釋出">
      <PullToRefresh onRefresh={load}>
        <SubTabs
          value={tab}
          onChange={(v) => setTab(v as "all" | "mine")}
          options={[
            { value: "all", label: "全部", count: items.length },
            { value: "mine", label: myStoreName ?? "我的店", count: mine.length },
          ]}
        />

        <div className="space-y-3 px-4 pt-3 pb-6">
          <p className="text-[13px] leading-relaxed text-[var(--secondary-label)]">
            分店手上多出來的現貨會釋出在這裡。
            {myStoreName ? `${myStoreName}` : "你所在店家"}釋出的才看得到金額，
            其他分店的商品金額不顯示。
          </p>

          {loading && <LoadingScreen />}

          {err && (
            <div className="rounded-2xl bg-[var(--ios-red)]/10 p-3 text-[15px] text-[#c4271d]">
              {err}
            </div>
          )}

          {!loading && !err && visible.length === 0 && (
            <div className="flex flex-col items-center py-16 text-center">
              <div
                className="flex h-24 w-24 items-center justify-center rounded-full text-5xl"
                style={{
                  background:
                    "linear-gradient(135deg, var(--brand-soft) 0%, #fff4f6 100%)",
                }}
              >
                📦
              </div>
              <p className="mt-4 text-[17px] font-semibold text-[var(--foreground)]">
                {tab === "mine" ? "你的店目前沒有釋出商品" : "目前沒有店家釋出商品"}
              </p>
              <p className="mt-1 text-[14px] text-[var(--secondary-label)]">
                下拉重新整理，有店家釋出就會出現在這裡
              </p>
            </div>
          )}

          {visible.length > 0 && (
            <div className="grid grid-cols-2 gap-3">
              {visible.map((item) => (
                <ReleasedProductCard key={item.id} item={item} />
              ))}
            </div>
          )}
        </div>
      </PullToRefresh>
    </PageShell>
  );
}

"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { PrPipelineStepper } from "@/components/PrPipelineStepper";

type CloseDateGroup = {
  close_date: string;
  campaigns: { id: number; name: string }[];
  total_skus: number;
  total_qty: number;
  existing_pr_id: number | null;
  existing_pr_no: string | null;
  existing_pr_status: string | null;
  existing_review_status: string | null;
};

const STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  submitted: "已送審",
  partially_ordered: "部分轉單",
  fully_ordered: "全部轉單",
  cancelled: "已取消",
};

export default function NewPurchaseRequestPage() {
  const router = useRouter();
  const [groups, setGroups] = useState<CloseDateGroup[] | null>(null);
  const [busyDate, setBusyDate] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const supabase = getSupabase();
        const since = new Date();
        since.setDate(since.getDate() - 60);

        // 撈最近 60 天 closed campaigns
        const { data: camps, error: cErr } = await supabase
          .from("group_buy_campaigns")
          .select("id, name, end_at")
          .eq("status", "closed")
          .gte("end_at", since.toISOString())
          .order("end_at", { ascending: false });
        if (cErr) throw new Error(cErr.message);

        // 撈既有 close_date PRs（避免重複開）
        const { data: existingPrs } = await supabase
          .from("purchase_requests")
          .select("id, pr_no, source_close_date, status, review_status")
          .eq("source_type", "close_date")
          .neq("status", "cancelled");

        const prByDate = new Map<
          string,
          { id: number; pr_no: string; status: string; review_status: string }
        >();
        for (const p of existingPrs ?? []) {
          if (!p.source_close_date) continue;
          prByDate.set(p.source_close_date, {
            id: p.id,
            pr_no: p.pr_no,
            status: p.status,
            review_status: p.review_status,
          });
        }

        // 依 close_date 分組 campaigns
        const byDate = new Map<string, { id: number; name: string }[]>();
        for (const c of camps ?? []) {
          if (!c.end_at) continue;
          const d = new Date(c.end_at).toLocaleDateString("sv-SE");
          if (!byDate.has(d)) byDate.set(d, []);
          byDate.get(d)!.push({ id: c.id, name: c.name });
        }

        // 撈各 campaign 的需求總量
        const campaignIds = (camps ?? []).map((c) => c.id);
        const demandByCampaign = new Map<number, { skus: Set<number>; qty: number }>();
        if (campaignIds.length) {
          const { data: items } = await supabase
            .from("customer_order_items")
            .select("sku_id, qty, customer_orders!inner(campaign_id, status)")
            .in("customer_orders.campaign_id", campaignIds);
          type ItemAgg = {
            sku_id: number;
            qty: number;
            customer_orders: { campaign_id: number; status: string }[] | { campaign_id: number; status: string };
          };
          for (const it of (items as ItemAgg[] | null) ?? []) {
            const ord = Array.isArray(it.customer_orders) ? it.customer_orders[0] : it.customer_orders;
            if (!ord || ["cancelled", "expired"].includes(ord.status)) continue;
            const cid = ord.campaign_id;
            if (!demandByCampaign.has(cid)) demandByCampaign.set(cid, { skus: new Set(), qty: 0 });
            const e = demandByCampaign.get(cid)!;
            e.skus.add(it.sku_id);
            e.qty += Number(it.qty);
          }
        }

        const result: CloseDateGroup[] = Array.from(byDate.entries())
          .map(([close_date, list]) => {
            const skus = new Set<number>();
            let qty = 0;
            for (const c of list) {
              const d = demandByCampaign.get(c.id);
              if (d) {
                for (const s of d.skus) skus.add(s);
                qty += d.qty;
              }
            }
            const ex = prByDate.get(close_date);
            return {
              close_date,
              campaigns: list,
              total_skus: skus.size,
              total_qty: qty,
              existing_pr_id: ex?.id ?? null,
              existing_pr_no: ex?.pr_no ?? null,
              existing_pr_status: ex?.status ?? null,
              existing_review_status: ex?.review_status ?? null,
            };
          })
          .sort((a, b) => b.close_date.localeCompare(a.close_date));

        if (!cancelled) setGroups(result);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleImport(closeDate: string) {
    setBusyDate(closeDate);
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const opUid = userData.user?.id;
      if (!opUid) throw new Error("未登入");

      const { data: prId, error: rpcErr } = await supabase.rpc("rpc_create_pr_from_close_date", {
        p_close_date: closeDate,
        p_operator: opUid,
      });
      if (rpcErr) throw new Error(rpcErr.message);

      router.push(`/purchase/requests/edit?id=${prId}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyDate(null);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">新增採購單</h1>
        <p className="text-sm text-zinc-500">
          每個結單日一張採購單。點選下方卡片產生該日採購單。
        </p>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {groups === null && (
        <div className="text-sm text-zinc-500">載入中…</div>
      )}

      {groups !== null && groups.length === 0 && (
        <div className="rounded-md border border-zinc-200 bg-zinc-50 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          近 60 天無已結單活動。請先到「開團」頁結單後回來。
        </div>
      )}

      {groups !== null && groups.length > 0 && (
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {groups.map((g) => {
            const opened = g.existing_pr_id !== null;
            return (
              <div
                key={g.close_date}
                className={`rounded-md border p-4 ${
                  opened
                    ? "border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900"
                    : "border-emerald-200 bg-white shadow-sm dark:border-emerald-900 dark:bg-zinc-900"
                }`}
              >
                <div className="mb-2 flex items-baseline justify-between">
                  <div className="text-base font-semibold">{g.close_date}</div>
                  {opened && (
                    <span className="rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                      已開單
                    </span>
                  )}
                </div>

                <div className="mb-3 text-xs text-zinc-500">
                  {g.campaigns.length} 個團 · {g.total_skus} 個 SKU · 總量 {g.total_qty}
                </div>

                <ul className="mb-3 max-h-20 space-y-0.5 overflow-y-auto text-xs">
                  {g.campaigns.slice(0, 4).map((c) => (
                    <li key={c.id} className="truncate text-zinc-600 dark:text-zinc-400">
                      · {c.name}
                    </li>
                  ))}
                  {g.campaigns.length > 4 && (
                    <li className="text-zinc-400">…還有 {g.campaigns.length - 4} 個</li>
                  )}
                </ul>

                {/* Pipeline mini-stepper（已開單才顯示）*/}
                {opened && (
                  <div className="mb-3 rounded-md border border-zinc-200 bg-white p-2 dark:border-zinc-700 dark:bg-zinc-950">
                    <PrPipelineStepper
                      status={g.existing_pr_status ?? ""}
                      reviewStatus={g.existing_review_status ?? ""}
                      compact
                    />
                  </div>
                )}

                {opened ? (
                  <div className="flex flex-col gap-1">
                    <a
                      href={`/purchase/requests/edit?id=${g.existing_pr_id}`}
                      className="block rounded-md border border-zinc-300 px-3 py-2 text-center text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      查看 {g.existing_pr_no}（{STATUS_LABEL[g.existing_pr_status ?? ""] ?? g.existing_pr_status}）
                    </a>
                  </div>
                ) : g.total_qty === 0 ? (
                  <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-center text-xs text-zinc-500 dark:border-zinc-700 dark:bg-zinc-800">
                    無顧客訂單，無法開單
                  </div>
                ) : (
                  <button
                    onClick={() => handleImport(g.close_date)}
                    disabled={busyDate !== null}
                    className="w-full rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500 disabled:opacity-50"
                  >
                    {busyDate === g.close_date ? "建立中…" : "📋 帶入該日商品"}
                  </button>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

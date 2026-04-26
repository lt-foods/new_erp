"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { PrPipelineStepper } from "@/components/PrPipelineStepper";

type Row = {
  id: number;
  pr_no: string;
  source_type: string;
  source_close_date: string | null;
  status: string;
  review_status: string;
  total_amount: number;
  notes: string | null;
  updated_at: string;
};

type CloseDateGroup = {
  close_date: string;
  campaigns: { id: number; name: string }[];
  total_skus: number;
  total_qty: number;
};

const STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  submitted: "已送審",
  partially_ordered: "部分轉單",
  fully_ordered: "全部轉單",
  cancelled: "已取消",
};

const REVIEW_LABEL: Record<string, string> = {
  approved: "已通過",
  pending_review: "待審核",
  rejected: "已退回",
};

const SOURCE_LABEL: Record<string, string> = {
  close_date: "結單日帶入",
  campaign: "單一團購",
  manual: "手動",
};

type ClosedCampaignRow = {
  id: number;
  name: string;
  close_date: string;
  existing_pr_id: number | null;
  same_close_date_has_pr: boolean;
};

export default function PurchaseRequestsListPage() {
  const router = useRouter();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [pendingDates, setPendingDates] = useState<CloseDateGroup[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<string>("");
  const [reviewFilter, setReviewFilter] = useState<string>("");
  const [reloadTick, setReloadTick] = useState(0);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [busyDate, setBusyDate] = useState<string | null>(null);
  const [creatingBlank, setCreatingBlank] = useState(false);
  const [showCampaignModal, setShowCampaignModal] = useState(false);
  const [closedCampaigns, setClosedCampaigns] = useState<ClosedCampaignRow[] | null>(null);
  const [creatingFromCampaignId, setCreatingFromCampaignId] = useState<number | null>(null);
  const [progressById, setProgressById] = useState<
    Map<number, {
      po_total: number; po_sent: number; po_received_fully: number;
      transfer_total: number; transfer_shipped: number; transfer_delivered: number;
      item_count: number; unassigned_supplier_count: number;
      all_campaigns_finalized: boolean;
    }>
  >(new Map());

  // ============== 載入既有 PRs ==============
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        let q = getSupabase()
          .from("purchase_requests")
          .select(
            "id, pr_no, source_type, source_close_date, status, review_status, total_amount, notes, updated_at",
          )
          .order("updated_at", { ascending: false })
          .limit(200);
        if (statusFilter) q = q.eq("status", statusFilter);
        if (reviewFilter) q = q.eq("review_status", reviewFilter);
        const { data, error: err } = await q;
        if (cancelled) return;
        if (err) {
          setError(err.message);
          return;
        }
        setError(null);
        const prRows = (data ?? []) as Row[];
        setRows(prRows);

        const ids = prRows.map((r) => r.id);
        if (ids.length) {
          const { data: prog } = await getSupabase()
            .from("v_pr_progress")
            .select("pr_id, po_total, po_sent, po_received_fully, transfer_total, transfer_shipped, transfer_delivered, item_count, unassigned_supplier_count, all_campaigns_finalized")
            .in("pr_id", ids);
          if (!cancelled) {
            const m = new Map<
              number,
              {
                po_total: number; po_sent: number; po_received_fully: number;
                transfer_total: number; transfer_shipped: number; transfer_delivered: number;
                item_count: number; unassigned_supplier_count: number;
                all_campaigns_finalized: boolean;
              }
            >();
            type ProgRow = {
              pr_id: number;
              po_total: number;
              po_sent: number;
              po_received_fully: number;
              transfer_total: number;
              transfer_shipped: number;
              transfer_delivered: number;
              item_count: number;
              unassigned_supplier_count: number;
              all_campaigns_finalized: boolean;
            };
            for (const p of (prog as ProgRow[] | null) ?? []) {
              m.set(p.pr_id, {
                po_total: Number(p.po_total),
                po_sent: Number(p.po_sent),
                po_received_fully: Number(p.po_received_fully),
                transfer_total: Number(p.transfer_total),
                transfer_shipped: Number(p.transfer_shipped),
                transfer_delivered: Number(p.transfer_delivered),
                item_count: Number(p.item_count),
                unassigned_supplier_count: Number(p.unassigned_supplier_count),
                all_campaigns_finalized: !!p.all_campaigns_finalized,
              });
            }
            setProgressById(m);
          }
        } else {
          setProgressById(new Map());
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [statusFilter, reviewFilter, reloadTick]);

  // ============== 載入「結單日待開單」cards ==============
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const supabase = getSupabase();
        const since = new Date();
        since.setDate(since.getDate() - 60);

        const { data: camps } = await supabase
          .from("group_buy_campaigns")
          .select("id, name, end_at")
          .eq("status", "closed")
          .gte("end_at", since.toISOString())
          .order("end_at", { ascending: false });

        const { data: existingPrs } = await supabase
          .from("purchase_requests")
          .select("source_close_date")
          .eq("source_type", "close_date")
          .neq("status", "cancelled");
        const datesWithPR = new Set(
          (existingPrs ?? []).map((p) => p.source_close_date as string).filter(Boolean),
        );

        // 依 close_date 分組 campaigns（只列尚未開單的日期）
        const byDate = new Map<string, { id: number; name: string }[]>();
        for (const c of camps ?? []) {
          if (!c.end_at) continue;
          const d = new Date(c.end_at).toLocaleDateString("sv-SE");
          if (datesWithPR.has(d)) continue;
          if (!byDate.has(d)) byDate.set(d, []);
          byDate.get(d)!.push({ id: c.id, name: c.name });
        }

        // 撈各 campaign 的需求總量
        const campaignIds = Array.from(byDate.values()).flat().map((c) => c.id);
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
            return { close_date, campaigns: list, total_skus: skus.size, total_qty: qty };
          })
          .filter((g) => g.total_qty > 0) // 0 量的不顯示
          .sort((a, b) => b.close_date.localeCompare(a.close_date));

        if (!cancelled) setPendingDates(result);
      } catch {
        if (!cancelled) setPendingDates([]);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick]);

  async function handleImport(closeDate: string) {
    setBusyDate(closeDate);
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: prId, error: rpcErr } = await supabase.rpc("rpc_create_pr_from_close_date", {
        p_close_date: closeDate,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      router.push(`/purchase/requests/edit?id=${prId}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyDate(null);
    }
  }

  async function handleCreateBlank() {
    setCreatingBlank(true);
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: prId, error: rpcErr } = await supabase.rpc("rpc_create_pr_blank", {
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      router.push(`/purchase/requests/edit?id=${prId}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setCreatingBlank(false);
    }
  }

  async function openCampaignModal() {
    setShowCampaignModal(true);
    setError(null);
    if (closedCampaigns !== null) return;
    try {
      const supabase = getSupabase();
      const since = new Date();
      since.setDate(since.getDate() - 60);
      const { data: camps } = await supabase
        .from("group_buy_campaigns")
        .select("id, name, end_at")
        .eq("status", "closed")
        .gte("end_at", since.toISOString())
        .order("end_at", { ascending: false });

      const { data: existingCampaignPRs } = await supabase
        .from("purchase_requests")
        .select("id, source_campaign_id")
        .eq("source_type", "campaign")
        .neq("status", "cancelled");
      const prByCamp = new Map<number, number>(
        ((existingCampaignPRs as { id: number; source_campaign_id: number | null }[] | null) ?? [])
          .filter((p) => p.source_campaign_id !== null)
          .map((p) => [p.source_campaign_id as number, p.id]),
      );

      const { data: existingCloseDatePRs } = await supabase
        .from("purchase_requests")
        .select("source_close_date")
        .eq("source_type", "close_date")
        .neq("status", "cancelled");
      const closeDateSet = new Set(
        ((existingCloseDatePRs as { source_close_date: string | null }[] | null) ?? [])
          .map((p) => p.source_close_date)
          .filter((d): d is string => !!d),
      );

      const result: ClosedCampaignRow[] = ((camps as { id: number; name: string; end_at: string | null }[] | null) ?? [])
        .filter((c) => !!c.end_at)
        .map((c) => {
          const closeDate = new Date(c.end_at as string).toLocaleDateString("sv-SE");
          return {
            id: c.id,
            name: c.name,
            close_date: closeDate,
            existing_pr_id: prByCamp.get(c.id) ?? null,
            same_close_date_has_pr: closeDateSet.has(closeDate),
          };
        });

      setClosedCampaigns(result);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setClosedCampaigns([]);
    }
  }

  async function handleCreateFromCampaign(campaignId: number) {
    setCreatingFromCampaignId(campaignId);
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: prId, error: rpcErr } = await supabase.rpc("rpc_create_pr_from_campaign", {
        p_campaign_id: campaignId,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      router.push(`/purchase/requests/edit?id=${prId}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setCreatingFromCampaignId(null);
    }
  }

  async function approve(id: number) {
    if (!confirm("確定通過審核？")) return;
    setBusyId(id);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc("rpc_approve_purchase_request", {
        p_pr_id: id,
        p_note: null,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyId(null);
    }
  }

  async function reject(id: number) {
    const reason = prompt("退回原因（必填）");
    if (!reason) return;
    setBusyId(id);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc("rpc_reject_purchase_request", {
        p_pr_id: id,
        p_reason: reason,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">採購單（PR）</h1>
          <p className="text-sm text-zinc-500">
            {rows === null ? "載入中…" : `共 ${rows.length} 筆`}
          </p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={openCampaignModal}
            disabled={creatingBlank}
            className="rounded-md border border-blue-600 bg-white px-3 py-2 text-sm font-medium text-blue-600 hover:bg-blue-50 disabled:opacity-50 dark:bg-zinc-900 dark:hover:bg-zinc-800"
          >
            + 針對團購建單
          </button>
          <button
            onClick={handleCreateBlank}
            disabled={creatingBlank}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800"
          >
            {creatingBlank ? "建立中…" : "+ 空白採購單"}
          </button>
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* 結單日待開單 cards */}
      {pendingDates !== null && pendingDates.length > 0 && (
        <section className="rounded-md border border-emerald-200 bg-emerald-50 p-4 dark:border-emerald-900 dark:bg-emerald-950/30">
          <h2 className="mb-3 text-sm font-semibold text-emerald-900 dark:text-emerald-200">
            🆕 結單日待開單（{pendingDates.length}）
          </h2>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {pendingDates.map((g) => (
              <div
                key={g.close_date}
                className="rounded-md border border-emerald-200 bg-white p-3 shadow-sm dark:border-emerald-900 dark:bg-zinc-900"
              >
                <div className="mb-1 text-base font-semibold">{g.close_date}</div>
                <div className="mb-2 text-xs text-zinc-500">
                  {g.campaigns.length} 個團 · {g.total_skus} 個 SKU · 總量 {g.total_qty}
                </div>
                <ul className="mb-2 max-h-16 space-y-0.5 overflow-y-auto text-xs">
                  {g.campaigns.slice(0, 3).map((c) => (
                    <li key={c.id} className="truncate text-zinc-600 dark:text-zinc-400">
                      · {c.name}
                    </li>
                  ))}
                  {g.campaigns.length > 3 && (
                    <li className="text-zinc-400">…還有 {g.campaigns.length - 3} 個</li>
                  )}
                </ul>
                <button
                  onClick={() => handleImport(g.close_date)}
                  disabled={busyDate !== null}
                  className="w-full rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500 disabled:opacity-50"
                >
                  {busyDate === g.close_date ? "建立中…" : "📋 開始建立"}
                </button>
              </div>
            ))}
          </div>
        </section>
      )}

      {/* 篩選 */}
      <div className="grid gap-3 sm:grid-cols-2">
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部狀態</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </select>
        <select
          value={reviewFilter}
          onChange={(e) => setReviewFilter(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部審核狀態</option>
          {Object.entries(REVIEW_LABEL).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </select>
      </div>

      {/* PR 列表 */}
      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>單號</Th>
              <Th>來源</Th>
              <Th>結單日</Th>
              <Th>狀態</Th>
              <Th>審核</Th>
              <Th className="text-right">品項</Th>
              <Th className="text-right">總金額</Th>
              <Th className="text-right">更新</Th>
              <Th></Th>
              <Th className="min-w-[280px]">流程</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr>
                <td colSpan={10} className="p-3 text-center text-zinc-500">
                  載入中…
                </td>
              </tr>
            ) : rows.length === 0 ? (
              <tr>
                <td colSpan={10} className="p-6 text-center text-zinc-500">
                  尚無採購單
                </td>
              </tr>
            ) : (
              rows.map((r) => (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="font-mono">
                    <a
                      href={`/purchase/requests/edit?id=${r.id}`}
                      className="hover:underline"
                    >
                      {r.pr_no}
                    </a>
                  </Td>
                  <Td className="text-xs text-zinc-500">
                    {SOURCE_LABEL[r.source_type] ?? r.source_type}
                  </Td>
                  <Td className="text-xs">{r.source_close_date ?? "—"}</Td>
                  <Td>
                    <Badge label={STATUS_LABEL[r.status] ?? r.status} kind="status" status={r.status} />
                  </Td>
                  <Td>
                    <Badge
                      label={REVIEW_LABEL[r.review_status] ?? r.review_status}
                      kind="review"
                      status={r.review_status}
                    />
                  </Td>
                  <Td className="text-right text-xs">
                    {(() => {
                      const p = progressById.get(r.id);
                      if (!p) return <span className="text-zinc-400">—</span>;
                      return (
                        <span className="font-mono">
                          {p.item_count}
                          {p.unassigned_supplier_count > 0 && (
                            <span
                              className="ml-1 rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                              title="未指派供應商"
                            >
                              {p.unassigned_supplier_count} 待指派
                            </span>
                          )}
                        </span>
                      );
                    })()}
                  </Td>
                  <Td className="text-right font-mono">${Number(r.total_amount).toFixed(0)}</Td>
                  <Td className="text-right text-xs text-zinc-500">
                    {new Date(r.updated_at).toLocaleString("zh-TW")}
                  </Td>
                  <Td>
                    <div className="flex gap-2">
                      {r.review_status === "pending_review" && (
                        <>
                          <button
                            disabled={busyId === r.id}
                            onClick={() => approve(r.id)}
                            className="text-xs text-emerald-600 hover:underline disabled:opacity-50 dark:text-emerald-400"
                          >
                            通過
                          </button>
                          <button
                            disabled={busyId === r.id}
                            onClick={() => reject(r.id)}
                            className="text-xs text-red-600 hover:underline disabled:opacity-50 dark:text-red-400"
                          >
                            退回
                          </button>
                        </>
                      )}
                    </div>
                  </Td>
                  <Td>
                    <PrPipelineStepper
                      status={r.status}
                      reviewStatus={r.review_status}
                      compact
                      poSummary={(() => {
                        const p = progressById.get(r.id);
                        return p
                          ? { total: p.po_total, sent: p.po_sent, receivedFully: p.po_received_fully }
                          : undefined;
                      })()}
                      transferSummary={(() => {
                        const p = progressById.get(r.id);
                        return p
                          ? { total: p.transfer_total, shipped: p.transfer_shipped, delivered: p.transfer_delivered }
                          : undefined;
                      })()}
                      campaignFinalized={progressById.get(r.id)?.all_campaigns_finalized}
                      events={{
                        create: { href: `/purchase/requests/edit?id=${r.id}` },
                        draft: { href: `/purchase/requests/edit?id=${r.id}` },
                        submit: { href: `/purchase/requests/edit?id=${r.id}` },
                        review: { href: `/purchase/requests/edit?id=${r.id}` },
                        split: { href: `/purchase/orders` },
                        send: { href: `/purchase/orders` },
                        receive: { href: `/purchase/orders` },
                        ship: r.source_close_date ? { detail: `配送 ${r.source_close_date}`, href: `/picking/history` } : undefined,
                        delivered: r.source_close_date ? { detail: `配送 ${r.source_close_date}` } : undefined,
                      }}
                    />
                  </Td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {showCampaignModal && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
          onClick={() => setShowCampaignModal(false)}
        >
          <div
            className="max-h-[80vh] w-full max-w-2xl overflow-hidden rounded-lg bg-white shadow-xl dark:bg-zinc-900"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
              <h3 className="text-base font-semibold">針對單一團購建單</h3>
              <button
                onClick={() => setShowCampaignModal(false)}
                className="text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100"
              >
                ✕
              </button>
            </div>
            <div className="max-h-[60vh] overflow-y-auto p-4">
              {closedCampaigns === null ? (
                <div className="text-center text-sm text-zinc-500">載入中…</div>
              ) : closedCampaigns.length === 0 ? (
                <div className="text-center text-sm text-zinc-500">過去 60 天無已結單團購</div>
              ) : (
                <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {closedCampaigns.map((c) => {
                    const disabled = c.existing_pr_id !== null || creatingFromCampaignId !== null;
                    return (
                      <li key={c.id} className="flex items-center justify-between gap-3 py-2">
                        <div className="min-w-0 flex-1">
                          <div className="truncate text-sm font-medium">{c.name}</div>
                          <div className="mt-0.5 text-xs text-zinc-500">
                            結單日 {c.close_date}
                            {c.existing_pr_id !== null && (
                              <a
                                href={`/purchase/requests/edit?id=${c.existing_pr_id}`}
                                className="ml-2 text-amber-600 hover:underline dark:text-amber-400"
                              >
                                · 已有採購單 #{c.existing_pr_id}
                              </a>
                            )}
                            {c.existing_pr_id === null && c.same_close_date_has_pr && (
                              <span className="ml-2 text-zinc-400">· 同日已有結單日 PR（共存）</span>
                            )}
                          </div>
                        </div>
                        <button
                          onClick={() => handleCreateFromCampaign(c.id)}
                          disabled={disabled}
                          className="shrink-0 rounded-md bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-500 disabled:opacity-40"
                        >
                          {creatingFromCampaignId === c.id ? "建立中…" : "建單"}
                        </button>
                      </li>
                    );
                  })}
                </ul>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function Th({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
  return (
    <th
      className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}
    >
      {children}
    </th>
  );
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}
function Badge({
  label,
  status,
  kind,
}: {
  label: string;
  status: string;
  kind: "status" | "review";
}) {
  const cls =
    kind === "review"
      ? status === "pending_review"
        ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
        : status === "rejected"
          ? "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300"
          : "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
      : status === "draft"
        ? "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
        : status === "submitted"
          ? "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300"
          : status === "fully_ordered"
            ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
            : "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300";
  return <span className={`inline-block rounded px-2 py-0.5 text-xs ${cls}`}>{label}</span>;
}

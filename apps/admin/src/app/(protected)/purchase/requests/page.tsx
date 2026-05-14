"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { RowAction } from "@/components/RowAction";

const PAGE_SIZE = 20;

type PRStatus =
  | "draft"
  | "submitted"
  | "partially_ordered"
  | "fully_ordered"
  | "cancelled";
type ReviewStatus = "pending_review" | "approved" | "rejected";
type SourceType = "close_date" | "campaign" | "manual";

type Row = {
  id: number;
  pr_no: string;
  source_type: string;
  source_close_date: string | null;
  status: PRStatus;
  review_status: ReviewStatus;
  total_amount: number;
  notes: string | null;
  updated_at: string;
};

type Progress = {
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

type CloseDateGroup = {
  close_date: string;
  campaigns: { id: number; name: string }[];
  total_skus: number;
  total_qty: number;
};

type ClosedCampaignRow = {
  id: number;
  name: string;
  close_date: string;
  existing_pr_id: number | null;
  same_close_date_has_pr: boolean;
};

type StatusTab = "all" | PRStatus;

const STATUS_LABEL: Record<PRStatus, string> = {
  draft: "草稿",
  submitted: "已送審",
  partially_ordered: "部分轉單",
  fully_ordered: "全部轉單",
  cancelled: "已取消",
};

const REVIEW_LABEL: Record<ReviewStatus, string> = {
  approved: "已通過",
  pending_review: "待審核",
  rejected: "已退回",
};

const SOURCE_LABEL: Record<SourceType, string> = {
  close_date: "結單日帶入",
  campaign: "單一團購",
  manual: "手動",
};

const STATUS_TAB_ORDER: StatusTab[] = [
  "all",
  "draft",
  "submitted",
  "partially_ordered",
  "fully_ordered",
  "cancelled",
];

const STATUS_BADGE: Record<PRStatus, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  submitted: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  partially_ordered:
    "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  fully_ordered:
    "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

const REVIEW_BADGE: Record<ReviewStatus, string> = {
  pending_review:
    "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  rejected: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  approved:
    "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
};

type SortCol = "updated_at" | "source_close_date" | "total_amount" | "pr_no";

export default function PurchaseRequestsListPage() {
  const router = useRouter();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [pendingDates, setPendingDates] = useState<CloseDateGroup[] | null>(
    null,
  );
  const [error, setError] = useState<string | null>(null);

  // 篩選 / 排序 / 分組
  const [tab, setTab] = useState<StatusTab>("all");
  const [reviewFilter, setReviewFilter] = useState<"" | ReviewStatus>("");
  const [sourceFilter, setSourceFilter] = useState<"" | SourceType>("");
  const [search, setSearch] = useState("");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [groupBy, setGroupBy] = useState<
    "none" | "close_date" | "source" | "status"
  >("none");
  const [sortBy, setSortBy] = useState<SortCol>("updated_at");
  const [sortDir, setSortDir] = useState<"asc" | "desc">("desc");
  const [page, setPage] = useState(1);

  const [reloadTick, setReloadTick] = useState(0);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [busyDate, setBusyDate] = useState<string | null>(null);
  const [creatingBlank, setCreatingBlank] = useState(false);
  const [showCampaignModal, setShowCampaignModal] = useState(false);
  const [closedCampaigns, setClosedCampaigns] = useState<
    ClosedCampaignRow[] | null
  >(null);
  const [selectedCampaignIds, setSelectedCampaignIds] = useState<Set<number>>(
    new Set(),
  );
  const [campaignQuery, setCampaignQuery] = useState("");
  const [creatingMulti, setCreatingMulti] = useState(false);
  const [progressById, setProgressById] = useState<Map<number, Progress>>(
    new Map(),
  );

  // ============== 載入既有 PRs ==============
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error: err } = await getSupabase()
          .from("purchase_requests")
          .select(
            "id, pr_no, source_type, source_close_date, status, review_status, total_amount, notes, updated_at",
          )
          .order("updated_at", { ascending: false })
          .limit(500);
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
            .select(
              "pr_id, po_total, po_sent, po_received_fully, transfer_total, transfer_shipped, transfer_delivered, item_count, unassigned_supplier_count, all_campaigns_finalized",
            )
            .in("pr_id", ids);
          if (!cancelled) {
            const m = new Map<number, Progress>();
            type ProgRow = Progress & { pr_id: number };
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
  }, [reloadTick]);

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
          (existingPrs ?? [])
            .map((p) => p.source_close_date as string)
            .filter(Boolean),
        );

        const byDate = new Map<string, { id: number; name: string }[]>();
        for (const c of camps ?? []) {
          if (!c.end_at) continue;
          const d = new Date(c.end_at).toLocaleDateString("sv-SE");
          if (datesWithPR.has(d)) continue;
          if (!byDate.has(d)) byDate.set(d, []);
          byDate.get(d)!.push({ id: c.id, name: c.name });
        }

        const campaignIds = Array.from(byDate.values())
          .flat()
          .map((c) => c.id);
        const demandByCampaign = new Map<
          number,
          { skus: Set<number>; qty: number }
        >();
        if (campaignIds.length) {
          const { data: items } = await supabase
            .from("customer_order_items")
            .select(
              "sku_id, qty, customer_orders!inner(campaign_id, status)",
            )
            .in("customer_orders.campaign_id", campaignIds);
          type ItemAgg = {
            sku_id: number;
            qty: number;
            customer_orders:
              | { campaign_id: number; status: string }[]
              | { campaign_id: number; status: string };
          };
          for (const it of (items as ItemAgg[] | null) ?? []) {
            const ord = Array.isArray(it.customer_orders)
              ? it.customer_orders[0]
              : it.customer_orders;
            if (!ord || ["cancelled", "expired"].includes(ord.status)) continue;
            const cid = ord.campaign_id;
            if (!demandByCampaign.has(cid))
              demandByCampaign.set(cid, { skus: new Set(), qty: 0 });
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
            return {
              close_date,
              campaigns: list,
              total_skus: skus.size,
              total_qty: qty,
            };
          })
          .filter((g) => g.total_qty > 0)
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
      const { data: prId, error: rpcErr } = await supabase.rpc(
        "rpc_create_pr_from_close_date",
        {
          p_close_date: closeDate,
          p_operator: userData.user?.id,
        },
      );
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
      const { data: prId, error: rpcErr } = await supabase.rpc(
        "rpc_create_pr_blank",
        {
          p_operator: userData.user?.id,
        },
      );
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
        (
          (existingCampaignPRs as
            | { id: number; source_campaign_id: number | null }[]
            | null) ?? []
        )
          .filter((p) => p.source_campaign_id !== null)
          .map((p) => [p.source_campaign_id as number, p.id]),
      );

      const { data: existingCloseDatePRs } = await supabase
        .from("purchase_requests")
        .select("source_close_date")
        .eq("source_type", "close_date")
        .neq("status", "cancelled");
      const closeDateSet = new Set(
        (
          (existingCloseDatePRs as
            | { source_close_date: string | null }[]
            | null) ?? []
        )
          .map((p) => p.source_close_date)
          .filter((d): d is string => !!d),
      );

      const result: ClosedCampaignRow[] = (
        (camps as
          | { id: number; name: string; end_at: string | null }[]
          | null) ?? []
      )
        .filter((c) => !!c.end_at)
        .map((c) => {
          const closeDate = new Date(c.end_at as string).toLocaleDateString(
            "sv-SE",
          );
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

  async function handleCreateFromMultipleCampaigns() {
    if (selectedCampaignIds.size === 0) return;
    setCreatingMulti(true);
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: prId, error: rpcErr } = await supabase.rpc(
        "rpc_create_pr_from_campaigns",
        {
          p_campaign_ids: Array.from(selectedCampaignIds),
          p_operator: userData.user?.id,
        },
      );
      if (rpcErr) throw new Error(rpcErr.message);
      router.push(`/purchase/requests/edit?id=${prId}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setCreatingMulti(false);
    }
  }

  function toggleCampaignSelect(id: number) {
    setSelectedCampaignIds((s) => {
      const next = new Set(s);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  async function approve(id: number) {
    if (!confirm("確定通過審核？")) return;
    setBusyId(id);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc(
        "rpc_approve_purchase_request",
        {
          p_pr_id: id,
          p_note: null,
          p_operator: userData.user?.id,
        },
      );
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
      const { error: rpcErr } = await supabase.rpc(
        "rpc_reject_purchase_request",
        {
          p_pr_id: id,
          p_reason: reason,
          p_operator: userData.user?.id,
        },
      );
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusyId(null);
    }
  }

  // === KPI 統計 ===
  const stats = useMemo(() => {
    const acc = {
      draft: 0,
      submitted: 0,
      partially_ordered: 0,
      fully_ordered: 0,
      cancelled: 0,
      pending_review: 0,
      to_split: 0, // approved + draft + submitted, status not fully/cancelled
      total_amount_in_flight: 0,
      unassigned: 0,
    };
    for (const r of rows ?? []) {
      acc[r.status] += 1;
      if (r.review_status === "pending_review") acc.pending_review += 1;
      const inFlight =
        r.review_status === "approved" &&
        r.status !== "fully_ordered" &&
        r.status !== "cancelled";
      if (inFlight) {
        acc.to_split += 1;
        acc.total_amount_in_flight += Number(r.total_amount) || 0;
      }
      const p = progressById.get(r.id);
      if (p) acc.unassigned += p.unassigned_supplier_count;
    }
    return acc;
  }, [rows, progressById]);

  // tab counts
  const tabCounts = useMemo(
    () => ({
      all: rows?.length ?? 0,
      draft: stats.draft,
      submitted: stats.submitted,
      partially_ordered: stats.partially_ordered,
      fully_ordered: stats.fully_ordered,
      cancelled: stats.cancelled,
    }),
    [rows, stats],
  );

  // 篩選變動 → 重置到第 1 頁
  useEffect(() => {
    setPage(1);
  }, [
    tab,
    reviewFilter,
    sourceFilter,
    search,
    dateFrom,
    dateTo,
    sortBy,
    sortDir,
    groupBy,
  ]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (rows ?? []).filter((r) => {
      if (tab !== "all" && r.status !== tab) return false;
      if (reviewFilter && r.review_status !== reviewFilter) return false;
      if (sourceFilter && r.source_type !== sourceFilter) return false;
      if (
        dateFrom &&
        (!r.source_close_date || r.source_close_date < dateFrom)
      )
        return false;
      if (dateTo && (!r.source_close_date || r.source_close_date > dateTo))
        return false;
      if (q) {
        const hits = [r.pr_no, r.notes]
          .filter((x): x is string => !!x)
          .some((x) => x.toLowerCase().includes(q));
        if (!hits) return false;
      }
      return true;
    });
  }, [rows, tab, reviewFilter, sourceFilter, search, dateFrom, dateTo]);

  const sorted = useMemo(() => {
    const arr = [...filtered];
    arr.sort((a, b) => {
      let av: string | number;
      let bv: string | number;
      if (sortBy === "total_amount") {
        av = Number(a.total_amount) || 0;
        bv = Number(b.total_amount) || 0;
      } else if (sortBy === "pr_no") {
        av = a.pr_no;
        bv = b.pr_no;
      } else if (sortBy === "source_close_date") {
        av = a.source_close_date ?? "";
        bv = b.source_close_date ?? "";
      } else {
        av = a.updated_at;
        bv = b.updated_at;
      }
      if (av < bv) return sortDir === "asc" ? -1 : 1;
      if (av > bv) return sortDir === "asc" ? 1 : -1;
      return 0;
    });
    return arr;
  }, [filtered, sortBy, sortDir]);

  const total = sorted.length;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const pageRows = sorted.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);

  const grouped = useMemo(() => {
    if (groupBy === "none") return null;
    const map = new Map<string, { label: string; rows: Row[] }>();
    for (const r of pageRows) {
      let key = "—";
      let label = "—";
      if (groupBy === "close_date") {
        key = r.source_close_date ?? "no-date";
        label = r.source_close_date ?? "(無結單日)";
      } else if (groupBy === "source") {
        key = r.source_type;
        label =
          SOURCE_LABEL[r.source_type as SourceType] ?? r.source_type;
      } else {
        key = r.status;
        label = STATUS_LABEL[r.status] ?? r.status;
      }
      let slot = map.get(key);
      if (!slot) {
        slot = { label, rows: [] };
        map.set(key, slot);
      }
      slot.rows.push(r);
    }
    return Array.from(map.entries())
      .sort((a, b) => {
        if (groupBy === "close_date") return b[0].localeCompare(a[0]);
        return a[1].label.localeCompare(b[1].label);
      })
      .map(([k, v]) => ({ key: k, ...v }));
  }, [pageRows, groupBy]);

  function setSort(col: SortCol) {
    if (sortBy === col) setSortDir((d) => (d === "asc" ? "desc" : "asc"));
    else {
      setSortBy(col);
      setSortDir("desc");
    }
  }

  const filtersActive =
    tab !== "all" ||
    !!reviewFilter ||
    !!sourceFilter ||
    !!search ||
    !!dateFrom ||
    !!dateTo;

  function clearFilters() {
    setTab("all");
    setReviewFilter("");
    setSourceFilter("");
    setSearch("");
    setDateFrom("");
    setDateTo("");
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
          <SpinButton
            onClick={openCampaignModal}
            disabled={creatingBlank}
            className="rounded-md border border-blue-600 bg-white px-3 py-2 text-sm font-medium text-blue-600 hover:bg-blue-50 disabled:opacity-50 dark:bg-zinc-900 dark:hover:bg-zinc-800"
          >
            + 針對團購建單
          </SpinButton>
          <SpinButton
            onClick={handleCreateBlank}
            disabled={creatingBlank}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800"
          >
            {creatingBlank ? "建立中…" : "+ 空白採購單"}
          </SpinButton>
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* === 總覽 KPI cards === */}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard
          label="待審核"
          hint="送審中,等待通過"
          value={stats.pending_review}
          accent="text-amber-700 dark:text-amber-400"
          active={reviewFilter === "pending_review"}
          onClick={() =>
            setReviewFilter(
              reviewFilter === "pending_review" ? "" : "pending_review",
            )
          }
        />
        <KpiCard
          label="待轉單"
          hint="已通過、尚未全部轉成 PO"
          value={stats.to_split}
          accent="text-blue-700 dark:text-blue-400"
        />
        <KpiCard
          label="⚠ 待指派供應商"
          hint="品項仍未指派供應商,無法拆 PO"
          value={stats.unassigned}
          accent="text-red-700 dark:text-red-400"
        />
        <KpiCard
          label="🆕 結單日待開單"
          hint="近 60 天結單、尚未建 PR 的日期"
          value={pendingDates?.length ?? 0}
          accent="text-emerald-700 dark:text-emerald-400"
        />
      </div>

      {/* === 結單日待開單 cards === */}
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
                <div className="mb-1 text-base font-semibold">
                  {g.close_date}
                </div>
                <div className="mb-2 text-xs text-zinc-500">
                  {g.campaigns.length} 個團 · {g.total_skus} 個品項 · 總量{" "}
                  {g.total_qty}
                </div>
                <ul className="mb-2 max-h-16 space-y-0.5 overflow-y-auto text-xs">
                  {g.campaigns.slice(0, 3).map((c) => (
                    <li
                      key={c.id}
                      className="truncate text-zinc-600 dark:text-zinc-400"
                    >
                      · {c.name}
                    </li>
                  ))}
                  {g.campaigns.length > 3 && (
                    <li className="text-zinc-400">
                      …還有 {g.campaigns.length - 3} 個
                    </li>
                  )}
                </ul>
                <SpinButton
                  onClick={() => handleImport(g.close_date)}
                  disabled={busyDate !== null}
                  className="w-full rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500 disabled:opacity-50"
                >
                  {busyDate === g.close_date ? "建立中…" : "📋 開始建立"}
                </SpinButton>
              </div>
            ))}
          </div>
        </section>
      )}

      {/* === 狀態 tabs === */}
      <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {STATUS_TAB_ORDER.map((s) => {
          const label = s === "all" ? "全部" : STATUS_LABEL[s];
          const count = tabCounts[s];
          const active = tab === s;
          return (
            <SpinButton
              key={s}
              onClick={() => setTab(s)}
              className={`-mb-px border-b-2 px-3 py-2 text-sm ${
                active
                  ? "border-blue-600 font-semibold text-blue-700 dark:text-blue-300"
                  : "border-transparent text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
              }`}
            >
              {label}
              <span className="ml-1 text-xs text-zinc-400">{count}</span>
            </SpinButton>
          );
        })}
      </div>

      {/* === 篩選 / 搜尋工具列 === */}
      <div className="flex flex-wrap items-center gap-2">
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="🔍 搜尋 單號 / 備註"
          className="flex-1 min-w-[180px] rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
        />
        <select
          value={reviewFilter}
          onChange={(e) =>
            setReviewFilter(e.target.value as ReviewStatus | "")
          }
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
        >
          <option value="">全部審核</option>
          {(Object.keys(REVIEW_LABEL) as ReviewStatus[]).map((v) => (
            <option key={v} value={v}>
              {REVIEW_LABEL[v]}
            </option>
          ))}
        </select>
        <select
          value={sourceFilter}
          onChange={(e) =>
            setSourceFilter(e.target.value as SourceType | "")
          }
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
        >
          <option value="">全部來源</option>
          {(Object.keys(SOURCE_LABEL) as SourceType[]).map((v) => (
            <option key={v} value={v}>
              {SOURCE_LABEL[v]}
            </option>
          ))}
        </select>
        <input
          type="date"
          value={dateFrom}
          onChange={(e) => setDateFrom(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          title="結單日 起"
        />
        <span className="text-xs text-zinc-400">~</span>
        <input
          type="date"
          value={dateTo}
          onChange={(e) => setDateTo(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          title="結單日 迄"
        />
        <label className="flex items-center gap-1 text-xs text-zinc-500">
          <span>分組</span>
          <select
            value={groupBy}
            onChange={(e) =>
              setGroupBy(e.target.value as typeof groupBy)
            }
            className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-xs dark:border-zinc-700 dark:bg-zinc-900"
          >
            <option value="none">不分組</option>
            <option value="close_date">依結單日</option>
            <option value="source">依來源</option>
            <option value="status">依狀態</option>
          </select>
        </label>
        {filtersActive && (
          <SpinButton
            onClick={clearFilters}
            className="rounded-md border border-zinc-300 px-2 py-1.5 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            清除篩選
          </SpinButton>
        )}
        <span className="ml-auto text-xs text-zinc-500">
          {rows === null
            ? "載入中…"
            : `符合 ${total} 筆${total > PAGE_SIZE ? ` · 第 ${page}/${totalPages} 頁` : ""}`}
        </span>
      </div>

      {/* === 主表格 === */}
      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <SortTh
                col="pr_no"
                label="單號"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
              />
              <Th>來源</Th>
              <SortTh
                col="source_close_date"
                label="結單日"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
              />
              <Th>狀態</Th>
              <Th>審核</Th>
              <Th align="right">品項</Th>
              <SortTh
                col="total_amount"
                label="總金額"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
                align="right"
              />
              <Th align="left">進度</Th>
              <SortTh
                col="updated_at"
                label="更新"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
                align="right"
              />
              <Th align="right">動作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr>
                <td colSpan={10} className="p-6 text-center text-zinc-500">
                  載入中…
                </td>
              </tr>
            ) : pageRows.length === 0 ? (
              <tr>
                <td colSpan={10} className="p-6 text-center text-zinc-500">
                  {filtersActive ? "沒有符合條件的採購單" : "尚無採購單"}
                </td>
              </tr>
            ) : grouped ? (
              grouped.flatMap((g) => [
                <tr
                  key={`g-${g.key}`}
                  className="bg-zinc-50 dark:bg-zinc-950"
                >
                  <td
                    colSpan={10}
                    className="px-4 py-2 text-xs font-semibold text-zinc-700 dark:text-zinc-200"
                  >
                    📂 {g.label}
                    <span className="ml-2 font-normal text-zinc-500">
                      ({g.rows.length})
                    </span>
                  </td>
                </tr>,
                ...g.rows.map((r) => (
                  <PRRow
                    key={r.id}
                    row={r}
                    progress={progressById.get(r.id)}
                    busyId={busyId}
                    onApprove={approve}
                    onReject={reject}
                  />
                )),
              ])
            ) : (
              pageRows.map((r) => (
                <PRRow
                  key={r.id}
                  row={r}
                  progress={progressById.get(r.id)}
                  busyId={busyId}
                  onApprove={approve}
                  onReject={reject}
                />
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* === 分頁 === */}
      {total > PAGE_SIZE && (
        <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
          <span className="text-xs text-zinc-500">
            共 {total} 筆 · 顯示 {(page - 1) * PAGE_SIZE + 1} -{" "}
            {Math.min(page * PAGE_SIZE, total)}
          </span>
          <SpinButton
            onClick={() => setPage(1)}
            disabled={page === 1}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            « 第一頁
          </SpinButton>
          <SpinButton
            onClick={() => setPage((p) => Math.max(1, p - 1))}
            disabled={page === 1}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            ‹ 上頁
          </SpinButton>
          <span className="text-xs text-zinc-500">
            {page} / {totalPages}
          </span>
          <SpinButton
            onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
            disabled={page === totalPages}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            下頁 ›
          </SpinButton>
          <SpinButton
            onClick={() => setPage(totalPages)}
            disabled={page === totalPages}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            最末頁 »
          </SpinButton>
        </div>
      )}

      {showCampaignModal && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
          onClick={() => {
            setShowCampaignModal(false);
            setSelectedCampaignIds(new Set());
            setCampaignQuery("");
          }}
        >
          <div
            className="max-h-[80vh] w-full max-w-2xl overflow-hidden rounded-lg bg-white shadow-xl dark:bg-zinc-900"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
              <div>
                <h3 className="text-base font-semibold">針對團購建採購單</h3>
                <p className="mt-0.5 text-xs text-zinc-500">
                  可多選、同團購可重複開單（補單）
                </p>
              </div>
              <SpinButton
                onClick={() => {
                  setShowCampaignModal(false);
                  setSelectedCampaignIds(new Set());
                  setCampaignQuery("");
                }}
                className="text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100"
              >
                ✕
              </SpinButton>
            </div>
            <div className="border-b border-zinc-200 px-4 py-2 dark:border-zinc-800">
              <input
                type="search"
                value={campaignQuery}
                onChange={(e) => setCampaignQuery(e.target.value)}
                placeholder="搜尋團名 / 結單日 (YYYY-MM-DD)"
                autoFocus
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
              />
            </div>
            <div className="max-h-[60vh] overflow-y-auto p-4">
              {closedCampaigns === null ? (
                <div className="text-center text-sm text-zinc-500">
                  載入中…
                </div>
              ) : closedCampaigns.length === 0 ? (
                <div className="text-center text-sm text-zinc-500">
                  過去 60 天無已結單團購
                </div>
              ) : (() => {
                const q = campaignQuery.trim().toLowerCase();
                const filtered = q
                  ? closedCampaigns.filter((c) =>
                      c.name.toLowerCase().includes(q) ||
                      c.close_date.toLowerCase().includes(q)
                    )
                  : closedCampaigns;
                if (filtered.length === 0) {
                  return (
                    <div className="text-center text-sm text-zinc-500">
                      沒有符合「{campaignQuery}」的團
                    </div>
                  );
                }
                return (
                  <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
                    {filtered.map((c) => {
                      const checked = selectedCampaignIds.has(c.id);
                      return (
                        <li
                          key={c.id}
                          className="flex cursor-pointer items-center gap-3 py-2 hover:bg-zinc-50 dark:hover:bg-zinc-800"
                          onClick={() => toggleCampaignSelect(c.id)}
                        >
                          <input
                            type="checkbox"
                            checked={checked}
                            onChange={() => toggleCampaignSelect(c.id)}
                            onClick={(e) => e.stopPropagation()}
                            className="h-4 w-4 rounded border-zinc-300 text-blue-600 focus:ring-blue-500"
                          />
                          <div className="min-w-0 flex-1">
                            <div className="truncate text-sm font-medium">
                              {c.name}
                            </div>
                            <div className="mt-0.5 text-xs text-zinc-500">
                              結單日 {c.close_date}
                              {c.existing_pr_id !== null && (
                                <Link
                                  href={`/purchase/requests/edit?id=${c.existing_pr_id}`}
                                  onClick={(e) => e.stopPropagation()}
                                  className="ml-2 text-amber-600 hover:underline dark:text-amber-400"
                                >
                                  · 已有採購單 #{c.existing_pr_id}（補單會新建）
                                </Link>
                              )}
                            </div>
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                );
              })()}
            </div>
            {closedCampaigns && closedCampaigns.length > 0 && (
              <div className="flex items-center justify-between gap-3 border-t border-zinc-200 px-4 py-3 dark:border-zinc-800">
                <span className="text-xs text-zinc-500">
                  已選 {selectedCampaignIds.size} 個
                </span>
                <div className="flex gap-2">
                  <SpinButton
                    onClick={() => {
                      setShowCampaignModal(false);
                      setSelectedCampaignIds(new Set());
                      setCampaignQuery("");
                    }}
                    className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                  >
                    取消
                  </SpinButton>
                  <SpinButton
                    onClick={handleCreateFromMultipleCampaigns}
                    disabled={selectedCampaignIds.size === 0 || creatingMulti}
                    className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-500 disabled:opacity-40"
                  >
                    {creatingMulti
                      ? "建立中…"
                      : `📋 建立採購單（${selectedCampaignIds.size}）`}
                  </SpinButton>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function KpiCard({
  label,
  hint,
  value,
  accent,
  active,
  onClick,
}: {
  label: string;
  hint?: string;
  value: number | string;
  accent: string;
  active?: boolean;
  onClick?: () => void;
}) {
  const Wrapper = onClick ? "button" : "div";
  return (
    <Wrapper
      type={onClick ? "button" : undefined}
      onClick={onClick}
      title={hint}
      className={`rounded-md border p-3 text-left transition ${
        active
          ? "border-blue-500 bg-blue-50 dark:border-blue-700 dark:bg-blue-950/40"
          : "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
      } ${onClick ? "hover:border-blue-400 hover:bg-zinc-50 dark:hover:bg-zinc-800/60" : ""}`}
    >
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-0.5 text-2xl font-semibold ${accent}`}>{value}</div>
      {hint && <div className="mt-0.5 text-[10px] text-zinc-400">{hint}</div>}
    </Wrapper>
  );
}

function PRRow({
  row,
  progress,
  busyId,
  onApprove,
  onReject,
}: {
  row: Row;
  progress: Progress | undefined;
  busyId: number | null;
  onApprove: (id: number) => void;
  onReject: (id: number) => void;
}) {
  return (
    <tr className="hover:bg-zinc-50 dark:hover:bg-zinc-900/60">
      <Td className="font-mono">
        <Link
          href={`/purchase/requests/edit?id=${row.id}`}
          className="text-blue-600 hover:underline dark:text-blue-400"
        >
          {row.pr_no}
        </Link>
      </Td>
      <Td className="text-xs text-zinc-500">
        {SOURCE_LABEL[row.source_type as SourceType] ?? row.source_type}
      </Td>
      <Td className="text-xs">{row.source_close_date ?? "—"}</Td>
      <Td>
        <span
          className={`inline-flex rounded px-2 py-0.5 text-xs ${STATUS_BADGE[row.status]}`}
        >
          {STATUS_LABEL[row.status]}
        </span>
      </Td>
      <Td>
        <span
          className={`inline-flex rounded px-2 py-0.5 text-xs ${REVIEW_BADGE[row.review_status]}`}
        >
          {REVIEW_LABEL[row.review_status]}
        </span>
      </Td>
      <Td className="text-right text-xs">
        {progress ? (
          <span className="font-mono">
            {progress.item_count}
            {progress.unassigned_supplier_count > 0 && (
              <span
                className="ml-1 rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                title="未指派供應商"
              >
                {progress.unassigned_supplier_count} 待指派
              </span>
            )}
          </span>
        ) : (
          <span className="text-zinc-400">—</span>
        )}
      </Td>
      <Td className="text-right font-mono">
        ${Number(row.total_amount).toLocaleString()}
      </Td>
      <Td>
        <ProgressCells progress={progress} prId={row.id} />
      </Td>
      <Td className="text-right text-xs text-zinc-500">
        {new Date(row.updated_at).toLocaleDateString("zh-TW", {
          month: "numeric",
          day: "numeric",
        })}
      </Td>
      <Td className="text-right">
        <div className="flex justify-end gap-1">
          {row.review_status === "pending_review" && (
            <>
              <RowAction
                variant="success"
                disabled={busyId === row.id}
                onClick={() => onApprove(row.id)}
              >
                通過
              </RowAction>
              <RowAction
                variant="danger"
                disabled={busyId === row.id}
                onClick={() => onReject(row.id)}
              >
                退回
              </RowAction>
            </>
          )}
        </div>
      </Td>
    </tr>
  );
}

function ProgressCells({
  progress,
  prId,
}: {
  progress: Progress | undefined;
  prId: number;
}) {
  if (!progress || progress.po_total === 0) {
    return <span className="text-xs text-zinc-400">—</span>;
  }
  const tip =
    `PO 總數 ${progress.po_total} / 已發 ${progress.po_sent} / 全收 ${progress.po_received_fully}` +
    (progress.transfer_total > 0
      ? ` · 派貨 ${progress.transfer_total} / 出貨 ${progress.transfer_shipped} / 收 ${progress.transfer_delivered}`
      : "");
  return (
    <Link
      href={`/purchase/orders?pr=${prId}`}
      className="inline-flex items-center gap-1 rounded border border-zinc-200 bg-zinc-50 px-2 py-0.5 text-[11px] text-zinc-600 hover:border-blue-400 hover:bg-blue-50 hover:text-blue-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:border-blue-700 dark:hover:bg-blue-950 dark:hover:text-blue-300"
      title={tip}
    >
      <span className="font-mono">PO {progress.po_total}</span>
      <span className="text-zinc-400">·</span>
      <span className="font-mono text-blue-700 dark:text-blue-400">
        發 {progress.po_sent}
      </span>
      <span className="text-zinc-400">·</span>
      <span className="font-mono text-emerald-700 dark:text-emerald-400">
        收 {progress.po_received_fully}
      </span>
      {progress.transfer_total > 0 && (
        <>
          <span className="ml-1 text-zinc-400">|</span>
          <span className="font-mono text-indigo-700 dark:text-indigo-400">
            派 {progress.transfer_delivered}/{progress.transfer_total}
          </span>
        </>
      )}
    </Link>
  );
}

function Th({
  children,
  align = "left",
}: {
  children?: React.ReactNode;
  align?: "left" | "right" | "center";
}) {
  const cls =
    align === "right"
      ? "text-right"
      : align === "center"
        ? "text-center"
        : "text-left";
  return (
    <th
      className={`px-4 py-2 text-xs font-medium uppercase tracking-wide text-zinc-500 ${cls}`}
    >
      {children}
    </th>
  );
}

function SortTh({
  col,
  label,
  sortBy,
  sortDir,
  onClick,
  align = "left",
}: {
  col: SortCol;
  label: string;
  sortBy: SortCol;
  sortDir: "asc" | "desc";
  onClick: (col: SortCol) => void;
  align?: "left" | "right";
}) {
  const active = sortBy === col;
  const arrow = active ? (sortDir === "asc" ? "▲" : "▼") : "";
  const cls = align === "right" ? "text-right" : "text-left";
  return (
    <th
      className={`px-4 py-2 text-xs font-medium uppercase tracking-wide text-zinc-500 ${cls}`}
    >
      <button
        type="button"
        onClick={() => onClick(col)}
        className={`inline-flex items-center gap-1 hover:text-zinc-900 dark:hover:text-zinc-100 ${
          active ? "text-zinc-900 dark:text-zinc-100" : ""
        }`}
      >
        {label}
        {arrow && <span className="text-[10px]">{arrow}</span>}
      </button>
    </th>
  );
}

function Td({
  children,
  className = "",
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}

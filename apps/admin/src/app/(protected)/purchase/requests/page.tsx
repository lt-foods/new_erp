"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { RowAction } from "@/components/RowAction";
import Spinner, { LoadingBlock } from "@/components/Spinner";
import {
  PR_STATUS_LABEL,
  PR_REVIEW_LABEL,
  PR_TERM_ZH,
  type PRStatus,
  type PRReviewStatus,
} from "@/lib/prStatus";
import { PO_TERM_ZH } from "@/lib/poStatus";

const PAGE_SIZE = 20;

type ReviewStatus = PRReviewStatus;
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

type SupplementableDate = {
  close_date: string;
  campaign_count: number;
  remaining_skus: number;
  remaining_qty: number;
};

type ClosedCampaignRow = {
  id: number;
  name: string;
  close_date: string;
  existing_pr_id: number | null;
  same_close_date_has_pr: boolean;
};

type StatusTab = "all" | PRStatus;

// === 樞紐（依廠商彙整品項）===
// 形狀直接對應 rpc_pr_supplier_pivot 的回傳（聚合已在 DB 算完）
type PivotSkuAgg = {
  sku_id: number;
  label: string;
  qty: number;
  ordered_qty: number;
  amount: number;
  prs: { id: number; pr_no: string }[];
};
type PivotGroup = {
  supplier_id: number | null;
  supplier_name: string;
  skus: PivotSkuAgg[];
  qty: number;
  ordered_qty: number;
  amount: number;
  pr_count: number;
};

// rpc_pr_list 的回傳形狀（server-side 篩選 / 排序 / 分頁）
type ListResp = {
  total: number;
  counts: Record<StatusTab, number>;
  kpi: {
    pending_review: number;
    to_split: number;
    amount_in_flight: number;
    unassigned: number;
  };
  rows: (Row & Progress)[];
};

const EMPTY_COUNTS: Record<StatusTab, number> = {
  all: 0, draft: 0, submitted: 0, partially_ordered: 0, fully_ordered: 0, cancelled: 0,
};

const STATUS_LABEL = PR_STATUS_LABEL;
const REVIEW_LABEL = PR_REVIEW_LABEL;

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
  const [pendingDates, setPendingDates] = useState<CloseDateGroup[] | null>(
    null,
  );
  const [supplementDates, setSupplementDates] = useState<
    SupplementableDate[] | null
  >(null);
  const [busySuppDate, setBusySuppDate] = useState<string | null>(null);
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
  const [data, setData] = useState<ListResp | null>(null);

  // 檢視模式：清單（原本）/ 樞紐（把篩選出的 PR 品項依廠商彙整）
  const [viewMode, setViewMode] = useState<"list" | "pivot">("list");
  // 樞紐子篩選：全部品項 / 只看還沒轉成 PO 的品項（＝還要去跟廠商下單的量）
  const [pivotOnlyUnordered, setPivotOnlyUnordered] = useState(false);
  // 樞紐資料連同抓取當下的條件指紋一起存，指紋對不上就是過期 → 重撈
  const [pivotData, setPivotData] = useState<{ tick: string; groups: PivotGroup[] } | null>(null);

  // search 是輸入框當下的值；dSearch 是進 DB 查詢的 debounce 值
  const [dSearch, setDSearch] = useState("");

  // 樞紐快取鍵：任一篩選條件或資料重載都會讓既有彙總過期
  const pivotTick = JSON.stringify([
    reloadTick, tab, reviewFilter, sourceFilter, dSearch, dateFrom, dateTo, pivotOnlyUnordered,
  ]);
  const pivotReady = pivotData !== null && pivotData.tick === pivotTick;
  const pivotGroups = pivotReady ? pivotData.groups : [];
  const pivotLoading = viewMode === "pivot" && !pivotReady;

  // 搜尋 debounce：打字停 300ms 才進 DB
  useEffect(() => {
    const t = setTimeout(() => setDSearch(search), 300);
    return () => clearTimeout(t);
  }, [search]);

  // ============== 清單資料：全部交給 rpc_pr_list ==============
  // 篩選 / 排序 / 分頁 / 計數 / 進度都在 DB 算完，前端只收當頁 PAGE_SIZE 筆。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data: resp, error: err } = await getSupabase().rpc("rpc_pr_list", {
          p_status: tab === "all" ? null : tab,
          p_review: reviewFilter || null,
          p_source: sourceFilter || null,
          p_search: dSearch.trim() || null,
          p_date_from: dateFrom || null,
          p_date_to: dateTo || null,
          p_sort: sortBy,
          p_dir: sortDir,
          p_page: page,
          p_page_size: PAGE_SIZE,
        });
        if (cancelled) return;
        if (err) throw new Error(err.message);
        setData(resp as ListResp);
        setError(null);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [tab, reviewFilter, sourceFilter, dSearch, dateFrom, dateTo, sortBy, sortDir, page, reloadTick]);

  // ============== 樞紐資料（lazy）==============
  // 聚合直接在 DB 做（rpc_pr_supplier_pivot），前端只收各廠商的彙總結果。
  // 重入保護靠 pivotReady：抓取期間維持 false 但依賴不變，不會重複發查詢。
  useEffect(() => {
    if (viewMode !== "pivot" || pivotReady) return;
    let cancelled = false;
    (async () => {
      try {
        const { data: resp, error: err } = await getSupabase().rpc("rpc_pr_supplier_pivot", {
          p_status: tab === "all" ? null : tab,
          p_review: reviewFilter || null,
          p_source: sourceFilter || null,
          p_search: dSearch.trim() || null,
          p_date_from: dateFrom || null,
          p_date_to: dateTo || null,
          p_only_unordered: pivotOnlyUnordered,
        });
        if (cancelled) return;
        if (err) throw new Error(err.message);
        setPivotData({
          tick: pivotTick,
          groups: ((resp as { groups: PivotGroup[] } | null)?.groups ?? []),
        });
      } catch (e) {
        // 塞空陣列避免「載入中」卡死；錯誤原因由上方 error banner 呈現
        if (!cancelled) {
          setError(e instanceof Error ? e.message : String(e));
          setPivotData({ tick: pivotTick, groups: [] });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [viewMode, pivotReady, pivotTick, tab, reviewFilter, sourceFilter, dSearch, dateFrom, dateTo, pivotOnlyUnordered]);

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
          .neq("campaign_no", "__INTERNAL_RESTOCK__")
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

  // ============== 載入「結單日補單」cards ==============
  // 已建過 close_date PR、但該日仍有未請購量(delta>0)的結單日。
  // delta 邏輯全在 rpc_list_supplementable_close_dates（單一真相）。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data, error: err } = await getSupabase().rpc(
          "rpc_list_supplementable_close_dates",
        );
        if (cancelled) return;
        if (err) {
          setSupplementDates([]);
          return;
        }
        const list = ((data as SupplementableDate[] | null) ?? []).map((d) => ({
          close_date: d.close_date,
          campaign_count: Number(d.campaign_count),
          remaining_skus: Number(d.remaining_skus),
          remaining_qty: Number(d.remaining_qty),
        }));
        setSupplementDates(list);
      } catch {
        if (!cancelled) setSupplementDates([]);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick]);

  async function handleSupplement(closeDate: string) {
    setBusySuppDate(closeDate);
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: prId, error: rpcErr } = await supabase.rpc(
        "rpc_create_supplementary_pr_from_close_date",
        {
          p_close_date: closeDate,
          p_operator: userData.user?.id,
        },
      );
      if (rpcErr) throw new Error(rpcErr.message);
      router.push(`/purchase/requests/edit?id=${prId}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setBusySuppDate(null);
    }
  }

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
        .neq("campaign_no", "__INTERNAL_RESTOCK__")
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

  async function deletePr(id: number) {
    if (
      !confirm(
        `確定刪除${PR_TERM_ZH} #${id}？此動作無法復原。\n（若此單有鎖定中的團，會一併解鎖回「已結單」狀態；顧客訂單不受影響）`,
      )
    )
      return;
    setBusyId(id);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc("rpc_delete_pr", {
        p_pr_id: id,
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

  // === 統計 / 當頁資料：全部來自 rpc_pr_list，前端不再自己算 ===
  const stats = {
    pending_review: data?.kpi.pending_review ?? 0,
    to_split: data?.kpi.to_split ?? 0,
    unassigned: data?.kpi.unassigned ?? 0,
    amountInFlight: Number(data?.kpi.amount_in_flight ?? 0),
  };
  const tabCounts = data?.counts ?? EMPTY_COUNTS;
  // rows 已經是 DB 篩選 + 排序 + 分頁後的當前頁，且每列自帶進度欄位
  const pageRows = useMemo(() => data?.rows ?? [], [data]);
  const loaded = data !== null;
  const total = data?.total ?? 0;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));

  const grouped = useMemo(() => {
    if (groupBy === "none") return null;
    const map = new Map<string, { label: string; rows: (Row & Progress)[] }>();
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
          <h1 className="text-xl font-semibold">{PR_TERM_ZH}（PR）</h1>
          <p className="text-sm text-zinc-500">
            {!loaded ? (
              <Spinner size={14} className="inline-block align-[-2px]" />
            ) : (
              `共 ${tabCounts.all} 筆`
            )}
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
            {creatingBlank ? "建立中…" : `+ 空白${PR_TERM_ZH}`}
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

      {/* === 結單日補單 cards（已建單但仍有未請購量）=== */}
      {supplementDates !== null && supplementDates.length > 0 && (
        <section className="rounded-md border border-amber-200 bg-amber-50 p-4 dark:border-amber-900 dark:bg-amber-950/30">
          <h2 className="mb-1 text-sm font-semibold text-amber-900 dark:text-amber-200">
            🔁 結單日補單（{supplementDates.length}）
          </h2>
          <p className="mb-3 text-xs text-amber-800/80 dark:text-amber-300/70">
            這些結單日已建過{PR_TERM_ZH}，但仍有尚未請購的數量。補單只會帶入「新增未請購量」，原單不受影響。
          </p>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {supplementDates.map((g) => (
              <div
                key={g.close_date}
                className="rounded-md border border-amber-200 bg-white p-3 shadow-sm dark:border-amber-900 dark:bg-zinc-900"
              >
                <div className="mb-1 text-base font-semibold">
                  {g.close_date}
                </div>
                <div className="mb-2 text-xs text-zinc-500">
                  {g.campaign_count} 個團 · 尚缺 {g.remaining_skus} 個品項 · 補單量{" "}
                  {g.remaining_qty}
                </div>
                <SpinButton
                  onClick={() => handleSupplement(g.close_date)}
                  disabled={busySuppDate !== null}
                  className="flex w-full items-center justify-center rounded-md bg-amber-600 px-3 py-2 text-sm font-medium text-white hover:bg-amber-500 disabled:opacity-50"
                >
                  {busySuppDate === g.close_date ? (
                    <Spinner size={16} />
                  ) : (
                    "➕ 補單"
                  )}
                </SpinButton>
              </div>
            ))}
          </div>
        </section>
      )}

      {/* === 檢視切換：清單 / 樞紐 === */}
      <div className="flex flex-wrap items-center gap-2">
        <div className="inline-flex rounded-md border border-zinc-300 p-0.5 dark:border-zinc-700">
          <SpinButton
            onClick={() => setViewMode("list")}
            className={`rounded px-3 py-1 text-sm ${viewMode === "list" ? "bg-blue-600 font-semibold text-white" : "text-zinc-600 dark:text-zinc-300"}`}
          >
            清單
          </SpinButton>
          <SpinButton
            onClick={() => setViewMode("pivot")}
            className={`rounded px-3 py-1 text-sm ${viewMode === "pivot" ? "bg-blue-600 font-semibold text-white" : "text-zinc-600 dark:text-zinc-300"}`}
          >
            樞紐（依廠商）
          </SpinButton>
        </div>
        {viewMode === "pivot" && (
          <>
            <label className="flex cursor-pointer items-center gap-1.5 text-sm text-zinc-600 dark:text-zinc-300">
              <input
                type="checkbox"
                checked={pivotOnlyUnordered}
                onChange={(e) => setPivotOnlyUnordered(e.target.checked)}
                className="h-3.5 w-3.5 accent-amber-500"
              />
              只看未轉{PO_TERM_ZH}的品項
            </label>
            <span className="text-xs text-zinc-400">
              彙整範圍＝目前篩選出的 {total} 張{PR_TERM_ZH}（不含已作廢）
            </span>
          </>
        )}
      </div>

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
          {!loaded ? (
            <Spinner size={14} className="inline-block align-[-2px]" />
          ) : (
            `符合 ${total} 筆${total > PAGE_SIZE ? ` · 第 ${page}/${totalPages} 頁` : ""}`
          )}
        </span>
      </div>

      {viewMode === "pivot" && (
        <PrPivot groups={pivotGroups} loading={pivotLoading} onlyUnordered={pivotOnlyUnordered} />
      )}

      {/* === 主表格 === */}
      {viewMode === "list" && (
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
            {!loaded ? (
              <tr>
                <td colSpan={10}>
                  <LoadingBlock />
                </td>
              </tr>
            ) : pageRows.length === 0 ? (
              <tr>
                <td colSpan={10} className="p-6 text-center text-zinc-500">
                  {filtersActive ? `沒有符合條件的${PR_TERM_ZH}` : `尚無${PR_TERM_ZH}`}
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
                    progress={r}
                    busyId={busyId}
                    onApprove={approve}
                    onReject={reject}
                    onDelete={deletePr}
                  />
                )),
              ])
            ) : (
              pageRows.map((r) => (
                <PRRow
                  key={r.id}
                  row={r}
                  progress={r}
                  busyId={busyId}
                  onApprove={approve}
                  onReject={reject}
                  onDelete={deletePr}
                />
              ))
            )}
          </tbody>
        </table>
      </div>
      )}

      {/* === 分頁 === */}
      {viewMode === "list" && total > PAGE_SIZE && (
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
                <h3 className="text-base font-semibold">針對團購建{PR_TERM_ZH}</h3>
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
                <div className="flex justify-center py-4 text-zinc-400">
                  <Spinner size={20} />
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
                                  · 已有{PR_TERM_ZH} #{c.existing_pr_id}（補單會新建）
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
                      : `📋 建立${PR_TERM_ZH}（${selectedCampaignIds.size}）`}
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

// 樞紐：依廠商彙整篩選範圍內所有 PR 的品項，一家一張卡片。
function PrPivot({
  groups,
  loading,
  onlyUnordered,
}: {
  groups: PivotGroup[];
  loading: boolean;
  onlyUnordered: boolean;
}) {
  if (loading) {
    return (
      <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
        載入樞紐資料中…
      </div>
    );
  }
  if (groups.length === 0) {
    return (
      <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
        {onlyUnordered
          ? `目前篩選範圍內沒有「尚未轉${PO_TERM_ZH}」的品項。`
          : "目前篩選範圍內沒有品項。"}
      </div>
    );
  }
  const totQty = groups.reduce((s, g) => s + g.qty, 0);
  const totOrdered = groups.reduce((s, g) => s + g.ordered_qty, 0);
  const totAmount = groups.reduce((s, g) => s + g.amount, 0);
  return (
    <div className="flex flex-col gap-4">
      <div className="text-xs text-zinc-500">
        {groups.length} 家廠商 · 請購合計 {totQty} · 已轉單 {totOrdered} · 未轉單{" "}
        {totQty - totOrdered} · 金額 ${Math.round(totAmount).toLocaleString()}
      </div>
      {groups.map((g) => {
        const outstanding = g.qty - g.ordered_qty;
        return (
          <div
            key={g.supplier_id ?? "none"}
            className="overflow-hidden rounded-md border border-zinc-200 dark:border-zinc-800"
          >
            <div className="flex flex-wrap items-baseline justify-between gap-2 bg-zinc-50 px-3 py-2 dark:bg-zinc-900">
              <div
                className={`font-semibold ${
                  g.supplier_id === null ? "text-red-600 dark:text-red-400" : ""
                }`}
              >
                {g.supplier_name}
                <span className="ml-2 text-xs font-normal text-zinc-500">
                  {g.pr_count} 張 {PR_TERM_ZH} · {g.skus.length} 品項
                </span>
              </div>
              <div className="text-xs text-zinc-500">
                請購 {g.qty} · 已轉單 {g.ordered_qty} ·{" "}
                <span className={outstanding > 0 ? "text-amber-600 dark:text-amber-400" : ""}>
                  未轉單 {outstanding}
                </span>{" "}
                · <span className="font-mono">${Math.round(g.amount).toLocaleString()}</span>
              </div>
            </div>

            {/* 桌機：表格 */}
            <div className="hidden overflow-x-auto sm:block">
              <table className="min-w-full text-sm">
                <thead className="text-xs text-zinc-500">
                  <tr className="border-b border-zinc-200 dark:border-zinc-800">
                    <th className="px-3 py-1.5 text-left font-medium">品項</th>
                    <th className="px-3 py-1.5 text-right font-medium">請購</th>
                    <th className="px-3 py-1.5 text-right font-medium">已轉單</th>
                    <th className="px-3 py-1.5 text-right font-medium">未轉單</th>
                    <th className="px-3 py-1.5 text-right font-medium">金額</th>
                    <th className="px-3 py-1.5 text-left font-medium">來源 {PR_TERM_ZH}</th>
                  </tr>
                </thead>
                <tbody>
                  {g.skus.map((s) => {
                    const left = s.qty - s.ordered_qty;
                    return (
                      <tr key={s.sku_id} className="border-b border-zinc-100 dark:border-zinc-800/60">
                        <td className="px-3 py-1.5">{s.label}</td>
                        <td className="px-3 py-1.5 text-right font-mono">{s.qty}</td>
                        <td className="px-3 py-1.5 text-right font-mono">{s.ordered_qty}</td>
                        <td
                          className={`px-3 py-1.5 text-right font-mono ${
                            left > 0 ? "text-amber-600 dark:text-amber-400" : "text-zinc-400"
                          }`}
                        >
                          {left}
                        </td>
                        <td className="px-3 py-1.5 text-right font-mono">
                          ${Math.round(s.amount).toLocaleString()}
                        </td>
                        <td className="px-3 py-1.5 font-mono text-xs">
                          <PrLinks prs={s.prs} />
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>

            {/* 手機：每個品項一張堆疊卡片 */}
            <ul className="divide-y divide-zinc-100 sm:hidden dark:divide-zinc-800/60">
              {g.skus.map((s) => {
                const left = s.qty - s.ordered_qty;
                return (
                  <li key={s.sku_id} className="px-3 py-2">
                    <div className="text-sm">{s.label}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-x-4 gap-y-0.5 text-xs text-zinc-500">
                      <span>
                        請購{" "}
                        <span className="font-mono text-zinc-800 dark:text-zinc-200">{s.qty}</span>
                      </span>
                      <span>
                        已轉單{" "}
                        <span className="font-mono text-zinc-800 dark:text-zinc-200">
                          {s.ordered_qty}
                        </span>
                      </span>
                      <span>
                        未轉單{" "}
                        <span
                          className={`font-mono ${
                            left > 0 ? "text-amber-600 dark:text-amber-400" : "text-zinc-400"
                          }`}
                        >
                          {left}
                        </span>
                      </span>
                      <span className="font-mono">${Math.round(s.amount).toLocaleString()}</span>
                    </div>
                    <div className="mt-0.5 font-mono text-[11px] text-zinc-400">
                      {PR_TERM_ZH} <PrLinks prs={s.prs} />
                    </div>
                  </li>
                );
              })}
            </ul>
          </div>
        );
      })}
    </div>
  );
}

// 樞紐裡的來源 PR 單號清單：每個單號連到 PR 詳細頁
function PrLinks({ prs }: { prs: { id: number; pr_no: string }[] }) {
  // 同一 SKU 可能來自多張 PR；去重後照單號排序
  const entries = Array.from(new Map(prs.map((p) => [p.id, p.pr_no])).entries()).sort(
    (a, b) => a[1].localeCompare(b[1]),
  );
  return (
    <>
      {entries.map(([id, no], i) => (
        <span key={id}>
          {i > 0 && <span className="text-zinc-400">、</span>}
          <Link
            href={`/purchase/requests/edit?id=${id}`}
            className="text-blue-600 hover:underline dark:text-blue-400"
          >
            {no}
          </Link>
        </span>
      ))}
    </>
  );
}

function PRRow({
  row,
  progress,
  busyId,
  onApprove,
  onReject,
  onDelete,
}: {
  row: Row;
  progress: Progress | undefined;
  busyId: number | null;
  onApprove: (id: number) => void;
  onReject: (id: number) => void;
  onDelete: (id: number) => void;
}) {
  // 可刪：草稿/送審中/已作廢，且尚未拆出任何 PO（雙重保險）
  const canDelete =
    ["draft", "submitted", "cancelled"].includes(row.status) &&
    (!progress || progress.po_total === 0);
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
                variant="warning"
                disabled={busyId === row.id}
                onClick={() => onReject(row.id)}
              >
                退回
              </RowAction>
            </>
          )}
          {canDelete && (
            <RowAction
              variant="danger"
              disabled={busyId === row.id}
              onClick={() => onDelete(row.id)}
              title="刪除請購單（已拆 PO 的不可刪）"
            >
              刪除
            </RowAction>
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

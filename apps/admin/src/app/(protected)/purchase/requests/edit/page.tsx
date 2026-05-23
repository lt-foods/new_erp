"use client";

import { Suspense, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { PrPipelineStepper, type PrStepEvents, type POSummary, type TransferSummary } from "@/components/PrPipelineStepper";
import SpinButton from "@/components/SpinButton";
import { prStatusLabel, prReviewLabel, PR_TERM_ZH } from "@/lib/prStatus";
import { PO_TERM_ZH } from "@/lib/poStatus";

type PRHeader = {
  id: number;
  pr_no: string;
  source_type: string;
  source_close_date: string | null;
  status: string;
  review_status: string;
  total_amount: number;
  notes: string | null;
  created_by: string | null;
  created_at: string | null;
  updated_by: string | null;
  updated_at: string | null;
  submitted_at: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  review_note: string | null;
};

type DerivedPO = {
  id: number;
  po_no: string;
  status: string;
  created_at: string | null;
  created_by: string | null;
  sent_at: string | null;
  sent_by: string | null;
  sent_channel: string | null;
};

type Supplier = { id: number; name: string };

type ItemRow = {
  id: number;
  sku_id: number;
  sku_code: string;
  product_name: string;
  variant_name: string | null;
  unit_uom: string | null;
  qty_requested: number;
  unit_cost: number;
  line_subtotal: number;
  suggested_supplier_id: number | null;
  source_campaign_id: number | null;
  retail_price: number | null;     // PR snapshot，可手動覆寫
  franchise_price: number | null;  // PR snapshot，可手動覆寫
  purchased_so_far: number;        // 同 (campaign, sku) 在其他已通過 PR 的累積採購量
  dirty: boolean;
};

const STATUS_LABEL = prStatusLabel;
const REVIEW_LABEL = prReviewLabel;

export default function EditPurchaseRequestPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PageContent />
    </Suspense>
  );
}

function PageContent() {
  const router = useRouter();
  const params = useSearchParams();
  const idStr = params.get("id");
  const id = idStr ? Number(idStr) : null;

  const [header, setHeader] = useState<PRHeader | null>(null);
  const [items, setItems] = useState<ItemRow[]>([]);
  const [derivedPOs, setDerivedPOs] = useState<DerivedPO[]>([]);
  const [campaignFinalized, setCampaignFinalized] = useState<boolean>(false);
  const [transferSummary, setTransferSummary] = useState<TransferSummary | undefined>(undefined);
  const [staffNames, setStaffNames] = useState<Map<string, string>>(new Map());
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  // 廠商被指派的次數（v_supplier_usage_count），用來把常用排在下拉前面
  const [supplierUsage, setSupplierUsage] = useState<Map<number, number>>(new Map());
  const [missingCampaigns, setMissingCampaigns] = useState<{ id: number; name: string; campaign_no: string }[]>([]);
  const [appending, setAppending] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<"save" | "submit" | "split" | "reopen" | null>(null);
  const [destLocationId, setDestLocationId] = useState<number | null>(null);

  useEffect(() => {
    if (!id) {
      setLoading(false);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const supabase = getSupabase();

        const [
          { data: prData, error: prErr },
          { data: itemRows, error: itemErr },
          { data: supRows },
          { data: usageRows },
          { data: locRow },
        ] = await Promise.all([
          supabase
            .from("purchase_requests")
            .select(
              "id, pr_no, source_type, source_close_date, status, review_status, total_amount, notes, source_location_id, created_by, created_at, updated_by, updated_at, submitted_at, reviewed_by, reviewed_at, review_note",
            )
            .eq("id", id)
            .maybeSingle(),
          supabase
            .from("purchase_request_items")
            .select(
              "id, sku_id, qty_requested, unit_cost, line_subtotal, suggested_supplier_id, source_campaign_id, retail_price, franchise_price, po_item_id",
            )
            .eq("pr_id", id)
            .order("id"),
          supabase.from("suppliers").select("id, name").eq("is_active", true).order("name"),
          supabase.from("v_supplier_usage_count").select("supplier_id, usage_count"),
          supabase.from("locations").select("id").order("id").limit(1).maybeSingle(),
        ]);

        if (cancelled) return;
        if (prErr || !prData) throw new Error(prErr?.message ?? `找不到${PR_TERM_ZH}`);
        if (itemErr) throw new Error(itemErr.message);

        setHeader(prData as PRHeader);
        setSuppliers((supRows ?? []) as Supplier[]);
        {
          const m = new Map<number, number>();
          for (const u of ((usageRows ?? []) as { supplier_id: number; usage_count: number }[])) {
            m.set(u.supplier_id, Number(u.usage_count));
          }
          setSupplierUsage(m);
        }
        setDestLocationId(prData.source_location_id ?? locRow?.id ?? null);

        // 抓拆出的 PO（透過 PR items 反查）
        const itemIds = (itemRows ?? [])
          .map((r) => r.po_item_id)
          .filter((x): x is number => x !== null && x !== undefined);
        if (itemIds.length) {
          const { data: poiRows } = await supabase
            .from("purchase_order_items")
            .select("po_id")
            .in("id", itemIds);
          const poIds = Array.from(
            new Set((poiRows ?? []).map((r) => r.po_id).filter((x): x is number => !!x)),
          );
          if (poIds.length) {
            const { data: pos } = await supabase
              .from("purchase_orders")
              .select("id, po_no, status, created_at, created_by, sent_at, sent_by, sent_channel")
              .in("id", poIds)
              .order("id");
            setDerivedPOs((pos ?? []) as DerivedPO[]);
          }
        }

        // 從 v_pr_progress 讀 transfer 進度（與 PR / PO list 共用同一個 source of truth）
        {
          const { data: prog } = await supabase
            .from("v_pr_progress")
            .select("transfer_total, transfer_shipped, transfer_delivered")
            .eq("pr_id", id)
            .maybeSingle();
          if (!cancelled && prog) {
            setTransferSummary({
              total: Number(prog.transfer_total),
              shipped: Number(prog.transfer_shipped),
              delivered: Number(prog.transfer_delivered),
            });
          }
        }

        // 查 source campaigns（for 結算狀態）
        const campIds = Array.from(
          new Set((itemRows ?? []).map((r) => r.source_campaign_id).filter((x): x is number => !!x)),
        );
        if (campIds.length) {
          const { data: camps } = await supabase
            .from("group_buy_campaigns")
            .select("id, status")
            .in("id", campIds);
          const allCompleted =
            (camps ?? []).length > 0 && (camps ?? []).every((c) => c.status === "completed");
          setCampaignFinalized(allCompleted);
        }

        // 偵測同 close_date 缺漏 campaign（PR 為 close_date 來源 + draft 才有意義）
        if (prData.source_type === "close_date" && prData.source_close_date && prData.status === "draft") {
          const { data: closedCamps } = await supabase
            .from("group_buy_campaigns")
            .select("id, name, campaign_no, end_at")
            .eq("status", "closed");
          const inPR = new Set(campIds);
          const candidates = (closedCamps ?? []).filter((c) => {
            if (!c.end_at) return false;
            const d = new Date(c.end_at).toLocaleDateString("sv-SE");
            return d === prData.source_close_date && !inPR.has(c.id);
          });
          // 進一步：只列有顧客訂單的（無訂單併入也沒意義）
          const candidateIds = candidates.map((c) => c.id);
          if (candidateIds.length) {
            const { data: demandRows } = await supabase
              .from("customer_orders")
              .select("campaign_id, customer_order_items!inner(qty, status)")
              .in("campaign_id", candidateIds)
              .not("status", "in", "(cancelled,expired)");
            type DemandRow = {
              campaign_id: number;
              customer_order_items: { qty: number; status: string }[] | { qty: number; status: string };
            };
            const hasDemand = new Set<number>();
            for (const r of (demandRows as DemandRow[] | null) ?? []) {
              const its = Array.isArray(r.customer_order_items)
                ? r.customer_order_items
                : [r.customer_order_items];
              if (its.some((i) => !["cancelled", "expired"].includes(i.status) && Number(i.qty) > 0)) {
                hasDemand.add(r.campaign_id);
              }
            }
            const filtered = candidates.filter((c) => hasDemand.has(c.id));
            setMissingCampaigns(filtered.map((c) => ({ id: c.id, name: c.name, campaign_no: c.campaign_no })));
          } else {
            setMissingCampaigns([]);
          }
        }

        // 查 staff names（用於 timeline 顯示誰做的）
        const allUids = new Set<string>();
        if (prData.created_by) allUids.add(prData.created_by);
        if (prData.updated_by) allUids.add(prData.updated_by);
        if (prData.reviewed_by) allUids.add(prData.reviewed_by);
        for (const r of itemRows ?? []) {
          // PR items 沒有 by 欄位，這裡留空，未來若有需要再加
          void r;
        }
        if (allUids.size) {
          const { data: names } = await supabase.rpc("rpc_get_staff_names", {
            p_uids: Array.from(allUids),
          });
          const m = new Map<string, string>();
          for (const n of (names as { id: string; display_name: string }[] | null) ?? []) {
            m.set(n.id, n.display_name);
          }
          setStaffNames(m);
        }

        const skuIds = (itemRows ?? []).map((r) => r.sku_id);
        if (skuIds.length === 0) {
          setItems([]);
          return;
        }

        // 一次撈 SKU + product 資訊
        const { data: skuRows } = await supabase
          .from("skus")
          .select(
            "id, sku_code, variant_name, base_unit, products!inner(name)",
          )
          .in("id", skuIds);

        const skuMap = new Map(
          (skuRows ?? []).map((s) => {
            const prod = Array.isArray(s.products) ? s.products[0] : s.products;
            return [
              s.id,
              {
                sku_code: s.sku_code as string,
                variant_name: s.variant_name as string | null,
                product_name: prod?.name as string | null,
                unit_uom: (s.base_unit as string | null) ?? null,
              },
            ];
          }),
        );

        // 一次撈 SKU 目前的 cost / retail / branch 三種價格（用於補空欄）
        const { data: priceRows } = await supabase
          .from("prices")
          .select("sku_id, scope, price")
          .in("sku_id", skuIds)
          .in("scope", ["cost", "retail", "branch"])
          .is("effective_to", null);
        const priceMap = new Map<number, { cost?: number; retail?: number; branch?: number }>();
        for (const p of (priceRows ?? []) as { sku_id: number; scope: string; price: number }[]) {
          const slot = priceMap.get(p.sku_id) ?? {};
          if (p.scope === "cost" && slot.cost === undefined) slot.cost = Number(p.price);
          if (p.scope === "retail" && slot.retail === undefined) slot.retail = Number(p.price);
          if (p.scope === "branch" && slot.branch === undefined) slot.branch = Number(p.price);
          priceMap.set(p.sku_id, slot);
        }

        // 拉「該 PR 各 (campaign, sku) 在其他已通過 PR 已採購過多少」
        const { data: purchasedRows } = await supabase
          .from("v_pr_purchased_history")
          .select("campaign_id, sku_id, purchased_so_far")
          .eq("current_pr_id", id);
        // 同一 sku 可能有多 campaign、加總（避免漏算）
        const purchasedMap = new Map<number, number>();
        for (const p of (purchasedRows as { campaign_id: number; sku_id: number; purchased_so_far: number }[] | null) ?? []) {
          purchasedMap.set(p.sku_id, (purchasedMap.get(p.sku_id) ?? 0) + Number(p.purchased_so_far));
        }

        const merged: ItemRow[] = (itemRows ?? []).map((r) => {
          const m = skuMap.get(r.sku_id);
          const sp = priceMap.get(r.sku_id) ?? {};
          // PR 既有值優先；空 / 0 fallback 到 SKU 現行價（unit_cost 是 NOT NULL，0 視為未填）
          const prCost = Number(r.unit_cost);
          const cost = prCost > 0 ? prCost : (sp.cost ?? 0);
          const retail = r.retail_price !== null && r.retail_price !== undefined
            ? Number(r.retail_price)
            : (sp.retail ?? null);
          const branch = r.franchise_price !== null && r.franchise_price !== undefined
            ? Number(r.franchise_price)
            : (sp.branch ?? null);
          // 若 fallback 改了任一價、line_subtotal 重算
          const qty = Number(r.qty_requested);
          const subtotal = cost > 0 ? qty * cost : Number(r.line_subtotal ?? 0);
          const usedFallback = prCost === 0 && (sp.cost ?? 0) > 0
            || (r.retail_price === null && sp.retail !== undefined)
            || (r.franchise_price === null && sp.branch !== undefined);
          return {
            id: r.id,
            sku_id: r.sku_id,
            sku_code: m?.sku_code ?? "?",
            product_name: m?.product_name ?? "?",
            variant_name: m?.variant_name ?? null,
            unit_uom: m?.unit_uom ?? null,
            qty_requested: qty,
            unit_cost: cost,
            line_subtotal: subtotal,
            suggested_supplier_id: r.suggested_supplier_id,
            source_campaign_id: r.source_campaign_id,
            retail_price: retail,
            franchise_price: branch,
            purchased_so_far: purchasedMap.get(r.sku_id) ?? 0,
            // 若用了 fallback、標 dirty 讓 UI 提示「儲存後 PR 留紀錄」
            dirty: usedFallback,
          };
        });

        // 依 sku_code 排序，讓同商品（同 G00022-* prefix）的不同規格相鄰；
        // numeric:true 確保 G00018-10 排在 G00018-2 之後而不是字典序排前面
        merged.sort((a, b) =>
          a.sku_code.localeCompare(b.sku_code, undefined, { numeric: true, sensitivity: "base" }),
        );

        setItems(merged);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id]);

  const editable = header?.status === "draft";
  const canSplit =
    header?.status === "submitted" && header?.review_status === "approved";
  const canReopen = header?.status === "submitted";

  const totals = useMemo(() => {
    const subtotal = items.reduce((s, r) => s + r.qty_requested * r.unit_cost, 0);
    return { subtotal, withTax: subtotal * 1.05 };
  }, [items]);

  const unassignedCount = items.filter((r) => !r.suggested_supplier_id).length;

  function patchItem(idx: number, patch: Partial<ItemRow>) {
    setItems((cur) =>
      cur.map((r, i) => {
        if (i !== idx) return r;
        const next = { ...r, ...patch, dirty: true };
        next.line_subtotal = next.qty_requested * next.unit_cost;
        return next;
      }),
    );
  }

  function removeItem(idx: number) {
    setItems((cur) => cur.filter((_, i) => i !== idx));
  }

  async function saveDraft() {
    if (!id) return;
    setBusy("save");
    setError(null);
    try {
      const supabase = getSupabase();
      const dirtyRows = items.filter((r) => r.dirty);
      for (const r of dirtyRows) {
        const { error: err } = await supabase
          .from("purchase_request_items")
          .update({
            qty_requested: r.qty_requested,
            unit_cost: r.unit_cost,
            suggested_supplier_id: r.suggested_supplier_id,
            retail_price: r.retail_price,
            franchise_price: r.franchise_price,
          })
          .eq("id", r.id);
        if (err) throw new Error(err.message);
      }
      // notes
      if (header) {
        const { error: hErr } = await supabase
          .from("purchase_requests")
          .update({ notes: header.notes })
          .eq("id", id);
        if (hErr) throw new Error(hErr.message);
      }
      setItems((cur) => cur.map((r) => ({ ...r, dirty: false })));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  async function submitForReview() {
    if (!id) return;
    // 送審前驗：每行必須填妥成本 / 分店價 / 售價 + 數量 + 供應商
    // 並且要符合 成本 < 分店價 < 售價 三段遞增關係
    const incomplete: string[] = [];
    const priceIssues: string[] = [];
    for (const r of items) {
      const issues: string[] = [];
      if (!r.qty_requested || r.qty_requested <= 0) issues.push("數量");
      if (!r.unit_cost || r.unit_cost <= 0) issues.push("成本");
      if (r.franchise_price === null || r.franchise_price === undefined) issues.push("分店價");
      if (r.retail_price === null || r.retail_price === undefined) issues.push("售價");
      if (!r.suggested_supplier_id) issues.push("供應商");
      if (issues.length > 0) {
        incomplete.push(`${r.sku_code}：${issues.join("、")}`);
        continue;
      }
      const cost = Number(r.unit_cost);
      const branch = Number(r.franchise_price);
      const retail = Number(r.retail_price);
      if (!(cost < branch && branch < retail)) {
        priceIssues.push(`${r.sku_code}：成本 $${cost} / 分店價 $${branch} / 售價 $${retail}`);
      }
    }
    if (incomplete.length > 0) {
      setError(`送審前需補完所有欄位：\n${incomplete.join("\n")}`);
      return;
    }
    if (priceIssues.length > 0) {
      setError(`價格必須符合 成本 < 分店價 < 售價：\n${priceIssues.join("\n")}`);
      return;
    }
    if (!confirm("確定送出審核？")) {
      return;
    }
    await saveDraft();
    setBusy("submit");
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc("rpc_submit_pr", {
        p_pr_id: id,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      // refresh header
      const { data } = await supabase
        .from("purchase_requests")
        .select("status, review_status, total_amount")
        .eq("id", id)
        .maybeSingle();
      if (data && header) {
        setHeader({ ...header, ...(data as Partial<PRHeader>) });
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  async function reopenToDraft() {
    if (!id) return;
    if (!confirm("確定退回草稿？退回後可重新編輯品項與供應商，需再次送審。")) return;
    setBusy("reopen");
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc("rpc_pr_reopen", {
        p_pr_id: id,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      window.location.reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setBusy(null);
    }
  }

  async function appendMissing() {
    if (!id || missingCampaigns.length === 0) return;
    if (
      !confirm(
        `要把 ${missingCampaigns.length} 個同日結單但未納入的團（${missingCampaigns
          .map((c) => c.campaign_no)
          .join(", ")}）併入本${PR_TERM_ZH}嗎？`,
      )
    )
      return;
    setAppending(true);
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      for (const c of missingCampaigns) {
        const { error: rpcErr } = await supabase.rpc("rpc_append_campaign_to_pr", {
          p_pr_id: id,
          p_campaign_id: c.id,
          p_operator: userData.user?.id,
        });
        if (rpcErr) throw new Error(`${c.campaign_no}: ${rpcErr.message}`);
      }
      // reload page
      window.location.reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setAppending(false);
    }
  }

  async function splitToPos() {
    if (!id || !destLocationId) return;
    if (unassignedCount > 0) {
      setError(`有 ${unassignedCount} 行未指派供應商，無法拆 PO`);
      return;
    }
    if (!confirm(`確定建立${PO_TERM_ZH}？建立後可逐一發給各供應商。`)) return;
    setBusy("split");
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: poIds, error: rpcErr } = await supabase.rpc("rpc_split_pr_to_pos", {
        p_pr_id: id,
        p_dest_location_id: destLocationId,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      alert(`已產生 ${(poIds as number[]).length} 張${PO_TERM_ZH}`);
      router.push("/purchase/orders");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  if (!id) {
    return (
      <div className="p-6 text-sm text-zinc-500">
        缺少 id 參數。請從 <Link href="/purchase/requests" className="text-blue-600 underline">{PR_TERM_ZH}列表</Link> 進入。
      </div>
    );
  }

  if (loading) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  if (!header) return <div className="p-6 text-sm text-red-600">{error ?? `找不到${PR_TERM_ZH}`}</div>;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">
            {PR_TERM_ZH} {header.pr_no}
            <span className="ml-3 inline-block rounded bg-zinc-100 px-2 py-0.5 text-xs font-normal dark:bg-zinc-800">
              {STATUS_LABEL(header.status)}
            </span>
            <span
              className={`ml-2 inline-block rounded px-2 py-0.5 text-xs font-normal ${
                header.review_status === "pending_review"
                  ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                  : header.review_status === "rejected"
                    ? "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300"
                    : "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
              }`}
            >
              {REVIEW_LABEL(header.review_status)}
            </span>
          </h1>
          <p className="text-sm text-zinc-500">
            結單日：{header.source_close_date ?? "—"}　·　共 {items.length} 項
            {unassignedCount > 0 && (
              <span className="ml-2 text-red-600 dark:text-red-400">⚠ {unassignedCount} 行未指派供應商</span>
            )}
          </p>
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* Timeline stepper（hover 顯示誰+何時）*/}
      <div className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
        <PrPipelineStepper
          status={header.status}
          reviewStatus={header.review_status}
          events={buildEvents(header, derivedPOs, staffNames)}
          poSummary={computePOSummary(derivedPOs)}
          transferSummary={transferSummary}
          campaignFinalized={campaignFinalized}
        />
      </div>

      {/* 左右兩欄：左 280px 工具/摘要/動作/備註，右側為採購清單表 */}
      <div className="grid gap-4 md:grid-cols-[280px_1fr]">
        <aside className="flex flex-col gap-4">
          {/* 摘要卡片 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">摘要</h3>
            <dl className="space-y-2 text-sm">
              <Row label="品項數">{items.length}</Row>
              <Row label="供應商">
                {new Set(items.map((r) => r.suggested_supplier_id).filter(Boolean)).size}
              </Row>
              <Row label="未指派">
                {unassignedCount > 0 ? (
                  <span className="text-red-600 dark:text-red-400">{unassignedCount}</span>
                ) : (
                  0
                )}
              </Row>
              <div className="my-2 border-t border-zinc-200 dark:border-zinc-700" />
              <Row label="未稅小計">${totals.subtotal.toFixed(1)}</Row>
              <Row label="含稅總計">
                <span className="text-lg font-semibold text-blue-600 dark:text-blue-400">
                  ${totals.withTax.toFixed(1)}
                </span>
              </Row>
            </dl>
          </section>

          {/* 動作卡片 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">動作</h3>
            <div className="flex flex-col gap-2">
              <Link
                href={`/purchase/requests/print?id=${id}`}
                target="_blank"
                rel="noopener"
                className="rounded-md border border-zinc-300 px-3 py-2 text-center text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                🖨 列印
              </Link>
              {editable && (
                <>
                  <SpinButton
                    onClick={saveDraft}
                    disabled={busy !== null}
                    className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                  >
                    {busy === "save" ? "存檔中…" : "💾 存為草稿"}
                  </SpinButton>
                  <SpinButton
                    onClick={submitForReview}
                    disabled={busy !== null}
                    className="rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500 disabled:opacity-50"
                  >
                    {busy === "submit" ? "送審中…" : "📤 送出審核"}
                  </SpinButton>
                </>
              )}
              {canSplit && (
                <SpinButton
                  onClick={splitToPos}
                  disabled={busy !== null || unassignedCount > 0}
                  className="rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-50"
                  title={unassignedCount > 0 ? "有未指派供應商" : ""}
                >
                  {busy === "split" ? "建立中…" : `📦 建立${PO_TERM_ZH}`}
                </SpinButton>
              )}
              {canReopen && (
                <SpinButton
                  onClick={reopenToDraft}
                  disabled={busy !== null}
                  className="rounded-md border border-amber-400 px-3 py-2 text-sm font-medium text-amber-700 hover:bg-amber-50 disabled:opacity-50 dark:border-amber-700 dark:text-amber-400 dark:hover:bg-amber-950"
                  title="退回草稿以重新編輯"
                >
                  {busy === "reopen" ? "退回中…" : "↩ 退回草稿"}
                </SpinButton>
              )}
              {!editable && !canSplit && !canReopen && (
                <p className="text-xs text-zinc-500">此{PR_TERM_ZH}已 {STATUS_LABEL(header.status)}，無可用動作。</p>
              )}
            </div>
          </section>

          {/* 備註卡片 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">備註</h3>
            <textarea
              value={header.notes ?? ""}
              onChange={(e) => setHeader({ ...header, notes: e.target.value })}
              disabled={!editable}
              rows={4}
              placeholder="(選填)…"
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800"
            />
          </section>
        </aside>

        {/* 右側採購清單 */}
        <div className="flex flex-col rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-2 dark:border-zinc-800">
            <h3 className="text-sm font-semibold">📋 內部採購清單</h3>
            <span className="text-xs text-zinc-500">
              *成本=廠商給的價格，售價=ERP 商品價格
            </span>
          </div>
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>#</Th>
              <Th>品名</Th>
              <Th>供應商</Th>
              <Th>單位</Th>
              <Th className="text-right">已採購</Th>
              <Th className="text-right">數量</Th>
              <Th className="text-right">成本</Th>
              <Th className="text-right">分店價</Th>
              <Th className="text-right">售價</Th>
              <Th className="text-right">小計</Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {items.length === 0 ? (
              <tr>
                <td colSpan={11} className="p-6 text-center text-zinc-500">
                  {header?.source_type === "manual" ? (
                    <div className="space-y-1">
                      <div>無品項</div>
                      <div className="text-xs text-amber-600 dark:text-amber-400">
                        ⚠️ 手動加列 UI 尚未實作；目前空白 PR 僅可觀察 / 取消，加列功能跟隨 PR 將補上
                      </div>
                    </div>
                  ) : (
                    "無品項"
                  )}
                </td>
              </tr>
            ) : (
              items.map((r, idx) => {
                // 成本 < 分店價 < 售價 必須遞增，三值有任一缺則不檢查（送審前才擋）
                const cost = Number(r.unit_cost);
                const branch = r.franchise_price != null ? Number(r.franchise_price) : null;
                const retail = r.retail_price != null ? Number(r.retail_price) : null;
                const priceBad =
                  cost > 0 && branch != null && retail != null && !(cost < branch && branch < retail);
                const cellWarn = priceBad
                  ? "border-rose-400 bg-rose-50 dark:border-rose-700 dark:bg-rose-950"
                  : "border-zinc-300 dark:border-zinc-700";
                return (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="text-zinc-500">{idx + 1}</Td>
                  <Td>
                    <div>{r.product_name}{r.variant_name ? `-${r.variant_name}` : ""}</div>
                    <div className="font-mono text-xs text-zinc-500">{r.sku_code}</div>
                    {priceBad && (
                      <div className="mt-0.5 text-[11px] font-medium text-rose-600 dark:text-rose-400">
                        ⚠ 成本 &lt; 分店價 &lt; 售價 順序錯
                      </div>
                    )}
                  </Td>
                  <Td>
                    {editable ? (
                      <SupplierPicker
                        value={r.suggested_supplier_id}
                        suppliers={suppliers}
                        usage={supplierUsage}
                        onChange={(id) =>
                          patchItem(idx, { suggested_supplier_id: id })
                        }
                      />
                    ) : (
                      suppliers.find((s) => s.id === r.suggested_supplier_id)?.name ?? "—"
                    )}
                  </Td>
                  <Td className="text-zinc-500">{r.unit_uom ?? "—"}</Td>
                  <Td className="text-right">
                    {r.purchased_so_far > 0 ? (
                      <span className="font-mono text-amber-600 dark:text-amber-400" title="此品項在同團購的其他已通過 PR 已採購過">
                        {r.purchased_so_far}
                      </span>
                    ) : (
                      <span className="text-zinc-300">—</span>
                    )}
                  </Td>
                  <Td className="text-right">
                    {editable ? (
                      <input
                        type="number"
                        step="1"
                        value={r.qty_requested}
                        onChange={(e) => patchItem(idx, { qty_requested: Number(e.target.value) })}
                        className="w-24 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                      />
                    ) : (
                      r.qty_requested
                    )}
                  </Td>
                  <Td className="text-right">
                    {editable ? (
                      <input
                        type="number"
                        step="1"
                        value={r.unit_cost}
                        onChange={(e) => patchItem(idx, { unit_cost: Number(e.target.value) })}
                        className={`w-24 rounded-md border bg-white px-2 py-1 text-right text-sm dark:bg-zinc-800 ${cellWarn}`}
                      />
                    ) : (
                      r.unit_cost.toFixed(4)
                    )}
                  </Td>
                  <Td className="text-right">
                    {editable ? (
                      <input
                        type="number"
                        step="1"
                        value={r.franchise_price ?? ""}
                        onChange={(e) =>
                          patchItem(idx, {
                            franchise_price: e.target.value === "" ? null : Number(e.target.value),
                          })
                        }
                        className={`w-20 rounded-md border bg-white px-2 py-1 text-right text-sm dark:bg-zinc-800 ${cellWarn}`}
                      />
                    ) : r.franchise_price !== null ? (
                      `$${r.franchise_price.toFixed(0)}`
                    ) : (
                      "—"
                    )}
                  </Td>
                  <Td className="text-right">
                    {editable ? (
                      <input
                        type="number"
                        step="1"
                        value={r.retail_price ?? ""}
                        onChange={(e) =>
                          patchItem(idx, {
                            retail_price: e.target.value === "" ? null : Number(e.target.value),
                          })
                        }
                        className={`w-20 rounded-md border bg-white px-2 py-1 text-right text-sm dark:bg-zinc-800 ${cellWarn}`}
                      />
                    ) : r.retail_price !== null ? (
                      `$${r.retail_price.toFixed(0)}`
                    ) : (
                      "—"
                    )}
                  </Td>
                  <Td className="text-right font-mono">
                    ${(r.qty_requested * r.unit_cost).toFixed(0)}
                  </Td>
                  <Td>
                    {editable && (
                      <SpinButton
                        onClick={() => removeItem(idx)}
                        className="text-xs text-red-600 hover:underline dark:text-red-400"
                      >
                        ✕
                      </SpinButton>
                    )}
                  </Td>
                </tr>
                );
              })
            )}
          </tbody>
        </table>
          </div>
        </div>
      </div>
    </div>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-zinc-500">{label}</dt>
      <dd className="font-mono">{children}</dd>
    </div>
  );
}

function fmtTime(iso: string | null): string | null {
  if (!iso) return null;
  return new Date(iso).toLocaleString("zh-TW", { hour12: false });
}
function nameOf(uid: string | null, names: Map<string, string>): string | null {
  if (!uid) return null;
  return names.get(uid) ?? uid.slice(0, 8);
}

function buildEvents(
  header: PRHeader,
  pos: DerivedPO[],
  names: Map<string, string>,
): PrStepEvents {
  const evt: PrStepEvents = {};
  const prHref = `/purchase/requests/edit?id=${header.id}`;
  evt.create = {
    actor: nameOf(header.created_by, names),
    time: fmtTime(header.created_at),
    detail: header.pr_no,
    href: prHref,
  };
  evt.draft = {
    actor: nameOf(header.updated_by, names),
    time: fmtTime(header.updated_at),
    href: prHref,
  };
  if (header.submitted_at) {
    evt.submit = {
      actor: nameOf(header.updated_by, names),
      time: fmtTime(header.submitted_at),
      href: prHref,
    };
  }
  if (header.reviewed_at) {
    evt.review = {
      actor: nameOf(header.reviewed_by, names),
      time: fmtTime(header.reviewed_at),
      detail: header.review_note ?? null,
      href: prHref,
    };
  }
  if (pos.length > 0) {
    const first = pos[0];
    evt.split = {
      actor: nameOf(first.created_by, names),
      time: fmtTime(first.created_at),
      detail: `${pos.length} 張 PO：${pos.map((p) => p.po_no).join(", ")}`,
      href: pos.length === 1 ? `/purchase/orders/edit?id=${pos[0].id}` : `/purchase/orders`,
    };
  }
  // S6 發送供應商
  const sentPOs = pos.filter((p) =>
    ["sent", "partially_received", "fully_received", "closed"].includes(p.status),
  );
  if (sentPOs.length > 0) {
    const earliest = sentPOs
      .filter((p) => p.sent_at)
      .sort((a, b) => (a.sent_at ?? "").localeCompare(b.sent_at ?? ""))[0];
    if (earliest) {
      evt.send = {
        actor: nameOf(earliest.sent_by, names),
        time: fmtTime(earliest.sent_at),
        detail: `${sentPOs.length}/${pos.length} 張已發送`,
        href: pos.length === 1 ? `/purchase/orders/edit?id=${pos[0].id}` : `/purchase/orders`,
      };
    }
  }
  // S7 收貨
  const receivedFully = pos.filter((p) =>
    ["fully_received", "closed"].includes(p.status),
  );
  if (receivedFully.length > 0) {
    evt.receive = {
      detail: `${receivedFully.length}/${pos.length} 張全部到貨`,
      href: pos.length === 1 ? `/purchase/orders/edit?id=${pos[0].id}` : `/purchase/orders`,
    };
  }
  // S8 派貨 / S9 分店確認 — 顯示配送日
  if (header.source_close_date) {
    evt.ship = {
      detail: `配送 ${header.source_close_date}`,
      href: `/wms/picking/history`,
    };
    evt.delivered = { detail: `配送 ${header.source_close_date}` };
  }
  return evt;
}

export function computePOSummary(pos: DerivedPO[]): POSummary {
  let sent = 0;
  let receivedFully = 0;
  for (const p of pos) {
    if (["sent", "partially_received", "fully_received", "closed"].includes(p.status)) sent++;
    if (["fully_received", "closed"].includes(p.status)) receivedFully++;
  }
  return { total: pos.length, sent, receivedFully };
}

function Th({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
  return (
    <th
      className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}
    >
      {children}
    </th>
  );
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-3 py-2 ${className}`}>{children}</td>;
}

// 廠商選擇 combobox：拼音排序 + 常用 (usage >0) 釘在前面 + 即時搜尋
// 用顯式 -u-co-pinyin Unicode extension 強制拼音 collation，避免 zh-TW
// 在不同瀏覽器 fallback 到筆畫
const pinyinCollator = new Intl.Collator("zh-Hans-CN-u-co-pinyin");

function SupplierPicker({
  value,
  suppliers,
  usage,
  onChange,
}: {
  value: number | null;
  suppliers: Supplier[];
  usage: Map<number, number>;
  onChange: (id: number | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const rootRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // 點外面關閉
  useEffect(() => {
    if (!open) return;
    function onDocClick(e: MouseEvent) {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener("mousedown", onDocClick);
    return () => document.removeEventListener("mousedown", onDocClick);
  }, [open]);

  // 開啟時自動聚焦搜尋框
  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  const selected = suppliers.find((s) => s.id === value) ?? null;

  // 排序：usage desc → 拼音 asc
  const sorted = useMemo(() => {
    return [...suppliers].sort((a, b) => {
      const ua = usage.get(a.id) ?? 0;
      const ub = usage.get(b.id) ?? 0;
      if (ub !== ua) return ub - ua;
      return pinyinCollator.compare(a.name, b.name);
    });
  }, [suppliers, usage]);

  // 搜尋：name 包含關鍵字（忽略大小寫，中文 includes 直接比就行）
  const filtered = useMemo(() => {
    const kw = search.trim().toLowerCase();
    if (!kw) return sorted;
    return sorted.filter((s) => s.name.toLowerCase().includes(kw));
  }, [sorted, search]);

  // 分區：常用 (usage>0) vs 其餘；搜尋時不分區
  const { topUsed, rest } = useMemo(() => {
    if (search.trim()) return { topUsed: [] as Supplier[], rest: filtered };
    const top: Supplier[] = [];
    const others: Supplier[] = [];
    for (const s of filtered) {
      if ((usage.get(s.id) ?? 0) > 0) top.push(s);
      else others.push(s);
    }
    return { topUsed: top, rest: others };
  }, [filtered, usage, search]);

  function pick(id: number | null) {
    onChange(id);
    setOpen(false);
    setSearch("");
  }

  return (
    <div className="relative" ref={rootRef}>
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className={`flex w-full min-w-[8rem] items-center justify-between rounded-md border px-2 py-1 text-left text-sm ${
          !value
            ? "border-red-300 bg-red-50 dark:border-red-800 dark:bg-red-950"
            : "border-zinc-300 dark:border-zinc-700"
        } bg-white dark:bg-zinc-800`}
      >
        <span className="truncate">{selected?.name ?? "— 未指派 —"}</span>
        <span className="ml-2 text-zinc-400">▾</span>
      </button>
      {open && (
        <div className="absolute z-30 mt-1 max-h-80 w-56 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
          <div className="sticky top-0 z-10 border-b border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <input
              ref={inputRef}
              type="search"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="搜尋廠商"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </div>
          <button
            type="button"
            onClick={() => pick(null)}
            className="block w-full px-3 py-1.5 text-left text-sm text-zinc-500 hover:bg-zinc-50 dark:hover:bg-zinc-950"
          >
            — 未指派 —
          </button>
          {topUsed.length > 0 && (
            <>
              <div className="px-3 py-1 text-[10px] font-medium uppercase tracking-wide text-zinc-400">
                常用
              </div>
              {topUsed.map((s) => (
                <SupplierOption
                  key={s.id}
                  s={s}
                  usage={usage.get(s.id) ?? 0}
                  selected={s.id === value}
                  onPick={pick}
                />
              ))}
              {rest.length > 0 && (
                <div className="mt-1 border-t border-zinc-100 px-3 py-1 text-[10px] font-medium uppercase tracking-wide text-zinc-400 dark:border-zinc-800">
                  全部
                </div>
              )}
            </>
          )}
          {rest.map((s) => (
            <SupplierOption
              key={s.id}
              s={s}
              usage={usage.get(s.id) ?? 0}
              selected={s.id === value}
              onPick={pick}
            />
          ))}
          {filtered.length === 0 && (
            <div className="px-3 py-4 text-center text-xs text-zinc-500">
              找不到符合的廠商
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function SupplierOption({
  s,
  usage,
  selected,
  onPick,
}: {
  s: Supplier;
  usage: number;
  selected: boolean;
  onPick: (id: number) => void;
}) {
  return (
    <button
      type="button"
      onClick={() => onPick(s.id)}
      className={`flex w-full items-center justify-between px-3 py-1.5 text-left text-sm hover:bg-zinc-50 dark:hover:bg-zinc-950 ${
        selected ? "bg-blue-50 font-medium dark:bg-blue-950" : ""
      }`}
    >
      <span className="truncate">{s.name}</span>
      {usage > 0 && (
        <span className="ml-2 shrink-0 text-[10px] text-zinc-400">×{usage}</span>
      )}
    </button>
  );
}

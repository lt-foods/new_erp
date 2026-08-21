"use client";

import Link from "next/link";
import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { PR_TERM_ZH } from "@/lib/prStatus";
import SpinButton from "@/components/SpinButton";
import { DatePicker } from "@/components/DatePicker";
import { RowAction } from "@/components/RowAction";
import { OrderDetail } from "@/components/OrderDetail";
import { Modal } from "@/components/Modal";
import { AidOrderStatusActions } from "@/components/AidOrderStatusActions";
import { PickModal, type PickWave } from "@/components/PickModal";
import ExceptionsContent from "@/components/ExceptionsContent";
import TransferDetailModal from "@/components/TransferDetailModal";
import { parseWaveId } from "@/components/TransferReceiveModal";
import RestockDetailModal from "@/components/RestockDetailModal";
import RestockToPrModal from "@/components/RestockToPrModal";
import { ORDER_STATUS_LABEL as AID_STATUS_LABEL, type OrderStatus as AidStatus } from "@/lib/orderStatus";
import { printViaIframe } from "@/lib/printIframe";
import { withBasePath } from "@/lib/basePath";

// standby(候補)目前只有 restock 來源會用到:pending + standby_at 有值 = 等貨源、先不佔待處理
type Stage = "pending" | "standby" | "in_transit" | "done" | "rejected";
type SourceTag = "restock" | "transfer" | "aid" | "air" | "shortage" | "picking" | "exception";

const STAGE_LABEL: Record<Stage, string> = {
  pending: "待處理",
  standby: "候補",
  in_transit: "在途",
  done: "已完成",
  rejected: "已拒絕 / 取消",
};

const STAGE_COLOR: Record<Stage, string> = {
  pending: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  standby: "bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-300",
  in_transit: "bg-cyan-100 text-cyan-800 dark:bg-cyan-950 dark:text-cyan-300",
  done: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  rejected: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

const ALL_STAGES: Stage[] = ["pending", "standby", "in_transit", "done", "rejected"];

const SOURCE_LABEL: Record<SourceTag, string> = {
  restock: "補貨申請",
  transfer: "轉貨單",
  aid: "互助訂單",
  air: "空中轉",
  shortage: "⚠️ 短少訂單",
  picking: "撿貨單",
  exception: "⚠️ 異常",
};

const SOURCE_COLOR: Record<SourceTag, string> = {
  restock: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  transfer: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  aid: "bg-fuchsia-100 text-fuchsia-800 dark:bg-fuchsia-950 dark:text-fuchsia-300",
  air: "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300",
  shortage: "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
  picking: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  exception: "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
};

const RESOLUTION_LABEL: Record<string, string> = {
  notified: "✓ 已通知客戶",
  cancelled: "✓ 已取消退款",
  reallocated: "✓ 已改派",
  waiting_next_po: "⏳ 等下批 PO",
};

type RestockRaw = {
  id: number;
  status: "pending" | "approved_transfer" | "approved_pr" | "shipped" | "received" | "rejected" | "cancelled";
  notes: string | null;
  rejected_reason: string | null;
  stockout_at: string | null;
  standby_at: string | null;
  /** 已開請購單的明細（品相）數；pending 但 >0 = 部分開單 */
  pr_line_count: number;
  linked_transfer_id: number | null;
  linked_pr_id: number | null;
  linked_transfer_no: string | null;
  linked_pr_no: string | null;
  store_name: string | null;
  requested_at: string;
  line_count: number;
  total_amount: number;
  items_summary: string;
};

type TransferRaw = {
  id: number;
  transfer_no: string;
  source_location: number;
  dest_location: number;
  status: string;
  transfer_type: string;
  shipping_temp: string | null;
  is_air_transfer: boolean;
  hq_notes: string | null;
  shipped_at: string | null;
  received_at: string | null;
  created_at: string;
  source_name: string;
  dest_name: string;
  line_count: number;
  notes: string | null;
  items_summary: string;
};

type AidRaw = {
  id: number;
  order_no: string;
  status: AidStatus;
  is_air_transfer: boolean | null;
  pickup_store_id: number | null;
  store_name: string | null;
  campaign_no: string | null;
  updated_at: string;
  line_count: number;
  items_summary: string;
  // 來源（轉出）端 —— 轉入單本身只寫得出取貨店＝收貨的那一頭，
  // 總倉光看「→ 三峽店」不知道要跟誰收貨、也不知道經不經自己的手。
  transferred_from_order_id: number | null;
  from_order_no: string | null;
  from_store_id: number | null;
  from_store_name: string | null;
};

type ShortageRaw = {
  order_id: number;
  order_no: string;
  member_id: number | null;
  store_name: string | null;
  order_status: string;
  shortage_resolution: string | null;
  shortage_notified_at: string | null;
  // 該訂單裡所有短缺品項聚合
  short_items: { sku_id: number; sku_label: string; order_qty: number; demand_unfulfillable: number }[];
  total_unfulfillable: number;
  order_updated_at: string;
};

type PickingRaw = {
  id: number;
  wave_code: string;
  wave_date: string;
  status: "draft" | "picking" | "picked" | "shipped" | "cancelled";
  store_count: number;
  item_count: number;
  total_qty: number;
  expected_total: number;
  actual_total: number;
  source_po_id: number | null;
  source_po_no: string | null;
  note: string | null;
  created_at: string;
  items_summary: string;
};

type Row =
  | { key: string; source: "restock"; ts: number; stage: Stage; raw: RestockRaw }
  | { key: string; source: "transfer"; ts: number; stage: Stage; raw: TransferRaw }
  | { key: string; source: "aid"; ts: number; stage: Stage; raw: AidRaw }
  | { key: string; source: "air"; ts: number; stage: Stage; raw: AidRaw }
  | { key: string; source: "shortage"; ts: number; stage: Stage; raw: ShortageRaw }
  | { key: string; source: "picking"; ts: number; stage: Stage; raw: PickingRaw };

function classifyRestock(s: RestockRaw["status"], standbyAt: string | null): Stage {
  if (s === "pending") return standbyAt ? "standby" : "pending";
  if (s === "approved_transfer" || s === "approved_pr" || s === "shipped") return "in_transit";
  if (s === "received") return "done";
  return "rejected";
}

function classifyTransfer(t: TransferRaw): Stage {
  if (t.status === "draft" || t.status === "confirmed") return "pending";
  // return_to_hq:status=shipped 表示「店家已寄出、HQ 待收」,從 HQ 角度是待處理
  if (t.status === "shipped" && t.transfer_type === "return_to_hq") return "pending";
  if (t.status === "shipped") return "in_transit";
  if (t.status === "received") return "done";
  return "rejected";
}

// 退訂單(rpc_create_order_return 產生的 transfer,notes 以「[order return」開頭)
function isOrderReturnTransfer(notes: string | null | undefined): boolean {
  return !!notes && notes.startsWith("[order return");
}

function classifyAid(s: AidStatus): Stage {
  if (s === "pending" || s === "confirmed") return "pending";
  if (s === "shipping") return "in_transit";
  if (s === "ready" || s === "completed" || s === "partially_completed") return "done";
  return "rejected";
}

function classifyShortage(resolution: string | null): Stage {
  if (resolution === null) return "pending";              // 還沒處理
  if (resolution === "notified") return "in_transit";     // 已通知客戶
  if (resolution === "waiting_next_po") return "in_transit"; // 等下批
  if (resolution === "cancelled" || resolution === "reallocated") return "done";
  return "pending";
}

function classifyPicking(s: PickingRaw["status"]): Stage {
  if (s === "draft" || s === "picking" || s === "picked") return "pending"; // 都是「等派貨」
  if (s === "shipped") return "done"; // 已派出 = 完成
  return "rejected"; // cancelled
}

// === Status → Stage 對應(server-side 過濾用)===
// restock 的 pending / standby 不能只靠 status 分——fetchRestockRows 會再依 standby_at 過濾
const RESTOCK_STATUS_BY_STAGE: Record<Stage, string[]> = {
  pending: ["pending"],
  standby: ["pending"],
  in_transit: ["approved_transfer", "approved_pr", "shipped"],
  done: ["received"],
  rejected: ["rejected", "cancelled"],
};
const TRANSFER_STATUS_BY_STAGE: Record<Stage, string[]> = {
  pending: ["draft", "confirmed"],
  standby: [], // 轉貨單沒有候補概念
  in_transit: ["shipped"],
  done: ["received"],
  rejected: ["cancelled"],
};
const TRANSFER_STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  confirmed: "已確認",
  shipped: "已出貨",
  received: "已收貨",
  cancelled: "已取消",
  closed: "已結案",
};
const AID_STATUS_BY_STAGE: Record<Stage, AidStatus[]> = {
  pending: ["pending", "confirmed"],
  standby: [],
  in_transit: ["shipping"],
  done: ["ready", "completed", "partially_completed"],
  // view 的 stage CASE 是 ELSE 'rejected',所以 cancelled 以外的終態也要列進來,
  // 否則 badge 數字(rpc_inbox_counts 走 view)會比列表多
  rejected: ["cancelled", "expired", "transferred_out"],
};
const PICKING_STATUS_BY_STAGE: Record<Stage, string[]> = {
  pending: ["draft", "picking", "picked"],
  standby: [],
  in_transit: [], // 撿貨單沒有「在途」概念,出貨後直接 done
  done: ["shipped"],
  rejected: ["cancelled"],
};
const SHORTAGE_RESOLUTION_BY_STAGE: Record<Stage, string[] | null> = {
  pending: null, // resolution IS NULL
  standby: [],
  in_transit: ["notified", "waiting_next_po"],
  done: ["cancelled", "reallocated"],
  rejected: [], // never
};

const PAGE_SIZE = 20;

// === 各來源的 server-side fetcher(回 { rows, total })===
type SBClient = ReturnType<typeof getSupabase>;

// 撈某張表（restock_request_lines / transfer_items / customer_order_items / picking_wave_items）
// 對應每張單的 items 摘要：「品名×qty、品名×qty…」（最多前 4 個 SKU，其餘 +N）
// 對 transfer_items 傳 includeFreeFormCols=true：自由轉貨行用 description 取代 sku label，並把估價附在後面
async function fetchItemsSummaryMap(
  sb: SBClient,
  table: string,
  idCol: string,
  ids: number[],
  qtyCol: string,
  includeFreeFormCols = false,
): Promise<Map<number, string>> {
  if (ids.length === 0) return new Map();
  const cols = includeFreeFormCols
    ? `${idCol}, sku_id, ${qtyCol}, description, estimated_amount`
    : `${idCol}, sku_id, ${qtyCol}`;
  const { data } = await sb.from(table).select(cols).in(idCol, ids);
  type Line = Record<string, number | string | null>;
  const lines = (data ?? []) as unknown as Line[];
  const skuIds = Array.from(
    new Set(
      lines
        // 自由轉貨行有 description 就不靠 sku label
        .filter((l) => !includeFreeFormCols || !l.description)
        .map((l) => Number(l.sku_id))
        .filter((x) => Number.isFinite(x))
    )
  );
  let skuLabelMap = new Map<number, string>();
  if (skuIds.length > 0) {
    const { data: skus } = await sb
      .from("skus")
      .select("id, sku_code, variant_name, product_id")
      .in("id", skuIds);
    const arr = (skus ?? []) as {
      id: number; sku_code: string; variant_name: string | null; product_id: number | null;
    }[];
    const prodIds = Array.from(new Set(arr.map((s) => s.product_id).filter((x): x is number => x != null)));
    let prodMap = new Map<number, string>();
    if (prodIds.length > 0) {
      const { data: ps } = await sb.from("products").select("id, name").in("id", prodIds);
      prodMap = new Map(((ps ?? []) as { id: number; name: string }[]).map((p) => [p.id, p.name]));
    }
    skuLabelMap = new Map(
      arr.map((s) => {
        // 品名 + 品相一起顯示（品相有值才接，無則退回 sku_code）
        const prodName = s.product_id != null ? (prodMap.get(s.product_id) ?? null) : null;
        const base = prodName ?? s.sku_code;
        return [s.id, s.variant_name ? `${base} / ${s.variant_name}` : base];
      })
    );
  }
  const partsMap = new Map<number, string[]>();
  for (const l of lines) {
    const id = Number(l[idCol]);
    const qty = Number(l[qtyCol] ?? 0);
    if (!Number.isFinite(id)) continue;
    let label: string;
    let suffix = "";
    if (includeFreeFormCols && typeof l.description === "string" && l.description) {
      label = l.description;
      const est = Number(l.estimated_amount ?? 0);
      if (est > 0) suffix = `（估 $${est.toFixed(0)}）`;
    } else {
      const skuId = Number(l.sku_id);
      if (!Number.isFinite(skuId)) continue;
      label = skuLabelMap.get(skuId) ?? `#${skuId}`;
    }
    const arr = partsMap.get(id) ?? [];
    arr.push(`${label}×${qty}${suffix}`);
    partsMap.set(id, arr);
  }
  const result = new Map<number, string>();
  const MAX = 4;
  for (const [id, parts] of partsMap) {
    if (parts.length <= MAX) result.set(id, parts.join("、"));
    else result.set(id, parts.slice(0, MAX).join("、") + ` +${parts.length - MAX}`);
  }
  return result;
}

async function fetchRestockRows(
  sb: SBClient,
  stage: Stage | null,
  page: number,
  dateFrom: string,
  dateTo: string,
): Promise<{ rows: Row[]; total: number }> {
  let q = sb
    .from("restock_requests")
    .select(
      "id, status, notes, rejected_reason, stockout_at, standby_at, linked_transfer_id, linked_pr_id, requested_at, stores!inner(name)",
      { count: "exact" },
    )
    .order("requested_at", { ascending: false });
  // pending / standby 都是 status='pending',差在 standby_at 有沒有值
  if (stage === "pending") q = q.eq("status", "pending").is("standby_at", null);
  else if (stage === "standby") q = q.eq("status", "pending").not("standby_at", "is", null);
  else if (stage) q = q.in("status", RESTOCK_STATUS_BY_STAGE[stage]);
  if (dateFrom) q = q.gte("requested_at", `${dateFrom}T00:00:00`);
  if (dateTo) q = q.lte("requested_at", `${dateTo}T23:59:59.999`);
  const start = (page - 1) * PAGE_SIZE;
  q = q.range(start, start + PAGE_SIZE - 1);
  const { data, count, error } = await q;
  if (error) throw new Error("restock: " + error.message);
  const rsRows = (data ?? []) as unknown as Array<RestockRaw & { stores?: { name: string } }>;

  const reqIds = rsRows.map((r) => r.id);
  const lineMap = new Map<number, { count: number; total: number; prCount: number }>();
  if (reqIds.length > 0) {
    const { data: lineData } = await sb
      .from("restock_request_lines")
      .select("request_id, qty, unit_price, linked_pr_id")
      .in("request_id", reqIds);
    for (const l of (lineData ?? []) as { request_id: number; qty: number; unit_price: number; linked_pr_id: number | null }[]) {
      const slot = lineMap.get(l.request_id) ?? { count: 0, total: 0, prCount: 0 };
      slot.count += 1;
      slot.total += Number(l.qty) * Number(l.unit_price);
      if (l.linked_pr_id != null) slot.prCount += 1;
      lineMap.set(l.request_id, slot);
    }
  }
  const xferIds = rsRows.map((r) => r.linked_transfer_id).filter((x): x is number => !!x);
  const prIds = rsRows.map((r) => r.linked_pr_id).filter((x): x is number => !!x);
  const xferNoMap = new Map<number, string>();
  const prNoMap = new Map<number, string>();
  if (xferIds.length > 0) {
    const { data: xs } = await sb.from("transfers").select("id, transfer_no").in("id", xferIds);
    for (const x of (xs ?? []) as { id: number; transfer_no: string }[]) xferNoMap.set(x.id, x.transfer_no);
  }
  if (prIds.length > 0) {
    const { data: ps } = await sb.from("purchase_requests").select("id, pr_no").in("id", prIds);
    for (const p of (ps ?? []) as { id: number; pr_no: string }[]) prNoMap.set(p.id, p.pr_no);
  }

  const itemsMap = await fetchItemsSummaryMap(sb, "restock_request_lines", "request_id", reqIds, "qty");

  const rows: Row[] = rsRows.map((r) => ({
    key: `restock-${r.id}`,
    source: "restock" as const,
    ts: new Date(r.requested_at).getTime(),
    stage: classifyRestock(r.status, r.standby_at),
    raw: {
      id: r.id,
      status: r.status,
      notes: r.notes,
      rejected_reason: r.rejected_reason,
      stockout_at: r.stockout_at,
      standby_at: r.standby_at,
      linked_transfer_id: r.linked_transfer_id,
      linked_pr_id: r.linked_pr_id,
      linked_transfer_no: r.linked_transfer_id ? xferNoMap.get(r.linked_transfer_id) ?? null : null,
      linked_pr_no: r.linked_pr_id ? prNoMap.get(r.linked_pr_id) ?? null : null,
      store_name: r.stores?.name ?? null,
      requested_at: r.requested_at,
      line_count: lineMap.get(r.id)?.count ?? 0,
      total_amount: lineMap.get(r.id)?.total ?? 0,
      pr_line_count: lineMap.get(r.id)?.prCount ?? 0,
      items_summary: itemsMap.get(r.id) ?? "",
    },
  }));
  return { rows, total: count ?? 0 };
}

async function fetchTransferRows(
  sb: SBClient,
  stage: Stage | null,
  page: number,
  dateFrom: string,
  dateTo: string,
  transferKind: "all" | "store_to_store" | "return_to_hq" | "hq_to_store" | "aid_handoff" = "all",
): Promise<{ rows: Row[]; total: number }> {
  if (stage === "standby") return { rows: [], total: 0 }; // 只有 restock 有候補
  let q = sb
    .from("transfers")
    .select(
      "id, transfer_no, source_location, dest_location, status, transfer_type, shipping_temp, is_air_transfer, hq_notes, notes, shipped_at, received_at, created_at",
      { count: "exact" },
    )
    .order("id", { ascending: false });
  // stage filter:
  //   pending     → status in (draft, confirmed) OR (status=shipped AND type=return_to_hq)
  //   in_transit  → status=shipped AND type<>return_to_hq
  //   done/rejected → status in (...) 既有邏輯
  if (stage === "pending") {
    q = q.or("status.in.(draft,confirmed),and(status.eq.shipped,transfer_type.eq.return_to_hq)");
  } else if (stage === "in_transit") {
    q = q.eq("status", "shipped").neq("transfer_type", "return_to_hq");
  } else if (stage) {
    q = q.in("status", TRANSFER_STATUS_BY_STAGE[stage]);
  }
  if (transferKind !== "all") q = q.eq("transfer_type", transferKind);
  if (dateFrom) q = q.gte("created_at", `${dateFrom}T00:00:00`);
  if (dateTo) q = q.lte("created_at", `${dateTo}T23:59:59.999`);
  const start = (page - 1) * PAGE_SIZE;
  q = q.range(start, start + PAGE_SIZE - 1);
  const { data, count, error } = await q;
  if (error) throw new Error("transfers: " + error.message);
  const trs = (data as TransferRaw[] | null) ?? [];

  const locIds = Array.from(new Set(trs.flatMap((t) => [t.source_location, t.dest_location])));
  const locNameMap = new Map<number, string>();
  if (locIds.length > 0) {
    const { data: lr } = await sb.from("locations").select("id, name").in("id", locIds);
    for (const l of (lr ?? []) as { id: number; name: string }[]) locNameMap.set(l.id, l.name);
  }
  const tIds = trs.map((t) => t.id);
  const tLineMap = new Map<number, number>();
  if (tIds.length > 0) {
    const { data: tl } = await sb.from("transfer_items").select("transfer_id").in("transfer_id", tIds);
    for (const it of (tl ?? []) as { transfer_id: number }[]) {
      tLineMap.set(it.transfer_id, (tLineMap.get(it.transfer_id) ?? 0) + 1);
    }
  }

  const itemsMap = await fetchItemsSummaryMap(sb, "transfer_items", "transfer_id", tIds, "qty_shipped", true);

  const rows: Row[] = trs.map((t) => ({
    key: `transfer-${t.id}`,
    source: "transfer" as const,
    ts: new Date(t.created_at).getTime(),
    stage: classifyTransfer(t),
    raw: {
      ...t,
      source_name: locNameMap.get(t.source_location) ?? `#${t.source_location}`,
      dest_name: locNameMap.get(t.dest_location) ?? `#${t.dest_location}`,
      line_count: tLineMap.get(t.id) ?? 0,
      items_summary: itemsMap.get(t.id) ?? "",
    },
  }));
  return { rows, total: count ?? 0 };
}

// 收件匣的互助 / 空中轉列一律走 v_hq_inbox_aid（20260818000040）：
// 它已經排除同店轉單（貨沒有移動、總倉不用確認也不用派貨），並把轉出端
// （來源單 / 轉出店）查好 —— PostgREST 直查 customer_orders 做不到
// 「來源單.pickup_store_id = 本單.pickup_store_id」這種欄位對欄位比較。
const AID_SELECT = `id, order_no, status, is_air_transfer, pickup_store_id,
       transferred_from_order_id, updated_at, campaign_no, store_name,
       from_order_no, from_store_id, from_store_name, line_count`;

type AidQueryRow = {
  id: number;
  order_no: string;
  status: AidStatus;
  is_air_transfer: boolean | null;
  pickup_store_id: number | null;
  transferred_from_order_id: number | null;
  updated_at: string;
  campaign_no: string | null;
  store_name: string | null;
  from_order_no: string | null;
  from_store_id: number | null;
  from_store_name: string | null;
  line_count: number | null;
};

async function toAidRows(sb: SBClient, aidRows: AidQueryRow[], airMode: "aid" | "air"): Promise<Row[]> {
  const itemsMap = await fetchItemsSummaryMap(
    sb, "customer_order_items", "order_id", aidRows.map((a) => a.id), "qty",
  );
  return aidRows.map((a) => ({
    key: `${airMode}-${a.id}`,
    source: airMode,
    ts: new Date(a.updated_at).getTime(),
    stage: classifyAid(a.status),
    raw: {
      id: a.id,
      order_no: a.order_no,
      status: a.status,
      is_air_transfer: a.is_air_transfer,
      pickup_store_id: a.pickup_store_id,
      store_name: a.store_name,
      campaign_no: a.campaign_no,
      updated_at: a.updated_at,
      line_count: a.line_count ?? 0,
      items_summary: itemsMap.get(a.id) ?? "",
      transferred_from_order_id: a.transferred_from_order_id,
      from_order_no: a.from_order_no,
      from_store_id: a.from_store_id,
      from_store_name: a.from_store_name,
    },
  }));
}

async function fetchAidRows(
  sb: SBClient,
  stage: Stage | null,
  page: number,
  dateFrom: string,
  dateTo: string,
  airMode: "aid" | "air",
  aidStatus: string,
): Promise<{ rows: Row[]; total: number }> {
  if (stage === "standby") return { rows: [], total: 0 }; // 只有 restock 有候補
  let q = sb
    .from("v_hq_inbox_aid")
    .select(AID_SELECT, { count: "exact" })
    .order("updated_at", { ascending: false });
  if (stage) q = q.in("status", AID_STATUS_BY_STAGE[stage] as string[]);
  if (aidStatus) q = q.eq("status", aidStatus);
  // view 的 is_air_transfer 已 COALESCE 成 false,不會有 null
  q = q.eq("is_air_transfer", airMode === "air");
  if (dateFrom) q = q.gte("updated_at", `${dateFrom}T00:00:00`);
  if (dateTo) q = q.lte("updated_at", `${dateTo}T23:59:59.999`);
  const start = (page - 1) * PAGE_SIZE;
  q = q.range(start, start + PAGE_SIZE - 1);
  const { data, count, error } = await q;
  if (error) throw new Error("aid: " + error.message);

  const rows = await toAidRows(sb, (data ?? []) as unknown as AidQueryRow[], airMode);
  return { rows, total: count ?? 0 };
}

async function fetchShortageRows(
  sb: SBClient,
  stage: Stage | null,
  page: number,
  dateFrom: string,
  dateTo: string,
): Promise<{ rows: Row[]; total: number }> {
  // server-side 分頁:rpc_hq_shortage_orders 在 DB 端把 v_order_shortage
  // (order × sku) 聚合到 order 維度、套 stage / 日期篩選後分頁,
  // 一次回傳 { total, rows(ShortageRaw 形狀) },前端只收當頁 20 筆。
  if (stage && (SHORTAGE_RESOLUTION_BY_STAGE[stage]?.length ?? 1) === 0) {
    return { rows: [], total: 0 }; // standby / rejected:訂單短少沒有這兩個 stage
  }
  const { data, error } = await sb.rpc("rpc_hq_shortage_orders", {
    p_stage: stage,
    p_page: page,
    p_page_size: PAGE_SIZE,
    p_date_from: dateFrom ? `${dateFrom}T00:00:00` : null,
    p_date_to: dateTo ? `${dateTo}T23:59:59.999` : null,
  });
  if (error) throw new Error("shortage: " + error.message);

  const resp = (data ?? { total: 0, rows: [] }) as { total: number; rows: ShortageRaw[] };
  const rows: Row[] = (resp.rows ?? []).map((s) => ({
    key: `shortage-${s.order_id}`,
    source: "shortage" as const,
    ts: new Date(s.order_updated_at).getTime(),
    stage: classifyShortage(s.shortage_resolution),
    raw: {
      ...s,
      total_unfulfillable: Number(s.total_unfulfillable),
      short_items: (s.short_items ?? []).map((it) => ({
        ...it,
        order_qty: Number(it.order_qty),
        demand_unfulfillable: Number(it.demand_unfulfillable),
      })),
    },
  }));
  return { rows, total: resp.total ?? 0 };
}

async function fetchPickingRows(
  sb: SBClient,
  stage: Stage | null,
  page: number,
  dateFrom: string,
  dateTo: string,
): Promise<{ rows: Row[]; total: number }> {
  let q = sb
    .from("picking_waves")
    .select(
      "id, wave_code, wave_date, status, store_count, item_count, total_qty, note, created_at, source_po_id",
      { count: "exact" },
    )
    .order("created_at", { ascending: false });
  if (stage) {
    const statuses = PICKING_STATUS_BY_STAGE[stage];
    if (statuses.length === 0) return { rows: [], total: 0 };
    q = q.in("status", statuses);
  }
  if (dateFrom) q = q.gte("created_at", `${dateFrom}T00:00:00`);
  if (dateTo) q = q.lte("created_at", `${dateTo}T23:59:59.999`);
  const start = (page - 1) * PAGE_SIZE;
  q = q.range(start, start + PAGE_SIZE - 1);
  const { data, count, error } = await q;
  if (error) throw new Error("picking: " + error.message);
  const waveRows = (data ?? []) as Array<Omit<PickingRaw, "expected_total" | "actual_total" | "source_po_no">>;

  // 補 expected/actual + source_po_no
  // item_count 用 distinct sku_id;原本 row count 會把 (store × sku) 都算進去
  const ids = waveRows.map((w) => w.id);
  const totals = new Map<number, { expected: number; actual: number; skus: Set<number> }>();
  if (ids.length > 0) {
    const { data: itemRows } = await sb
      .from("picking_wave_items")
      .select("wave_id, sku_id, qty, picked_qty")
      .in("wave_id", ids);
    for (const r of (itemRows as { wave_id: number; sku_id: number; qty: number; picked_qty: number | null }[] | null) ?? []) {
      const cur = totals.get(r.wave_id) ?? { expected: 0, actual: 0, skus: new Set<number>() };
      cur.expected += Number(r.qty);
      cur.actual += Number(r.picked_qty ?? r.qty);
      cur.skus.add(r.sku_id);
      totals.set(r.wave_id, cur);
    }
  }
  const poIds = Array.from(new Set(waveRows.map((w) => w.source_po_id).filter((x): x is number => x !== null)));
  const poNoMap = new Map<number, string>();
  if (poIds.length > 0) {
    const { data: poRows } = await sb
      .from("purchase_orders")
      .select("id, po_no")
      .in("id", poIds);
    for (const p of (poRows as { id: number; po_no: string }[] | null) ?? []) poNoMap.set(p.id, p.po_no);
  }
  const itemsMap = await fetchItemsSummaryMap(sb, "picking_wave_items", "wave_id", ids, "qty");

  const rows: Row[] = waveRows.map((w) => ({
    key: `picking-${w.id}`,
    source: "picking" as const,
    ts: new Date(w.created_at).getTime(),
    stage: classifyPicking(w.status),
    raw: {
      ...w,
      total_qty: Number(w.total_qty),
      expected_total: totals.get(w.id)?.expected ?? 0,
      actual_total: totals.get(w.id)?.actual ?? 0,
      item_count: totals.get(w.id)?.skus.size ?? w.item_count,
      source_po_no: w.source_po_id ? (poNoMap.get(w.source_po_id) ?? null) : null,
      items_summary: itemsMap.get(w.id) ?? "",
    },
  }));
  return { rows, total: count ?? 0 };
}

// === ByIds 變體 — 給「全部」視圖分頁用(已從 v_hq_inbox 拿到 page keys 後,反查各表詳情) ===

async function fetchRestockRowsByIds(sb: SBClient, ids: number[]): Promise<Row[]> {
  if (ids.length === 0) return [];
  const { data, error } = await sb
    .from("restock_requests")
    .select(
      "id, status, notes, rejected_reason, stockout_at, standby_at, linked_transfer_id, linked_pr_id, requested_at, stores!inner(name)",
    )
    .in("id", ids);
  if (error) throw new Error("restock: " + error.message);
  const rsRows = (data ?? []) as unknown as Array<RestockRaw & { stores?: { name: string } }>;
  const lineMap = new Map<number, { count: number; total: number; prCount: number }>();
  if (rsRows.length > 0) {
    const { data: lineData } = await sb
      .from("restock_request_lines")
      .select("request_id, qty, unit_price, linked_pr_id")
      .in("request_id", rsRows.map((r) => r.id));
    for (const l of (lineData ?? []) as { request_id: number; qty: number; unit_price: number; linked_pr_id: number | null }[]) {
      const slot = lineMap.get(l.request_id) ?? { count: 0, total: 0, prCount: 0 };
      slot.count += 1;
      slot.total += Number(l.qty) * Number(l.unit_price);
      if (l.linked_pr_id != null) slot.prCount += 1;
      lineMap.set(l.request_id, slot);
    }
  }
  const xferIds = rsRows.map((r) => r.linked_transfer_id).filter((x): x is number => !!x);
  const prIds = rsRows.map((r) => r.linked_pr_id).filter((x): x is number => !!x);
  const xferNoMap = new Map<number, string>();
  const prNoMap = new Map<number, string>();
  if (xferIds.length > 0) {
    const { data: xs } = await sb.from("transfers").select("id, transfer_no").in("id", xferIds);
    for (const x of (xs ?? []) as { id: number; transfer_no: string }[]) xferNoMap.set(x.id, x.transfer_no);
  }
  if (prIds.length > 0) {
    const { data: ps } = await sb.from("purchase_requests").select("id, pr_no").in("id", prIds);
    for (const p of (ps ?? []) as { id: number; pr_no: string }[]) prNoMap.set(p.id, p.pr_no);
  }
  const itemsMap = await fetchItemsSummaryMap(sb, "restock_request_lines", "request_id", rsRows.map((r) => r.id), "qty");
  return rsRows.map((r) => ({
    key: `restock-${r.id}`,
    source: "restock" as const,
    ts: new Date(r.requested_at).getTime(),
    stage: classifyRestock(r.status, r.standby_at),
    raw: {
      id: r.id,
      status: r.status,
      notes: r.notes,
      rejected_reason: r.rejected_reason,
      stockout_at: r.stockout_at,
      standby_at: r.standby_at,
      linked_transfer_id: r.linked_transfer_id,
      linked_pr_id: r.linked_pr_id,
      linked_transfer_no: r.linked_transfer_id ? xferNoMap.get(r.linked_transfer_id) ?? null : null,
      linked_pr_no: r.linked_pr_id ? prNoMap.get(r.linked_pr_id) ?? null : null,
      store_name: r.stores?.name ?? null,
      requested_at: r.requested_at,
      line_count: lineMap.get(r.id)?.count ?? 0,
      total_amount: lineMap.get(r.id)?.total ?? 0,
      pr_line_count: lineMap.get(r.id)?.prCount ?? 0,
      items_summary: itemsMap.get(r.id) ?? "",
    },
  }));
}

async function fetchTransferRowsByIds(sb: SBClient, ids: number[]): Promise<Row[]> {
  if (ids.length === 0) return [];
  const { data, error } = await sb
    .from("transfers")
    .select(
      "id, transfer_no, source_location, dest_location, status, transfer_type, shipping_temp, is_air_transfer, hq_notes, notes, shipped_at, received_at, created_at",
    )
    .in("id", ids);
  if (error) throw new Error("transfers: " + error.message);
  const trs = (data as TransferRaw[] | null) ?? [];
  const locIds = Array.from(new Set(trs.flatMap((t) => [t.source_location, t.dest_location])));
  const locNameMap = new Map<number, string>();
  if (locIds.length > 0) {
    const { data: lr } = await sb.from("locations").select("id, name").in("id", locIds);
    for (const l of (lr ?? []) as { id: number; name: string }[]) locNameMap.set(l.id, l.name);
  }
  const tLineMap = new Map<number, number>();
  if (trs.length > 0) {
    const { data: tl } = await sb.from("transfer_items").select("transfer_id").in("transfer_id", trs.map((t) => t.id));
    for (const it of (tl ?? []) as { transfer_id: number }[]) {
      tLineMap.set(it.transfer_id, (tLineMap.get(it.transfer_id) ?? 0) + 1);
    }
  }
  const itemsMap = await fetchItemsSummaryMap(sb, "transfer_items", "transfer_id", trs.map((t) => t.id), "qty_shipped", true);
  return trs.map((t) => ({
    key: `transfer-${t.id}`,
    source: "transfer" as const,
    ts: new Date(t.created_at).getTime(),
    stage: classifyTransfer(t),
    raw: {
      ...t,
      source_name: locNameMap.get(t.source_location) ?? `#${t.source_location}`,
      dest_name: locNameMap.get(t.dest_location) ?? `#${t.dest_location}`,
      line_count: tLineMap.get(t.id) ?? 0,
      items_summary: itemsMap.get(t.id) ?? "",
    },
  }));
}

// airMode: "aid" 排除空中轉 / "air" 只留空中轉(tag 用,決定 row.source 與 key 前綴)
// v_hq_inbox 的 aid 分支不分空中轉(row_key 一律 aid-<id>),所以這裡**不能**濾
// is_air_transfer —— 濾掉的話那幾列在「全部」分頁會被 detailMap 查不到而靜靜消失,
// 但 total 仍然把它們算進去(筆數對不上列數)。列的 source 改成逐列判定。
async function fetchAidRowsByIds(sb: SBClient, ids: number[]): Promise<Row[]> {
  if (ids.length === 0) return [];
  const { data, error } = await sb
    .from("v_hq_inbox_aid")
    .select(AID_SELECT)
    .in("id", ids);
  if (error) throw new Error("aid: " + error.message);
  const rows = (data ?? []) as unknown as AidQueryRow[];
  const built = await Promise.all(
    rows.map(async (r) => {
      const [row] = await toAidRows(sb, [r], r.is_air_transfer ? "air" : "aid");
      // key 要對回 v_hq_inbox 的 row_key(aid-<id>),空中轉才不會落空
      return { ...row, key: `aid-${r.id}` };
    }),
  );
  return built;
}

async function fetchShortageRowsByIds(sb: SBClient, ids: number[]): Promise<Row[]> {
  if (ids.length === 0) return [];
  const { data, error } = await sb
    .from("v_order_shortage")
    .select(
      "order_id, order_no, member_id, store_name, order_status, shortage_resolution, shortage_notified_at, sku_id, product_name, variant_name, sku_code, order_qty, demand_unfulfillable, order_updated_at",
    )
    .in("order_id", ids);
  if (error) throw new Error("shortage: " + error.message);
  type ShortageRowRaw = {
    order_id: number;
    order_no: string;
    member_id: number | null;
    store_name: string | null;
    order_status: string;
    shortage_resolution: string | null;
    shortage_notified_at: string | null;
    sku_id: number;
    product_name: string | null;
    variant_name: string | null;
    sku_code: string | null;
    order_qty: number;
    demand_unfulfillable: number;
    order_updated_at: string;
  };
  const shortageRaw = (data ?? []) as ShortageRowRaw[];
  const byOrder = new Map<number, ShortageRaw>();
  for (const r of shortageRaw) {
    let s = byOrder.get(r.order_id);
    if (!s) {
      s = {
        order_id: r.order_id,
        order_no: r.order_no,
        member_id: r.member_id,
        store_name: r.store_name,
        order_status: r.order_status,
        shortage_resolution: r.shortage_resolution,
        shortage_notified_at: r.shortage_notified_at,
        short_items: [],
        total_unfulfillable: 0,
        order_updated_at: r.order_updated_at,
      };
      byOrder.set(r.order_id, s);
    }
    const skuLabel = `${r.product_name ?? ""}${r.variant_name ? ` / ${r.variant_name}` : ""}`.trim() || `品項#${r.sku_id}`;
    s.short_items.push({
      sku_id: r.sku_id,
      sku_label: r.sku_code ? `${r.sku_code} ${skuLabel}` : skuLabel,
      order_qty: Number(r.order_qty),
      demand_unfulfillable: Number(r.demand_unfulfillable),
    });
    s.total_unfulfillable += Number(r.demand_unfulfillable);
  }
  return Array.from(byOrder.values()).map((s) => ({
    key: `shortage-${s.order_id}`,
    source: "shortage" as const,
    ts: new Date(s.order_updated_at).getTime(),
    stage: classifyShortage(s.shortage_resolution),
    raw: s,
  }));
}

export default function HqInboxPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <HqInboxContent />
    </Suspense>
  );
}

function HqInboxContent() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [hqLocId, setHqLocId] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);

  const searchParams = useSearchParams();
  const [stage, setStage] = useState<Stage | "all">("pending");
  // sourceFilter:URL ?source= 優先 > localStorage 上次選擇 > 預設 "picking"
  // (移除「全部」chip 後不再有 UI 入口進 "all";仍保留 type 給 URL 使用)
  const [sourceFilter, setSourceFilter] = useState<SourceTag | "all">(() => {
    if (typeof window === "undefined") return "picking";
    const fromUrl = new URLSearchParams(window.location.search).get("source");
    if (fromUrl === "restock" || fromUrl === "transfer" || fromUrl === "aid" || fromUrl === "air" || fromUrl === "shortage" || fromUrl === "picking" || fromUrl === "exception" || fromUrl === "all") {
      return fromUrl;
    }
    const saved = window.localStorage.getItem("hq-inbox-source");
    if (saved === "restock" || saved === "transfer" || saved === "aid" || saved === "air" || saved === "shortage" || saved === "picking" || saved === "exception") {
      return saved;
    }
    // 舊 localStorage 是 "all" → 改成 picking(因為 UI 沒入口了)
    return "picking";
  });
  const [search, setSearch] = useState("");

  // sourceFilter 變動 → 寫回 localStorage
  useEffect(() => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem("hq-inbox-source", sourceFilter);
    }
  }, [sourceFilter]);

  // 跟 ?source= URL param 同步(支援從 /transfers/aid redirect 過來)
  useEffect(() => {
    const src = searchParams.get("source");
    if (src === "restock" || src === "transfer" || src === "aid" || src === "air" || src === "shortage" || src === "picking" || src === "exception") {
      setSourceFilter(src);
    }
  }, [searchParams]);

  // 「候補」stage 只屬於補貨申請;來源不是 restock 時(例如 ?source= URL 直接切走)
  // 一律視為「待處理」,不改 state、純 derive,避免 effect 裡 setState
  const effectiveStage: Stage | "all" =
    stage === "standby" && sourceFilter !== "restock" ? "pending" : stage;

  // 共用日期區間(所有來源)
  const [dateFrom, setDateFrom] = useState<string>("");
  const [dateTo, setDateTo] = useState<string>("");

  // Aid 專屬篩選 (source=aid 時才顯示;空中轉已獨立成 air source,故不再有 mode 下拉)
  const [aidStatusFilter, setAidStatusFilter] = useState<string>("");
  // Transfer 專屬篩選 (source=transfer 時才顯示)
  type TransferKind = "all" | "store_to_store" | "return_to_hq" | "hq_to_store" | "aid_handoff";
  const [transferKindFilter, setTransferKindFilter] = useState<TransferKind>("all");
  const [page, setPage] = useState(1);

  // server-side counts: per source × per stage(badge / tab 用)
  const [counts, setCounts] = useState<Record<SourceTag, Record<Stage, number>> | null>(null);
  // 異常 chip count = 異常「四類全算」(rpc_hq_exceptions 的 counts.all)
  //
  // 口徑由老闆 2026-08-21 裁示:chip 標籤寫「⚠️ 異常」,點進去的清單預設也是「全部」分頁,
  // 徽章就該等於那個「全部」的數字。
  //
  // 為什麼 counts.all 是安全的(2026-08-21 老闆截圖實證):
  //   進貨短少 3 ＋ 進貨破損 2 ＋ 過量進貨 78 ＋ 收貨短少 109 = 192 = 全部分頁的數字
  //   → 四類加總剛好等於 all ⇒ 正式庫的 v_hq_exceptions 已是套過
  //     20260811020010_hq_exceptions_drop_customer_shortage 的版本,
  //     沒有已廢棄的 customer_shortage 殘留在 all 裡面
  //     (ExceptionsContent.tsx 的 rows filter 仍留著當防線,不要拿掉)。
  // 而且 <ExceptionsContent> 透過 onCountChange 回報的就是 cnts.all
  //   (ExceptionsContent.tsx:189)⇒ 兩邊同口徑,點進去前後不會跳動。
  //
  // counts 在 RPC 內是 FROM ex(整個 view、未依 p_type 過濾)算的
  //   (20260704000020_hq_exceptions_view_and_pagination.sql:273-283),
  //   所以帶哪個 p_type 都拿得到同一份 counts;這裡帶 'all' 只是讓意圖跟讀的欄位一致。
  //
  // 這個數字必須在收件匣就先抓好:2026-08-21 線上實測 844 件的短收躺著沒人處理,
  // 就是因為它一直顯示 0(舊版只有 <ExceptionsContent /> 掛載時才會被填 → 要先點進異常分頁)。
  const [exceptionCount, setExceptionCount] = useState<number>(0);
  // 點進異常分頁後 <ExceptionsContent /> 每抓完一次都會回報筆數(cnts.all,與徽章同口徑)。
  // 這裡只把它當「清單有變動」的訊號用,由下面那個 effect 自己重抓一次
  // (處理掉一筆後徽章才會跟著少),不直接把回報值塞進徽章 —— 少一條資料來源少一種不一致。
  const [exceptionTick, setExceptionTick] = useState(0);
  // server-side total: 當前 (source, stage) 篩選的總數
  const [total, setTotal] = useState(0);
  // 載入狀態
  const [loadingRows, setLoadingRows] = useState(false);

  const [busy, setBusy] = useState<string | null>(null);
  const [rejectModal, setRejectModal] = useState<{ id: number; reason: string } | null>(null);
  const [aidDetailId, setAidDetailId] = useState<number | null>(null);
  const [transferDetailId, setTransferDetailId] = useState<number | null>(null);
  const [restockDetailId, setRestockDetailId] = useState<number | null>(null);
  const [restockPrId, setRestockPrId] = useState<number | null>(null);
  const [editingWave, setEditingWave] = useState<PickWave | null>(null);
  const [dispatchingWaveId, setDispatchingWaveId] = useState<number | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [batchBusy, setBatchBusy] = useState(false);
  const [groupBy, setGroupBy] = useState<"none" | "store" | "source" | "campaign">("none");

  // 一次:抓 HQ location id
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data } = await sb
        .from("locations")
        .select("id")
        .eq("type", "central_warehouse")
        .eq("is_active", true)
        .order("id")
        .limit(1);
      if (cancelled) return;
      const id = ((data as { id: number }[] | null) ?? [])[0]?.id ?? null;
      setHqLocId(id);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // 一次 RPC 拿全部 4 來源 × 4 階段 的 count(rpc_inbox_counts);picking 額外 client-side 算
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const fallback: Record<Stage, number> = { pending: 0, standby: 0, in_transit: 0, done: 0, rejected: 0 };
        const [{ data, error }, pickingCounts, airCounts] = await Promise.all([
          sb.rpc("rpc_inbox_counts"),
          // picking 還沒進 rpc_inbox_counts(server-side migration 待 deploy),先 client-side 算
          (async () => {
            const result: Record<Stage, number> = { ...fallback };
            const { data: rows } = await sb.from("picking_waves").select("status");
            for (const r of (rows as { status: string }[] | null) ?? []) {
              const stg = classifyPicking(r.status as PickingRaw["status"]);
              result[stg] += 1;
            }
            return result;
          })(),
          // 空中轉(air):rpc_inbox_counts 仍把空中轉併進 aid,故 client-side 另算一份,
          // 之後從 aid 扣掉、避免重複計。
          (async () => {
            const result: Record<Stage, number> = { ...fallback };
            const { data: rows } = await sb
              .from("v_hq_inbox_aid")
              .select("status")
              .eq("is_air_transfer", true);
            for (const r of (rows as { status: AidStatus }[] | null) ?? []) {
              const stg = classifyAid(r.status);
              result[stg] += 1;
            }
            return result;
          })(),
        ]);
        if (cancelled) return;
        if (error) throw error;
        const raw = (data ?? {}) as Partial<Record<SourceTag, Partial<Record<Stage, number>>>>;
        const serverAid: Record<Stage, number> = { ...fallback, ...(raw.aid ?? {}) };
        // aid 扣掉 air(server 端 aid 尚含空中轉)
        const aidCounts: Record<Stage, number> = {
          pending: Math.max(0, serverAid.pending - airCounts.pending),
          standby: 0,
          in_transit: Math.max(0, serverAid.in_transit - airCounts.in_transit),
          done: Math.max(0, serverAid.done - airCounts.done),
          rejected: Math.max(0, serverAid.rejected - airCounts.rejected),
        };
        const newCounts: Record<SourceTag, Record<Stage, number>> = {
          restock: { ...fallback, ...(raw.restock ?? {}) },
          transfer: { ...fallback, ...(raw.transfer ?? {}) },
          aid: aidCounts,
          air: airCounts,
          shortage: { ...fallback, ...(raw.shortage ?? {}) },
          picking: pickingCounts,
          exception: { ...fallback }, // 異常徽章走獨立的 exceptionCount(rpc_hq_exceptions),不走 rpc_inbox_counts
        };
        setCounts(newCounts);
      } catch {
        // counts 失敗就用 null,UI 會 fallback 顯示 0
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick]);

  // <ExceptionsContent onCountChange> 用:必須是「穩定」的 function —— 它的 useEffect
  // deps 含 onCountChange,傳 inline arrow 會讓那個 effect 每次 render 都重跑(無限抓)。
  const lastReportedExceptionTotal = useRef<number | null>(null);
  const handleExceptionListChanged = useCallback((reportedTotal: number) => {
    // 同一個數字重複回報(切分頁籤 / 換頁)不必重抓;真的變了(處理掉一筆)才重抓
    if (lastReportedExceptionTotal.current === reportedTotal) return;
    lastReportedExceptionTotal.current = reportedTotal;
    setExceptionTick((t) => t + 1);
  }, []);

  // 異常 chip 的筆數(四類全算)— 不等使用者點進異常分頁就先抓好
  //
  // ⚠️ 故意獨立成一個 effect、不併進上面那個 Promise.all:rpc_hq_exceptions 內部是
  // WITH ex AS MATERIALIZED (SELECT * FROM v_hq_exceptions),每次都把整個 view 算完
  // (p_page_size 省的是傳輸不是計算)。併進 Promise.all 會讓撿貨單 / 補貨申請 / 轉貨單
  // 那幾個徽章一起等它 → 分開之後,慢的只有異常那一顆數字,收件匣其餘內容不受影響。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: err } = await sb.rpc("rpc_hq_exceptions", {
          p_type: "all",
          p_page: 1,
          p_page_size: 1, // 只要 counts,不要 rows
        });
        if (cancelled || err) return;
        // counts.all = 四類總和(口徑理由見 exceptionCount 宣告處)
        const n = (data as { counts?: Record<string, number> } | null)?.counts?.all;
        // 抓不到就維持前一個值,不歸零(歸零等於又回到「永遠顯示 0」的老問題);
        // 真的是 0 筆時 n === 0,不會被這一行擋掉。
        if (n == null) return;
        setExceptionCount(Number(n));
      } catch {
        // 同上:失敗不歸零
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick, exceptionTick]);

  // 抓當前 view 的 rows(server-side pagination)
  // 變動觸發:source / stage / page / 日期 / Aid 篩選 / reloadTick
  useEffect(() => {
    let cancelled = false;
    setLoadingRows(true);
    (async () => {
      try {
        const sb = getSupabase();
        const stageArg: Stage | null = effectiveStage === "all" ? null : effectiveStage;

        let resultRows: Row[] = [];
        let resultTotal = 0;

        if (sourceFilter === "all") {
          // 「全部」視圖:用 rpc_hq_inbox_keys 從 v_hq_inbox 拿 page keys,再 by-id 反查各表詳情
          const { data: keysData, error: keysErr } = await sb.rpc("rpc_hq_inbox_keys", {
            p_stage: stageArg,
            p_date_from: dateFrom ? `${dateFrom}T00:00:00Z` : null,
            p_date_to: dateTo ? `${dateTo}T23:59:59.999Z` : null,
            p_page: page,
            p_page_size: PAGE_SIZE,
          });
          if (keysErr) throw keysErr;
          const keysObj = (keysData ?? { rows: [], total: 0 }) as { rows: Array<{ row_key: string; source: SourceTag; stage: Stage; ts: string; source_id: number }>; total: number };
          const idsBy: Record<SourceTag, number[]> = { restock: [], transfer: [], aid: [], air: [], shortage: [], picking: [], exception: [] };
          // v_hq_inbox 還沒含 picking;若未來 server-side 加進去,picking 鍵也已就位
          for (const k of keysObj.rows) {
            if (idsBy[k.source]) idsBy[k.source].push(Number(k.source_id));
          }

          const [r, t, a, sh] = await Promise.all([
            fetchRestockRowsByIds(sb, idsBy.restock),
            fetchTransferRowsByIds(sb, idsBy.transfer),
            fetchAidRowsByIds(sb, idsBy.aid),
            fetchShortageRowsByIds(sb, idsBy.shortage),
          ]);
          const detailMap = new Map<string, Row>();
          for (const row of [...r, ...t, ...a, ...sh]) detailMap.set(row.key, row);
          // 依 keys 的順序(view 已 ORDER BY ts DESC)組回去
          resultRows = keysObj.rows
            .map((k) => detailMap.get(k.row_key))
            .filter((x): x is Row => !!x);
          resultTotal = keysObj.total;
        } else {
          let res: { rows: Row[]; total: number };
          if (sourceFilter === "restock") {
            res = await fetchRestockRows(sb, stageArg, page, dateFrom, dateTo);
          } else if (sourceFilter === "transfer") {
            res = await fetchTransferRows(sb, stageArg, page, dateFrom, dateTo, transferKindFilter);
          } else if (sourceFilter === "aid") {
            res = await fetchAidRows(sb, stageArg, page, dateFrom, dateTo, "aid", aidStatusFilter);
          } else if (sourceFilter === "air") {
            res = await fetchAidRows(sb, stageArg, page, dateFrom, dateTo, "air", "");
          } else if (sourceFilter === "picking") {
            res = await fetchPickingRows(sb, stageArg, page, dateFrom, dateTo);
          } else {
            res = await fetchShortageRows(sb, stageArg, page, dateFrom, dateTo);
          }
          resultRows = res.rows;
          resultTotal = res.total;
        }

        if (cancelled) return;
        setRows(resultRows);
        setTotal(resultTotal);
        setError(null);
      } catch (e) {
        if (!cancelled) setError(translateRpcError(e));
      } finally {
        if (!cancelled) setLoadingRows(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [sourceFilter, effectiveStage, page, dateFrom, dateTo, aidStatusFilter, transferKindFilter, reloadTick]);

  // stage tab counts:依當前 sourceFilter,從 cached counts 算出
  const stageCounts = useMemo(() => {
    const c: Record<Stage, number> = { pending: 0, standby: 0, in_transit: 0, done: 0, rejected: 0 };
    if (!counts) return c;
    const sources: SourceTag[] = sourceFilter === "all"
      ? ["restock", "transfer", "aid", "shortage"]
      : [sourceFilter];
    for (const s of sources) {
      for (const stg of ALL_STAGES) {
        c[stg] += counts[s][stg] ?? 0;
      }
    }
    return c;
  }, [counts, sourceFilter]);

  // source chip counts:依當前 stage,從 cached counts 算出
  const sourceCounts = useMemo(() => {
    const c: Record<SourceTag, number> = { restock: 0, transfer: 0, aid: 0, air: 0, shortage: 0, picking: 0, exception: 0 };
    if (!counts) return c;
    const stages: Stage[] = effectiveStage === "all" ? ALL_STAGES : [effectiveStage];
    for (const s of ["restock", "transfer", "aid", "air", "shortage", "picking", "exception"] as SourceTag[]) {
      for (const stg of stages) c[s] += counts[s][stg] ?? 0;
    }
    return c;
  }, [counts, effectiveStage]);

  // server-side 已過濾 source / stage / 日期 / Aid filters,client-side 只做 search(限當前頁)
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (rows ?? []).filter((r) => {
      if (!q) return true;
      if (r.source === "restock") {
        const s = r.raw;
        return [s.store_name, s.notes, s.linked_transfer_no, s.linked_pr_no, `RESTOCK#${s.id}`]
          .filter((x): x is string => !!x)
          .some((x) => x.toLowerCase().includes(q));
      }
      if (r.source === "transfer") {
        const t = r.raw;
        return [t.transfer_no, t.source_name, t.dest_name, t.hq_notes].filter((x): x is string => !!x).some((x) => x.toLowerCase().includes(q));
      }
      if (r.source === "shortage") {
        const sh = r.raw;
        return [sh.order_no, sh.store_name, ...sh.short_items.map((it) => it.sku_label)]
          .filter((x): x is string => !!x).some((x) => x.toLowerCase().includes(q));
      }
      if (r.source === "picking") {
        const w = r.raw;
        return [w.wave_code, w.source_po_no, w.note]
          .filter((x): x is string => !!x).some((x) => x.toLowerCase().includes(q));
      }
      const a = r.raw;
      // 轉出店 / 來源單號也要搜得到 —— 列上顯示的就是「轉出店 → 收貨店」
      return [a.order_no, a.store_name, a.campaign_no, a.from_store_name, a.from_order_no]
        .filter((x): x is string => !!x).some((x) => x.toLowerCase().includes(q));
    });
  }, [rows, search]);

  // server-side 已分頁,paginatedRows 直接 = filtered(當前頁的 rows 經過 search 過濾)
  const paginatedRows = filtered;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));

  // 分頁控制列 — 列表上、下各放一份(手機不用滑到底才能換頁)
  const paginationBar = total > PAGE_SIZE ? (
    <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
      <span className="text-xs text-zinc-500">
        共 {total} 筆 ·
        顯示 {(page - 1) * PAGE_SIZE + 1} - {Math.min(page * PAGE_SIZE, total)}
      </span>
      <SpinButton onClick={() => setPage(1)} disabled={page === 1}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        « 第一頁
      </SpinButton>
      <SpinButton onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={page === 1}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        ‹ 上頁
      </SpinButton>
      <span className="text-xs text-zinc-500">{page} / {totalPages}</span>
      <SpinButton onClick={() => setPage((p) => Math.min(totalPages, p + 1))} disabled={page === totalPages}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        下頁 ›
      </SpinButton>
      <SpinButton onClick={() => setPage(totalPages)} disabled={page === totalPages}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        最末頁 »
      </SpinButton>
    </div>
  ) : null;

  // 任何 server 端篩選變動 → 回到第 1 頁(避免 page 超出範圍)
  useEffect(() => {
    setPage(1);
  }, [stage, sourceFilter, aidStatusFilter, transferKindFilter, dateFrom, dateTo]);

  // 計算 group key for each row
  function getGroupKey(r: Row): { key: string; label: string } {
    if (groupBy === "source") return { key: r.source, label: SOURCE_LABEL[r.source] };
    if (groupBy === "store") {
      let label = "未指定";
      if (r.source === "restock") label = r.raw.store_name ?? "未指定";
      else if (r.source === "transfer") label = r.raw.dest_name;
      else if (r.source === "aid" || r.source === "air") label = r.raw.store_name ?? "未指定";
      else if (r.source === "shortage") label = r.raw.store_name ?? "未指定";
      return { key: label, label };
    }
    if (groupBy === "campaign") {
      let key = "—", label = "無開團";
      if (r.source === "aid" || r.source === "air") {
        label = r.raw.campaign_no ?? "無開團";
        key = label;
      }
      // 其他來源沒 campaign 資訊,放「其他」
      else label = "(其他來源)";
      return { key: label === label ? key : "—", label };
    }
    return { key: "_all", label: "" };
  }

  // 依 groupBy 分組(只在 groupBy !== "none" 時有效)
  const grouped = useMemo(() => {
    if (groupBy === "none") return null;
    const map = new Map<string, { label: string; rows: Row[] }>();
    for (const r of paginatedRows) {
      const { key, label } = getGroupKey(r);
      const slot = map.get(key) ?? { label, rows: [] };
      slot.rows.push(r);
      map.set(key, slot);
    }
    return Array.from(map.entries())
      .sort((a, b) => a[1].label.localeCompare(b[1].label))
      .map(([key, v]) => ({ key, ...v }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [paginatedRows, groupBy]);

  async function approveToTransfer(id: number) {
    if (!confirm("確定派庫存出貨？此動作會建一張 transfer 單。")) return;
    setBusy(`restock-${id}-tx`);
    try {
      const { error: err } = await getSupabase().rpc("rpc_approve_restock_to_transfer", { p_request_id: id });
      if (err) throw err;
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  // 下訂單改開品相勾選視窗（RestockToPrModal），可依品相分張開請購單
  async function approveToPr(id: number) {
    setRestockPrId(id);
  }

  // 轉入 / 轉出候補區(status 維持 pending,只掛 standby_at 旗標;可隨時反悔,不跳 confirm)
  async function setStandby(id: number, standby: boolean) {
    setBusy(`restock-${id}-standby`);
    try {
      const { error: err } = await getSupabase().rpc("rpc_restock_set_standby", {
        p_request_id: id,
        p_standby: standby,
      });
      if (err) throw err;
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  async function shipPrReceived(id: number) {
    if (!confirm("確定 PR 已到貨、現在從 HQ 派貨到分店？")) return;
    setBusy(`restock-${id}-ship`);
    try {
      const { error: err } = await getSupabase().rpc("rpc_ship_restock_pr_received", { p_request_id: id });
      if (err) throw err;
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  async function reject() {
    if (!rejectModal || !rejectModal.reason.trim()) return;
    setBusy(`restock-${rejectModal.id}-reject`);
    try {
      const { error: err } = await getSupabase().rpc("rpc_reject_restock", {
        p_request_id: rejectModal.id,
        p_reason: rejectModal.reason.trim(),
      });
      if (err) throw err;
      setRejectModal(null);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  function toggleSelected(key: string) {
    setSelected((cur) => {
      const next = new Set(cur);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  // 「可批次」的 row keys
  // - transfer source:pending(配送 / 刪除) + in_transit(到倉) 都可
  // - picking source:pending(派貨出倉 / 刪除)
  // - 其他 source:只 pending
  const batchableKeys = useMemo(() => {
    if (sourceFilter === "all") return [] as string[];
    if (sourceFilter === "air") return [] as string[]; // 空中轉唯讀,不可批次
    return paginatedRows
      .filter((r) => {
        if (r.source !== sourceFilter) return false;
        if (sourceFilter === "transfer") {
          return r.stage === "pending" || r.stage === "in_transit";
        }
        if (sourceFilter === "restock") {
          return r.stage === "pending" || r.stage === "standby";
        }
        return r.stage === "pending";
      })
      .map((r) => r.key);
  }, [paginatedRows, sourceFilter]);

  // 批次配送日選擇器顯示值 = 所選撿貨單中最早的配送日（不另存 state，改完 reload 自動跟著更新）
  const batchWaveDate = useMemo(() => {
    const dates = paginatedRows
      .filter((r) => selected.has(r.key) && r.source === "picking")
      .map((r) => (r.raw as PickingRaw).wave_date)
      .sort();
    return dates[0] ?? "";
  }, [paginatedRows, selected]);

  function selectAllVisible() {
    setSelected(new Set(batchableKeys));
  }
  function clearSelection() {
    setSelected(new Set());
  }

  // 批次動作 — 依 sourceFilter 跑對應 RPC
  async function batchAction(action: string) {
    // transfer source 可以批次的 row 含 pending 與 in_transit;其他 source 只 pending
    // 「確認入倉 / 退訂單取消」是退訂單 (shipped + return_to_hq) 專屬、stage='pending'
    const validStages: Record<string, Stage[]> =
      sourceFilter === "transfer"
        ? {
            "配送": ["pending"], "刪除": ["pending"], "到倉": ["in_transit"],
            "確認入倉": ["pending"], "退訂單取消": ["pending"],
          }
        : sourceFilter === "picking"
          ? { "派貨出倉": ["pending"], "取消": ["pending"] }
          : sourceFilter === "restock"
            ? {
                "派貨": ["pending", "standby"], "下訂單": ["pending", "standby"],
                "轉候補": ["pending"], "取消候補": ["standby"],
              }
            : {};
    const allowedStages = validStages[action] ?? (["pending"] as Stage[]);
    let items = paginatedRows.filter(
      (r) => selected.has(r.key) && allowedStages.includes(r.stage),
    );
    // 退訂單專屬動作要再過濾 transfer_type
    if (sourceFilter === "transfer" && (action === "確認入倉" || action === "退訂單取消")) {
      items = items.filter((r) => r.source === "transfer" && isOrderReturnTransfer((r.raw as TransferRaw).notes));
    } else if (sourceFilter === "transfer" && (action === "配送" || action === "刪除")) {
      // 一般 pending 動作排除退訂單（退訂單不該被「配送/刪除」）
      items = items.filter((r) => r.source === "transfer" && !isOrderReturnTransfer((r.raw as TransferRaw).notes));
    }
    if (items.length === 0) return;

    // 「退訂單取消」要先輸入原因（與單筆 reject 對齊、走 audit log）
    let reason: string | null = null;
    if (action === "退訂單取消") {
      reason = prompt(`取消原因(必填、會留 audit log，將套用到全部 ${items.length} 筆)：`);
      if (!reason || !reason.trim()) return;
    } else {
      if (!confirm(`確認對選中的 ${items.length} 筆執行「${action}」?`)) return;
    }
    setBatchBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      // transfer 走批次 RPC、整批一次發
      if (sourceFilter === "transfer") {
        const ids = items
          .filter((r) => r.source === "transfer")
          .map((r) => (r.raw as TransferRaw).id);

        // 退訂單取消沒有 batch RPC，逐筆呼叫 rpc_reject_transfer
        if (action === "退訂單取消") {
          const settles = await Promise.allSettled(
            ids.map((id) =>
              sb.rpc("rpc_reject_transfer", {
                p_transfer_id: id,
                p_reason: reason,
                p_operator: operator,
              }),
            ),
          );
          let ok = 0;
          const fails: { id: number; reason: string }[] = [];
          settles.forEach((s, i) => {
            if (s.status === "fulfilled" && !s.value.error) ok += 1;
            else {
              const msg = s.status === "rejected"
                ? String(s.reason)
                : translateRpcError(s.value.error);
              fails.push({ id: ids[i], reason: msg });
            }
          });
          if (fails.length === 0) {
            alert(`✅ 取消 ${ok} 筆退貨回總倉單`);
          } else {
            const lines = fails.slice(0, 5).map((f) => `  #${f.id}: ${f.reason}`);
            alert(
              `成功 ${ok} / 失敗 ${fails.length}\n\n${lines.join("\n")}` +
                (fails.length > 5 ? `\n…(還有 ${fails.length - 5} 筆)` : ""),
            );
          }
          setSelected(new Set());
          setReloadTick((t) => t + 1);
          return;
        }

        let rpcName: string;
        let params: Record<string, unknown>;
        if (action === "配送") {
          if (hqLocId === null) throw new Error("找不到 HQ location");
          rpcName = "rpc_transfer_distribute_batch";
          params = { p_transfer_ids: ids, p_hq_location_id: hqLocId, p_operator: operator };
        } else if (action === "到倉" || action === "確認入倉") {
          if (hqLocId === null) throw new Error("找不到 HQ location");
          rpcName = "rpc_transfer_arrive_at_hq_batch";
          params = { p_transfer_ids: ids, p_hq_location_id: hqLocId, p_operator: operator };
        } else if (action === "刪除") {
          rpcName = "rpc_transfer_batch_delete";
          params = { p_transfer_ids: ids, p_operator: operator };
        } else {
          throw new Error(`無對應動作: transfer/${action}`);
        }
        const { data, error: err } = await sb.rpc(rpcName, params);
        if (err) throw new Error(translateRpcError(err));
        const res = data as {
          succeeded?: number[];
          deleted?: number[];
          failed?: { id: number; reason: string }[];
        };
        const okCount = (res.succeeded?.length ?? 0) + (res.deleted?.length ?? 0);
        const fails = res.failed ?? [];
        if (fails.length === 0) {
          alert(`✅ 完成 ${okCount} 筆`);
        } else {
          const lines = fails.slice(0, 5).map((f) => `  #${f.id}: ${translateRpcError(f.reason)}`);
          alert(
            `成功 ${okCount} / 失敗 ${fails.length}\n\n${lines.join("\n")}` +
              (fails.length > 5 ? `\n…(還有 ${fails.length - 5} 筆)` : ""),
          );
        }
        setSelected(new Set());
        setReloadTick((t) => t + 1);
        return;
      }

      // 非 transfer source — 沿用 per-row Promise.allSettled
      const results = await Promise.allSettled(items.map(async (r) => {
        if (r.source === "restock") {
          const id = r.raw.id;
          if (action === "派貨") return sb.rpc("rpc_approve_restock_to_transfer", { p_request_id: id });
          // 批次下訂單＝整張申請開一張請購單；要依品相分張請用單筆列的「下訂單」
          if (action === "下訂單") return sb.rpc("rpc_approve_restock_to_pr", { p_request_id: id });
          if (action === "轉候補") return sb.rpc("rpc_restock_set_standby", { p_request_id: id, p_standby: true });
          if (action === "取消候補") return sb.rpc("rpc_restock_set_standby", { p_request_id: id, p_standby: false });
        }
        if (r.source === "aid") {
          const id = r.raw.id;
          if (action === "確認") return sb.rpc("rpc_advance_order_status", { p_order_id: id, p_new_status: "confirmed", p_operator: operator });
          if (action === "派貨") return sb.rpc("rpc_ship_aid_order", { p_order_id: id, p_operator: operator });
        }
        if (r.source === "shortage") {
          const id = r.raw.order_id;
          const map: Record<string, string> = { "通知客戶": "notified", "等下批": "waiting_next_po" };
          const a = map[action];
          if (a) return sb.rpc("rpc_handle_shortage_order", { p_order_id: id, p_action: a, p_operator: operator });
        }
        if (r.source === "picking") {
          const w = r.raw;
          if (action === "派貨出倉") {
            if (hqLocId === null) throw new Error("找不到 HQ location");
            // 兩步:必要時 confirm_picked,再 generate_transfer
            if (w.status !== "picked") {
              const { error: e1 } = await sb.rpc("rpc_confirm_picked", { p_wave_id: w.id, p_operator: operator });
              if (e1) return { error: e1 };
            }
            return sb.rpc("generate_transfer_from_wave", { p_wave_id: w.id, p_hq_location_id: hqLocId, p_operator: operator });
          }
          if (action === "取消") {
            return sb.rpc("rpc_cancel_picking_wave", { p_wave_id: w.id, p_operator: operator, p_reason: "批次取消" });
          }
        }
        throw new Error(`無對應動作: ${r.source}/${action}`);
      }));

      const okCount = results.filter((r) => r.status === "fulfilled" && !(r.value as { error?: unknown })?.error).length;
      const failed = results.length - okCount;
      if (failed === 0) {
        alert(`✅ 完成 ${okCount} 筆`);
      } else {
        const errs: string[] = [];
        results.forEach((r) => {
          if (r.status === "rejected") errs.push(translateRpcError(r.reason));
          else if ((r.value as { error?: { message?: string } })?.error) errs.push(translateRpcError((r.value as { error: { message: string } }).error.message));
        });
        alert(`成功 ${okCount} / 失敗 ${failed}\n\n${errs.slice(0, 3).join("\n")}`);
      }
      setSelected(new Set());
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBatchBusy(false);
    }
  }

  // 批次設定配送日 — 只對勾選的「待處理」撿貨單（shipped/cancelled 不在 batchable 內，RPC 端也擋）
  async function batchSetWaveDate(newDate: string) {
    const targets = paginatedRows.filter(
      (r) => selected.has(r.key) && r.source === "picking" && r.stage === "pending" && r.raw.wave_date !== newDate,
    );
    if (targets.length === 0) return;
    if (!confirm(`將選中的 ${targets.length} 張撿貨單配送日改為 ${newDate}？`)) return;
    setBatchBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      const results = await Promise.allSettled(
        targets.map((r) =>
          sb.rpc("rpc_update_wave_date", {
            p_wave_id: (r.raw as PickingRaw).id,
            p_new_date: newDate,
            p_operator: operator,
          }),
        ),
      );
      const okCount = results.filter((r) => r.status === "fulfilled" && !(r.value as { error?: unknown })?.error).length;
      const failed = results.length - okCount;
      if (failed === 0) {
        alert(`✅ 已將 ${okCount} 張撿貨單配送日改為 ${newDate}`);
      } else {
        const errs: string[] = [];
        results.forEach((r) => {
          if (r.status === "rejected") errs.push(translateRpcError(r.reason));
          else if ((r.value as { error?: { message?: string } })?.error) {
            errs.push(translateRpcError((r.value as { error: { message: string } }).error.message));
          }
        });
        alert(`成功 ${okCount} / 失敗 ${failed}\n\n${errs.slice(0, 3).join("\n")}`);
      }
      setSelected(new Set());
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBatchBusy(false);
    }
  }

  async function handleTransferAction(transferId: number, action: "ship" | "arrive_at_hq" | "delete" | "reject" | "unreject") {
    const labels: Record<typeof action, string> = {
      ship: "從 HQ 出貨(扣庫存、推到「已出貨」)",
      arrive_at_hq: "確認到倉(全收、入 HQ 庫存)",
      delete: "刪除草稿",
      reject: "取消(拒收、將貨退回 source location)",
      unreject: "恢復在途(沖銷拒收回流、單據回到店端待收)",
    };
    let reason: string | null = null;
    if (action === "reject") {
      reason = prompt(`取消原因(必填,會留 audit log):`);
      if (!reason || !reason.trim()) return;
    } else {
      if (!confirm(`確定:${labels[action]}?`)) return;
    }
    setBusy(`transfer-${transferId}-${action}`);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      if ((action === "ship" || action === "arrive_at_hq") && hqLocId === null) {
        throw new Error("找不到 HQ location");
      }
      let rpcName: string;
      let params: Record<string, unknown>;
      if (action === "ship") {
        rpcName = "rpc_transfer_distribute_batch";
        params = { p_transfer_ids: [transferId], p_hq_location_id: hqLocId, p_operator: operator };
      } else if (action === "arrive_at_hq") {
        rpcName = "rpc_transfer_arrive_at_hq_batch";
        params = { p_transfer_ids: [transferId], p_hq_location_id: hqLocId, p_operator: operator };
      } else if (action === "reject") {
        rpcName = "rpc_reject_transfer";
        params = { p_transfer_id: transferId, p_reason: reason, p_operator: operator };
      } else if (action === "unreject") {
        rpcName = "rpc_unreject_transfer";
        params = { p_transfer_id: transferId, p_operator: operator, p_notes: null };
      } else {
        rpcName = "rpc_transfer_batch_delete";
        params = { p_transfer_ids: [transferId], p_operator: operator };
      }
      const { data, error: err } = await sb.rpc(rpcName, params);
      if (err) throw err;
      const res = data as { failed?: { id: number; reason: string }[] } | null;
      if (res?.failed && res.failed.length > 0) {
        throw new Error(res.failed.map((f) => `#${f.id}: ${f.reason}`).join("\n"));
      }
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  async function handleShortageAction(orderId: number, action: "notified" | "cancelled" | "waiting_next_po" | "reallocated") {
    const labelMap: Record<typeof action, string> = {
      notified: "通知客戶(PWA 推播 + 標記已通知)",
      cancelled: "取消(請去訂單頁正式取消退款)",
      waiting_next_po: "等下批 PO 補貨",
      reallocated: "改派(從其他店調貨)",
    };
    if (!confirm(`確定:${labelMap[action]}?`)) return;
    setBusy(`shortage-${orderId}-${action}`);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: err } = await sb.rpc("rpc_handle_shortage_order", {
        p_order_id: orderId,
        p_action: action,
        p_operator: operator,
      });
      if (err) throw err;
      // TODO: action='notified' 觸發 PWA push edge function
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  // ============== 撿貨單 row 動作 ==============
  async function dispatchWave(w: PickingRaw) {
    if (hqLocId === null) {
      setError("找不到 HQ location");
      return;
    }
    const needsConfirm = w.status !== "picked";
    const diff = w.actual_total - w.expected_total;
    const diffMsg = diff === 0 ? "" : diff > 0 ? `\n⚠ 實分 多 ${diff}(超撿)` : `\n⚠ 實分 少 ${-diff}(短缺)`;
    const msg =
      `確認派貨出倉 ${w.wave_code}?\n${w.store_count} 間分店 · 應發 ${w.expected_total} / 實分 ${w.actual_total}${diffMsg}\n\n` +
      (needsConfirm ? "目前狀態為「" + w.status + "」,將自動 確認撿貨完成 + 派貨出倉。" : "將從總倉建立 transfer 並出庫。");
    if (!confirm(msg)) return;
    setDispatchingWaveId(w.id);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      if (needsConfirm) {
        const { error: e1 } = await sb.rpc("rpc_confirm_picked", { p_wave_id: w.id, p_operator: operator });
        if (e1) throw new Error(translateRpcError(e1));
      }
      const { error: e2 } = await sb.rpc("generate_transfer_from_wave", {
        p_wave_id: w.id,
        p_hq_location_id: hqLocId,
        p_operator: operator,
      });
      if (e2) throw new Error(translateRpcError(e2));
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setDispatchingWaveId(null);
    }
  }

  async function cancelWave(w: PickingRaw) {
    const reason = prompt(`取消撿貨單 ${w.wave_code} — 取消原因(選填,會留 audit log):`);
    if (reason === null) return; // 按取消視同放棄
    setBusy(`picking-${w.id}-cancel`);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_cancel_picking_wave", {
        p_wave_id: w.id,
        p_operator: operator,
        p_reason: reason.trim() || null,
      });
      if (e) throw new Error(translateRpcError(e));
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  // 配送日改在收件匣設定（派貨工作台建單只帶預設隔天）；shipped/cancelled 由 RPC 擋
  async function changeWaveDate(w: PickingRaw, newDate: string) {
    if (newDate === w.wave_date) return;
    setBusy(`picking-${w.id}-date`);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_update_wave_date", {
        p_wave_id: w.id,
        p_new_date: newDate,
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  function openWaveEdit(w: PickingRaw) {
    // PickModal 需要的欄位跟 PickingRaw 完全相同(除了 source_po_no 在 outbound 是 null|string,picking 也是)
    setEditingWave({
      id: w.id,
      wave_code: w.wave_code,
      wave_date: w.wave_date,
      status: w.status,
      store_count: w.store_count,
      item_count: w.item_count,
      total_qty: w.total_qty,
      note: w.note,
      created_at: w.created_at,
      expected_total: w.expected_total,
      actual_total: w.actual_total,
      source_po_id: w.source_po_id,
      source_po_no: w.source_po_no,
    });
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">總倉收件匣</h1>
        {(rows === null || hqLocId === null) && (
          <p className="text-sm text-zinc-500">
            {rows === null ? "載入中…" : ""}
            {hqLocId === null ? " ⚠️ 未找到 HQ location" : ""}
          </p>
        )}
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* === 來源資料夾 chip bar === */}
      <div className="flex flex-wrap items-center gap-2">
        {(["picking", "restock", "transfer", "aid", "air", "exception"] as const).map((s) => {
          const active = sourceFilter === s;
          const label = ({
            picking: "📋 撿貨單",
            restock: "📦 補貨申請",
            transfer: "🚚 轉貨單",
            aid: "🤝 互助訂單",
            air: "✈️ 空中轉",
            exception: "⚠️ 異常",
          } as const)[s];
          // chip 顯示「該來源」的待處理數(從 cached counts 算,固定值,跟 stage 切換無關)
          // exception 走自己的 exceptionCount = 異常四類總和(counts.all,理由見宣告處註解),
          //   跟點進去看到的「全部」分頁同一個數字
          // air 顯示「在途」數(空中轉自動出貨,貨在飛=in_transit),非 pending
          const count = s === "exception"
            ? exceptionCount
            : s === "air"
              ? (!counts ? 0 : counts.air.in_transit)
              : (!counts ? 0 : counts[s].pending);
          return (
            <SpinButton
              key={s}
              // 空中轉自動出貨、無 pending 單;選它時跳「全部」stage 才看得到紀錄
              // 「候補」stage 只有補貨申請有,切走時退回「待處理」
              onClick={() => {
                setSourceFilter(s);
                if (s === "air") setStage("all");
                else if (stage === "standby" && s !== "restock") setStage("pending");
              }}
              className={`flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium transition ${
                active
                  ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                  : "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
              }`}
            >
              <span>{label}</span>
              {count > 0 && (
                <span className={`rounded-full px-1.5 py-0.5 text-[10px] font-semibold ${
                  active ? "bg-white/20 text-white dark:bg-zinc-900/20 dark:text-zinc-900" : "bg-blue-600 text-white"
                }`}>
                  {count}
                </span>
              )}
            </SpinButton>
          );
        })}
      </div>

      {/* Aid 專屬篩選 — 選 Aid 才出現(空中轉已獨立成 air source,故只剩狀態篩選) */}
      {sourceFilter === "aid" && (
        <div className="flex flex-wrap items-center gap-2 rounded-md border border-fuchsia-200 bg-fuchsia-50 px-3 py-2 text-xs dark:border-fuchsia-900 dark:bg-fuchsia-950/30">
          <span className="font-semibold text-fuchsia-700 dark:text-fuchsia-300">互助專屬:</span>
          <select
            value={aidStatusFilter}
            onChange={(e) => setAidStatusFilter(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-900"
          >
            <option value="">全部狀態</option>
            {Object.entries(AID_STATUS_LABEL).map(([v, l]) => (
              <option key={v} value={v}>{l}</option>
            ))}
          </select>
          {aidStatusFilter && (
            <SpinButton
              onClick={() => {
                setAidStatusFilter("");
              }}
              className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              清除
            </SpinButton>
          )}
        </div>
      )}

      {/* Transfer 專屬篩選 — 選 轉貨單 才出現 */}
      {sourceFilter === "transfer" && (
        <div className="flex flex-wrap items-center gap-2 rounded-md border border-blue-200 bg-blue-50 px-3 py-2 text-xs dark:border-blue-900 dark:bg-blue-950/30">
          <span className="font-semibold text-blue-700 dark:text-blue-300">類型:</span>
          {(
            [
              { v: "all", label: "全部" },
              { v: "hq_to_store", label: "🚚 總倉派貨" },
              { v: "store_to_store", label: "🔄 自由轉貨" },
              { v: "return_to_hq", label: "↩ 退貨回總倉" },
            ] as { v: typeof transferKindFilter; label: string }[]
          ).map((opt) => {
            const active = transferKindFilter === opt.v;
            return (
              <SpinButton
                key={opt.v}
                onClick={() => setTransferKindFilter(opt.v)}
                className={`rounded-full border px-2.5 py-1 text-xs font-medium ${
                  active
                    ? "border-blue-700 bg-blue-700 text-white"
                    : "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
                }`}
              >
                {opt.label}
              </SpinButton>
            );
          })}
        </div>
      )}

      {/* === 主區 === */}
      <div className="flex flex-1 flex-col gap-3 min-w-0">
        {sourceFilter === "exception" ? (
          <ExceptionsContent showHeader={false} onCountChange={handleExceptionListChanged} />
        ) : (
          <>

          {/* Toolbar: 搜尋 + 起迄日 + 閱讀模式 */}
          <div className="flex flex-wrap items-center gap-2">
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="🔍 搜尋 單號 / 店 / 備註"
              className="flex-1 min-w-[180px] rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
            />
            <input
              type="date"
              value={dateFrom}
              onChange={(e) => setDateFrom(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
              title="起日"
            />
            <span className="text-xs text-zinc-400">~</span>
            <input
              type="date"
              value={dateTo}
              onChange={(e) => setDateTo(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
              title="迄日"
            />
            <label className="flex items-center gap-1 text-xs text-zinc-500">
              <span>閱讀模式</span>
              <select
                value={groupBy}
                onChange={(e) => setGroupBy(e.target.value as typeof groupBy)}
                className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-900"
              >
                <option value="none">不分組</option>
                <option value="store">分店</option>
                <option value="campaign">開團</option>
              </select>
            </label>
          </div>

          {/* Stage tabs (套用在當前資料夾;「候補」只有補貨申請有) */}
          <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
            {(sourceFilter === "restock"
              ? (["pending", "standby", "in_transit", "done", "rejected", "all"] as const)
              : (["pending", "in_transit", "done", "rejected", "all"] as const)
            ).map((s) => {
              const label = s === "all" ? "全部" : STAGE_LABEL[s];
              const count = s === "all"
                ? Object.values(stageCounts).reduce((a, b) => a + b, 0)
                : stageCounts[s];
              const active = effectiveStage === s;
              return (
                <SpinButton
                  key={s}
                  onClick={() => setStage(s)}
                  className={`-mb-px border-b-2 px-3 py-2 text-sm ${
                    active
                      ? "border-blue-600 font-semibold text-blue-700 dark:text-blue-300"
                      : "border-transparent text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
                  }`}
                >
                  {label} <span className="ml-1 text-xs text-zinc-400">{count}</span>
                </SpinButton>
              );
            })}
          </div>

          {/* 批次工具列 */}
          {sourceFilter !== "all" && batchableKeys.length > 0 && (
            <div className="flex flex-wrap items-center gap-2 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
              <input
                type="checkbox"
                checked={selected.size > 0 && selected.size === batchableKeys.length}
                onChange={() => selected.size === batchableKeys.length ? clearSelection() : selectAllVisible()}
                className="cursor-pointer"
                title="全選 / 清空"
              />
              <span className="text-xs text-zinc-500">
                {selected.size > 0 ? `已選 ${selected.size} / ${batchableKeys.length} 筆待處理` : `${batchableKeys.length} 筆待處理可批次`}
              </span>
              <SpinButton
                type="button"
                onClick={selectAllVisible}
                disabled={selected.size === batchableKeys.length}
                className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                全選
              </SpinButton>
              {selected.size > 0 && (
                <SpinButton
                  type="button"
                  onClick={clearSelection}
                  className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  清空
                </SpinButton>
              )}
              {selected.size > 0 && (
                <div className="ml-auto flex flex-wrap gap-1">
                  {sourceFilter === "restock" && (
                    <>
                      <RowAction variant="success" onClick={() => batchAction("派貨")} disabled={batchBusy}>派貨 ({selected.size})</RowAction>
                      <RowAction variant="indigo" onClick={() => batchAction("下訂單")} disabled={batchBusy}>下訂單 ({selected.size})</RowAction>
                      {effectiveStage === "pending" && (
                        <RowAction variant="warning" onClick={() => batchAction("轉候補")} disabled={batchBusy}>⏳ 轉候補 ({selected.size})</RowAction>
                      )}
                      {effectiveStage === "standby" && (
                        <RowAction variant="neutral" onClick={() => batchAction("取消候補")} disabled={batchBusy}>取消候補 ({selected.size})</RowAction>
                      )}
                    </>
                  )}
                  {sourceFilter === "aid" && (
                    <>
                      <RowAction variant="primary" onClick={() => batchAction("確認")} disabled={batchBusy}>確認 ({selected.size})</RowAction>
                      <RowAction variant="success" onClick={() => batchAction("派貨")} disabled={batchBusy}>派貨 ({selected.size})</RowAction>
                    </>
                  )}
                  {sourceFilter === "shortage" && (
                    <>
                      <RowAction variant="primary" onClick={() => batchAction("通知客戶")} disabled={batchBusy}>通知客戶 ({selected.size})</RowAction>
                      <RowAction variant="warning" onClick={() => batchAction("等下批")} disabled={batchBusy}>等下批 ({selected.size})</RowAction>
                    </>
                  )}
                  {sourceFilter === "picking" && (
                    <>
                      <Link
                        href={`/picking/print-sign?waveIds=${paginatedRows
                          .filter((r) => selected.has(r.key) && r.source === "picking")
                          .map((r) => (r.raw as PickWave).id)
                          .join(",")}`}
                        target="_blank"
                        className="inline-flex items-center rounded border border-blue-300 bg-blue-50 px-2 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                      >
                        📄 列印簽收單 ({selected.size})
                      </Link>
                      <div
                        className="inline-flex items-center gap-1 rounded border border-blue-300 bg-blue-50 px-2 py-1 text-xs font-medium text-blue-700 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300"
                        title="一次把所選撿貨單的配送日改成同一天"
                      >
                        📅 設定配送日 ({selected.size})
                        <DatePicker
                          value={batchWaveDate}
                          onChange={batchSetWaveDate}
                          popover="fixed"
                          disabled={batchBusy}
                          className="rounded border border-dashed border-blue-400 px-1 font-mono text-xs font-semibold text-blue-700 hover:bg-blue-100 disabled:opacity-50 dark:border-blue-600 dark:text-blue-300 dark:hover:bg-blue-900"
                        />
                      </div>
                      <RowAction variant="success" onClick={() => batchAction("派貨出倉")} disabled={batchBusy}>派貨出倉 ({selected.size})</RowAction>
                      <RowAction variant="danger" onClick={() => batchAction("取消")} disabled={batchBusy}>取消 ({selected.size})</RowAction>
                    </>
                  )}
                  {sourceFilter === "transfer" && (() => {
                    // 只有當所選 row 全部同 stage 才顯示對應動作(避免混 batch)
                    // pending 還要再細分「退訂單」vs「一般 draft」— 兩者動作完全不同
                    const sel = paginatedRows.filter((r) => selected.has(r.key) && r.source === "transfer");
                    const stages = new Set(sel.map((r) => r.stage));
                    const allPending = stages.size === 1 && stages.has("pending");
                    const allInTransit = stages.size === 1 && stages.has("in_transit");
                    const pendingTypes = new Set(
                      sel.map((r) => (isOrderReturnTransfer((r.raw as TransferRaw).notes) ? "return" : "normal"))
                    );
                    const allPendingReturn = allPending && pendingTypes.size === 1 && pendingTypes.has("return");
                    const allPendingNormal = allPending && pendingTypes.size === 1 && pendingTypes.has("normal");
                    return (
                      <>
                        {allPendingNormal && (
                          <>
                            <RowAction variant="success" onClick={() => batchAction("配送")} disabled={batchBusy}>配送 ({selected.size})</RowAction>
                            <RowAction variant="danger" onClick={() => batchAction("刪除")} disabled={batchBusy}>刪除 ({selected.size})</RowAction>
                          </>
                        )}
                        {allPendingReturn && (
                          <>
                            <RowAction variant="primary" onClick={() => batchAction("確認入倉")} disabled={batchBusy}>確認入倉 ({selected.size})</RowAction>
                            <RowAction variant="danger" onClick={() => batchAction("退訂單取消")} disabled={batchBusy}>取消 ({selected.size})</RowAction>
                          </>
                        )}
                        {allPending && !allPendingReturn && !allPendingNormal && (
                          <span className="self-center text-xs text-zinc-500">已混合退貨回總倉與一般轉貨、無法批次</span>
                        )}
                        {allInTransit && (
                          <RowAction variant="primary" onClick={() => batchAction("到倉")} disabled={batchBusy}>到倉 ({selected.size})</RowAction>
                        )}
                        {!allPending && !allInTransit && (
                          <span className="self-center text-xs text-zinc-500">已選跨多階段、無法批次</span>
                        )}
                      </>
                    );
                  })()}
                </div>
              )}
            </div>
          )}

          {/* 分頁 — 列表上方(手機優先看得到) */}
          {paginationBar}

          {/* === Row list (郵件列) === */}
          <div className="overflow-hidden rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            {rows === null ? (
              <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>
            ) : filtered.length === 0 ? (
              <div className="p-6 text-center text-sm text-zinc-500">目前沒有資料</div>
            ) : (
              (() => {
                const showCheckbox = sourceFilter !== "all" && batchableKeys.length > 0;
                const renderRow = (r: Row) => {
                  const batchable = batchableKeys.includes(r.key);
                  return (
                    <MailRow key={r.key} row={r} busy={busy}
                      onApproveTransfer={approveToTransfer} onApprovePr={approveToPr} onShipPrReceived={shipPrReceived}
                      onSetStandby={setStandby}
                      onOpenReject={(id) => setRejectModal({ id, reason: "" })}
                      onOpenAidDetail={setAidDetailId} onAidChanged={() => setReloadTick((t) => t + 1)}
                      onOpenTransferDetail={setTransferDetailId} onOpenRestockDetail={setRestockDetailId}
                      onShortageAction={handleShortageAction} onTransferAction={handleTransferAction}
                      onPickingDispatch={dispatchWave} onPickingEdit={openWaveEdit} onPickingCancel={cancelWave}
                      onPickingDateChange={changeWaveDate}
                      dispatchingWaveId={dispatchingWaveId}
                      hqLocId={hqLocId}
                      showCheckbox={showCheckbox} batchable={batchable}
                      selected={selected.has(r.key)} onToggleSelect={() => toggleSelected(r.key)}
                    />
                  );
                };
                if (grouped) {
                  return grouped.flatMap((g) => [
                    <div key={`g-${g.key}`} className="border-b border-zinc-200 bg-zinc-100 px-4 py-2 text-xs font-semibold text-zinc-700 dark:border-zinc-800 dark:bg-zinc-800 dark:text-zinc-200">
                      📂 {g.label} <span className="ml-2 font-normal text-zinc-500">({g.rows.length})</span>
                    </div>,
                    ...g.rows.map(renderRow),
                  ]);
                }
                return paginatedRows.map(renderRow);
              })()
            )}
          </div>

          {/* 分頁 — server-side,所有來源(含「全部」)都可用;列表下方再放一份 */}
          {paginationBar}
          </>
        )}
      </div>

      {rejectModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-md rounded-md bg-white p-4 shadow-lg dark:bg-zinc-900">
            <h2 className="mb-3 text-base font-semibold">拒絕補貨申請 #{rejectModal.id}</h2>
            <label className="block space-y-1 text-sm">
              <span className="text-zinc-600 dark:text-zinc-400">拒絕原因 *</span>
              <textarea
                value={rejectModal.reason}
                onChange={(e) => setRejectModal({ ...rejectModal, reason: e.target.value })}
                placeholder="例如：庫存不足且採購週期太長 / 商品已停售…"
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                rows={3}
              />
            </label>
            <div className="mt-3 flex gap-2">
              <SpinButton
                onClick={reject}
                disabled={!rejectModal.reason.trim() || busy === `restock-${rejectModal.id}-reject`}
                className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-500 disabled:opacity-50"
              >
                確認拒絕
              </SpinButton>
              <SpinButton
                onClick={() => setRejectModal(null)}
                className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
              >
                取消
              </SpinButton>
            </div>
          </div>
        </div>
      )}

      <Modal
        open={aidDetailId !== null}
        onClose={() => setAidDetailId(null)}
        title="互助訂單明細"
        maxWidth="max-w-4xl"
      >
        {aidDetailId !== null && <OrderDetail orderId={aidDetailId} />}
      </Modal>

      <TransferDetailModal
        open={transferDetailId !== null}
        transferId={transferDetailId}
        onClose={() => setTransferDetailId(null)}
      />
      <RestockDetailModal
        open={restockDetailId !== null}
        restockId={restockDetailId}
        onClose={() => setRestockDetailId(null)}
      />
      <RestockToPrModal
        open={restockPrId !== null}
        restockId={restockPrId}
        onClose={() => setRestockPrId(null)}
        onDone={() => setReloadTick((t) => t + 1)}
      />

      {editingWave && (
        <PickModal
          wave={editingWave}
          onClose={() => {
            setEditingWave(null);
            setReloadTick((t) => t + 1);
          }}
          onSubmitted={() => {
            setEditingWave(null);
            setReloadTick((t) => t + 1);
          }}
        />
      )}
    </div>
  );
}

function MailRow({
  row,
  busy,
  onApproveTransfer,
  onApprovePr,
  onShipPrReceived,
  onSetStandby,
  onOpenReject,
  onOpenAidDetail,
  onAidChanged,
  onOpenTransferDetail,
  onOpenRestockDetail,
  onShortageAction,
  onTransferAction,
  onPickingDispatch,
  onPickingEdit,
  onPickingCancel,
  onPickingDateChange,
  dispatchingWaveId,
  hqLocId,
  showCheckbox,
  batchable,
  selected,
  onToggleSelect,
}: {
  row: Row;
  busy: string | null;
  onApproveTransfer: (id: number) => Promise<void>;
  onApprovePr: (id: number) => Promise<void>;
  onShipPrReceived: (id: number) => Promise<void>;
  onSetStandby: (id: number, standby: boolean) => Promise<void>;
  onOpenReject: (id: number) => void;
  onOpenAidDetail: (id: number) => void;
  onAidChanged: () => void;
  onOpenTransferDetail: (id: number) => void;
  onOpenRestockDetail: (id: number) => void;
  onShortageAction: (orderId: number, action: "notified" | "cancelled" | "waiting_next_po" | "reallocated") => Promise<void>;
  onTransferAction: (transferId: number, action: "ship" | "arrive_at_hq" | "delete" | "reject" | "unreject") => Promise<void>;
  onPickingDispatch: (w: PickingRaw) => Promise<void>;
  onPickingEdit: (w: PickingRaw) => void;
  onPickingCancel: (w: PickingRaw) => Promise<void>;
  onPickingDateChange: (w: PickingRaw, newDate: string) => Promise<void>;
  dispatchingWaveId: number | null;
  hqLocId: number | null;
  showCheckbox: boolean;
  batchable: boolean;
  selected: boolean;
  onToggleSelect: () => void;
}) {
  const isPending = row.stage === "pending";
  const stageCls = STAGE_COLOR[row.stage];
  const stageText = STAGE_LABEL[row.stage];
  const accent = ({
    restock: "border-l-indigo-500",
    transfer: "border-l-blue-500",
    aid: "border-l-fuchsia-500",
    air: "border-l-sky-500",
    shortage: "border-l-rose-500",
    picking: "border-l-emerald-500",
  } as const)[row.source];

  // source chip:transfer 依 transfer_type 細分,其他用 SOURCE_LABEL/COLOR
  // 註：互助訂單派貨實際走 hq_to_store + store_to_store（transfer_no 前綴 AT-），
  // 不是 aid_handoff。aid_handoff transfer_type 目前沒任何 RPC 產生，故不放 mapping。
  let sourceCls = SOURCE_COLOR[row.source];
  let sourceText: string = SOURCE_LABEL[row.source];
  let sourceTitle: string | undefined;
  if (row.source === "transfer") {
    const t = row.raw;
    const isOrderReturn = isOrderReturnTransfer(t.notes);
    const isAidTransfer = t.transfer_no.startsWith("AT-");
    if (isOrderReturn) {
      sourceCls = "bg-rose-100 text-rose-700 dark:bg-rose-950 dark:text-rose-300";
      sourceText = "↩ 退貨回總倉";
      sourceTitle = "由店端顧客訂單退貨回總倉建立";
    } else if (isAidTransfer) {
      sourceCls = "bg-fuchsia-100 text-fuchsia-700 dark:bg-fuchsia-950 dark:text-fuchsia-300";
      sourceText = "🤝 互助派貨";
      sourceTitle = "互助訂單派貨（rpc_ship_aid_order 產生）";
    } else {
      switch (t.transfer_type) {
        case "store_to_store":
          sourceCls = "bg-sky-100 text-sky-700 dark:bg-sky-950 dark:text-sky-300";
          sourceText = "🔄 自由轉貨";
          sourceTitle = "店與店之間自由轉貨（虛擬 SKU + 備註）";
          break;
        case "return_to_hq":
          sourceCls = "bg-orange-100 text-orange-700 dark:bg-orange-950 dark:text-orange-300";
          sourceText = "↩ 退貨回總倉";
          sourceTitle = "店端發起退貨回總倉";
          break;
        case "hq_to_store":
          sourceCls = "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300";
          sourceText = "🚚 總倉派貨";
          sourceTitle = "總倉派貨到分店（撿貨單 wave）";
          break;
      }
    }
  }

  let idText: string;
  let title: React.ReactNode;
  let subtitle: React.ReactNode;
  let timeIso: string;
  let actions: React.ReactNode;

  if (row.source === "restock") {
    const s = row.raw;
    idText = `RESTOCK#${s.id}`;
    title = <>{s.store_name ?? "—"} <span className="text-zinc-400 mx-1">→</span> HQ</>;
    subtitle = (
      <>
        急補 {s.line_count} 項 · NT${s.total_amount.toFixed(0)}
        {/* 部分品相已開請購單、整張還掛 pending/候補 → 標出來,不然看不出「到底訂了沒」 */}
        {s.status === "pending" && s.pr_line_count > 0 && (
          <span className="ml-2 font-medium text-indigo-600 dark:text-indigo-400">
            · 已開單 {s.pr_line_count}/{s.line_count} 品相
          </span>
        )}
        {s.linked_pr_id && (
          <Link href={`/purchase/requests/edit?id=${s.linked_pr_id}`} className="ml-2 font-mono text-blue-600 hover:underline dark:text-blue-400">
            · {s.linked_pr_no ?? `${PR_TERM_ZH} #${s.linked_pr_id}`}
          </Link>
        )}
        {s.linked_transfer_id && (
          <Link href={`/hq/inbox?source=transfer&id=${s.linked_transfer_id}`} className="ml-2 font-mono text-blue-600 hover:underline dark:text-blue-400">
            · {s.linked_transfer_no ?? `轉貨單 #${s.linked_transfer_id}`}
          </Link>
        )}
        {s.status === "rejected" && s.rejected_reason && (
          <span className="ml-2 text-red-600" title={s.rejected_reason}>· 拒絕:{s.rejected_reason}</span>
        )}
        {s.status === "cancelled" && s.stockout_at && (
          <span className="ml-2 text-red-600" title={`採購斷貨於 ${new Date(s.stockout_at).toLocaleString("zh-TW")}`}>· ⛔ 斷貨</span>
        )}
      </>
    );
    timeIso = s.requested_at;
    if (s.status === "pending") {
      const isBusy = busy?.startsWith(`restock-${s.id}`) ?? false;
      const inStandby = s.standby_at !== null;
      actions = (
        <>
          <RowAction variant="success" onClick={() => onApproveTransfer(s.id)} disabled={isBusy}>派貨</RowAction>
          <RowAction variant="indigo" onClick={() => onApprovePr(s.id)} disabled={isBusy}>下訂單</RowAction>
          {inStandby ? (
            <RowAction variant="neutral" onClick={() => onSetStandby(s.id, false)} disabled={isBusy} title="移回「待處理」">
              取消候補
            </RowAction>
          ) : (
            <RowAction variant="warning" onClick={() => onSetStandby(s.id, true)} disabled={isBusy} title="等貨源、先移到「候補」分類（不佔待處理）">
              ⏳ 轉候補
            </RowAction>
          )}
          <RowAction variant="danger" onClick={() => onOpenReject(s.id)} disabled={isBusy}>拒絕</RowAction>
        </>
      );
    } else if (s.status === "approved_pr") {
      actions = (
        <RowAction variant="success" onClick={() => onShipPrReceived(s.id)} disabled={busy?.startsWith(`restock-${s.id}`) ?? false}>PO 到貨建轉貨單</RowAction>
      );
    } else {
      actions = null;
    }
  } else if (row.source === "transfer") {
    const t = row.raw;
    const isOrderReturn = isOrderReturnTransfer(t.notes);
    idText = t.transfer_no;
    title = (
      <>
        {t.source_name} <span className="text-zinc-400 mx-1">→</span> {t.dest_name}
      </>
    );
    subtitle = (
      <>
        {t.line_count} 項
        {t.is_air_transfer && <span className="ml-1">· ✈ 空運</span>}
        {t.shipping_temp && <span className="ml-1">· {t.shipping_temp}</span>}
        <span className="ml-1 text-[10px] text-zinc-400">· {TRANSFER_STATUS_LABEL[t.status] ?? t.status}</span>
      </>
    );
    timeIso = t.created_at;
    actions = <TransferActions transfer={t} hqLocId={hqLocId} busy={busy} onAction={onTransferAction} />;
  } else if (row.source === "shortage") {
    const sh = row.raw;
    const isBusy = busy?.startsWith(`shortage-${sh.order_id}`) ?? false;
    const itemsTooltip = sh.short_items
      .map((it) => `${it.sku_label}:訂 ${it.order_qty}, 缺 ${it.demand_unfulfillable}`)
      .join("\n");
    idText = sh.order_no;
    title = <>會員 #{sh.member_id ?? "—"} <span className="text-zinc-400 mx-1">·</span> {sh.store_name ?? "—"}</>;
    subtitle = (
      <span title={itemsTooltip}>
        <span className="font-semibold text-rose-700 dark:text-rose-400">
          缺 {sh.total_unfulfillable}({sh.short_items.length} 項)
        </span>
        {sh.shortage_resolution && (
          <span className="ml-2 text-zinc-500">
            · {RESOLUTION_LABEL[sh.shortage_resolution] ?? sh.shortage_resolution}
          </span>
        )}
        {sh.shortage_notified_at && (
          <span className="ml-2 text-zinc-400">已通知 {new Date(sh.shortage_notified_at).toLocaleDateString("zh-TW")}</span>
        )}
      </span>
    );
    timeIso = sh.order_updated_at;
    actions = (
      <>
        <RowAction variant="primary" onClick={() => onShortageAction(sh.order_id, "notified")} disabled={isBusy}>通知客戶</RowAction>
        <RowAction variant="warning" onClick={() => onShortageAction(sh.order_id, "waiting_next_po")} disabled={isBusy}>等下批</RowAction>
        <RowAction variant="success" onClick={() => onShortageAction(sh.order_id, "reallocated")} disabled={isBusy}>改派</RowAction>
        <RowAction variant="danger" onClick={() => onShortageAction(sh.order_id, "cancelled")} disabled={isBusy}>取消退款</RowAction>
      </>
    );
  } else if (row.source === "picking") {
    const w = row.raw;
    const diff = w.actual_total - w.expected_total;
    const completion = w.expected_total > 0 ? Math.round((w.actual_total / w.expected_total) * 100) : 0;
    idText = w.wave_code;
    // 配送日在此設定（派貨工作台建單只帶預設隔天）；shipped/cancelled 唯讀
    const dateEditable = w.status !== "shipped" && w.status !== "cancelled";
    title = (
      <>
        {dateEditable ? (
          <div
            className="inline-flex items-center gap-1 rounded bg-blue-100 px-1.5 py-0.5 text-xs font-semibold text-blue-800 dark:bg-blue-950 dark:text-blue-300"
            title="點日期修改配送日"
            onClick={(e) => e.stopPropagation()}
          >
            📅 配送日
            <DatePicker
              value={w.wave_date}
              onChange={(d) => onPickingDateChange(w, d)}
              popover="fixed"
              disabled={busy === `picking-${w.id}-date`}
              className="rounded border border-dashed border-blue-400 px-1 font-mono text-xs font-semibold text-blue-800 hover:bg-blue-200 disabled:opacity-50 dark:border-blue-600 dark:text-blue-300 dark:hover:bg-blue-900"
            />
          </div>
        ) : (
          <span className="inline-block rounded bg-blue-100 px-1.5 py-0.5 text-xs font-semibold text-blue-800 dark:bg-blue-950 dark:text-blue-300">
            📅 配送日 {w.wave_date}
          </span>
        )}
        {w.source_po_no && (
          <span className="ml-2 text-[11px] text-zinc-500">← {w.source_po_no}</span>
        )}
      </>
    );
    subtitle = (
      <>
        {w.item_count} 品項 / {w.store_count} 店 · 應發 {w.expected_total} / 實分 {w.actual_total}
        {diff !== 0 && (
          <span className={`ml-1 ${diff > 0 ? "text-purple-600" : "text-rose-600"}`}>
            ({diff > 0 ? `+${diff}` : diff})
          </span>
        )}
        {w.expected_total > 0 && (
          <span
            className={`ml-2 inline-block rounded px-1.5 py-0.5 text-[11px] font-semibold ${
              completion === 100
                ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                : "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
            }`}
          >
            {completion}%
          </span>
        )}
      </>
    );
    timeIso = w.created_at;
    const isDispatching = dispatchingWaveId === w.id;
    const printLink = (
      <Link
        href={`/picking/print-sign?date=${w.wave_date}`}
        target="_blank"
        onClick={(e) => e.stopPropagation()}
        title="列印分店簽收單"
        className="inline-flex items-center rounded border border-blue-300 bg-blue-50 px-2 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
      >
        📄 簽收單
      </Link>
    );
    if (row.stage === "pending") {
      actions = (
        <>
          <RowAction
            variant="success"
            onClick={() => onPickingDispatch(w)}
            disabled={isDispatching || hqLocId === null}
            title={w.status === "picked" ? "建立 transfer 並從總倉出庫" : "自動 確認撿貨完成 + 派貨出倉"}
          >
            {isDispatching ? "派貨中…" : "🚚 派貨出倉"}
          </RowAction>
          <RowAction variant="neutral" onClick={() => onPickingEdit(w)} title="開啟明細修正撿貨數量">
            ✎ 修正數量
          </RowAction>
          {printLink}
          <RowAction variant="danger" onClick={() => onPickingCancel(w)} title="軟取消(留 audit log)">
            取消
          </RowAction>
        </>
      );
    } else if (row.stage === "done") {
      actions = (
        <>
          <RowAction variant="neutral" onClick={() => onPickingEdit(w)}>
            看明細
          </RowAction>
          {printLink}
        </>
      );
    } else {
      // rejected (取消) — 不需要列印
      actions = (
        <RowAction variant="neutral" onClick={() => onPickingEdit(w)}>
          看明細
        </RowAction>
      );
    }
  } else if (row.source === "air") {
    // 空中轉:貨走店對店、總倉不碰。轉單當下就自動出貨、轉入單直接進「配送中」
    // (20260814030000),所以這裡不會再出現「派貨」(那顆只在 confirmed 顯示) ——
    // 接收店在「收貨」頁收掉 AT- 單就結束,月結自動一加一扣。
    // 動作按鈕仍留一份當後備:自動出貨上線前卡在「已確認」的舊單要有人推得動
    // (之前做成純唯讀 + 分店看不到 /hq/inbox,結果全站沒人有入口,線上卡了 5 張)。
    const a = row.raw;
    idText = a.order_no;
    title = <AidRouteTitle a={a} />;
    subtitle = (
      <>
        {a.line_count} 項
        <span className="ml-1">· ✈ 空中轉</span>
        <span className="ml-1">· {AID_STATUS_LABEL[a.status]}</span>
      </>
    );
    timeIso = a.updated_at;
    actions = (
      <>
        <AidOrderStatusActions order={{ id: a.id, status: a.status }} onChanged={onAidChanged} />
        <AidPrintAction order={a} />
        <RowAction variant="neutral" onClick={() => onOpenAidDetail(a.id)}>查看訂單</RowAction>
      </>
    );
  } else {
    const a = row.raw;
    idText = a.order_no;
    title = <AidRouteTitle a={a} />;
    subtitle = (
      <>
        {a.line_count} 項
        {a.is_air_transfer && <span className="ml-1">· ✈ 空運</span>}
        <span className="ml-1">· {AID_STATUS_LABEL[a.status]}</span>
      </>
    );
    timeIso = a.updated_at;
    actions = (
      <>
        <AidOrderStatusActions order={{ id: a.id, status: a.status }} onChanged={onAidChanged} />
        <AidPrintAction order={a} />
        <RowAction variant="neutral" onClick={() => onOpenAidDetail(a.id)}>查看訂單</RowAction>
      </>
    );
  }

  const time = new Date(timeIso).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" });

  // 點 row 任意空白處開明細
  const rowClickable =
    row.source === "picking" || row.source === "aid" || row.source === "air" ||
    row.source === "transfer" || row.source === "restock";
  const handleRowClick = (e: React.MouseEvent<HTMLDivElement>) => {
    if (!rowClickable) return;
    const target = e.target as HTMLElement;
    if (target.closest("button, a, input, select, textarea, label")) return;
    if (row.source === "picking") onPickingEdit(row.raw);
    else if (row.source === "aid" || row.source === "air") onOpenAidDetail(row.raw.id);
    else if (row.source === "transfer") onOpenTransferDetail(row.raw.id);
    else if (row.source === "restock") onOpenRestockDetail(row.raw.id);
  };

  return (
    <div
      onClick={handleRowClick}
      className={`flex flex-col gap-2 border-b border-l-4 px-4 py-3 transition hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-950 sm:flex-row sm:items-start sm:gap-3 ${accent} ${row.source === "shortage" ? "bg-rose-50/30 dark:bg-rose-950/20" : ""} ${selected ? "bg-blue-50 dark:bg-blue-950/30" : ""} ${rowClickable ? "cursor-pointer" : ""}`}
    >
      {/* min-w-0 flex-1:內容區撐滿剩餘寬度,右側 400px 動作區才會每列貼右對齊(不然按鈕跟著內容長短跑) */}
      <div className="flex min-w-0 flex-1 items-start gap-3">
        {/* checkbox */}
        <div className="w-5 shrink-0 pt-1">
          {showCheckbox && batchable ? (
            <input type="checkbox" checked={selected} onChange={onToggleSelect} className="cursor-pointer" />
          ) : null}
        </div>

        {/* source chip + 未讀 dot (sm+) */}
        <div className="hidden sm:block min-w-28 shrink-0 pt-0.5">
          <span
            className={`inline-flex w-fit items-center gap-1 whitespace-nowrap rounded px-2 py-0.5 text-[10px] font-medium ${sourceCls}`}
            title={sourceTitle}
          >
            {isPending && <span className="h-1.5 w-1.5 rounded-full bg-current opacity-80" aria-hidden />}
            {sourceText}
          </span>
        </div>

        {/* 主旨 + 摘要 */}
        <div className="min-w-0 flex-1">
          <div className={`flex flex-wrap items-baseline gap-x-2 ${isPending ? "font-semibold" : "text-zinc-700 dark:text-zinc-300"}`}>
            {/* div 不用 span:撿貨單 title 內含 DatePicker(根節點是 div),span 包 div 會觸發 React DOM nesting 警告 */}
            <div className="truncate text-sm">{title}</div>
            <span className="font-mono text-[10px] text-zinc-500">{idText}</span>
            <span className={`sm:hidden inline-flex rounded px-1.5 py-0.5 text-[9px] font-medium ${sourceCls}`}>
              {sourceText}
            </span>
          </div>
          <div className="mt-0.5 truncate text-xs text-zinc-500">{subtitle}</div>
          {row.source !== "shortage" && (() => {
            const summary = (row.raw as { items_summary?: string }).items_summary;
            if (!summary) return null;
            return (
              <div
                className="mt-0.5 truncate text-[11px] text-zinc-600 dark:text-zinc-400"
                title={summary}
              >
                📦 {summary}
              </div>
            );
          })()}
        </div>

        {/* 階段 chip 直接放在內容右邊 */}
        <div className="flex shrink-0 items-start pt-0.5">
          <span className={`inline-flex rounded px-1.5 py-0.5 text-[10px] ${stageCls}`}>{stageText}</span>
        </div>
      </div>

      {/* 動作 + 時間 — 手機版全寬換行,sm+ 固定寬度靠右 */}
      <div className="flex w-full flex-col items-stretch gap-1 pl-8 sm:w-[400px] sm:shrink-0 sm:items-end sm:pl-0">
        <div className="flex flex-wrap items-center gap-1 sm:justify-end">
          {actions}
        </div>
        <span className="text-[11px] text-zinc-400 sm:text-right">{time}</span>
      </div>
    </div>
  );
}

// 互助 / 空中轉列的標題：貨「從哪一家店 → 到哪一家店」。
// 原本標的是「開團 → 取貨店」——取貨店只是收貨的那一頭，總倉看不出要跟誰收貨，
// 而經總倉的互助正是總倉要親手轉交的（Leg-1 來源店 → 總倉、Leg-2 總倉 → 收貨店，
// 20260510000004）。同店轉單（只是換客人、貨沒離開本店）在「待處理 / 在途」已經
// 被 v_hq_inbox_aid 濾掉（20260818000040），但已完成 / 已取消的歷史還看得到，
// 所以這個標記留著 —— 全站 375 張轉入單裡有 359 張是這種。
function AidRouteTitle({ a }: { a: AidRaw }) {
  const dest = a.store_name ?? "—";
  const sameStore = a.from_store_id != null && a.from_store_id === a.pickup_store_id;
  if (sameStore) {
    return (
      <>
        {dest}
        <span className="ml-1 text-xs font-normal text-zinc-500">（同店轉單・貨沒有移動）</span>
      </>
    );
  }
  return (
    <>
      {a.from_store_name ?? "—"} <span className="text-zinc-400 mx-1">→</span> {dest}
    </>
  );
}

// 互助 / 空中轉的出貨單（隨貨聯 + 出貨店存根聯）。
// 經總倉的互助拆兩段、Leg-1 身上沒有訂單也看不出最終要送到哪家店（見
// /transfers/print-aid 檔頭），所以這裡一律用訂單 id 印整條路徑的單。
function AidPrintAction({ order }: { order: AidRaw }) {
  if (["cancelled", "expired"].includes(order.status)) return null;
  return (
    <RowAction
      variant="neutral"
      onClick={() => printViaIframe(withBasePath(`/transfers/print-aid?order_id=${order.id}`))}
      title="列印互助出貨單（隨貨聯 + 出貨店存根聯）：印出來跟著箱子走，總倉／收貨店照單點收簽名"
    >
      🖨 出貨單
    </RowAction>
  );
}

function TransferActions({
  transfer,
  hqLocId,
  busy,
  onAction,
}: {
  transfer: TransferRaw;
  hqLocId: number | null;
  busy: string | null;
  onAction: (transferId: number, action: "ship" | "arrive_at_hq" | "delete" | "reject" | "unreject") => Promise<void>;
}) {
  const isBusy = busy?.startsWith(`transfer-${transfer.id}`) ?? false;
  const isHqDest = hqLocId !== null && transfer.dest_location === hqLocId;
  const isOrderReturn = isOrderReturnTransfer(transfer.notes);
  const buttons: React.ReactNode[] = [];

  // 誤拒收復原：波次派貨單被拒收(cancelled + [rejected:...]) → 一鍵恢復在途
  // RPC 端有完整守衛（重複復原/庫存不足/aid 鏈皆擋），這裡只做入口
  if (
    transfer.status === "cancelled" &&
    parseWaveId(transfer.transfer_no) !== null &&
    (transfer.notes ?? "").includes("[rejected:")
  ) {
    buttons.push(
      <RowAction
        key="unreject"
        variant="warning"
        onClick={() => onAction(transfer.id, "unreject")}
        disabled={isBusy}
        title="沖銷拒收回流、單據回到「在途」，店端收貨待辦會重新出現"
      >
        恢復在途
      </RowAction>,
    );
  }

  // draft: 可刪除
  if (transfer.status === "draft") {
    buttons.push(
      <RowAction
        key="delete"
        variant="danger"
        onClick={() => onAction(transfer.id, "delete")}
        disabled={isBusy}
      >
        刪除
      </RowAction>,
    );
  }

  // draft / confirmed → 出貨(RPC 不限 source,任何 source 都可以)
  if (transfer.status === "draft" || transfer.status === "confirmed") {
    buttons.push(
      <RowAction
        key="ship"
        variant="success"
        onClick={() => onAction(transfer.id, "ship")}
        disabled={isBusy}
      >
        出貨
      </RowAction>,
    );
  }

  // shipped + dest=HQ → 到倉(退訂單多加一個「取消」、label 改成「確認入倉」)
  if (transfer.status === "shipped" && isHqDest) {
    if (isOrderReturn) {
      buttons.push(
        <RowAction
          key="reject"
          variant="danger"
          onClick={() => onAction(transfer.id, "reject")}
          disabled={isBusy}
          title="拒收、將貨退回原寄出 location"
        >
          取消
        </RowAction>,
      );
    }
    buttons.push(
      <RowAction
        key="arrive"
        variant="primary"
        onClick={() => onAction(transfer.id, "arrive_at_hq")}
        disabled={isBusy}
      >
        {isOrderReturn ? "確認入倉" : "到倉"}
      </RowAction>,
    );
  }

  return <>{buttons}</>;
}

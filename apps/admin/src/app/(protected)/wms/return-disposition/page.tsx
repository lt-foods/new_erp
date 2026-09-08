"use client";

// 總倉退回貨待處理（2026-09-07，D 段前端）
//
// 資料來源：v_hq_return_batches_list（security_invoker，同 tenant RLS）
// 處理 RPC：rpc_dispose_hq_return（role 白名單 owner/admin/hq_manager）
//
// 店名解析鏈：batch.source_transfer_item_id → transfer_items.transfer_id
//   → transfers.source_location → locations.name
// ⛔ 不能猜店名，缺名以 id 明示。

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { translateRpcError } from "@/lib/rpcError";
import { useRole, canSeeCost, type Role } from "@/lib/role";
import { LoadingBlock } from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";

// ── 型別 ──

type BatchRow = {
  id: number;
  tenant_id: string;
  location_id: number;
  sku_id: number;
  source_movement_id: number;
  source_transfer_item_id: number | null;
  source_kind: string;
  source_reason: string | null;
  total_qty: number;
  unit_cost: number | null;
  qty_good: number;
  qty_damaged: number;
  qty_lost: number;
  qty_revoked: number;
  qty_pending: number;
  status: string;
  auto_flag: string | null;
  created_by: string;
  created_at: string;
  updated_at: string;
};

type EventRow = {
  id: number;
  batch_id: number;
  request_id: string;
  qty_good: number;
  qty_damaged: number;
  qty_lost: number;
  damage_reason: string | null;
  loss_reason: string | null;
  goods_confirmed: boolean;
  damage_movement_id: number | null;
  loss_movement_id: number | null;
  notes: string | null;
  operator_id: string;
  created_at: string;
};

type SkuRow = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

type SourceInfo = {
  transferNo: string;
  sourceName: string | null;
  destName: string | null;
};

type DisposePayload = {
  p_batch_id: number;
  p_request_id: string;
  p_qty_good: number;
  p_qty_damaged: number;
  p_qty_lost: number;
  p_damage_reason: string | null;
  p_loss_reason: string | null;
  p_goods_confirmed: boolean;
  p_notes: string | null;
};

type PendingRequest = {
  schemaVersion: 1;
  tenantId: string;
  operatorId: string;
  batchId: number;
  requestId: string;
  createdAt: string;
  payload: DisposePayload;
};

// ── helper ──

function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function fmtUnitCost(v: unknown): string {
  if (v === null || v === undefined || v === "") return "未提供成本";
  const n = Number(v);
  return Number.isFinite(n) ? `$${n.toFixed(2)}` : "未提供成本";
}

function canDisposeReturn(role: Role | null): boolean {
  return role === "owner" || role === "admin" || role === "hq_manager";
}

function fmtDate(v: string | null): string {
  return v ? new Date(v).toLocaleDateString("zh-TW") : "—";
}
function fmtDateTime(v: string | null): string {
  return v ? new Date(v).toLocaleString("zh-TW") : "—";
}

function skuLabel(s: SkuRow | undefined, id: number): string {
  if (!s) return `品項#${id}`;
  return (
    `${s.product_name ?? ""}${s.variant_name ? ` / ${s.variant_name}` : ""}`.trim() ||
    s.sku_code ||
    `#${s.id}`
  );
}

const SOURCE_KIND_ZH: Record<string, string> = {
  store_return: "門市退貨",
  shortage: "短少",
};

const STATUS_ZH: Record<string, { label: string; cls: string }> = {
  pending: {
    label: "待處理",
    cls: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  },
  partial: {
    label: "部分處理",
    cls: "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300",
  },
  completed: {
    label: "已完成",
    cls: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  },
  revoked: {
    label: "已撤回",
    cls: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400",
  },
};

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Safari-safe RFC 4122 v4 UUID。 */
function newRequestId(): string {
  if (typeof crypto === "undefined") {
    throw new Error("這台裝置無法安全產生送出識別碼，請改用支援的瀏覽器。");
  }
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();

  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** 編輯中保留原字串；合法性只在送出時完整檢查。 */
function clampDecimal(v: string, _max: number): string {
  void _max;
  return v;
}

const QTY_RE = /^\d+(?:\.\d{1,3})?$/;
const PAGE_SIZE = 200;
const STORAGE_PREFIX = "new-erp:hq-return-disposition:pending:v1";

function toThousandths(value: string): number | null {
  if (!QTY_RE.test(value)) return null;
  const [whole, fraction = ""] = value.split(".");
  const result = Number(whole) * 1000 + Number(fraction.padEnd(3, "0"));
  return Number.isSafeInteger(result) ? result : null;
}

function storedNumberIsValid(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && toThousandths(String(value)) !== null;
}

function storageKey(tenantId: string, operatorId: string): string {
  return `${STORAGE_PREFIX}:${tenantId}:${operatorId}`;
}

function isPendingRequest(value: unknown, tenantId: string, operatorId: string): value is PendingRequest {
  if (!value || typeof value !== "object") return false;
  const v = value as Partial<PendingRequest>;
  const p = v.payload as Partial<DisposePayload> | undefined;
  if (
    !p ||
    !storedNumberIsValid(p.p_qty_good) ||
    !storedNumberIsValid(p.p_qty_damaged) ||
    !storedNumberIsValid(p.p_qty_lost)
  ) return false;
  const total = p.p_qty_good + p.p_qty_damaged + p.p_qty_lost;
  return (
    v.schemaVersion === 1 &&
    v.tenantId === tenantId &&
    v.operatorId === operatorId &&
    typeof v.batchId === "number" && Number.isSafeInteger(v.batchId) && v.batchId > 0 &&
    typeof v.requestId === "string" && UUID_V4_RE.test(v.requestId) &&
    typeof v.createdAt === "string" && Number.isFinite(Date.parse(v.createdAt)) &&
    p.p_batch_id === v.batchId && p.p_request_id === v.requestId &&
    total > 0 && Number.isFinite(total) &&
    (p.p_damage_reason === null || typeof p.p_damage_reason === "string") &&
    (p.p_loss_reason === null || typeof p.p_loss_reason === "string") &&
    p.p_goods_confirmed === (p.p_qty_good > 0) &&
    (p.p_qty_damaged === 0 ? p.p_damage_reason === null : !!p.p_damage_reason?.trim()) &&
    (p.p_qty_lost === 0 ? p.p_loss_reason === null : !!p.p_loss_reason?.trim()) &&
    (p.p_notes === null || typeof p.p_notes === "string")
  );
}

function readPendingRequest(
  key: string,
  tenantId: string,
  operatorId: string,
): { request: PendingRequest | null; error: string | null } {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return { request: null, error: null };
    const parsed: unknown = JSON.parse(raw);
    return isPendingRequest(parsed, tenantId, operatorId)
      ? { request: parsed, error: null }
      : {
          request: null,
          error: "上次待確認的送出資料不完整。為避免重複處理，請先由工程人員查明後再操作。",
        };
  } catch {
    return {
      request: null,
      error: "無法讀取上次待確認的送出資料。為避免重複處理，請先由工程人員查明後再操作。",
    };
  }
}

function isDefiniteDatabaseRejection(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" && (/^[0-9A-Z]{5}$/.test(code) || code.startsWith("PGRST"));
}

// ── 主元件 ──

export default function HqReturnDispositionPage() {
  const role = useRole();
  const { user, tenant, loading: authLoading } = useAuth();
  const tenantFromToken = user?.app_metadata?.tenant_id;
  const tenantId = tenant?.id ?? (typeof tenantFromToken === "string" ? tenantFromToken : null);

  if (role === null || authLoading) return <LoadingBlock />;

  if (!canDisposeReturn(role)) {
    return (
      <div className="flex flex-1 flex-col gap-4 p-6">
        <h1 className="text-xl font-semibold">退回貨處理</h1>
        <div role="alert" className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          權限不足：此頁面只開放負責人、管理員與總倉主管。
        </div>
      </div>
    );
  }

  if (!user?.id || !tenantId) {
    return (
      <div className="flex flex-1 flex-col gap-4 p-6">
        <h1 className="text-xl font-semibold">退回貨處理</h1>
        <div role="alert" className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          登入資料不完整，為避免把處理資料記到錯的公司，這一頁暫時不能操作。請重新登入後再試。
        </div>
      </div>
    );
  }

  return (
    <ReturnDispositionWorkspace
      key={`${tenantId}:${user.id}`}
      role={role}
      tenantId={tenantId}
      operatorId={user.id}
    />
  );
}

function ReturnDispositionWorkspace({
  role,
  tenantId,
  operatorId,
}: {
  role: Role;
  tenantId: string;
  operatorId: string;
}) {
  const showCost = canSeeCost(role);
  const pendingStorageKey = storageKey(tenantId, operatorId);
  const [storedLoad] = useState(() => readPendingRequest(pendingStorageKey, tenantId, operatorId));
  const [pendingRequest, setPendingRequest] = useState<PendingRequest | null>(() =>
    storedLoad.request,
  );
  const storageLoadError = storedLoad.error;

  // ── 批次列表 ──
  const [batches, setBatches] = useState<BatchRow[]>([]);
  const [skuMap, setSkuMap] = useState<Map<number, SkuRow>>(new Map());
  const [sourceInfoMap, setSourceInfoMap] = useState<Map<number, SourceInfo>>(new Map());
  const [listLoading, setListLoading] = useState(true);
  const [listError, setListError] = useState<string | null>(null);
  const [includeHistory, setIncludeHistory] = useState(false);
  const [page, setPage] = useState(0);
  const [hasNextPage, setHasNextPage] = useState(false);
  const listRequestRef = useRef(0);

  // ── 選中的批次 ──
  const [selectedId, setSelectedId] = useState<number | null>(pendingRequest?.batchId ?? null);

  // ── 事件列表（選中批次的） ──
  const [events, setEvents] = useState<EventRow[]>([]);
  const [eventsLoading, setEventsLoading] = useState(pendingRequest !== null);
  const [eventsError, setEventsError] = useState<string | null>(null);
  const [operatorNames, setOperatorNames] = useState<Map<string, string>>(new Map());
  const [eventsReloadKey, setEventsReloadKey] = useState(0);

  // ── 處理表單 ──
  const [fGood, setFGood] = useState(() => pendingRequest ? String(pendingRequest.payload.p_qty_good) : "");
  const [fDamaged, setFDamaged] = useState(() => pendingRequest ? String(pendingRequest.payload.p_qty_damaged) : "");
  const [fLost, setFLost] = useState(() => pendingRequest ? String(pendingRequest.payload.p_qty_lost) : "");
  const [fDamageReason, setFDamageReason] = useState(() => pendingRequest?.payload.p_damage_reason ?? "");
  const [fLossReason, setFLossReason] = useState(() => pendingRequest?.payload.p_loss_reason ?? "");
  const [fGoodsConfirmed, setFGoodsConfirmed] = useState(() => pendingRequest?.payload.p_goods_confirmed ?? false);
  const [fNotes, setFNotes] = useState(() => pendingRequest?.payload.p_notes ?? "");
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitOk, setSubmitOk] = useState<string | null>(null);
  const submittingRef = useRef(false);

  const selected = useMemo(
    () => batches.find((b) => b.id === selectedId) ?? null,
    [batches, selectedId],
  );

  // ── 載入批次列表 ──
  const fetchBatchPage = useCallback(async () => {
    const sb = getSupabase();
    let q = sb
        .from("v_hq_return_batches_list")
        .select("*")
        .order("created_at", { ascending: false })
        .order("id", { ascending: false });

    if (!includeHistory) q = q.in("status", ["pending", "partial"]);

    const from = page * PAGE_SIZE;
    const { data, error } = await q.range(from, from + PAGE_SIZE);
    if (error) throw error;
    const fetched = (data ?? []) as BatchRow[];
    const rows = fetched.slice(0, PAGE_SIZE);

    // ── 解析 SKU 名稱 ──
    const skuIds = Array.from(new Set(rows.map((r) => r.sku_id)));
    const nextSkuMap = new Map<number, SkuRow>();
    if (skuIds.length > 0) {
      const skuRows = await fetchAllRows<SkuRow>(() =>
        sb
          .from("skus")
          .select("id, sku_code, product_name, variant_name")
          .in("id", skuIds)
          .order("id", { ascending: true }),
      );
      for (const sku of skuRows) nextSkuMap.set(sku.id, sku);
    }

    // ── 解析店名：source_transfer_item_id → transfer_items → transfers → locations ──
    const uniqueTiIds = Array.from(new Set(
      rows
        .map((row) => row.source_transfer_item_id)
        .filter((id): id is number => id != null),
    ));
    const nextSourceMap = new Map<number, SourceInfo>();

    if (uniqueTiIds.length > 0) {
      const tiRows = await fetchAllRows<{ id: number; transfer_id: number }>(() =>
        sb
          .from("transfer_items")
          .select("id, transfer_id")
          .in("id", uniqueTiIds)
          .order("id", { ascending: true }),
      );
      const tiToTransfer = new Map<number, number>();
      for (const item of tiRows) tiToTransfer.set(item.id, item.transfer_id);

      const transferIds = Array.from(new Set(tiRows.map((item) => item.transfer_id)));
      if (transferIds.length > 0) {
        const transferRows = await fetchAllRows<{
          id: number;
          transfer_no: string;
          source_location: number;
          dest_location: number;
        }>(() =>
          sb
            .from("transfers")
            .select("id, transfer_no, source_location, dest_location")
            .in("id", transferIds)
            .order("id", { ascending: true }),
        );

        const locationIds = Array.from(new Set(
          transferRows.flatMap((transfer) => [transfer.source_location, transfer.dest_location]),
        ));
        const locationNames = new Map<number, string>();
        if (locationIds.length > 0) {
          const locationRows = await fetchAllRows<{ id: number; name: string }>(() =>
            sb
              .from("locations")
              .select("id, name")
              .in("id", locationIds)
              .order("id", { ascending: true }),
          );
          for (const location of locationRows) locationNames.set(location.id, location.name);
        }

        const transferMap = new Map<number, SourceInfo>();
        for (const transfer of transferRows) {
          transferMap.set(transfer.id, {
            transferNo: transfer.transfer_no,
            sourceName: locationNames.get(transfer.source_location) ?? null,
            destName: locationNames.get(transfer.dest_location) ?? null,
          });
        }
        for (const itemId of uniqueTiIds) {
          const transferId = tiToTransfer.get(itemId);
          const info = transferId == null ? null : transferMap.get(transferId);
          if (info) nextSourceMap.set(itemId, info);
        }
      }
    }

    return { fetched, rows, nextSkuMap, nextSourceMap };
  }, [includeHistory, page]);

  const loadBatchPage = useCallback(async (): Promise<boolean> => {
    const requestNo = ++listRequestRef.current;
    try {
      const result = await fetchBatchPage();
      if (requestNo !== listRequestRef.current) return false;

      setBatches(result.rows);
      setHasNextPage(result.fetched.length > PAGE_SIZE);
      setSkuMap(result.nextSkuMap);
      setSourceInfoMap(result.nextSourceMap);
      setSelectedId((current) => {
        return current != null && result.rows.some((row) => row.id === current) ? current : null;
      });
      setListError(null);
      return true;
    } catch (err) {
      if (requestNo === listRequestRef.current) setListError(translateRpcError(err));
      return false;
    } finally {
      if (requestNo === listRequestRef.current) setListLoading(false);
    }
  }, [fetchBatchPage]);

  useEffect(() => {
    const requestNo = ++listRequestRef.current;
    let cancelled = false;
    (async () => {
      try {
        const result = await fetchBatchPage();
        if (cancelled || requestNo !== listRequestRef.current) return;
        setBatches(result.rows);
        setHasNextPage(result.fetched.length > PAGE_SIZE);
        setSkuMap(result.nextSkuMap);
        setSourceInfoMap(result.nextSourceMap);
        setSelectedId((current) => (
          current != null && result.rows.some((row) => row.id === current) ? current : null
        ));
        setListError(null);
      } catch (err) {
        if (!cancelled && requestNo === listRequestRef.current) setListError(translateRpcError(err));
      } finally {
        if (!cancelled && requestNo === listRequestRef.current) setListLoading(false);
      }
    })();
    return () => {
      cancelled = true;
      listRequestRef.current += 1;
    };
  }, [fetchBatchPage]);

  // ── 載入選中批次的事件 ──
  useEffect(() => {
    if (selectedId == null) return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const evts = await fetchAllRows<EventRow>(() =>
          sb
            .from("hq_return_events")
            .select(
              "id, batch_id, request_id, qty_good, qty_damaged, qty_lost, damage_reason, loss_reason, goods_confirmed, damage_movement_id, loss_movement_id, notes, operator_id, created_at",
            )
            .eq("batch_id", selectedId)
            .order("created_at", { ascending: true })
            .order("id", { ascending: true }),
        );
        if (cancelled) return;
        setEvents(evts);

        // 操作人名稱
        const uids = Array.from(
          new Set(evts.map((e) => e.operator_id).filter(Boolean)),
        );
        const nameMap = new Map<string, string>();
        if (uids.length > 0) {
          const { data: ns, error: namesError } = await sb.rpc("rpc_get_staff_names", {
            p_uids: uids,
          });
          if (namesError) throw namesError;
          for (const n of (ns as { id: string; display_name: string }[] | null) ?? [])
            nameMap.set(n.id, n.display_name);
        }

        if (cancelled) return;
        setOperatorNames(nameMap);
      } catch (err) {
        if (!cancelled) setEventsError(translateRpcError(err));
      } finally {
        if (!cancelled) setEventsLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [selectedId, eventsReloadKey]);

  // 清空表單
  const resetForm = useCallback(() => {
    setFGood("");
    setFDamaged("");
    setFLost("");
    setFDamageReason("");
    setFLossReason("");
    setFGoodsConfirmed(false);
    setFNotes("");
    setSubmitError(null);
    setSubmitOk(null);
  }, []);

  // 選批次時清表單
  const handleSelect = useCallback(
    (id: number) => {
      if (pendingRequest) {
        setSubmitError("上一筆送出結果還沒查明，現在不能關閉或切換批次。");
        return;
      }
      const isClosing = selectedId === id;
      setSelectedId(isClosing ? null : id);
      setEvents([]);
      setOperatorNames(new Map());
      setEventsError(null);
      setEventsLoading(!isClosing);
      resetForm();
    },
    [pendingRequest, resetForm, selectedId],
  );

  const clearStoredRequest = useCallback((): boolean => {
    try {
      window.localStorage.removeItem(pendingStorageKey);
      return true;
    } catch {
      setSubmitError("無法清除已確認的送出資料。為避免下次重複處理，請先不要繼續操作。");
      return false;
    }
  }, [pendingStorageKey]);

  const eventMatchesRequest = useCallback((event: EventRow, request: PendingRequest): boolean => {
    const p = request.payload;
    return (
      event.batch_id === p.p_batch_id &&
      event.request_id === p.p_request_id &&
      num(event.qty_good) === p.p_qty_good &&
      num(event.qty_damaged) === p.p_qty_damaged &&
      num(event.qty_lost) === p.p_qty_lost &&
      event.damage_reason === p.p_damage_reason &&
      event.loss_reason === p.p_loss_reason &&
      event.goods_confirmed === p.p_goods_confirmed &&
      event.notes === p.p_notes &&
      event.operator_id === request.operatorId
    );
  }, []);

  const confirmStoredRequest = useCallback(async (
    request: PendingRequest,
    successPrefix = "處理完成",
  ): Promise<boolean> => {
    try {
      const sb = getSupabase();
      const { data, error } = await sb
        .from("hq_return_events")
        .select(
          "id, batch_id, request_id, qty_good, qty_damaged, qty_lost, damage_reason, loss_reason, goods_confirmed, damage_movement_id, loss_movement_id, notes, operator_id, created_at",
        )
        .eq("tenant_id", request.tenantId)
        .eq("batch_id", request.batchId)
        .eq("request_id", request.requestId)
        .limit(1);
      if (error) throw error;
      const event = ((data ?? []) as EventRow[])[0];
      if (!event) {
        setSubmitError("目前還查不到這筆送出結果。數量已鎖定，請稍後再查，或原封不動重新傳送同一筆資料。");
        return false;
      }
      if (!eventMatchesRequest(event, request)) {
        setSubmitError("查到的處理紀錄與本機保留資料不一致。為避免錯帳，已停止後續操作，請交由工程人員查明。");
        return false;
      }
      setListLoading(true);
      if (!(await loadBatchPage())) {
        setSubmitError("已查到處理紀錄，但清單還沒重新整理成功。資料仍鎖定，請按「查詢送出結果」再試一次。");
        return false;
      }
      if (!clearStoredRequest()) return false;

      setPendingRequest(null);
      resetForm();
      setSubmitOk(`✓ ${successPrefix}（處理紀錄 #${event.id}）`);
      setEventsLoading(true);
      setEventsReloadKey((value) => value + 1);
      return true;
    } catch (err) {
      setSubmitError(`送出結果仍無法確認：${translateRpcError(err)}。原資料已保留並鎖定，請稍後再查。`);
      return false;
    }
  }, [clearStoredRequest, eventMatchesRequest, loadBatchPage, resetForm]);

  const sendStoredRequest = useCallback(async (request: PendingRequest) => {
    if (submittingRef.current) return;
    submittingRef.current = true;
    setSubmitting(true);
    setSubmitError(null);
    setSubmitOk(null);
    try {
      const sb = getSupabase();
      const { data, error } = await sb.rpc("rpc_dispose_hq_return", request.payload);
      if (error) {
        if (isDefiniteDatabaseRejection(error)) {
          if (clearStoredRequest()) {
            setPendingRequest(null);
            setSubmitError(`${translateRpcError(error)}。這次送出已被系統明確拒絕，可修正內容後再送。`);
          }
          return;
        }
        await confirmStoredRequest(request);
        return;
      }

      const result = data as { idempotent?: boolean } | null;
      await confirmStoredRequest(request, result?.idempotent ? "原資料重送確認完成" : "處理完成");
    } catch (err) {
      await confirmStoredRequest(request);
      if (!isDefiniteDatabaseRejection(err)) return;
      if (clearStoredRequest()) {
        setPendingRequest(null);
        setSubmitError(`${translateRpcError(err)}。這次送出已被系統明確拒絕，可修正內容後再送。`);
      }
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  }, [clearStoredRequest, confirmStoredRequest]);

  // ── 送出處理 ──
  const handleSubmit = useCallback(async () => {
    if (pendingRequest) {
      await sendStoredRequest(pendingRequest);
      return;
    }
    if (!selected || storageLoadError) return;
    const storedNow = readPendingRequest(pendingStorageKey, tenantId, operatorId);
    if (storedNow.error) {
      setSubmitError(storedNow.error);
      return;
    }
    if (storedNow.request) {
      const request = storedNow.request;
      setPendingRequest(request);
      setSelectedId(request.batchId);
      setFGood(String(request.payload.p_qty_good));
      setFDamaged(String(request.payload.p_qty_damaged));
      setFLost(String(request.payload.p_qty_lost));
      setFDamageReason(request.payload.p_damage_reason ?? "");
      setFLossReason(request.payload.p_loss_reason ?? "");
      setFGoodsConfirmed(request.payload.p_goods_confirmed);
      setFNotes(request.payload.p_notes ?? "");
      setSubmitError("另一個頁籤已有一筆送出結果尚未查明；原資料已恢復並鎖定，請先查詢結果。");
      return;
    }
    setSubmitError(null);
    setSubmitOk(null);

    const inputs = [
      ["完好數量", fGood],
      ["破損數量", fDamaged],
      ["遺失數量", fLost],
    ] as const;
    const parsed = inputs.map(([label, value]) => {
      const thousandths = value === "" ? 0 : toThousandths(value);
      if (thousandths === null) {
        setSubmitError(`${label}只能填 0 以上的數字，且最多 3 位小數。`);
      }
      return thousandths;
    });
    if (parsed.some((value) => value === null)) return;

    const [goodThousandths, damagedThousandths, lostThousandths] = parsed as number[];
    const totalThousandths = goodThousandths + damagedThousandths + lostThousandths;
    const pendingThousandths = toThousandths(String(selected.qty_pending));
    if (pendingThousandths === null) {
      setSubmitError("尚待確認量的格式不正確，已停止送出，請交由工程人員查明。");
      return;
    }
    if (totalThousandths <= 0) {
      setSubmitError("至少要填一種數量（完好、破損或遺失），不能全部是 0。");
      return;
    }
    if (totalThousandths > pendingThousandths) {
      setSubmitError(`本次處理合計 ${totalThousandths / 1000} 超過尚待確認量 ${pendingThousandths / 1000}。`);
      return;
    }

    const qGood = goodThousandths / 1000;
    const qDamaged = damagedThousandths / 1000;
    const qLost = lostThousandths / 1000;
    if (qGood > 0 && !fGoodsConfirmed) {
      setSubmitError("有填完好數量時，必須勾選「實物已到總倉」。");
      return;
    }
    if (qDamaged > 0 && !fDamageReason.trim()) {
      setSubmitError("有填破損數量時，必須填寫破損原因。");
      return;
    }
    if (qLost > 0 && !fLossReason.trim()) {
      setSubmitError("有填遺失數量時，必須填寫遺失原因。");
      return;
    }
    if (selected.tenant_id !== tenantId) {
      setSubmitError("這筆批次不屬於目前登入的公司，已停止送出。請重新登入後再試。");
      return;
    }

    let requestId: string;
    try {
      requestId = newRequestId();
    } catch (err) {
      setSubmitError(translateRpcError(err));
      return;
    }
    const payload: DisposePayload = {
      p_batch_id: selected.id,
      p_request_id: requestId,
      p_qty_good: qGood,
      p_qty_damaged: qDamaged,
      p_qty_lost: qLost,
      p_damage_reason: qDamaged > 0 ? fDamageReason.trim() : null,
      p_loss_reason: qLost > 0 ? fLossReason.trim() : null,
      p_goods_confirmed: qGood > 0,
      p_notes: fNotes.trim() || null,
    };
    const request: PendingRequest = {
      schemaVersion: 1,
      tenantId,
      operatorId,
      batchId: selected.id,
      requestId,
      createdAt: new Date().toISOString(),
      payload,
    };
    try {
      window.localStorage.setItem(pendingStorageKey, JSON.stringify(request));
    } catch {
      setSubmitError("這台裝置無法安全保留待確認資料，因此沒有送出。請確認瀏覽器允許本機儲存後再試。");
      return;
    }

    setPendingRequest(request);
    await sendStoredRequest(request);
  }, [
    pendingRequest,
    selected,
    storageLoadError,
    fGood,
    fDamaged,
    fLost,
    fGoodsConfirmed,
    fDamageReason,
    fLossReason,
    fNotes,
    tenantId,
    operatorId,
    pendingStorageKey,
    sendStoredRequest,
  ]);

  const pending = selected ? num(selected.qty_pending) : 0;
  const selectedSourceInfo = selected?.source_transfer_item_id == null
    ? undefined
    : sourceInfoMap.get(selected.source_transfer_item_id);
  const formLocked = submitting || pendingRequest !== null || storageLoadError !== null;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      {/* ── 頁首 ── */}
      <header>
        <h1 className="text-xl font-semibold">退回貨處理</h1>
        <p className="text-sm text-zinc-500">
          總倉收到門市退貨，或門市收貨時發現短少，請在這裡確認貨況。完好的貨可重新派出，破損與遺失會記入總倉損失。
        </p>
        <p className="mt-0.5 text-xs text-zinc-400">
          本頁不會再自動向店家收款或退款；責任歸屬另依老闆規則處理，來源成本也不等於最後認列的損失。
        </p>
      </header>

      {/* ── 篩選與操作列 ── */}
      <div className="flex flex-wrap items-center gap-3">
        <label className="flex items-center gap-1.5 text-sm">
          <input
            type="checkbox"
            checked={includeHistory}
            onChange={(e) => {
              setListLoading(true);
              setIncludeHistory(e.target.checked);
              setPage(0);
              setSelectedId(null);
              resetForm();
            }}
            disabled={pendingRequest !== null}
            className="rounded border-zinc-300 dark:border-zinc-600"
          />
          顯示已完成與已撤回
        </label>
        <SpinButton
          onClick={() => {
            setListLoading(true);
            return loadBatchPage();
          }}
          className="rounded-md border border-zinc-300 bg-white px-3 py-1 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-800 dark:hover:bg-zinc-700"
        >
          重新整理
        </SpinButton>
      </div>

      {/* ── 錯誤 ── */}
      {storageLoadError && (
        <div role="alert" className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {storageLoadError}
        </div>
      )}
      {listError && (
        <div role="alert" className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {listError}
        </div>
      )}
      {submitError && (
        <div role="alert" className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {submitError}
        </div>
      )}
      {submitOk && (
        <div aria-live="polite" className="rounded border border-emerald-200 bg-emerald-50 p-2 text-sm text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
          {submitOk}
        </div>
      )}
      {pendingRequest && (
        <div role="status" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">
          <strong>上一筆送出結果還沒查明。</strong> 批次 #{pendingRequest.batchId} 的原數量已保留並鎖定；現在不能改數量、切換批次或開新一筆。
          <div className="mt-2 flex flex-wrap gap-2">
            <SpinButton
              onClick={() => confirmStoredRequest(pendingRequest)}
              disabled={submitting}
              loading={submitting}
              className="rounded-md border border-amber-400 bg-white px-3 py-1.5 text-xs font-medium hover:bg-amber-100 disabled:opacity-60 dark:border-amber-700 dark:bg-amber-900 dark:hover:bg-amber-800"
            >
              查詢送出結果
            </SpinButton>
            <SpinButton
              onClick={() => sendStoredRequest(pendingRequest)}
              disabled={submitting}
              loading={submitting}
              className="rounded-md bg-amber-700 px-3 py-1.5 text-xs font-medium text-white hover:bg-amber-800 disabled:opacity-60"
            >
              重新傳送原資料
            </SpinButton>
          </div>
        </div>
      )}

      {/* ── 批次表格 ── */}
      <section className="flex flex-col gap-2">
        <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                <th className="px-3 py-2">批次</th>
                <th className="px-3 py-2">來源</th>
                <th className="px-3 py-2">店名</th>
                <th className="px-3 py-2">品項</th>
                <th className="px-3 py-2">原因</th>
                <th className="px-3 py-2 text-right">退回量</th>
                <th className="px-3 py-2 text-right">待確認</th>
                <th className="px-3 py-2 text-right">已處理</th>
                {showCost && <th className="px-3 py-2 text-right">來源單價</th>}
                <th className="px-3 py-2">狀態</th>
                <th className="px-3 py-2">建立</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {listLoading ? (
                <tr>
                  <td colSpan={showCost ? 11 : 10}>
                    <LoadingBlock />
                  </td>
                </tr>
              ) : batches.length === 0 ? (
                <tr>
                  <td
                    colSpan={showCost ? 11 : 10}
                    className="p-6 text-center text-zinc-500"
                  >
                    {includeHistory
                      ? "這一頁沒有退回貨批次。可回上一頁繼續查看。"
                      : "目前沒有待處理的退回貨批次。勾選「顯示已完成與已撤回」可看歷史。"}
                  </td>
                </tr>
              ) : (
                batches.map((b) => {
                  const sv = STATUS_ZH[b.status] ?? {
                    label: "狀態待確認",
                    cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
                  };
                  const sourceInfo = b.source_transfer_item_id == null
                    ? undefined
                    : sourceInfoMap.get(b.source_transfer_item_id);
                  const storeName = sourceInfo
                    ? (b.source_kind === "shortage" ? sourceInfo.destName : sourceInfo.sourceName) ?? "店名未查到"
                    : b.source_transfer_item_id == null ? "—" : "店名未查到";
                  const isSelected = selectedId === b.id;
                  return (
                    <tr
                      key={b.id}
                      className={`align-top transition-colors ${
                        isSelected
                          ? "bg-blue-50 dark:bg-blue-950"
                          : "hover:bg-zinc-50 dark:hover:bg-zinc-800"
                      }`}
                    >
                      <td className="px-3 py-2">
                        <button
                          type="button"
                          onClick={() => handleSelect(b.id)}
                          disabled={pendingRequest !== null}
                          aria-pressed={isSelected}
                          aria-label={`${isSelected ? "收起" : "查看"}批次 ${b.id}`}
                          className="rounded px-1 py-0.5 font-mono text-xs text-blue-700 underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 disabled:cursor-not-allowed disabled:text-zinc-400 disabled:no-underline dark:text-blue-300"
                        >
                          #{b.id}
                        </button>
                      </td>
                      <td className="px-3 py-2 text-xs">
                        {SOURCE_KIND_ZH[b.source_kind] ?? "其他來源"}
                        {b.auto_flag && (
                          <span className="ml-1 text-[10px] text-zinc-400">
                            ({b.auto_flag === "system" ? "系統" : "人工"})
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-xs">
                        <div>{storeName}</div>
                        {b.source_transfer_item_id != null && (
                          <div className="mt-0.5 whitespace-nowrap text-[10px] text-zinc-400">
                            {sourceInfo?.transferNo ? `原單 ${sourceInfo.transferNo}` : "原單號未查到"}
                            {` · 明細 #${b.source_transfer_item_id}`}
                          </div>
                        )}
                      </td>
                      <td className="px-3 py-2 text-xs">
                        {skuLabel(skuMap.get(b.sku_id), b.sku_id)}
                      </td>
                      <td className="px-3 py-2 text-xs">
                        {b.source_reason || "—"}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">
                        {num(b.total_qty)}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums font-medium text-amber-700 dark:text-amber-400">
                        {num(b.qty_pending)}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">
                        {num(b.qty_good) + num(b.qty_damaged) + num(b.qty_lost)}
                      </td>
                      {showCost && (
                        <td className="px-3 py-2 text-right tabular-nums text-xs text-zinc-500">
                          {fmtUnitCost(b.unit_cost)}
                        </td>
                      )}
                      <td className="px-3 py-2">
                        <span
                          className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ${sv.cls}`}
                        >
                          {sv.label}
                        </span>
                      </td>
                      <td className="px-3 py-2 text-xs text-zinc-500">
                        {fmtDate(b.created_at)}
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-zinc-500">
          <span>
            第 {page + 1} 頁，本頁 {batches.length} 筆
            {batches.length > 0 && `（第 ${page * PAGE_SIZE + 1}–${page * PAGE_SIZE + batches.length} 筆）`}。
          </span>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => {
                setListLoading(true);
                setPage((value) => Math.max(0, value - 1));
                setSelectedId(null);
                setEvents([]);
                resetForm();
              }}
              disabled={page === 0 || listLoading || pendingRequest !== null}
              className="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 disabled:cursor-not-allowed disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              上一頁
            </button>
            <button
              type="button"
              onClick={() => {
                setListLoading(true);
                setPage((value) => value + 1);
                setSelectedId(null);
                setEvents([]);
                resetForm();
              }}
              disabled={!hasNextPage || listLoading || pendingRequest !== null}
              className="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 disabled:cursor-not-allowed disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              下一頁
            </button>
          </div>
        </div>
      </section>

      {/* ── 選中批次的詳情 ── */}
      {selected && (
        <section className="flex flex-col gap-4 rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div>
              <h2 className="text-base font-semibold">
                批次 #{selected.id}
                <span className="ml-2 text-sm font-normal text-zinc-500">
                  {skuLabel(skuMap.get(selected.sku_id), selected.sku_id)}
                </span>
              </h2>
              <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-500">
                {selected.source_transfer_item_id != null && (
                  <span>
                    原單 <strong>{selectedSourceInfo?.transferNo ?? "號碼未查到"}</strong>
                    {` / 明細 #${selected.source_transfer_item_id}`}
                  </span>
                )}
                <span>
                  退回量 <strong>{num(selected.total_qty)}</strong>
                </span>
                <span>
                  完好 <strong>{num(selected.qty_good)}</strong>
                </span>
                <span>
                  破損 <strong>{num(selected.qty_damaged)}</strong>
                </span>
                <span>
                  遺失 <strong>{num(selected.qty_lost)}</strong>
                </span>
                {num(selected.qty_revoked) > 0 && (
                  <span>
                    撤回 <strong>{num(selected.qty_revoked)}</strong>
                  </span>
                )}
                <span className="font-medium text-amber-700 dark:text-amber-400">
                  尚待確認 <strong>{num(selected.qty_pending)}</strong>
                </span>
              </div>
              {showCost && (
                <div className="mt-0.5 text-xs text-zinc-400">
                  來源入庫紀錄單價 {fmtUnitCost(selected.unit_cost)}（不是售價，也不是最後認列的損失）
                </div>
              )}
            </div>
            <button
              type="button"
              onClick={() => {
                setSelectedId(null);
                resetForm();
              }}
              disabled={pendingRequest !== null}
              className="rounded text-xs text-zinc-400 hover:text-zinc-600 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 disabled:cursor-not-allowed disabled:opacity-50 dark:hover:text-zinc-300"
            >
              ✕ 關閉
            </button>
          </div>

          {/* ── 處理事件歷史 ── */}
          <div>
            <h3 className="mb-1 text-sm font-semibold">處理紀錄</h3>
            {eventsError && (
              <div role="alert" className="mb-2 rounded border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
                {eventsError}
              </div>
            )}
            {eventsLoading ? (
              <LoadingBlock />
            ) : events.length === 0 && !eventsError ? (
              <p className="text-xs text-zinc-500">尚未有任何處理事件。</p>
            ) : events.length > 0 ? (
              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
                  <thead>
                    <tr className="text-left text-[10px] uppercase tracking-wide text-zinc-400">
                      <th className="px-2 py-1">紀錄</th>
                      <th className="px-2 py-1 text-right">完好</th>
                      <th className="px-2 py-1 text-right">破損</th>
                      <th className="px-2 py-1 text-right">遺失</th>
                      <th className="px-2 py-1">破損原因</th>
                      <th className="px-2 py-1">遺失原因</th>
                      {showCost && <th className="px-2 py-1 text-right">單價依據</th>}
                      <th className="px-2 py-1">操作人</th>
                      <th className="px-2 py-1">時間</th>
                      <th className="px-2 py-1">備註</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                    {events.map((ev) => (
                      <tr key={ev.id} className="align-top">
                        <td className="px-2 py-1 font-mono">#{ev.id}</td>
                        <td className="px-2 py-1 text-right tabular-nums">
                          {num(ev.qty_good) || "—"}
                        </td>
                        <td className="px-2 py-1 text-right tabular-nums">
                          {num(ev.qty_damaged) || "—"}
                        </td>
                        <td className="px-2 py-1 text-right tabular-nums">
                          {num(ev.qty_lost) || "—"}
                        </td>
                        <td className="px-2 py-1 text-zinc-500">
                          {ev.damage_reason || "—"}
                        </td>
                        <td className="px-2 py-1 text-zinc-500">
                          {ev.loss_reason || "—"}
                        </td>
                        {showCost && (
                          <td className="px-2 py-1 text-right tabular-nums text-zinc-400">
                            {fmtUnitCost(selected.unit_cost)}
                          </td>
                        )}
                        <td className="px-2 py-1 text-zinc-500">
                          {operatorNames.get(ev.operator_id) ?? ev.operator_id}
                        </td>
                        <td className="px-2 py-1 text-zinc-500">
                          {fmtDateTime(ev.created_at)}
                        </td>
                        <td className="px-2 py-1 text-zinc-400">
                          {ev.notes || "—"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : null}
          </div>

          {/* ── 處理表單（有待確認量或尚待查明的送出資料時顯示） ── */}
          {pending > 0 || pendingRequest?.batchId === selected.id ? (
            <div className="rounded-md border border-zinc-200 bg-zinc-50 p-4 dark:border-zinc-700 dark:bg-zinc-800">
              <h3 className="mb-2 text-sm font-semibold">
                {pendingRequest ? "這筆資料正在等待確認" : `處理此批（尚待 ${pending}）`}
              </h3>
              <p className="mb-3 text-xs text-zinc-500">
                完好的貨會恢復成可重新派出的庫存；破損與遺失會記入總倉損失。
                不必一次處理完，未處理的數量會繼續保留。
              </p>

              <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                {/* 完好 */}
                <div>
                  <label htmlFor="return-good-qty" className="mb-1 block text-xs font-medium">
                    完好數量
                  </label>
                  <input
                    id="return-good-qty"
                    type="text"
                    inputMode="decimal"
                    value={fGood}
                    onChange={(e) =>
                      setFGood(clampDecimal(e.target.value, pending))
                    }
                    disabled={formLocked}
                    className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-sm tabular-nums disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                    placeholder="0"
                  />
                  {num(fGood) > 0 && (
                    <label className="mt-1 flex items-center gap-1.5 text-xs">
                      <input
                        id="return-goods-confirmed"
                        type="checkbox"
                        checked={fGoodsConfirmed}
                        onChange={(e) => setFGoodsConfirmed(e.target.checked)}
                        disabled={formLocked}
                        className="rounded border-zinc-300 dark:border-zinc-600"
                      />
                      <span>實物已到總倉（必勾）</span>
                    </label>
                  )}
                </div>

                {/* 破損 */}
                <div>
                  <label htmlFor="return-damaged-qty" className="mb-1 block text-xs font-medium">
                    破損數量
                  </label>
                  <input
                    id="return-damaged-qty"
                    type="text"
                    inputMode="decimal"
                    value={fDamaged}
                    onChange={(e) =>
                      setFDamaged(clampDecimal(e.target.value, pending))
                    }
                    disabled={formLocked}
                    className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-sm tabular-nums disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                    placeholder="0"
                  />
                  {num(fDamaged) > 0 && (
                    <div className="mt-1">
                      <label htmlFor="return-damage-reason" className="mb-1 block text-xs text-zinc-500">
                        破損原因（必填）
                      </label>
                      <input
                        id="return-damage-reason"
                        type="text"
                        value={fDamageReason}
                        onChange={(e) => setFDamageReason(e.target.value)}
                        disabled={formLocked}
                        className="w-full rounded-md border border-zinc-300 px-2 py-1 text-xs disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                        placeholder="例如：外箱破裂、商品滲漏"
                      />
                    </div>
                  )}
                </div>

                {/* 遺失 */}
                <div>
                  <label htmlFor="return-lost-qty" className="mb-1 block text-xs font-medium">
                    遺失數量
                  </label>
                  <input
                    id="return-lost-qty"
                    type="text"
                    inputMode="decimal"
                    value={fLost}
                    onChange={(e) =>
                      setFLost(clampDecimal(e.target.value, pending))
                    }
                    disabled={formLocked}
                    className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-sm tabular-nums disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                    placeholder="0"
                  />
                  {num(fLost) > 0 && (
                    <div className="mt-1">
                      <label htmlFor="return-loss-reason" className="mb-1 block text-xs text-zinc-500">
                        遺失原因（必填）
                      </label>
                      <input
                        id="return-loss-reason"
                        type="text"
                        value={fLossReason}
                        onChange={(e) => setFLossReason(e.target.value)}
                        disabled={formLocked}
                        className="w-full rounded-md border border-zinc-300 px-2 py-1 text-xs disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                        placeholder="例如：清點後未找到"
                      />
                    </div>
                  )}
                </div>
              </div>

              {/* 備註 */}
              <div className="mt-3">
                <label htmlFor="return-notes" className="mb-1 block text-xs font-medium">
                  備註（選填）
                </label>
                <input
                  id="return-notes"
                  type="text"
                  value={fNotes}
                  onChange={(e) => setFNotes(e.target.value)}
                  disabled={formLocked}
                  className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-sm disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                  placeholder="處理備註"
                />
              </div>

              {/* 按鈕列 */}
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <SpinButton
                  onClick={handleSubmit}
                  disabled={formLocked}
                  loading={submitting}
                  className="rounded-md bg-blue-600 px-4 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
                >
                  {pendingRequest ? "資料已鎖定" : "送出處理"}
                </SpinButton>
              </div>
            </div>
          ) : (
            <div className="rounded-md border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
              {selected.status === "completed"
                ? "✓ 此批已全部處理完畢。"
                : selected.status === "revoked"
                  ? "此批已被撤回。"
                  : "此批尚待量為 0。"}
            </div>
          )}

          {/* ── 寫錯數量的指引 ── */}
          <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-500 dark:border-zinc-700 dark:bg-zinc-800">
            <strong>原單收貨數量寫錯：</strong>請前往{" "}
            <Link
              href="/wms/inbound"
              className="text-blue-600 underline hover:text-blue-800 dark:text-blue-400"
            >
              收貨頁
            </Link>{" "}
            找到原單更正。<br />
            <strong>這次完好、破損或遺失填錯：</strong>處理紀錄目前不能直接修改，也不能靠更改原單收貨量修正；請先停止後續處理並交由主管查核。
            兩種情況都不要用手動調整庫存硬改，否則實物與帳會對不上。
          </div>
        </section>
      )}
    </div>
  );
}

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
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { translateRpcError } from "@/lib/rpcError";
import { useRole, isHqRole, canSeeCost } from "@/lib/role";
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
  unit_cost: number;
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

// ── helper ──

function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
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

/** Safari-safe UUID（比照 wms/receiving/ipad/page.tsx:247-250） */
function newRequestId(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `r_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}

/** 小數最多 3 位（不截整），用來把 input 值夾到合法範圍 */
function clampDecimal(v: string, max: number): string {
  // 保留使用者輸入的小數位，但不能超過 3 位
  const m = v.match(/^(\d+)(?:\.(\d{0,3}))?/);
  if (!m) return "";
  const clamped = Math.min(Number(m[0]), max);
  // 維持使用者打的小數型態
  if (m[2] !== undefined) {
    const decimals = Math.min(m[2].length, 3);
    return clamped.toFixed(decimals);
  }
  return String(Math.floor(clamped));
}

const MAX_ROWS = 200;

// ── 主元件 ──

export default function HqReturnDispositionPage() {
  const role = useRole();
  const showCost = canSeeCost(role);
  const allowed = isHqRole(role);

  // ── 批次列表 ──
  const [batches, setBatches] = useState<BatchRow[]>([]);
  const [skuMap, setSkuMap] = useState<Map<number, SkuRow>>(new Map());
  // source_transfer_item_id → 店名
  const [storeNameMap, setStoreNameMap] = useState<Map<number, string>>(new Map());
  const [listLoading, setListLoading] = useState(true);
  const [listError, setListError] = useState<string | null>(null);
  const [includeHistory, setIncludeHistory] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  // ── 選中的批次 ──
  const [selectedId, setSelectedId] = useState<number | null>(null);

  // ── 事件列表（選中批次的） ──
  const [events, setEvents] = useState<EventRow[]>([]);
  const [eventsLoading, setEventsLoading] = useState(false);
  const [eventsError, setEventsError] = useState<string | null>(null);
  const [operatorNames, setOperatorNames] = useState<Map<string, string>>(new Map());

  // ── 處理表單 ──
  const [fGood, setFGood] = useState("");
  const [fDamaged, setFDamaged] = useState("");
  const [fLost, setFLost] = useState("");
  const [fDamageReason, setFDamageReason] = useState("");
  const [fLossReason, setFLossReason] = useState("");
  const [fGoodsConfirmed, setFGoodsConfirmed] = useState(false);
  const [fNotes, setFNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitOk, setSubmitOk] = useState<string | null>(null);
  // 冪等 UUID：每次送出用同一個，成功或改 payload 後換新
  const requestIdRef = useRef(newRequestId());

  const selected = useMemo(
    () => batches.find((b) => b.id === selectedId) ?? null,
    [batches, selectedId],
  );

  // ── 載入批次列表 ──
  useEffect(() => {
    if (role === null) return; // 還在讀 role
    if (!allowed) {
      setListLoading(false);
      return;
    }
    let cancelled = false;
    setListLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        let q = sb
          .from("v_hq_return_batches_list")
          .select("*")
          .order("created_at", { ascending: false })
          .limit(MAX_ROWS);

        if (!includeHistory) {
          q = q.in("status", ["pending", "partial"]);
        }

        const { data, error } = await q;
        if (error) throw error;
        if (cancelled) return;
        const rows = (data ?? []) as BatchRow[];

        // ── 解析 SKU 名稱 ──
        const skuIds = Array.from(new Set(rows.map((r) => r.sku_id)));
        const newSkuMap = new Map<number, SkuRow>();
        if (skuIds.length > 0) {
          const skuRows = await fetchAllRows<SkuRow>(() =>
            sb
              .from("skus")
              .select("id, sku_code, product_name, variant_name")
              .in("id", skuIds)
              .order("id", { ascending: true }),
          );
          for (const s of skuRows) newSkuMap.set(s.id, s);
        }

        // ── 解析店名：source_transfer_item_id → transfer_items → transfers → locations ──
        const tiIds = rows
          .map((r) => r.source_transfer_item_id)
          .filter((x): x is number => x != null);
        const uniqueTiIds = Array.from(new Set(tiIds));
        const newStoreMap = new Map<number, string>();

        if (uniqueTiIds.length > 0) {
          // 1) transfer_items → 拿 transfer_id
          const tiRows = await fetchAllRows<{ id: number; transfer_id: number }>(() =>
            sb
              .from("transfer_items")
              .select("id, transfer_id")
              .in("id", uniqueTiIds)
              .order("id", { ascending: true }),
          );
          const tiToTransfer = new Map<number, number>();
          for (const ti of tiRows) tiToTransfer.set(ti.id, ti.transfer_id);

          // 2) transfers → 拿 source_location
          const transferIds = Array.from(new Set(tiRows.map((t) => t.transfer_id)));
          if (transferIds.length > 0) {
            const trRows = await fetchAllRows<{
              id: number;
              transfer_no: string;
              source_location: number;
            }>(() =>
              sb
                .from("transfers")
                .select("id, transfer_no, source_location")
                .in("id", transferIds)
                .order("id", { ascending: true }),
            );
            const trMap = new Map<number, number>();
            for (const tr of trRows) trMap.set(tr.id, tr.source_location);

            // 3) locations → 拿 name
            const locIds = Array.from(new Set(trRows.map((t) => t.source_location)));
            if (locIds.length > 0) {
              const { data: lr } = await sb
                .from("locations")
                .select("id, name")
                .in("id", locIds);
              const locName = new Map<number, string>();
              for (const l of (lr ?? []) as { id: number; name: string }[])
                locName.set(l.id, l.name);

              // 組合：tiId → storeName
              for (const tiId of uniqueTiIds) {
                const trId = tiToTransfer.get(tiId);
                if (trId == null) continue;
                const locId = trMap.get(trId);
                if (locId == null) continue;
                const name = locName.get(locId);
                if (name) newStoreMap.set(tiId, name);
              }
            }
          }
        }

        if (cancelled) return;
        setBatches(rows);
        setSkuMap(newSkuMap);
        setStoreNameMap(newStoreMap);
        setListError(null);
      } catch (err) {
        if (!cancelled) setListError(translateRpcError(err));
      } finally {
        if (!cancelled) setListLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [role, allowed, includeHistory, reloadKey]);

  // ── 載入選中批次的事件 ──
  useEffect(() => {
    if (selectedId == null) {
      setEvents([]);
      setEventsError(null);
      return;
    }
    let cancelled = false;
    setEventsLoading(true);
    setEventsError(null);
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error } = await sb
          .from("hq_return_events")
          .select(
            "id, batch_id, request_id, qty_good, qty_damaged, qty_lost, damage_reason, loss_reason, goods_confirmed, damage_movement_id, loss_movement_id, notes, operator_id, created_at",
          )
          .eq("batch_id", selectedId)
          .order("created_at", { ascending: true });
        if (error) throw error;
        if (cancelled) return;
        const evts = (data ?? []) as EventRow[];

        // 操作人名稱
        const uids = Array.from(
          new Set(evts.map((e) => e.operator_id).filter(Boolean)),
        );
        const nameMap = new Map<string, string>();
        if (uids.length > 0) {
          const { data: ns } = await sb.rpc("rpc_get_staff_names", {
            p_uids: uids,
          });
          for (const n of (ns as { id: string; display_name: string }[] | null) ?? [])
            nameMap.set(n.id, n.display_name);
        }

        if (cancelled) return;
        setEvents(evts);
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
  }, [selectedId, reloadKey]);

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
    requestIdRef.current = newRequestId();
  }, []);

  // 選批次時清表單
  const handleSelect = useCallback(
    (id: number) => {
      setSelectedId((prev) => (prev === id ? null : id));
      resetForm();
    },
    [resetForm],
  );

  // ── 送出處理 ──
  const handleSubmit = useCallback(async () => {
    if (!selected) return;
    setSubmitError(null);
    setSubmitOk(null);

    const qGood = num(fGood);
    const qDamaged = num(fDamaged);
    const qLost = num(fLost);
    const total = qGood + qDamaged + qLost;

    if (total <= 0) {
      setSubmitError("至少要填一種數量（完好/破損/遺失），不能全部是 0。");
      return;
    }
    if (total > num(selected.qty_pending)) {
      setSubmitError(
        `本次處理合計 ${total} 超過尚待確認量 ${num(selected.qty_pending)}。`,
      );
      return;
    }
    if (qGood > 0 && !fGoodsConfirmed) {
      setSubmitError("完好數量 > 0 時必須勾選「實物已到」。");
      return;
    }
    if (qDamaged > 0 && !fDamageReason.trim()) {
      setSubmitError("破損數量 > 0 時必須填寫破損原因。");
      return;
    }
    if (qLost > 0 && !fLossReason.trim()) {
      setSubmitError("遺失數量 > 0 時必須填寫遺失原因。");
      return;
    }

    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data, error } = await sb.rpc("rpc_dispose_hq_return", {
        p_batch_id: selected.id,
        p_request_id: requestIdRef.current,
        p_qty_good: qGood,
        p_qty_damaged: qDamaged,
        p_qty_lost: qLost,
        p_damage_reason: qDamaged > 0 ? fDamageReason.trim() : null,
        p_loss_reason: qLost > 0 ? fLossReason.trim() : null,
        p_goods_confirmed: qGood > 0 ? true : false,
        p_notes: fNotes.trim() || null,
      });
      if (error) throw error;

      const result = data as {
        event_id: number;
        batch_id: number;
        idempotent: boolean;
        new_status?: string;
      };

      setSubmitOk(
        result.idempotent
          ? `✓ 重試成功（同一筆 request，事件 #${result.event_id}）`
          : `✓ 處理完成（事件 #${result.event_id}${result.new_status === "completed" ? "，此批已全部處理完畢" : ""}）`,
      );

      // 成功後刷新列表與事件、重設表單
      // ⚠ 新 requestId 讓下次送出用新的冪等碼
      requestIdRef.current = newRequestId();
      setFGood("");
      setFDamaged("");
      setFLost("");
      setFDamageReason("");
      setFLossReason("");
      setFGoodsConfirmed(false);
      setFNotes("");
      setReloadKey((k) => k + 1);
    } catch (err) {
      setSubmitError(translateRpcError(err));
      // ⚠ 不確定是否已經成功（網路錯誤）→ 保留同一個 requestId，讓使用者可以安全重試
      // 如果使用者想改 payload，下面有「重新產生」按鈕會換新 id
    } finally {
      setSubmitting(false);
    }
  }, [selected, fGood, fDamaged, fLost, fDamageReason, fLossReason, fGoodsConfirmed, fNotes]);

  // 等 role 載入
  if (role === null) return <LoadingBlock />;

  // 權限不足
  if (!allowed) {
    return (
      <div className="flex flex-1 flex-col gap-4 p-6">
        <h1 className="text-xl font-semibold">退回貨處理</h1>
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          權限不足：此頁面僅限總倉管理角色（owner / admin / hq_manager）。
        </div>
      </div>
    );
  }

  const pending = selected ? num(selected.qty_pending) : 0;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      {/* ── 頁首 ── */}
      <header>
        <h1 className="text-xl font-semibold">退回貨處理</h1>
        <p className="text-sm text-zinc-500">
          門市退貨與收貨短少回到總倉的批次在這裡處理。完好的會放回可派庫存，破損與遺失會扣總倉帳。
        </p>
        <p className="mt-0.5 text-xs text-zinc-400">
          破損/遺失<strong>不會</strong>對店家收退款；責任歸屬待定，來源成本不等於正式損失認列。
        </p>
      </header>

      {/* ── 篩選與操作列 ── */}
      <div className="flex flex-wrap items-center gap-3">
        <label className="flex items-center gap-1.5 text-sm">
          <input
            type="checkbox"
            checked={includeHistory}
            onChange={(e) => setIncludeHistory(e.target.checked)}
            className="rounded border-zinc-300 dark:border-zinc-600"
          />
          含已完成/已撤回
        </label>
        <SpinButton
          onClick={() => setReloadKey((k) => k + 1)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-1 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-800 dark:hover:bg-zinc-700"
        >
          重新整理
        </SpinButton>
      </div>

      {/* ── 錯誤 ── */}
      {listError && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {listError}
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
                <th className="px-3 py-2 text-right">回帳量</th>
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
                      ? "此 tenant 沒有任何退回貨批次（並非代表全系統無資料，僅為本次查詢結果）。"
                      : "目前沒有待處理的退回貨批次。勾選「含已完成/已撤回」可看歷史。"}
                  </td>
                </tr>
              ) : (
                batches.map((b) => {
                  const sv = STATUS_ZH[b.status] ?? {
                    label: b.status,
                    cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
                  };
                  const storeName = b.source_transfer_item_id != null
                    ? storeNameMap.get(b.source_transfer_item_id) ??
                      `調撥明細#${b.source_transfer_item_id}`
                    : "—";
                  const isSelected = selectedId === b.id;
                  return (
                    <tr
                      key={b.id}
                      onClick={() => handleSelect(b.id)}
                      className={`cursor-pointer align-top transition-colors ${
                        isSelected
                          ? "bg-blue-50 dark:bg-blue-950"
                          : "hover:bg-zinc-50 dark:hover:bg-zinc-800"
                      }`}
                    >
                      <td className="px-3 py-2 font-mono text-xs">#{b.id}</td>
                      <td className="px-3 py-2 text-xs">
                        {SOURCE_KIND_ZH[b.source_kind] ?? b.source_kind}
                        {b.auto_flag && (
                          <span className="ml-1 text-[10px] text-zinc-400">
                            ({b.auto_flag === "system" ? "系統" : "人工"})
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-xs">{storeName}</td>
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
                          ${num(b.unit_cost).toFixed(2)}
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
        <p className="text-[11px] text-zinc-400">
          本次已載入 {batches.length} 筆（上限 {MAX_ROWS}）。
          {batches.length >= MAX_ROWS &&
            "已達上限，可能有更多批次未顯示。請縮小條件或聯繫工程師。"}
          此數字<strong>不代表</strong>全系統總數。
        </p>
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
                <span>
                  回帳量 <strong>{num(selected.total_qty)}</strong>
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
                  來源單價依據 ${num(selected.unit_cost).toFixed(2)}
                  （不是售價，是原出庫 movement 的 unit_cost）
                </div>
              )}
            </div>
            <button
              onClick={() => {
                setSelectedId(null);
                resetForm();
              }}
              className="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
            >
              ✕ 關閉
            </button>
          </div>

          {/* ── 處理事件歷史 ── */}
          <div>
            <h3 className="mb-1 text-sm font-semibold">處理紀錄</h3>
            {eventsError && (
              <div className="mb-2 rounded border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
                {eventsError}
              </div>
            )}
            {eventsLoading ? (
              <LoadingBlock />
            ) : events.length === 0 ? (
              <p className="text-xs text-zinc-500">尚未有任何處理事件。</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
                  <thead>
                    <tr className="text-left text-[10px] uppercase tracking-wide text-zinc-400">
                      <th className="px-2 py-1">事件</th>
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
                            ${num(selected.unit_cost).toFixed(2)}
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
            )}
          </div>

          {/* ── 處理表單（只在有 pending 時顯示） ── */}
          {pending > 0 ? (
            <div className="rounded-md border border-zinc-200 bg-zinc-50 p-4 dark:border-zinc-700 dark:bg-zinc-800">
              <h3 className="mb-2 text-sm font-semibold">
                處理此批（尚待 {pending}）
              </h3>
              <p className="mb-3 text-xs text-zinc-500">
                完好會放回可派庫存（reserved → available）；破損/遺失會寫負 movement 扣總倉帳。
                不一定要一次全部處理完，剩餘的尚待量會留著。
              </p>

              <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                {/* 完好 */}
                <div>
                  <label className="mb-1 block text-xs font-medium">
                    完好數量
                  </label>
                  <input
                    type="number"
                    inputMode="decimal"
                    step="any"
                    min="0"
                    max={pending}
                    value={fGood}
                    onChange={(e) =>
                      setFGood(clampDecimal(e.target.value, pending))
                    }
                    disabled={submitting}
                    className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-sm tabular-nums disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                    placeholder="0"
                  />
                  {num(fGood) > 0 && (
                    <label className="mt-1 flex items-center gap-1.5 text-xs">
                      <input
                        type="checkbox"
                        checked={fGoodsConfirmed}
                        onChange={(e) => setFGoodsConfirmed(e.target.checked)}
                        disabled={submitting}
                        className="rounded border-zinc-300 dark:border-zinc-600"
                      />
                      實物已到（必勾）
                    </label>
                  )}
                </div>

                {/* 破損 */}
                <div>
                  <label className="mb-1 block text-xs font-medium">
                    破損數量
                  </label>
                  <input
                    type="number"
                    inputMode="decimal"
                    step="any"
                    min="0"
                    max={pending}
                    value={fDamaged}
                    onChange={(e) =>
                      setFDamaged(clampDecimal(e.target.value, pending))
                    }
                    disabled={submitting}
                    className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-sm tabular-nums disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                    placeholder="0"
                  />
                  {num(fDamaged) > 0 && (
                    <div className="mt-1">
                      <input
                        type="text"
                        value={fDamageReason}
                        onChange={(e) => setFDamageReason(e.target.value)}
                        disabled={submitting}
                        className="w-full rounded-md border border-zinc-300 px-2 py-1 text-xs disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                        placeholder="破損原因（必填）"
                      />
                    </div>
                  )}
                </div>

                {/* 遺失 */}
                <div>
                  <label className="mb-1 block text-xs font-medium">
                    遺失數量
                  </label>
                  <input
                    type="number"
                    inputMode="decimal"
                    step="any"
                    min="0"
                    max={pending}
                    value={fLost}
                    onChange={(e) =>
                      setFLost(clampDecimal(e.target.value, pending))
                    }
                    disabled={submitting}
                    className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-sm tabular-nums disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                    placeholder="0"
                  />
                  {num(fLost) > 0 && (
                    <div className="mt-1">
                      <input
                        type="text"
                        value={fLossReason}
                        onChange={(e) => setFLossReason(e.target.value)}
                        disabled={submitting}
                        className="w-full rounded-md border border-zinc-300 px-2 py-1 text-xs disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                        placeholder="遺失原因（必填）"
                      />
                    </div>
                  )}
                </div>
              </div>

              {/* 備註 */}
              <div className="mt-3">
                <label className="mb-1 block text-xs font-medium">
                  備註（選填）
                </label>
                <input
                  type="text"
                  value={fNotes}
                  onChange={(e) => setFNotes(e.target.value)}
                  disabled={submitting}
                  className="w-full rounded-md border border-zinc-300 px-2 py-1.5 text-sm disabled:opacity-60 dark:border-zinc-600 dark:bg-zinc-700"
                  placeholder="處理備註"
                />
              </div>

              {/* 提交結果 */}
              {submitError && (
                <div className="mt-2 rounded border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
                  {submitError}
                  <div className="mt-1 text-[10px] text-zinc-400">
                    如果是網路中斷，可以直接再按一次送出（同一個 request UUID 會安全重試）。
                    如果你想<strong>改數量</strong>再送，請先按下面的「重新產生 Request ID」。
                  </div>
                </div>
              )}
              {submitOk && (
                <div className="mt-2 rounded border border-emerald-200 bg-emerald-50 p-2 text-xs text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
                  {submitOk}
                </div>
              )}

              {/* 按鈕列 */}
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <SpinButton
                  onClick={handleSubmit}
                  disabled={submitting}
                  loading={submitting}
                  className="rounded-md bg-blue-600 px-4 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
                >
                  送出處理
                </SpinButton>
                <button
                  type="button"
                  onClick={() => {
                    requestIdRef.current = newRequestId();
                    setSubmitError(null);
                    setSubmitOk(null);
                  }}
                  disabled={submitting}
                  className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs text-zinc-600 hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-600 dark:text-zinc-400 dark:hover:bg-zinc-700"
                >
                  重新產生 Request ID（改 payload 後按）
                </button>
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
            <strong>寫錯數量？</strong>{" "}
            處理事件一旦送出無法直接修改。如需更正，請前往{" "}
            <Link
              href="/wms/inbound"
              className="text-blue-600 underline hover:text-blue-800 dark:text-blue-400"
            >
              收貨頁（/wms/inbound）
            </Link>{" "}
            找到原單處理。已處理的批次或已鎖月份需依原單保護機制，不能直接硬改。
            <strong>不要</strong>用手動調整庫存來「修正」——那會讓帳對不上。
          </div>
        </section>
      )}
    </div>
  );
}

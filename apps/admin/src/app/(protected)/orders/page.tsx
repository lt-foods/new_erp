"use client";

import Link from "next/link";
import { Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { OrderDetail } from "@/components/OrderDetail";
import { PickupDialog } from "@/components/PickupDialog";
import { translateRpcError } from "@/lib/rpcError";
import { withBasePath } from "@/lib/basePath";

type OrderStatus =
  | "pending" | "confirmed" | "reserved" | "shipping" | "ready" | "partially_ready"
  | "partially_completed" | "completed" | "expired" | "cancelled" | "transferred_out";

type Row = {
  id: number;
  order_no: string;
  campaign_id: number;
  member_id: number | null;
  nickname_snapshot: string | null;
  pickup_store_id: number;
  pickup_deadline: string | null;
  status: OrderStatus;
  created_at: string;
  updated_at: string;
};

type Campaign = { id: number; campaign_no: string; name: string; cover_image_url: string | null };
type Store = { id: number; code: string; name: string };
type Member = { id: number; name: string | null; phone: string | null; member_no: string; avatar_url: string | null };

const STATUS_LABEL: Record<OrderStatus, string> = {
  pending: "待確認", confirmed: "已確認", reserved: "已保留", shipping: "派貨中",
  ready: "可取貨", partially_ready: "部分可取", partially_completed: "部分取貨",
  completed: "已完成", expired: "逾期", cancelled: "已取消",
  transferred_out: "已轉出",
};

const PAGE_SIZE = 50;

export default function OrdersListPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <OrdersListContent />
    </Suspense>
  );
}

function OrdersListContent() {
  const searchParams = useSearchParams();
  // 支援單個 campaignId（舊）+ campaignIds 多個逗號分隔（新）
  const initialCampaignIds = ((): string[] => {
    const multi = searchParams.get("campaignIds");
    if (multi) return multi.split(",").map((s) => s.trim()).filter(Boolean);
    const single = searchParams.get("campaignId");
    return single ? [single] : [];
  })();
  const initialStatus = searchParams.get("status") ?? "";
  const initialStoreId = searchParams.get("storeId") ?? "";

  const [rows, setRows] = useState<Row[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [campaignIds, setCampaignIds] = useState<string[]>(initialCampaignIds);
  const [status, setStatus] = useState(initialStatus);
  const [storeId, setStoreId] = useState(initialStoreId);
  const [page, setPage] = useState(1);
  const [campaignPickerOpen, setCampaignPickerOpen] = useState(false);

  const [campaigns, setCampaigns] = useState<Campaign[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  const [members, setMembers] = useState<Map<number, Member>>(new Map());
  const [itemSummary, setItemSummary] = useState<
    Map<
      number,
      {
        lineCount: number;
        totalQty: number;
        totalAmount: number;
        items: { product_name: string | null; variant_name: string | null; qty: number }[];
      }
    >
  >(new Map());
  const [pickupReady, setPickupReady] = useState<Map<number, boolean>>(new Map());
  const [detailId, setDetailId] = useState<number | null>(null);
  const [detailNo, setDetailNo] = useState<string>("");
  const [pickup, setPickup] = useState<{ id: number; no: string } | null>(null);
  const [reloadOrders, setReloadOrders] = useState(0);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [bulkBusy, setBulkBusy] = useState(false);

  useEffect(() => { setPage(1); }, [campaignIds, status, storeId]);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [c, s] = await Promise.all([
        sb.from("group_buy_campaigns").select("id, campaign_no, name, cover_image_url").order("updated_at", { ascending: false }).limit(200),
        sb.from("stores").select("id, code, name").order("name"),
      ]);
      setCampaigns((c.data as Campaign[]) ?? []);
      setStores((s.data as Store[]) ?? []);
    })();
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        let q = getSupabase()
          .from("customer_orders")
          .select("id, order_no, campaign_id, member_id, nickname_snapshot, pickup_store_id, pickup_deadline, status, created_at, updated_at", { count: "exact" })
          .order("updated_at", { ascending: false })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        if (campaignIds.length === 1) q = q.eq("campaign_id", Number(campaignIds[0]));
        else if (campaignIds.length > 1) q = q.in("campaign_id", campaignIds.map((x) => Number(x)));
        if (status) q = q.eq("status", status);
        else q = q.neq("status", "transferred_out"); // 預設隱藏已轉出（5a-1：視同關閉、金額/數量不入統計）
        if (storeId) q = q.eq("pickup_store_id", Number(storeId));

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) { setError(error.message); return; }
        setError(null);
        setRows((data ?? []) as Row[]);
        setTotal(count ?? 0);

        const ids = (data ?? []).map((r) => r.id);
        const memIds = Array.from(new Set((data ?? []).map((r) => r.member_id).filter((x): x is number => x != null)));
        const [ic, ms, pr] = await Promise.all([
          ids.length
            ? getSupabase().from("customer_order_items").select("order_id, qty, unit_price, sku:skus(product_name, variant_name)").in("order_id", ids)
            : Promise.resolve({ data: [] as { order_id: number; qty: number; unit_price: number; sku: { product_name: string | null; variant_name: string | null } | null }[] }),
          memIds.length
            ? getSupabase().from("members").select("id, name, phone, member_no, avatar_url").in("id", memIds)
            : Promise.resolve({ data: [] as Member[] }),
          ids.length
            ? getSupabase().from("v_order_pickup_ready").select("order_id, pickup_ready").in("order_id", ids)
            : Promise.resolve({ data: [] as { order_id: number; pickup_ready: boolean }[] }),
        ]);
        const im = new Map<number, { lineCount: number; totalQty: number; totalAmount: number; items: { product_name: string | null; variant_name: string | null; qty: number }[] }>();
        for (const id of ids) im.set(id, { lineCount: 0, totalQty: 0, totalAmount: 0, items: [] });
        for (const it of (ic.data as { order_id: number; qty: number; unit_price: number; sku: { product_name: string | null; variant_name: string | null } | null }[]) ?? []) {
          const cur = im.get(it.order_id) ?? { lineCount: 0, totalQty: 0, totalAmount: 0, items: [] };
          cur.lineCount += 1;
          cur.totalQty += Number(it.qty);
          cur.totalAmount += Number(it.qty) * Number(it.unit_price);
          cur.items.push({
            product_name: it.sku?.product_name ?? null,
            variant_name: it.sku?.variant_name ?? null,
            qty: Number(it.qty),
          });
          im.set(it.order_id, cur);
        }
        const mm = new Map<number, Member>();
        for (const m of (ms.data as Member[]) ?? []) mm.set(m.id, m);
        const prMap = new Map<number, boolean>();
        for (const row of (pr.data as { order_id: number; pickup_ready: boolean }[]) ?? []) {
          prMap.set(row.order_id, row.pickup_ready);
        }
        if (!cancelled) { setItemSummary(im); setMembers(mm); setPickupReady(prMap); }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [campaignIds, status, storeId, page, reloadOrders]);

  const campaignMap = useMemo(() => new Map(campaigns.map((c) => [c.id, c])), [campaigns]);
  const storeMap = useMemo(() => new Map(stores.map((s) => [s.id, s])), [stores]);

  // 批次取貨 — 抓所有勾選訂單的 pickable items, 連續呼 rpc_record_pickup,
  // 收集 event_ids,最後開一個合併的列印頁(/pickup/print?event_ids=a,b,c)
  const pickableRows = useMemo(
    () =>
      (rows ?? []).filter(
        (r) =>
          pickupReady.get(r.id) === true &&
          !["completed", "expired", "cancelled", "transferred_out"].includes(r.status),
      ),
    [rows, pickupReady],
  );
  const allPickableSelected =
    pickableRows.length > 0 && pickableRows.every((r) => selected.has(r.id));

  function toggleAllPickable() {
    if (allPickableSelected) setSelected(new Set());
    else setSelected(new Set(pickableRows.map((r) => r.id)));
  }
  function toggleSelected(id: number) {
    setSelected((s) => {
      const next = new Set(s);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  async function bulkPickup() {
    if (selected.size === 0) return;
    if (!confirm(`對 ${selected.size} 筆訂單執行取貨並列印整合單?`)) return;
    setBulkBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) {
        alert("尚未登入");
        return;
      }
      const orderIds = Array.from(selected);
      const { data: itemsData, error: ie } = await sb
        .from("customer_order_items")
        .select("id, order_id, status")
        .in("order_id", orderIds)
        .in("status", ["pending", "reserved", "ready"]);
      if (ie) {
        alert(`抓 items 失敗：${ie.message}`);
        return;
      }
      const itemsByOrder = new Map<number, number[]>();
      for (const it of (itemsData ?? []) as { id: number; order_id: number }[]) {
        const list = itemsByOrder.get(it.order_id) ?? [];
        list.push(it.id);
        itemsByOrder.set(it.order_id, list);
      }
      const eventIds: number[] = [];
      const failed: { id: number; msg: string }[] = [];
      for (const oid of orderIds) {
        const itemIds = itemsByOrder.get(oid) ?? [];
        if (itemIds.length === 0) continue;
        const { data, error } = await sb.rpc("rpc_record_pickup", {
          p_order_id: oid,
          p_item_ids: itemIds,
          p_operator: operator,
          p_notes: null,
        });
        if (error) {
          failed.push({ id: oid, msg: translateRpcError(error) });
          continue;
        }
        const result = data as { event_id: number };
        eventIds.push(result.event_id);
      }
      if (eventIds.length > 0) {
        window.open(
          withBasePath(`/pickup/print?event_ids=${eventIds.join(",")}`),
          "_blank",
        );
      }
      if (failed.length > 0) {
        alert(
          `已完成 ${eventIds.length} 筆\n失敗 ${failed.length} 筆:\n` +
            failed.map((f) => `#${f.id}: ${f.msg}`).join("\n"),
        );
      } else if (eventIds.length === 0) {
        alert("沒有可取的項目");
      }
      setSelected(new Set());
      setReloadOrders((n) => n + 1);
    } finally {
      setBulkBusy(false);
    }
  }

  async function cancelOrder(orderId: number, orderNo: string, status: string) {
    const reason = prompt(
      status === "shipping"
        ? `撤回派貨：${orderNo}\n會反向回收已出庫存，請輸入原因：`
        : `取消訂單：${orderNo}\n請輸入取消原因：`
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { error: rpcErr } = await sb.rpc("rpc_cancel_aid_order", {
      p_order_id: orderId,
      p_reason: reason,
      p_operator: operator,
    });
    if (rpcErr) { alert(`取消失敗：${translateRpcError(rpcErr)}`); return; }
    alert("已取消");
    setReloadOrders((n) => n + 1);
  }
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">訂單</h1>
          <p className="text-sm text-zinc-500">
            {loading ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（${fromIdx}-${toIdx}）`}
          </p>
        </div>
      </header>

      <div className="grid gap-3 sm:grid-cols-3">
        <div className="relative">
          <button
            type="button"
            onClick={() => setCampaignPickerOpen((v) => !v)}
            className="flex w-full items-center justify-between rounded-md border border-zinc-300 bg-white px-3 py-2 text-left text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <span className="truncate">
              {campaignIds.length === 0
                ? "全部開團"
                : campaignIds.length === 1
                ? campaigns.find((c) => String(c.id) === campaignIds[0])?.name ?? `團 ${campaignIds[0]}`
                : `已選 ${campaignIds.length} 個開團`}
            </span>
            <span className="ml-2 text-zinc-400">▾</span>
          </button>
          {campaignPickerOpen && (
            <div className="absolute z-20 mt-1 max-h-80 w-full overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
              <div className="sticky top-0 flex justify-between border-b border-zinc-200 bg-white px-3 py-2 text-xs dark:border-zinc-800 dark:bg-zinc-900">
                <button
                  onClick={() => setCampaignIds([])}
                  className="text-blue-600 hover:underline dark:text-blue-400"
                >
                  全部清除
                </button>
                <button
                  onClick={() => setCampaignPickerOpen(false)}
                  className="text-zinc-500 hover:text-zinc-700 dark:text-zinc-400"
                >
                  關閉
                </button>
              </div>
              {campaigns.map((c) => {
                const checked = campaignIds.includes(String(c.id));
                return (
                  <label
                    key={c.id}
                    className="flex cursor-pointer items-center gap-2 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-950"
                  >
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={(e) => {
                        const id = String(c.id);
                        setCampaignIds((cur) =>
                          e.target.checked ? [...cur, id] : cur.filter((x) => x !== id),
                        );
                      }}
                    />
                    <span className="font-mono text-xs text-zinc-500">{c.campaign_no}</span>
                    <span className="truncate">{c.name}</span>
                  </label>
                );
              })}
            </div>
          )}
        </div>
        <select value={status} onChange={(e) => setStatus(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部狀態</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
        <select value={storeId} onChange={(e) => setStoreId(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部取貨店</option>
          {stores.map((s) => <option key={s.id} value={s.id}>{s.name} ({s.code})</option>)}
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p><p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      {/* 批次取貨工具列 — 至少有一張可取的訂單時才出現 */}
      {pickableRows.length > 0 && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 dark:border-emerald-900 dark:bg-emerald-950">
          <div className="flex items-center gap-2 text-xs">
            <input
              type="checkbox"
              checked={allPickableSelected}
              onChange={toggleAllPickable}
              className="h-4 w-4"
            />
            <span className="text-zinc-700 dark:text-zinc-200">
              全選可取訂單
              <span className="ml-1 text-zinc-500">
                (本頁可取 {pickableRows.length} 筆 · 已選 {selected.size})
              </span>
            </span>
          </div>
          <div className="flex items-center gap-2">
            {selected.size > 0 && (
              <button
                onClick={() => setSelected(new Set())}
                className="text-xs text-zinc-600 hover:underline dark:text-zinc-300"
              >
                取消選取
              </button>
            )}
            <button
              onClick={bulkPickup}
              disabled={selected.size === 0 || bulkBusy}
              className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-emerald-300 disabled:text-emerald-700 dark:disabled:bg-emerald-950 dark:disabled:text-emerald-400"
            >
              {bulkBusy ? "處理中…" : `✅ 取貨並列印整合單${selected.size > 0 ? ` (${selected.size})` : ""}`}
            </button>
          </div>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th className="w-10">
                <input
                  type="checkbox"
                  checked={allPickableSelected}
                  onChange={toggleAllPickable}
                  disabled={pickableRows.length === 0}
                  className="h-4 w-4"
                  aria-label="全選可取訂單"
                />
              </Th>
              <Th>開團</Th><Th>會員 / 暱稱</Th><Th>取貨店</Th><Th className="text-right">項數</Th><Th className="text-right">總數量</Th><Th className="text-right">總金額</Th><Th className="text-right">日期</Th><Th className="text-right">操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={9} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">{total === 0 && campaignIds.length === 0 && !status && !storeId ? "尚無訂單。" : "沒有符合條件的訂單。"}</td></tr>
            ) : rows.map((r) => {
              const m = r.member_id ? members.get(r.member_id) : null;
              const c = campaignMap.get(r.campaign_id);
              const s = storeMap.get(r.pickup_store_id);
              return (
                <tr
                  key={r.id}
                  className={
                    r.status === "cancelled"
                      ? "bg-red-50 hover:bg-red-100 dark:bg-red-950/30 dark:hover:bg-red-950/50"
                      : r.status === "expired"
                      ? "bg-amber-50 hover:bg-amber-100 dark:bg-amber-950/30 dark:hover:bg-amber-950/50"
                      : r.status === "transferred_out"
                      ? "bg-zinc-100 text-zinc-500 hover:bg-zinc-200 dark:bg-zinc-900 dark:text-zinc-500 dark:hover:bg-zinc-800"
                      : "odd:bg-white even:bg-zinc-50 hover:bg-zinc-100 dark:odd:bg-zinc-950 dark:even:bg-zinc-900 dark:hover:bg-zinc-800"
                  }
                >
                  <Td className="w-10">
                    {pickupReady.get(r.id) === true &&
                      !["completed", "expired", "cancelled", "transferred_out"].includes(
                        r.status,
                      ) && (
                        <input
                          type="checkbox"
                          checked={selected.has(r.id)}
                          onChange={() => toggleSelected(r.id)}
                          className="h-4 w-4"
                          aria-label={`選取訂單 ${r.order_no}`}
                        />
                      )}
                  </Td>
                  <Td>
                    <button
                      onClick={() => { setDetailId(r.id); setDetailNo(r.order_no); }}
                      className="block w-full text-left hover:underline"
                      title={r.order_no}
                    >
                      {c ? (
                        <div className="flex items-start gap-2">
                          <CoverThumb src={c.cover_image_url} alt={c.name} />
                          <div className="min-w-0 flex-1 space-y-0.5">
                            <div className="text-xs text-zinc-500 break-words">{c.name}</div>
                            {(itemSummary.get(r.id)?.items ?? []).map((it, idx) => (
                              <div
                                key={idx}
                                className="break-words text-base font-bold text-zinc-900 dark:text-zinc-100"
                              >
                                {it.variant_name || it.product_name || "—"}
                                <span className="ml-1.5 text-xs font-normal text-zinc-500">
                                  × {it.qty}
                                </span>
                              </div>
                            ))}
                          </div>
                        </div>
                      ) : "—"}
                    </button>
                  </Td>
                  <Td>
                    {m ? (
                      <span className="flex items-center gap-2">
                        <Avatar src={m.avatar_url} name={m.name ?? r.nickname_snapshot ?? "?"} />
                        <span className="min-w-0">
                          <Link href={`/members/detail?id=${m.id}`} className="hover:underline">{m.name ?? "—"}</Link>
                          <span className="ml-1 font-mono text-xs text-zinc-500">{m.phone}</span>
                        </span>
                      </span>
                    ) : r.nickname_snapshot ? (
                      <span className="flex items-center gap-2">
                        <Avatar src={null} name={r.nickname_snapshot} />
                        <span className="text-zinc-500">({r.nickname_snapshot})</span>
                      </span>
                    ) : "—"}
                  </Td>
                  <Td className="text-xs">{s?.name ?? "—"}</Td>
                  <Td className="text-right font-mono">{itemSummary.get(r.id)?.lineCount ?? 0}</Td>
                  <Td className="text-right font-mono">{itemSummary.get(r.id)?.totalQty ?? 0}</Td>
                  <Td className="text-right font-mono">${itemSummary.get(r.id)?.totalAmount ?? 0}</Td>
                  <Td
                    className="text-right text-xs text-zinc-500"
                    title={`訂單日：${new Date(r.created_at).toLocaleString("zh-TW", { hour12: false })}\n更新日：${new Date(r.updated_at).toLocaleString("zh-TW", { hour12: false })}`}
                  >
                    <div>訂 {new Date(r.created_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" })}</div>
                    <div>更 {new Date(r.updated_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" })}</div>
                  </Td>
                  <Td className="text-right">
                    <div className="flex items-center justify-end gap-1">
                      {!["completed","expired","cancelled","transferred_out"].includes(r.status) && (() => {
                        // 取貨判斷改用 v_order_pickup_ready (基於分店收貨 transfer 實際狀態)
                        // 不再依賴 customer_orders.status === 'ready'（status 同步可能漏推）
                        const canPickup = pickupReady.get(r.id) === true;
                        return (
                          <button
                            onClick={() => setPickup({ id: r.id, no: r.order_no })}
                            disabled={!canPickup}
                            title={canPickup ? undefined : "分店尚未收貨，無法取貨"}
                            className="rounded-md bg-emerald-600 px-2 py-1 text-[11px] font-medium text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-emerald-200 disabled:text-emerald-700 disabled:hover:bg-emerald-200 dark:disabled:bg-emerald-950 dark:disabled:text-emerald-400 dark:disabled:hover:bg-emerald-950"
                          >
                            ✅ 取貨
                          </button>
                        );
                      })()}
                      {["pending", "confirmed", "shipping"].includes(r.status) && (
                        <button
                          onClick={() => cancelOrder(r.id, r.order_no, r.status)}
                          title={r.status === "shipping" ? "撤回派貨並反向回收已出庫存" : "取消訂單"}
                          className="rounded-md bg-red-600 px-2 py-1 text-[11px] font-medium text-white hover:bg-red-700"
                        >
                          取消
                        </button>
                      )}
                      {r.status === "cancelled" && (
                        <button
                          disabled
                          title="此訂單已取消"
                          className="rounded-md bg-red-200 px-2 py-1 text-[11px] font-medium text-red-700 cursor-not-allowed dark:bg-red-950 dark:text-red-300"
                        >
                          已取消
                        </button>
                      )}
                      {r.status === "expired" && (
                        <button
                          disabled
                          title="此訂單已逾期"
                          className="rounded-md bg-amber-200 px-2 py-1 text-[11px] font-medium text-amber-800 cursor-not-allowed dark:bg-amber-950 dark:text-amber-300"
                        >
                          已逾期
                        </button>
                      )}
                      {r.status === "completed" && (
                        <button
                          disabled
                          title="此訂單已完成"
                          className="rounded-md bg-emerald-200 px-2 py-1 text-[11px] font-medium text-emerald-800 cursor-not-allowed dark:bg-emerald-950 dark:text-emerald-300"
                        >
                          已完成
                        </button>
                      )}
                      {r.status === "transferred_out" && (
                        <button
                          disabled
                          title="此訂單已轉出"
                          className="rounded-md bg-zinc-300 px-2 py-1 text-[11px] font-medium text-zinc-700 cursor-not-allowed dark:bg-zinc-700 dark:text-zinc-300"
                        >
                          已轉出
                        </button>
                      )}
                    </div>
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {pickup && (
        <PickupDialog
          open={true}
          onClose={() => setPickup(null)}
          orderId={pickup.id}
          orderNo={pickup.no}
          onPickedUp={(r) => {
            setPickup(null);
            alert(`取貨完成 (${r.picked_count} 項)\n訂單狀態：${STATUS_LABEL[r.new_order_status as OrderStatus] ?? r.new_order_status}`);
            setReloadOrders((n) => n + 1);
          }}
        />
      )}

      <Modal
        open={detailId !== null}
        onClose={() => setDetailId(null)}
        title={`訂單明細 ${detailNo}`}
        maxWidth="max-w-4xl"
      >
        {detailId !== null && (
          <OrderDetail
            orderId={detailId}
            onNavigate={(id, no) => {
              setDetailId(id);
              setDetailNo(no);
            }}
          />
        )}
      </Modal>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn disabled={page === 1} onClick={() => setPage(1)}>« 第一頁</PagerBtn>
          <PagerBtn disabled={page === 1} onClick={() => setPage((p) => p - 1)}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage((p) => p + 1)}>下頁 ›</PagerBtn>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage(totalPages)}>最末頁 »</PagerBtn>
        </div>
      )}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "", title }: { children: React.ReactNode; className?: string; title?: string }) {
  return <td className={`px-4 py-3 ${className}`} title={title}>{children}</td>;
}
function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return <button onClick={onClick} disabled={disabled} className="rounded-md border border-zinc-300 px-2 py-1 transition-colors hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800">{children}</button>;
}
function CoverThumb({ src, alt }: { src: string | null; alt: string }) {
  if (!src) {
    return (
      <span
        aria-hidden
        className="flex h-10 w-10 flex-shrink-0 items-center justify-center rounded bg-zinc-100 text-xs text-zinc-400 dark:bg-zinc-800 dark:text-zinc-500"
      >
        ▦
      </span>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt={alt}
      className="h-10 w-10 flex-shrink-0 rounded object-cover"
      onError={(e) => {
        (e.currentTarget as HTMLImageElement).style.display = "none";
      }}
    />
  );
}
function Avatar({ src, name }: { src: string | null; name: string }) {
  const initial = name.trim().charAt(0) || "?";
  if (!src) {
    return (
      <span
        aria-hidden
        className="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-full bg-zinc-200 text-xs font-medium text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
      >
        {initial}
      </span>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt=""
      referrerPolicy="no-referrer"
      className="h-8 w-8 flex-shrink-0 rounded-full object-cover"
      onError={(e) => {
        const el = e.currentTarget as HTMLImageElement;
        el.style.display = "none";
      }}
    />
  );
}
function StatusBadge({ s }: { s: OrderStatus }) {
  const st: Record<OrderStatus, string> = {
    pending: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
    reserved: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
    shipping: "bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300",
    ready: "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
    partially_ready: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
    partially_completed: "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300",
    completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
    expired: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
    transferred_out: "bg-zinc-300 text-zinc-700 line-through dark:bg-zinc-700 dark:text-zinc-400",
  };
  return <span className={`inline-block rounded px-2 py-0.5 text-xs ${st[s]}`}>{STATUS_LABEL[s]}</span>;
}
